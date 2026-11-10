@tool
class_name CFDesign
extends RefCounted

## The tool's own schema for a card or a relic, plus normalisation, validation
## and description rendering.
##
## A design is a plain [Dictionary] rather than a Resource subclass on purpose:
## it keeps UndoRedo snapshots, JSON persistence and the exporter trivial, and it
## mirrors the shape of the game's own data closely enough to map 1:1.
##
## Nothing here hardcodes an enum member. Every value written into a design comes
## from [CFSchema], which was reverse-inferred from the unpacked game source.

const KIND_CARD := "card"
const KIND_RELIC := "relic"

const SEV_ERROR := "error"
const SEV_WARNING := "warning"
const SEV_INFO := "info"

## Every formatter name the game registers with SmartFormat. Verified against
## `MegaCrit.Sts2.Core.Localization.LocManager` (the `AddExtensions` list), the
## `Name` property of each class in `Core/Localization/Formatters/`, and the
## union of the specs used by the shipped `localization/*/*.json` tables.
##
## This list exists because a description is rendered *in game* by SmartFormat: a
## single unknown formatter makes the whole string throw, so the card shows no
## text at all and the only trace is this in the game log:
##   Localization formatting error! Error parsing format string:
##   No formatter with name 'difff' found at 0
## The tool's own preview used to accept any spec and quietly substitute a
## number, so a typo like `{Value3:difff()}` looked fine in the tool and shipped.
const FORMATTER_NAMES := [
	"abs", "choose", "cond", "conditional", "default", "diff", "energyIcons",
	"inverseDiff", "ismatch", "list", "locale", "n", "percentLess",
	"percentMore", "plural", "show", "starIcons", "substring",
]

## One-line reminder of the same names, for issue messages and UI hints.
const FORMATTER_HINT := "diff / plural / choose / cond / substring / ismatch / show / energyIcons / starIcons / abs / percentMore / percentLess / inverseDiff / n"

## Variable names the game injects into a card/relic description *on top of* the
## vars the author declares. Read off the `variables={...}` line the game logs
## for a card, plus the vanilla localization tables.
const ENGINE_VARS := [
	"IfUpgraded", "OnTable", "InCombat", "IsTargeting", "TargetType",
	"GainsBlock", "IsOstyAlive", "energyPrefix", "singleStarIcon",
]

static var _placeholder_regex: RegEx = null
static var _ident_regex: RegEx = null


# ---------------------------------------------------------------------------
# Factories
# ---------------------------------------------------------------------------

static func new_card(schema: CFSchema, pool_id: String = "") -> Dictionary:
	var type_member := _preferred(schema, "card_type", ["Attack", "Skill", "Power"])
	var rarity_member := _preferred(schema, "card_rarity", ["Common", "Basic"])
	var target_member := _preferred(schema, "target_type", ["AnyEnemy", "Self"])
	var value_prop := _preferred(schema, "value_prop", ["Move"])
	return {
		"kind": KIND_CARD,
		"id": "",
		"entry": "",
		"pool": _default_pool(schema, pool_id, false),
		"type": type_member,
		"rarity": rarity_member,
		"target": target_member,
		"cost": 1,
		"star_cost": -1,
		"has_x_cost": false,
		"keywords": [],
		"tags": [],
		"max_upgrade_level": 1,
		"text": _empty_text(KIND_CARD),
		"art": {"portrait": "", "atlas": "", "use_auto": true},
		"vars": [new_var("Damage", "Damage", "DamageVar", 6.0, value_prop)],
		"effects": [],
		"upgrade": {
			"cost_delta": 0,
			"keywords_add": [],
			"keywords_remove": [],
			"var_deltas": [],
			"text_override": _empty_text(KIND_CARD),
		},
		# Starting-deck / starting-relic injection.
		"deck": {"enabled": false, "character": "", "copies": 1},
		"flags": {
			"show_in_card_library": true,
			"gains_block": false,
		},
		"notes": "",
		"created": Time.get_datetime_string_from_system(),
		"modified": Time.get_datetime_string_from_system(),
	}


static func new_relic(schema: CFSchema, pool_id: String = "") -> Dictionary:
	var rarity_member := _preferred(schema, "relic_rarity", ["Common", "Starter"])
	var hook := _preferred_hook(schema, ["AfterObtained", "BeforeCombatStart"])
	return {
		"kind": KIND_RELIC,
		"id": "",
		"entry": "",
		"pool": _default_pool(schema, pool_id, true),
		"rarity": rarity_member,
		"stackable": false,
		"show_counter": false,
		"counter_period": 3,
		"text": _empty_text(KIND_RELIC),
		"art": {"icon": "", "atlas": "", "use_auto": true},
		"vars": [],
		"triggers": [
			{
				"hook": hook,
				"params": _default_param_bindings(schema, hook),
				"condition": new_condition(),
				"charge": {"mode": "always", "n": 1},
				"loop": {"mode": "none", "count": 1, "var": ""},
				"effects": [],
				"note": "",
			},
		],
		# Starting-relic injection.
		"deck": {"enabled": false, "character": ""},
		"notes": "",
		"created": Time.get_datetime_string_from_system(),
		"modified": Time.get_datetime_string_from_system(),
	}


static func new_var(name: String, kind: String, type_name: String, base: float,
		value_prop: String = "", generic: String = "") -> Dictionary:
	return {
		"name": name,
		"kind": kind,
		"type": type_name,
		"generic": generic,
		"base": base,
		"value_prop": value_prop,
		"upgrade_delta": 0.0,
	}


static func new_condition() -> Dictionary:
	# `right` is a **string**: it may be a number or another variable name, and the
	# raw JSON float is what used to make the emitter throw on `String(2.0)`.
	return {"mode": "none", "left": "", "op": ">=", "right": "", "note": ""}


static func new_effect(kind: String) -> Dictionary:
	return {
		"id": _uid(),
		"kind": kind,
		"enabled": true,
		"target": "",
		"amount": 0.0,
		"amount_var": "",
		"amount_is_var": false,
		"hits": 1,
		"value_prop": "",
		"power": "",
		"pile": "",
		"position": "",
		"card_entry": "",
		"keyword": "",
		"condition": new_condition(),
		"loop": {"mode": "none", "count": 1, "var": ""},
		"note": "",
	}


## Bind a hook's parameters to the expressions the effect emitter will use, so a
## relic trigger can address `creature`, `card`, `player`, … from the effect
## target picker instead of hardcoding `base.Owner.Creature`.
static func _default_param_bindings(schema: CFSchema, hook_name: String) -> Dictionary:
	var h := schema.hook(hook_name)
	var out: Dictionary = {}
	for p in h.get("params", []):
		var raw := String(p)
		var sp := raw.find(" ")
		if sp <= 0:
			continue
		var type_name := raw.substr(0, sp).strip_edges()
		var var_name := raw.substr(sp + 1).strip_edges().trim_prefix("?")
		var eq := var_name.find("=")
		if eq >= 0:
			var_name = var_name.substr(0, eq).strip_edges()
		out[var_name] = _guess_binding(type_name)
	return out


static func _guess_binding(type_name: String) -> String:
	var base := type_name.trim_suffix("?").trim_prefix("IReadOnlyList<").trim_suffix(">").trim_prefix("IEnumerable<").trim_suffix(">")
	match base:
		"PlayerChoiceContext": return "_choice"
		"Player": return "_player"
		"Creature": return "_creature"
		"CardModel": return "_card"
		"CardPlay": return "_cardPlay"
		"PowerModel": return "_power"
		"CombatSide": return "_side"
		"decimal", "float", "int": return "_amount"
		_: return "_" + CFIds.snake_case(base)


static func _empty_text(kind: String) -> Dictionary:
	var out := {}
	for locale in CFSchema.LOCALES:
		var entry := {}
		for field in CFSchema.LOC_FIELDS[kind]:
			entry[field] = ""
		out[locale] = entry
	return out


static func _uid() -> String:
	return "%d_%d" % [Time.get_ticks_usec(), randi() % 100000]


# ---------------------------------------------------------------------------
# Normalisation
# ---------------------------------------------------------------------------

static func normalize(schema: CFSchema, item: Dictionary) -> Dictionary:
	var kind := KIND_RELIC if String(item.get("kind", KIND_CARD)) == KIND_RELIC else KIND_CARD
	item["kind"] = kind
	item["id"] = String(item.get("id", "")).strip_edges()
	item["entry"] = CFIds.slugify(item["id"])
	item["modified"] = Time.get_datetime_string_from_system()
	if not item.has("art") or not (item["art"] is Dictionary):
		item["art"] = {}
	if not item.has("deck") or not (item["deck"] is Dictionary):
		item["deck"] = {}

	if kind == KIND_CARD:
		item["type"] = _coerce(schema, item.get("type", ""), "card_type")
		item["rarity"] = _coerce(schema, item.get("rarity", ""), "card_rarity")
		item["target"] = _coerce(schema, item.get("target", ""), "target_type")
		item["keywords"] = _coerce_list(schema, item.get("keywords", []), "card_keyword")
		item["tags"] = _coerce_list(schema, item.get("tags", []), "card_tag")
		item["cost"] = int(item.get("cost", 1))
		item["star_cost"] = int(item.get("star_cost", -1))
		item["has_x_cost"] = bool(item.get("has_x_cost", false))
		item["max_upgrade_level"] = maxi(1, int(item.get("max_upgrade_level", 1)))
		if not item.has("flags") or not (item["flags"] is Dictionary):
			item["flags"] = {}
	else:
		item["rarity"] = _coerce(schema, item.get("rarity", ""), "relic_rarity")

	# Text table.
	var text: Dictionary = item.get("text", {}) if item.get("text") is Dictionary else {}
	for locale in CFSchema.LOCALES:
		if not text.has(locale) or not (text[locale] is Dictionary):
			text[locale] = {}
		for field in CFSchema.LOC_FIELDS[kind]:
			if not text[locale].has(field):
				text[locale][field] = ""
	item["text"] = text

	# Vars.
	var vars: Array = item.get("vars", []) if item.get("vars") is Array else []
	for v in vars:
		v["value_prop"] = _coerce(schema, v.get("value_prop", ""), "value_prop")
		v["base"] = float(v.get("base", 0.0))
		v["upgrade_delta"] = float(v.get("upgrade_delta", 0.0))
		# `kind` is the tool's own short label for a var and must always agree
		# with `type`: the exporter emits the C# class from `type`, while
		# `var_values` special-cases `{Damage}` on `kind`. Letting the two drift
		# meant changing the type left a stale kind behind, so `{Damage:diff()}`
		# stopped resolving. Derive it instead of storing it independently.
		v["kind"] = _var_kind_from_type(String(v.get("type", "")), String(v.get("kind", "")))
	item["vars"] = vars

	# Effects.
	var effects: Array = item.get("effects", []) if item.get("effects") is Array else []
	for e in effects:
		_normalize_effect(schema, e)
	if kind == KIND_CARD:
		item["effects"] = effects
		var up: Dictionary = item.get("upgrade", {}) if item.get("upgrade") is Dictionary else {}
		up["cost_delta"] = int(up.get("cost_delta", 0))
		up["keywords_add"] = _coerce_list(schema, up.get("keywords_add", []), "card_keyword")
		up["keywords_remove"] = _coerce_list(schema, up.get("keywords_remove", []), "card_keyword")
		if not (up.get("var_deltas") is Array):
			up["var_deltas"] = []
		if not (up.get("text_override") is Dictionary):
			up["text_override"] = _empty_text(KIND_CARD)
		item["upgrade"] = up
	else:
		var triggers: Array = item.get("triggers", []) if item.get("triggers") is Array else []
		for t in triggers:
			var hook := String(t.get("hook", ""))
			if not hook.is_empty() and schema.hook(hook).is_empty():
				t["hook"] = ""
			if not (t.get("params") is Dictionary):
				t["params"] = _default_param_bindings(schema, String(t.get("hook", "")))
			if not (t.get("condition") is Dictionary):
				t["condition"] = new_condition()
			if not (t.get("charge") is Dictionary):
				t["charge"] = {"mode": "always", "n": 1}
			if not (t.get("loop") is Dictionary):
				t["loop"] = {"mode": "none", "count": 1, "var": ""}
			var teff: Array = t.get("effects", []) if t.get("effects") is Array else []
			for e in teff:
				_normalize_effect(schema, e)
			t["effects"] = teff
		item["triggers"] = triggers

	item["art"] = resolve_art(schema, item)
	return item


static func _normalize_effect(schema: CFSchema, e: Dictionary) -> void:
	e["enabled"] = bool(e.get("enabled", true))
	e["amount"] = float(e.get("amount", 0.0))
	e["hits"] = maxi(1, int(e.get("hits", 1)))
	e["amount_is_var"] = bool(e.get("amount_is_var", false))
	e["value_prop"] = _coerce(schema, e.get("value_prop", ""), "value_prop")
	e["pile"] = _coerce(schema, e.get("pile", ""), "pile_type")
	e["position"] = _coerce(schema, e.get("position", ""), "pile_position")
	e["keyword"] = _coerce(schema, e.get("keyword", ""), "card_keyword")
	if not (e.get("condition") is Dictionary):
		e["condition"] = new_condition()
	else:
		# A design saved by an earlier version has `right` as a JSON number; the
		# emitter and the simulator both want a token string.
		var cond: Dictionary = e["condition"]
		cond["mode"] = String(cond.get("mode", "none"))
		cond["op"] = String(cond.get("op", ">="))
		cond["left"] = CFEffects._token(cond.get("left", ""))
		cond["right"] = CFEffects._token(cond.get("right", ""))
	if not (e.get("loop") is Dictionary):
		e["loop"] = {"mode": "none", "count": 1, "var": ""}
	if String(e.get("id", "")).is_empty():
		e["id"] = _uid()


## Short label for a dynamic var, derived from its C# class name.
##
## "DamageVar" -> "Damage", "RepeatVar" -> "Repeat". `var_values()` keys the
## `{Damage}` placeholder off this, so it must track `type` rather than being
## stored as an independent field.
static func _var_kind_from_type(type_name: String, fallback: String = "") -> String:
	if type_name.is_empty():
		return fallback
	if type_name.ends_with("Var"):
		return type_name.substr(0, type_name.length() - 3)
	return type_name


static func _coerce(schema: CFSchema, value: Variant, role: String) -> String:
	var s := String(value)
	var members := schema.members_for_role(role)
	if members.is_empty():
		return s
	if members.has(s):
		return s
	for m in members:
		if m != "None":
			return m
	return members[0]


static func _coerce_list(schema: CFSchema, values: Variant, role: String) -> Array:
	var members := schema.members_for_role(role)
	var out: Array = []
	if values is Array:
		for v in values:
			var s := String(v)
			if members.is_empty() or members.has(s):
				if not out.has(s):
					out.append(s)
	return out


static func _preferred(schema: CFSchema, role: String, prefer: Array) -> String:
	var members := schema.members_for_role(role)
	for p in prefer:
		if members.has(p):
			return p
	for m in members:
		if m != "None":
			return m
	return ""


static func _preferred_hook(schema: CFSchema, prefer: Array) -> String:
	var usable := schema.usable_hooks()
	for p in prefer:
		for h in usable:
			if String(h["name"]) == p:
				return p
	return String(usable[0]["name"]) if not usable.is_empty() else ""


static func _default_pool(schema: CFSchema, requested: String, relic: bool) -> String:
	var pools := schema.relic_pools if relic else schema.card_pools
	if not requested.is_empty():
		for p in pools:
			if String(p.get("class_name", "")) == requested:
				return requested
	# Prefer a character pool: a card in no pool throws when its Pool is read.
	for p in pools:
		if not bool(p.get("is_colorless", false)) and not String(p.get("character", "")).is_empty():
			return String(p.get("class_name", ""))
	if not pools.is_empty():
		return String(pools[0].get("class_name", ""))
	return ""


# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------

## The `<Pool.Title>` path segment of every card art path.
##
## The game builds card art paths from `CardPoolModel.Title`, which is a
## lowercase id that is *not* always the class name lowercased
## (`IroncladCardPool.Title == "ironclad"`). Prefer the literal the schema
## scanner read out of the pool's source and fall back to stripping the `CardPool`
## suffix, which is right for every normal pool and lets an already-scanned
## (older) schema cache keep working.
static func pool_art_name(schema: CFSchema, pool_class: String) -> String:
	if pool_class.is_empty():
		return ""
	if schema != null:
		var p := schema.pool_by_class(pool_class, false)
		if not p.is_empty():
			var scanned := String(p.get("art_name", ""))
			if not scanned.is_empty():
				return scanned
	return CFIds.snake_case(pool_class.trim_suffix("CardPool"))


## Convention-based art paths, matching exactly where the game looks for a card
## portrait and a relic icon. Paths are relative to the game's resource root.
##
## Verified against `CardModel` / `RelicModel` / `AtlasResourceLoader`:
##
##   CardModel.PortraitPngPath = images/packed/card_portraits/<Pool.Title>/<entry>.png
##   CardModel.PortraitPath    = images/atlases/card_atlas.sprites/<Pool.Title>/<entry>.tres
##   RelicModel.BigIconPath    = images/relics/<entry>.png
##   RelicModel.PackedIconPath = images/atlases/relic_atlas.sprites/<entry>.tres
##
## (`<entry>` is `ModelId.Entry.to_lower()`.) The card paths used to be written
## without the `packed/` prefix and without the pool segment, so they pointed at
## `images/card_portraits/wudi.png` — a path no code in the game ever reads. The
## portrait therefore always fell back to the missing-art placeholder and the log
## only said:
##   AtlasResourceLoader: Missing sprite 'ironclad/wudi' in card_atlas
static func resolve_art(schema: CFSchema, item: Dictionary) -> Dictionary:
	var is_relic := String(item.get("kind", "")) == KIND_RELIC
	var art: Dictionary = item.get("art", {}) if item.get("art") is Dictionary else {}
	if not art.has("use_auto"):
		art["use_auto"] = true
	if not bool(art["use_auto"]):
		return art
	var base := String(item.get("entry", "")).to_lower()
	if base.is_empty():
		return art
	if is_relic:
		art["icon"] = "images/relics/%s.png" % base
		art["atlas"] = "images/atlases/relic_atlas.sprites/%s.tres" % base
	else:
		var pool := pool_art_name(schema, String(item.get("pool", "")))
		if pool.is_empty():
			# Without a pool the game has no path to look at, so do not invent one.
			art["portrait"] = ""
			art["atlas"] = ""
			return art
		art["portrait"] = "images/packed/card_portraits/%s/%s.png" % [pool, base]
		art["atlas"] = "images/atlases/card_atlas.sprites/%s/%s.tres" % [pool, base]
	return art


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

## Returns an array of issues: { severity, field, message }.
static func validate(schema: CFSchema, item: Dictionary, others: Array = [],
		custom_characters: Array = []) -> Array:
	var issues: Array = []
	var is_relic := String(item.get("kind", "")) == KIND_RELIC
	var kind := KIND_RELIC if is_relic else KIND_CARD
	var id := String(item.get("id", "")).strip_edges()
	var entry := String(item.get("entry", ""))

	if id.is_empty():
		issues.append(_issue(SEV_ERROR, "id", "ID 不能为空：它同时决定 C# 类名、本地化键与素材文件名。"))
	elif not CFIds.is_valid_cs_identifier(id):
		issues.append(_issue(SEV_ERROR, "id",
				"“%s” 不是合法的 C# 标识符（需字母/下划线开头，仅含字母数字下划线，长度 ≤ 64，且不能是关键字）。" % id))

	if not entry.is_empty():
		if not is_relic and schema.existing_card_ids().has(entry):
			issues.append(_issue(SEV_ERROR, "id", "ID 与游戏自带卡牌冲突（%s）。请换一个 ID。" % entry))
		if is_relic and schema.existing_relic_ids().has(entry):
			issues.append(_issue(SEV_ERROR, "id", "ID 与游戏自带遗物冲突（%s）。请换一个 ID。" % entry))
		for other in others:
			if other == item:
				continue
			if String(other.get("kind", "")) == kind and String(other.get("entry", "")) == entry:
				issues.append(_issue(SEV_ERROR, "id", "ID 与另一个设计重复（%s）。" % entry))
				break

	var pool := String(item.get("pool", ""))
	if pool.is_empty():
		issues.append(_issue(SEV_ERROR, "pool",
				"必须选择一个卡池：卡牌不属于任何池时，游戏读取 Pool 会抛 InvalidProgramException。"))
	elif schema.pool_by_class(pool, is_relic).is_empty() and not _custom_pool_exists(pool, is_relic, custom_characters):
		issues.append(_issue(SEV_ERROR, "pool", "卡池 “%s” 不在当前 schema 中。" % pool))

	# Expose this item's declared variable names to `_validate_effect`, which
	# needs them to check "repeat by variable" loops. Cleared in `finally`-style
	# fashion below so a later call cannot read a stale item's vars.
	_current_var_names = []
	_current_scope = kind
	_current_vars = item.get("vars", [])
	for v in (item.get("vars", []) if item.get("vars") is Array else []):
		var vn := String((v as Dictionary).get("name", "")).strip_edges()
		if not vn.is_empty() and not _current_var_names.has(vn):
			_current_var_names.append(vn)

	_validate_vars(schema, item, issues)
	if is_relic:
		_validate_relic(schema, item, issues)
	else:
		_validate_card(schema, item, issues)

	_validate_localization(schema, item, kind, issues)
	_validate_deck(item, is_relic, schema, issues, custom_characters)

	_current_var_names = []
	_current_scope = ""
	_current_vars = []
	return issues


## Every `DynamicVar` a design declares must be one the game actually has, and a
## `PowerVar` must name a concrete power.
##
## `CFExporter.emit_var` can only emit a constructor that exists in the scanned
## sources. An unknown `type` used to sail through preflight and resurface as a
## compile error inside the user's freshly exported mod — with no hint that the
## culprit was a variable, let alone which one.
static func _validate_vars(schema: CFSchema, item: Dictionary, issues: Array) -> void:
	var vars: Variant = item.get("vars", [])
	if not (vars is Array):
		return
	var seen: Dictionary = {}
	for v in (vars as Array):
		if not (v is Dictionary):
			continue
		var d: Dictionary = v
		var type_name := String(d.get("type", ""))
		var generic := String(d.get("generic", ""))
		var vname := String(d.get("name", "")).strip_edges()
		if type_name.is_empty():
			issues.append(_issue(SEV_ERROR, "vars", "存在没有选择类型的数值变量。"))
			continue
		if vname.is_empty():
			issues.append(_issue(SEV_ERROR, "vars",
				"数值变量（%s）没有名字：描述里的 {%s} 永远匹配不上，导出时会写成空 key。" % [type_name, type_name]))
		elif seen.has(vname):
			issues.append(_issue(SEV_WARNING, "vars", "数值变量名 “%s” 重复了。" % vname))
		else:
			seen[vname] = true
		if type_name == "PowerVar" and generic.is_empty():
			issues.append(_issue(SEV_ERROR, "vars",
				"PowerVar 必须指定具体的 Power（例如 VulnerablePower），否则 new PowerVar<…> 无法编译。"))
			continue
		if type_name == "PowerVar" and not schema.power_error(generic).is_empty():
			issues.append(_issue(SEV_ERROR, "vars", schema.power_error(generic)))
		var known := false
		for t in schema.dynamic_var_types:
			if String(t.get("type", "")) == type_name:
				known = true
				break
		if not known:
			issues.append(_issue(SEV_ERROR, "vars",
				"“%s” 不是当前游戏版本里的 DynamicVar 类型，导出会生成不存在的构造调用。" % type_name))
		else:
			var ctor_info := schema.var_ctor_info(type_name, generic)
			if ctor_info.is_empty():
				issues.append(_issue(SEV_INFO, "vars",
					"没有扫描到 “%s” 的构造函数，导出会退回内置默认写法，请留意编译结果。" % type_name))
			elif not _has_emittable_ctor(ctor_info.get("ctors", [])):
				issues.append(_issue(SEV_ERROR, "vars",
					"“%s” 的构造函数包含工具无法提供的参数，不能安全导出。请改用带名称和数值的 DynamicVar 类型。" % type_name))
			elif not _has_named_ctor(ctor_info.get("ctors", [])):
				var default_name := String(ctor_info.get("default_name", ""))
				if default_name.is_empty():
					default_name = type_name.trim_suffix("Var")
				if vname != default_name:
					issues.append(_issue(SEV_ERROR, "vars",
						"“%s” 只有默认名称 “%s” 的构造函数，不能把它注册为 “%s”。请改用支持自定义名称的变量类型。"
						% [type_name, default_name, vname]))


static func _has_emittable_ctor(ctors: Array) -> bool:
	for ctor in ctors:
		if not (ctor is Array) or (ctor as Array).is_empty():
			continue
		var supported := true
		for p in (ctor as Array):
			if String(p) not in ["string", "decimal", "int", "bool", "ValueProp", "UpgradeDisplay"]:
				supported = false
				break
		if supported:
			return true
	return false


static func _has_named_ctor(ctors: Array) -> bool:
	for ctor in ctors:
		if (ctor is Array) and not (ctor as Array).is_empty() \
				and String((ctor as Array)[0]) == "string":
			return true
	return false


static func _validate_card(schema: CFSchema, card: Dictionary, issues: Array) -> void:
	var cost := int(card.get("cost", 0))
	if cost < -1 or cost > 9:
		issues.append(_issue(SEV_WARNING, "cost", "费用 %d 超出常规范围（-1 表示 X 费，0-9 为常规费用）。" % cost))
	if not schema.members_for_role("card_type").has(String(card.get("type", ""))):
		issues.append(_issue(SEV_ERROR, "type", "卡牌类型不在 schema 枚举中。"))
	if not schema.members_for_role("card_rarity").has(String(card.get("rarity", ""))):
		issues.append(_issue(SEV_ERROR, "rarity", "稀有度不在 schema 枚举中。"))
	if not schema.members_for_role("target_type").has(String(card.get("target", ""))):
		issues.append(_issue(SEV_ERROR, "target", "目标类型不在 schema 枚举中。"))

	var effects: Array = card.get("effects", [])
	if effects.is_empty():
		issues.append(_issue(SEV_INFO, "effects", "这张牌没有任何效果。"))
	for e in effects:
		if not bool(e.get("enabled", true)):
			continue
		_validate_effect(schema, e, issues)

	var keywords: Array = card.get("keywords", [])
	if keywords.has("Unplayable") and not effects.is_empty():
		issues.append(_issue(SEV_WARNING, "keywords", "带有 Unplayable 的卡牌无法被打出，其效果不会触发。"))

	# `GainsBlock` only drives the card's own hover tip, not whether block is
	# granted (the effect does that) — but a block card without the flag looks
	# different in game, so mention it once instead of letting the user wonder.
	if not bool((card.get("flags", {}) as Dictionary).get("gains_block", false)):
		for e in effects:
			if bool(e.get("enabled", true)) and String(e.get("kind", "")) == "block":
				issues.append(_issue(SEV_INFO, "flags",
						"这张牌有「获得格挡」效果，但没有勾选「获得格挡」标志：格挡会正常生效，只是卡面提示里不会显示格挡说明。"))
				break

	# Text.
	var title_empty := true
	var text: Dictionary = card.get("text", {})
	for locale in CFSchema.LOCALES:
		if not String((text.get(locale, {}) as Dictionary).get("title", "")).strip_edges().is_empty():
			title_empty = false
	if title_empty:
		issues.append(_issue(SEV_WARNING, "text", "还没有填写任何语言的名称（游戏会显示原始 key）。"))


static func _validate_relic(schema: CFSchema, relic: Dictionary, issues: Array) -> void:
	if not schema.members_for_role("relic_rarity").has(String(relic.get("rarity", ""))):
		issues.append(_issue(SEV_ERROR, "rarity", "遗物稀有度不在 schema 枚举中。"))
	if bool(relic.get("show_counter", false)) and not bool(relic.get("stackable", false)):
		issues.append(_issue(SEV_INFO, "show_counter", "计数器开启但遗物不可堆叠。"))
	var triggers: Array = relic.get("triggers", [])
	if triggers.is_empty():
		issues.append(_issue(SEV_WARNING, "triggers", "这件遗物没有任何触发时机，不会产生效果。"))
	for t in triggers:
		var hook := String(t.get("hook", ""))
		if hook.is_empty():
			issues.append(_issue(SEV_ERROR, "triggers", "存在没有选择触发时机的条目。"))
		elif schema.hook(hook).is_empty():
			issues.append(_issue(SEV_ERROR, "triggers", "触发时机 “%s” 在当前 schema 中不存在。" % hook))
		var eff: Array = t.get("effects", [])
		if eff.is_empty():
			issues.append(_issue(SEV_INFO, "triggers", "触发时机 “%s” 下没有效果。" % hook))
		for e in eff:
			if not bool(e.get("enabled", true)):
				continue
			_validate_effect(schema, e, issues)
	var title_empty := true
	var text: Dictionary = relic.get("text", {})
	for locale in CFSchema.LOCALES:
		if not String((text.get(locale, {}) as Dictionary).get("title", "")).strip_edges().is_empty():
			title_empty = false
	if title_empty:
		issues.append(_issue(SEV_WARNING, "text", "还没有填写任何语言的名称（游戏会显示原始 key）。"))


static func _validate_effect(schema: CFSchema, e: Dictionary, issues: Array) -> void:
	var kind := String(e.get("kind", ""))
	var spec := CFEffects.kind_by_id(kind)
	if spec.is_empty():
		issues.append(_issue(SEV_ERROR, "effects", "未知效果类型 “%s”。" % kind))
		return
	var needs := String(spec.get("needs", "none"))
	if needs.contains("value"):
		if float(e.get("amount", 0.0)) == 0.0 and not bool(e.get("amount_is_var", false)):
			issues.append(_issue(SEV_WARNING, "effects", "效果“%s”的数值为 0。" % spec["label"]))
	if needs.contains("power") and String(e.get("power", "")).is_empty():
		issues.append(_issue(SEV_ERROR, "effects", "Buff/Debuff 效果没有选择目标 Power。"))
	if needs.contains("power") and not String(e.get("power", "")).is_empty():
		var error := schema.power_error(String(e["power"]))
		if not error.is_empty():
			issues.append(_issue(SEV_ERROR, "effects", error))
		if bool(e.get("amount_is_var", false)):
			for variable in _current_vars:
				if variable.get("name") == e.get("amount_var") and variable.get("type") == "PowerVar" and variable.get("generic") != e.get("power"):
					issues.append(_issue(SEV_WARNING, "effects", "变量 %s 表示 %s，但实际施加 %s；变量只提供层数，请核对效果中的状态。" % [variable["name"], variable.get("generic", ""), e["power"]]))
	if needs.contains("card") and String(e.get("card_entry", "")).is_empty():
		issues.append(_issue(SEV_ERROR, "effects", "生成牌效果没有指定要生成的卡牌。"))
	if needs.contains("keyword") and String(e.get("keyword", "")).is_empty():
		issues.append(_issue(SEV_ERROR, "effects", "关键字效果没有选择关键字。"))

	# A "repeat by variable" loop compiles to `base.DynamicVars.<Name>.IntValue`.
	# If no variable is named, the old emitter produced `DynamicVars..IntValue`
	# (CS0029 + CS0103); if it names one that is not declared in `vars`, the
	# generated card references a member that does not exist (CS1061). Both are
	# compile errors, so validate them here rather than shipping broken C#.
	var loop: Dictionary = e.get("loop", {})
	if String(loop.get("mode", "none")) == "var":
		var var_name := String(loop.get("var", "")).strip_edges()
		if var_name.is_empty():
			issues.append(_issue(SEV_ERROR, "effects",
					"效果“%s”的循环方式选了“按变量”，但没有选择变量：生成的 C# 会引用不存在的成员而无法编译。" % spec["label"]))
		elif not _declared_var_names().has(var_name):
			issues.append(_issue(SEV_ERROR, "effects",
					"效果“%s”的循环变量 “%s” 不在卡牌/遗物的数值列表中：请先在上方添加同名数值。" % [spec["label"], var_name]))

	# Scope-dependent checks. The two scopes emit different C#, and these are the
	# combinations with no valid emission at all.
	var scope_target := String(e.get("target", ""))
	if scope_target.is_empty():
		scope_target = String(spec.get("default_target", "self"))
	if _current_scope == KIND_RELIC:
		if scope_target == "card_target":
			issues.append(_issue(SEV_ERROR, "effects",
					"遗物没有「卡牌目标」：请改选「自己 / 拥有者」或某个触发参数（触发时机里没有 cardPlay）。"))
		if kind == "add_keyword":
			issues.append(_issue(SEV_ERROR, "effects",
					"「附加关键字」只对卡牌有效：RelicModel 上没有 AddKeyword，导出的 C# 无法编译。"))


## Names of the variables declared on the item currently being validated.
##
## `_validate_effect` only receives the effect, but a loop-var check needs the
## owning item's `vars`. `validate_item` sets this before walking effects and
## clears it afterwards, which keeps the (many) existing call sites unchanged.
static var _current_var_names: Array = []
static var _current_vars: Array = []
## `KIND_CARD` / `KIND_RELIC` for the item being validated. A relic trigger has
## no `cardPlay`, no `AddKeyword` and no `base.CombatState`, so `CFEffects` emits
## different C# per scope; some combinations have no valid emission at all.
static var _current_scope: String = ""


static func _declared_var_names() -> Array:
	return _current_var_names


static func _validate_localization(schema: CFSchema, item: Dictionary, kind: String,
		issues: Array) -> void:
	var entry := String(item.get("entry", ""))
	if entry.is_empty():
		return
	var table := String(CFSchema.LOC_TABLE[kind])
	for field in CFSchema.LOC_FIELDS[kind]:
		var key := CFIds.loc_key(entry, field)
		for locale in CFSchema.LOCALES:
			if schema.base_loc_has(locale, table, key):
				issues.append(_issue(SEV_ERROR, "id",
						"本地化键 %s.%s 已存在于游戏本体（%s/%s.json），游戏会静默覆盖它。请换一个 ID。"
						% [table, key, locale, table]))
				break

	# Placeholder syntax. The description is rendered in game by SmartFormat, and
	# one bad spec makes the *whole* string fail to render — the card then shows no
	# text at all. Reporting it here is the difference between "工具里预览正常"
	# and a card that silently comes out blank in game.
	var text: Dictionary = item.get("text", {}) if item.get("text") is Dictionary else {}
	for field in CFSchema.LOC_FIELDS[kind]:
		var key := CFIds.loc_key(entry, field)
		for locale in CFSchema.LOCALES:
			var body := String((text.get(locale, {}) as Dictionary).get(field, ""))
			for p in scan_placeholders(body):
				var reason := String(p.get("reason", ""))
				var where := "%s/%s.json 的 %s（%s）" % [locale, table, key, locale]
				if reason == "formatter":
					issues.append(_issue(SEV_ERROR, "text",
							"%s 用了游戏没有的格式化器 “%s”：游戏会整条文字渲染失败（卡面不显示文字）。可用：%s。"
							% [where, p.get("formatter", ""), FORMATTER_HINT]))
				elif reason == "syntax":
					issues.append(_issue(SEV_ERROR, "text",
							"%s 里的占位符 %s 写法不对：应为 {变量} 或 {变量:diff()}（变量和格式化器之间是冒号，不是点）。"
							% [where, p.get("raw", "")]))
				else:
					var vn := String(p.get("name", ""))
					if not _declared_var_names().has(vn) and not ENGINE_VARS.has(vn):
						issues.append(_issue(SEV_WARNING, "text",
								"%s 引用了变量 “%s”，但 ④动态变量 里没有这个名字：游戏会把占位符原样留在卡面上。"
								% [where, vn]))


static func _validate_deck(item: Dictionary, is_relic: bool, schema: CFSchema, issues: Array,
		custom_characters: Array = []) -> void:
	var deck: Dictionary = item.get("deck", {})
	if not bool(deck.get("enabled", false)):
		return
	var character := String(deck.get("character", ""))
	if character.is_empty():
		issues.append(_issue(SEV_ERROR, "deck", "启用了开局注入但没有选择角色。"))
		return
	var found := false
	for c in schema.characters:
		if String(c.get("class_name", "")) == character:
			found = true
			break
	if not found:
		for c in custom_characters:
			if String(c.get("id", c.get("class_name", ""))) == character:
				found = true
				break
	if not found:
		issues.append(_issue(SEV_ERROR, "deck", "角色 “%s” 不在当前 schema 中。" % character))
	var pool := String(item.get("pool", ""))
	var is_char_pool := false
	for p in (schema.relic_pools if is_relic else schema.card_pools):
		if String(p.get("class_name", "")) == pool and String(p.get("character", "")) == character:
			is_char_pool = true
			break
	if not is_char_pool:
		var pool_field := "relic_pool" if is_relic else "card_pool"
		for c in custom_characters:
			if String(c.get("id", c.get("class_name", ""))) == character \
					and String(c.get(pool_field, "")) == pool:
				is_char_pool = true
				break
	if not is_char_pool:
		issues.append(_issue(SEV_INFO, "deck",
				"内容所属的池不是 “%s” 的专属池；开局注入通常只对该角色的池生效。" % character))


static func _custom_pool_exists(pool: String, is_relic: bool, custom_characters: Array) -> bool:
	var field := "relic_pool" if is_relic else "card_pool"
	for character in custom_characters:
		if String(character.get(field, "")) == pool:
			return true
	return false


static func _issue(severity: String, field: String, message: String) -> Dictionary:
	return {"severity": severity, "field": field, "message": message}


## Badge summary for the list panel: { errors, warnings, infos }.
static func issue_counts(issues: Array) -> Dictionary:
	var out := {"errors": 0, "warnings": 0, "infos": 0}
	for i in issues:
		match String(i.get("severity", "")):
			SEV_ERROR: out["errors"] += 1
			SEV_WARNING: out["warnings"] += 1
			_: out["infos"] += 1
	return out


# ---------------------------------------------------------------------------
# Description rendering
# ---------------------------------------------------------------------------

## Render a description template for preview. `upgraded` selects upgrade values
## and drives `{IfUpgraded:show:a|b}`.
##
## Supported placeholders (the ones the game actually ships):
##   {Var:diff()}          numeric value of a dynamic var
##   {Var:energyIcons()}   energy icons (rendered as a bracketed count)
##   {Var:plural:one|many} simple pluralisation
##   {IfUpgraded:show:A|B} upgrade-conditional text
##   [gold]..[/gold]       BBCode, preserved for RichTextLabel
static func render_description(item: Dictionary, locale: String, upgraded: bool = false) -> Dictionary:
	var text: Dictionary = item.get("text", {})
	var entry: Dictionary = text.get(locale, {})
	var raw := String(entry.get("description", ""))
	if raw.strip_edges().is_empty():
		raw = String((text.get("eng", {}) as Dictionary).get("description", ""))
	if upgraded and item.has("upgrade"):
		var override: Dictionary = (item["upgrade"] as Dictionary).get("text_override", {})
		var ov := String((override.get(locale, {}) as Dictionary).get("description", ""))
		if ov.strip_edges().is_empty():
			ov = String((override.get("eng", {}) as Dictionary).get("description", ""))
		if not ov.strip_edges().is_empty():
			raw = ov
	var values := var_values(item, upgraded)
	var rendered := format_template(raw, values, upgraded)
	return {"bbcode": rendered, "plain": strip_bbcode(rendered), "raw": raw}


static func render_title(item: Dictionary, locale: String) -> String:
	var text: Dictionary = item.get("text", {})
	var t := String((text.get(locale, {}) as Dictionary).get("title", ""))
	if t.strip_edges().is_empty():
		t = String((text.get("eng", {}) as Dictionary).get("title", ""))
	if t.strip_edges().is_empty():
		t = String(item.get("id", ""))
	return t


## Numeric value of every dynamic var, honouring upgrade deltas.
static func var_values(item: Dictionary, upgraded: bool) -> Dictionary:
	var out: Dictionary = {}
	for v in item.get("vars", []):
		var name := String(v.get("name", ""))
		if name.is_empty():
			continue
		var base := float(v.get("base", 0.0))
		var delta := float(v.get("upgrade_delta", 0.0)) if upgraded else 0.0
		out[name] = base + delta
		if String(v.get("kind", "")) == "Damage":
			out["Damage"] = base + delta
	out["Energy"] = float(item.get("cost", 0))
	return out


static func format_template(template: String, values: Dictionary, upgraded: bool) -> String:
	if template.is_empty():
		return ""
	var out := template
	var re := RegEx.create_from_string("\\{([A-Za-z_][A-Za-z0-9_]*)((?::[^{}]*)?)\\}")
	var pos := 0
	var guard := 0
	while guard < 200:
		guard += 1
		var m := re.search(out, pos)
		if m == null:
			break
		var name := m.get_string(1)
		var spec := m.get_string(2)
		var replacement: Variant = _apply_spec(name, spec, values, upgraded)
		if replacement == null:
			pos = m.get_end()
			continue
		out = out.substr(0, m.get_start()) + str(replacement) + out.substr(m.get_end())
		pos = m.get_start() + str(replacement).length()
	return out


static func _apply_spec(name: String, spec: String, values: Dictionary, upgraded: bool) -> Variant:
	if name == "IfUpgraded":
		var body := spec.trim_prefix(":show:")
		var parts := body.split("|")
		if parts.size() >= 2:
			return parts[0] if upgraded else parts[1]
		return parts[0] if parts.size() == 1 else ""
	var value: Variant = values.get(name, null)
	if value == null:
		return null
	var s := String(spec)
	if s.begins_with(":plural:"):
		var forms := s.trim_prefix(":plural:").split("|")
		if forms.size() >= 2:
			return forms[0] if absf(float(value)) == 1.0 else forms[1]
		return forms[0] if forms.size() == 1 else ""
	# Only fake the specs the tool actually models. Everything else is left in
	# place, so a spec the game will reject shows up as literal text in the
	# preview instead of a plausible-looking number. `{Value3:difff()}` used to
	# preview as "1" and then render as nothing at all in game.
	if not _is_previewable_spec(s):
		return null
	var f := float(value)
	var rendered := String.num(f, 3) if f != floor(f) else str(int(f))
	if s.contains("energyIcons"):
		return "[%s]" % rendered
	return rendered


## Can the tool render this `:spec` itself? The ones that are pure number
## formatting (and the icon wrappers) can; the rest (`choose`, `cond`,
## `substring`, `ismatch`, ...) are left for the game, so the preview keeps the
## raw placeholder rather than inventing a value.
static func _is_previewable_spec(spec: String) -> bool:
	if spec.is_empty():
		return true
	var fmt := _formatter_name(spec.trim_prefix(":"))
	return ["diff", "n", "abs", "percentMore", "percentLess"].has(fmt) \
			or fmt == "energyIcons" or fmt == "starIcons"


# ---------------------------------------------------------------------------
# Placeholder scanning
# ---------------------------------------------------------------------------

## Every `{...}` placeholder in one localization string, with the reason the game
## would choke on it ("" when it is fine).
##
## Returns entries of `{ raw, name, formatter, reason }`:
##   * `reason == "formatter"` — the spec names a formatter the game does not
##     register; SmartFormat throws and the *whole* string fails to render.
##   * `reason == "syntax"` — not `{Name}` / `{Name:formatter}` at all, e.g. the
##     dotted `{Weak.diff()}` that SmartFormat reads as one bogus variable name.
##   * `reason == ""` and an empty `formatter` — a plain `{Name}`; whether that
##     name exists is the caller's business (see `_validate_localization`).
##
## Pure string work so the UI can run it on every keystroke.
static func scan_placeholders(text: String) -> Array:
	var out: Array = []
	if text.is_empty():
		return out
	for m in _placeholder_re().search_all(text):
		# `{{` is SmartFormat's escape for a literal brace.
		if m.get_start() > 0 and text[m.get_start() - 1] == "{":
			continue
		var body := m.get_string(1).strip_edges()
		if body.is_empty():
			continue
		var raw := m.get_string(0)
		var name := body
		var spec := ""
		var colon := body.find(":")
		if colon >= 0:
			name = body.substr(0, colon).strip_edges()
			spec = body.substr(colon + 1)
		if not _is_placeholder_name(name):
			out.append({"raw": raw, "name": name, "formatter": "", "reason": "syntax"})
			continue
		if colon < 0:
			out.append({"raw": raw, "name": name, "formatter": "", "reason": ""})
			continue
		var formatter := _formatter_name(spec)
		out.append({
			"raw": raw,
			"name": name,
			"formatter": formatter,
			"reason": "" if FORMATTER_NAMES.has(formatter) else "formatter",
		})
	return out


## Human-readable summary of `scan_placeholders` for a whole text field, or ""
## when there is nothing to report. Used by the editor's live hint line.
##
## `declared` is the list of var names the entry actually declares. It is passed
## in rather than read off `_declared_var_names()` so callers outside `validate()`
## (the editor's live hint) cannot be answered from another item's static state.
static func describe_placeholders(text: String, declared: Array = []) -> String:
	var parts: Array = []
	for p in scan_placeholders(text):
		var reason := String(p.get("reason", ""))
		if reason == "formatter":
			parts.append("格式化器 “%s” 游戏不认识 → 整条文字会渲染失败。可用：%s"
					% [p.get("formatter", ""), FORMATTER_HINT])
		elif reason == "syntax":
			parts.append("占位符 %s 写法不对 → 应为 {变量} 或 {变量:diff()}" % p.get("raw", ""))
		elif not declared.has(String(p.get("name", ""))) \
				and not ENGINE_VARS.has(String(p.get("name", ""))):
			parts.append("变量 “%s” 未在 ④动态变量 中声明 → 游戏会原样留下占位符" % p.get("name", ""))
	return "；".join(parts)


## Declared var names of one design, for callers that render a hint about the
## placeholders a description may use.
static func declared_var_names(item: Dictionary) -> Array:
	var out: Array = []
	for v in (item.get("vars", []) if item.get("vars") is Array else []):
		var name := String((v as Dictionary).get("name", "")).strip_edges()
		if not name.is_empty() and not out.has(name):
			out.append(name)
	return out


static func _placeholder_re() -> RegEx:
	if _placeholder_regex == null:
		_placeholder_regex = RegEx.create_from_string("\\{([^{}]*)\\}")
	return _placeholder_regex


## `Name` or a dotted path (`ApplierName.StringValue`) — both are valid selectors.
static func _is_placeholder_name(name: String) -> bool:
	if _ident_regex == null:
		_ident_regex = RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$")
	return _ident_regex.search(name) != null


## The formatter name out of `diff()` / `show:a|b` / `plural:one|many`.
static func _formatter_name(spec: String) -> String:
	var s := spec.strip_edges()
	var cut := s.length()
	for sep in ["(", "|", ":"]:
		var i := s.find(sep)
		if i >= 0 and i < cut:
			cut = i
	return s.substr(0, cut).strip_edges()


static func strip_bbcode(text: String) -> String:
	return RegEx.create_from_string("\\[/?[a-zA-Z][^\\]]*\\]").sub(text, "", true)


static func display_name(item: Dictionary, locale: String = "zhs") -> String:
	var t := render_title(item, locale)
	var id := String(item.get("id", ""))
	if t.is_empty():
		return id if not id.is_empty() else "(未命名)"
	if id.is_empty() or t == id:
		return t
	return "%s  (%s)" % [t, id]


static func describe_issue(issue: Dictionary) -> String:
	return "[%s] %s: %s" % [String(issue.get("severity", "")).to_upper(),
			issue.get("field", ""), issue.get("message", "")]


## Build the localization tables for a list of designs: { locale -> { table -> {} } }
static func build_localization(items: Array) -> Dictionary:
	var tables: Dictionary = {}
	for item in items:
		var kind := String(item.get("kind", KIND_CARD))
		var entry := String(item.get("entry", ""))
		if entry.is_empty():
			continue
		var text: Dictionary = item.get("text", {})
		for locale in CFSchema.LOCALES:
			if not tables.has(locale):
				tables[locale] = {}
			var by_table: Dictionary = tables[locale]
			var table := String(CFSchema.LOC_TABLE[kind])
			if not by_table.has(table):
				by_table[table] = {}
			var src: Dictionary = text.get(locale, {})
			var fallback: Dictionary = text.get("eng", {})
			for field in CFSchema.LOC_FIELDS[kind]:
				var value := String(src.get(field, "")).strip_edges()
				if value.is_empty():
					value = String(fallback.get(field, "")).strip_edges()
				if value.is_empty() and field == "title":
					value = String(item.get("id", ""))
				if value.is_empty():
					continue
				(by_table[table] as Dictionary)[CFIds.loc_key(entry, field)] = value
	return tables
