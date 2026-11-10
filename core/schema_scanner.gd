@tool
class_name CFSchemaScanner
extends RefCounted

## Reads the unpacked StS2 C# source and fills a [CFSchema].
##
## The scanner is deliberately shallow: it uses regexes over declaration lines
## rather than a real C# parser. That is enough because everything we need is
## declared in a regular way (`public enum X` + member lines, `public sealed
## class Y : RelicModel`, `public static async Task Z(...)`), and it keeps the
## tool dependency-free and fast (a full scan of ~3400 files takes ~1 s).

const MAX_FILES := 20000

var _schema: CFSchema
var _visited := 0
## `PowerVar<T>`'s constructor facts, kept until `_synthesize_power_vars` needs
## them for the concrete `PowerVar<SomePower>` entries.
var _powervar_facts := {}


## Scan `source_root` (the folder holding `src/Core` and `localization`).
static func scan(source_root: String, s: CFSchema) -> CFSchema:
	var scanner := CFSchemaScanner.new()
	s.reset()
	scanner._schema = s
	scanner._visited = 0
	var t0 := Time.get_ticks_msec()

	s.source_root = source_root
	s.scanned_at = Time.get_datetime_string_from_system(false, true)

	if source_root.is_empty() or not DirAccess.dir_exists_absolute(source_root):
		s.errors.append("解包数据目录不存在：%s" % source_root)
		return s

	scanner._scan_core(source_root.path_join("src").path_join("Core"))
	scanner._scan_localization(source_root.path_join("localization"))
	# Pools and characters each only know half the pairing (see the function).
	scanner._link_pools_to_characters()
	scanner._resolve_enum_labels()
	scanner._resolve_power_titles(source_root.path_join("localization"))
	scanner._synthesize_power_vars()
	scanner._mark_usable_hooks()

	s.files_visited = scanner._visited
	s.scan_ms = Time.get_ticks_msec() - t0
	s._reindex()
	return s


# ---------------------------------------------------------------------------
# Walking
# ---------------------------------------------------------------------------

func _scan_core(core_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(core_dir):
		_schema.errors.append("找不到 src/Core：%s" % core_dir)
		return
	_walk(core_dir, func(path: String) -> void: _parse_file(path))


func _walk(dir: String, on_file: Callable) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if _visited > MAX_FILES:
			return
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir.path_join(name)
		if d.current_is_dir():
			_walk(full, on_file)
		elif name.ends_with(".cs"):
			_visited += 1
			on_file.call(full)
		name = d.get_next()
	d.list_dir_end()


## Dispatch by folder, mirroring the game's own layout.
func _parse_file(path: String) -> void:
	var p := path.replace("\\", "/")
	if p.contains("/Models/CardPools/"):
		_parse_card_pool(path)
		return
	if p.contains("/Models/RelicPools/"):
		_parse_relic_pool(path)
		return
	if p.contains("/Models/Characters/"):
		_parse_character(path)
		return
	if p.contains("/Models/Cards/"):
		_parse_existing_card(path)
		return
	if p.contains("/Models/Relics/"):
		_parse_existing_relic(path)
		return
	if p.contains("/Models/Powers/"):
		_parse_power(path)
		return
	if p.contains("/Models/AbstractModel.cs"):
		_parse_hooks(path)
		return
	if p.contains("/Models/CardModel.cs"):
		_parse_model_fields(path, "card")
		return
	if p.contains("/Models/RelicModel.cs"):
		# RelicModel owns lifecycle hooks that are not declared on AbstractModel
		# (notably AfterObtained/AfterRemoved). They are valid relic triggers and
		# must be scanned or the editor silently falls back to combat hooks.
		_parse_hooks(path)
		_parse_model_fields(path, "relic")
		return
	if p.contains("/DynamicVars/DynamicVarSet.cs"):
		_parse_dynamic_var_set(path)
		return
	if p.contains("/ValueProps/") or p.contains("/DynamicVars/"):
		_parse_dynamic_var(path)
		return
	# Enum hunting: only files whose name looks like an enum, to stay fast.
	var base := path.get_file().get_basename()
	if _ENUM_HINT.has(base):
		_parse_enum(path)
		return
	if p.contains("/Commands/") and not p.contains("/Builders/"):
		_parse_commands(path)
		return


const _ENUM_HINT := {
	"CardType": true, "CardRarity": true, "CardKeyword": true, "CardTag": true,
	"TargetType": true, "PileType": true, "CardPilePosition": true,
	"ValueProp": true, "RelicRarity": true, "PowerType": true,
	"PowerStackType": true, "CombatSide": true, "RoomType": true,
	"CardCostColor": true, "CardScope": true, "PotionRarity": true,
	"KeywordSources": true, "RelicStatus": true,
}


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

static func _strip_comments(text: String) -> String:
	# Remove /* ... */ and // ... so member extraction is not fooled by docs.
	var out := text
	var re_block := RegEx.create_from_string("(?s)/\\*.*?\\*/")
	out = re_block.sub(out, "", true)
	var re_line := RegEx.create_from_string("//[^\\n]*")
	out = re_line.sub(out, "", true)
	return out


func _parse_enum(path: String) -> void:
	var text := _read(path)
	if text.is_empty():
		return
	var ns := _namespace_of(text)
	var re := RegEx.create_from_string("(?m)^\\s*(?:\\[[^\\]]*\\]\\s*)*(?:public|internal)\\s+enum\\s+([A-Za-z_][A-Za-z0-9_]*)")
	var m := re.search(text)
	if m == null:
		return
	var name := m.get_string(1)
	# Slice from the enum declaration to its closing brace.
	var brace := text.find("{", m.get_end())
	if brace < 0:
		return
	var body := _balanced_body(text, brace)
	var members: Array = []
	var re_member := RegEx.create_from_string("(?m)^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*(?:=\\s*([^,\\n]+))?\\s*,?\\s*$")
	for line in body.split("\n"):
		var lm := re_member.search(line)
		if lm == null:
			continue
		var member := lm.get_string(1)
		if member.is_empty() or member == "None" and members.is_empty() and false:
			continue
		members.append({"name": member, "value": lm.get_string(2).strip_edges()})
	if members.is_empty():
		return
	_schema.enums[name] = {
		"namespace": ns, "full_name": "%s.%s" % [ns, name] if not ns.is_empty() else name,
		"file": path, "members": members,
	}


## Return the text inside the brace block starting at `open_index`.
static func _balanced_body(text: String, open_index: int) -> String:
	var depth := 0
	var i := open_index
	while i < text.length():
		var c := text[i]
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				return text.substr(open_index + 1, i - open_index - 1)
		i += 1
	return text.substr(open_index + 1)


static func _namespace_of(text: String) -> String:
	var m := RegEx.create_from_string("(?m)^\\s*namespace\\s+([A-Za-z_][A-Za-z0-9_.]*)").search(text)
	return m.get_string(1) if m != null else ""


# ---------------------------------------------------------------------------
# Pools / characters
# ---------------------------------------------------------------------------

func _parse_card_pool(path: String) -> void:
	var text := _read(path)
	var info := _class_of(text, "CardPoolModel")
	if info.is_empty():
		info = _class_of(text, "AbstractModel")
	if info.is_empty():
		return
	var cls := String(info["name"])
	var ns := _namespace_of(text)
	var entry := CFIds.slugify(cls)
	# `CardPoolModel.Title` is the lowercase id that every card *art* path is
	# built from (`images/packed/card_portraits/<Title>/<entry>.png`), so it has
	# to be read, not guessed: it differs from the class name for real pools
	# (`IroncladCardPool` is `"ironclad"`, `DeprecatedCardPool` is `"token"`).
	var art_name := _pool_title(text)
	if art_name.is_empty():
		# Older/unreadable source shape: the suffix rule is right for every
		# ordinary pool and keeps the tool useful without a fresh scan.
		art_name = CFIds.snake_case(cls.trim_suffix("CardPool"))
	_schema.card_pools.append({
		"class_name": cls,
		"namespace": ns,
		"entry": entry,
		"title": art_name,
		"art_name": art_name,
		# Filled in by `_link_pools_to_characters` once the characters have been read.
		"character": "",
		"is_colorless": cls.to_lower().contains("colorless"),
		"file": path,
	})


## `public override string Title => "ironclad";` — the pool's art/energy id.
func _pool_title(text: String) -> String:
	var m := RegEx.create_from_string(
			"(?m)override\\s+string\\s+Title\\s*=>\\s*\"([^\"]*)\"").search(text)
	return m.get_string(1) if m != null else ""


func _parse_relic_pool(path: String) -> void:
	var text := _read(path)
	var info := _class_of(text, "RelicPoolModel")
	if info.is_empty():
		info = _class_of(text, "AbstractModel")
	if info.is_empty():
		return
	var cls := String(info["name"])
	_schema.relic_pools.append({
		"class_name": cls,
		"namespace": _namespace_of(text),
		"entry": CFIds.slugify(cls),
		"title": cls,
		# Filled in by `_link_pools_to_characters` once the characters have been read.
		"character": "",
		"is_shared": cls.to_lower().contains("shared"),
		"file": path,
	})


func _parse_character(path: String) -> void:
	var text := _read(path)
	var info := _class_of(text, "CharacterModel")
	if info.is_empty():
		return
	var cls := String(info["name"])
	if cls.begins_with("Abstract"):
		return
	_schema.characters.append({
		"class_name": cls,
		"namespace": _namespace_of(text),
		"entry": CFIds.slugify(cls),
		"title": cls,
		"card_pool": _referenced_pool(text, "CardPool"),
		"relic_pool": _referenced_pool(text, "RelicPool"),
		"starting_deck": _starting_deck(text),
		"file": path,
	})


## Read only the StartingDeck expression, preserving duplicates and order.
static func _starting_deck(text: String) -> Array:
	var start := text.find(" StartingDeck =>")
	if start < 0:
		return []
	var end := text.find(";", start)
	var result: Array = []
	for match in RegEx.create_from_string("ModelDb\\.Card<([A-Za-z_][A-Za-z0-9_]*)>").search_all(text.substr(start, end - start)):
		result.append({"source": "game", "id": match.get_string(1), "copies": 1})
	return result


## `public override CardPoolModel CardPool => ModelDb.CardPool<IroncladCardPool>();`
## — the same line exists for `RelicPool`.
static func _referenced_pool(text: String, kind: String) -> String:
	var m := RegEx.create_from_string(
			"%s\\s*<\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*>" % kind).search(text)
	return m.get_string(1) if m != null else ""


## Fill in each pool's `character` from the character→pool links.
##
## The pairing only exists in the **character's** source: a pool file names
## itself and nothing else, so asking a pool "who owns you?" can only ever answer
## with its own class name. That is exactly what the pool dropdown used to show
## (`IroncladCardPool  (IroncladCardPool)`), and it made the preflight warn about
## every deck injection (`…的池属于 IroncladCardPool，却要加入 Ironclad`).
##
## Has to run after the whole tree is walked — `CardPools/` sorts before
## `Characters/`, so the owning character does not exist yet at parse time.
func _link_pools_to_characters() -> void:
	var card_owners := _pool_owners("card_pool", "CardPool")
	var relic_owners := _pool_owners("relic_pool", "RelicPool")
	for p in _schema.card_pools:
		p["character"] = String(card_owners.get(String(p.get("class_name", "")), ""))
	for p in _schema.relic_pools:
		p["character"] = String(relic_owners.get(String(p.get("class_name", "")), ""))


## pool class -> owning character class, from every character's
## `CardPool` / `RelicPool` override.
func _pool_owners(field: String, suffix: String) -> Dictionary:
	var out := {}
	for c in _schema.characters:
		var pool_cls := String(c.get(field, ""))
		if pool_cls.is_empty():
			continue
		var cls := String(c.get("class_name", ""))
		# A character named after the pool (`Ironclad` ↔ `IroncladCardPool`) is the
		# real owner; `RandomCharacter` / `DeprecatedCharacter` point at someone
		# else's pool and must not shadow it.
		if pool_cls.trim_suffix(suffix) == cls:
			out[pool_cls] = cls
		elif not out.has(pool_cls):
			out[pool_cls] = cls
	return out


## Find `[modifiers] class <name> : <base>` and return { name, base, line }.
static func _class_of(text: String, base: String) -> Dictionary:
	var re := RegEx.create_from_string("(?m)^\\s*(?:\\[[^\\]]*\\]\\s*)*(?:public|internal)\\s+(?:sealed\\s+|abstract\\s+|static\\s+)*class\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*:\\s*([A-Za-z0-9_.<>, ]+)")
	var search_from := 0
	while true:
		var m := re.search(text, search_from)
		if m == null:
			return {}
		var baselist := m.get_string(2)
		if baselist.contains(base) or base == "AbstractModel":
			return {"name": m.get_string(1), "base": baselist.strip_edges(), "line": m.get_string(0)}
		search_from = m.get_end()
	return {}


# ---------------------------------------------------------------------------
# Existing content catalogue
# ---------------------------------------------------------------------------

func _parse_existing_card(path: String) -> void:
	var text := _read(path)
	var info := _class_of(text, "CardModel")
	if info.is_empty():
		return
	var cls := String(info["name"])
	if cls.begins_with("Abstract") or cls.begins_with("Calculated"):
		return
	var ctor := RegEx.create_from_string(":\\s*base\\s*\\(\\s*(-?\\d+)\\s*,\\s*CardType\\.([A-Za-z0-9_]+)\\s*,\\s*CardRarity\\.([A-Za-z0-9_]+)\\s*,\\s*TargetType\\.([A-Za-z0-9_]+)").search(text)
	var cost := -1
	var ctype := ""
	var rarity := ""
	var target := ""
	if ctor != null:
		cost = int(ctor.get_string(1))
		ctype = ctor.get_string(2)
		rarity = ctor.get_string(3)
		target = ctor.get_string(4)
	_schema.existing_cards.append({
		"class_name": cls,
		"entry": CFIds.slugify(cls),
		"namespace": _namespace_of(text),
		"cost": cost, "type": ctype, "rarity": rarity, "target": target,
		"keywords": _enum_members_of(text, "CardKeyword"),
		"file": path,
	})


func _parse_existing_relic(path: String) -> void:
	var text := _read(path)
	var info := _class_of(text, "RelicModel")
	if info.is_empty():
		return
	var cls := String(info["name"])
	if cls.begins_with("Abstract"):
		return
	var m := RegEx.create_from_string("RelicRarity\\.([A-Za-z0-9_]+)").search(text)
	_schema.existing_relics.append({
		"class_name": cls,
		"entry": CFIds.slugify(cls),
		"namespace": _namespace_of(text),
		"rarity": m.get_string(1) if m != null else "",
		"hooks": _hooks_overridden(text),
		"file": path,
	})


func _parse_power(path: String) -> void:
	var text := _read(path)
	var info := _class_of(text, "AbstractModel")
	if info.is_empty():
		return
	var cls := String(info["name"])
	if not String(info["base"]).split(",")[0].strip_edges().ends_with("Power") and not String(info["base"]).begins_with("PowerModel"):
		return
	var entry := CFIds.slugify(cls)
	var type_m := RegEx.create_from_string("PowerType\\.([A-Za-z0-9_]+)").search(text)
	var ns := _namespace_of(text)
	_schema.powers.append({
		"class_name": cls,
		"namespace": ns,
		# The game's own test doubles live in `...Models.Powers.Mocks`. They are
		# public and do compile, but they are stubs, so the picker hides them.
		"is_mock": ns.ends_with(".Mocks") or cls.begins_with("Mock"),
		"is_abstract": String(info["line"]).contains("abstract "),
		"entry": entry,
		"is_debuff": cls.to_lower().contains("debuff") or bool(type_m != null and type_m.get_string(1).to_lower().contains("debuff")),
		"power_type": type_m.get_string(1) if type_m != null else "",
		"file": path,
	})


func _enum_members_of(text: String, enum_name: String) -> Array:
	var out: Array = []
	var re := RegEx.create_from_string("%s\\.([A-Za-z0-9_]+)" % enum_name)
	for m in re.search_all(text):
		var v := m.get_string(1)
		if not out.has(v):
			out.append(v)
	return out


func _hooks_overridden(text: String) -> Array:
	var out: Array = []
	var re := RegEx.create_from_string("override\\s+(?:async\\s+)?(?:Task|void|bool|int|decimal|string)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	for m in re.search_all(text):
		var v := m.get_string(1)
		if not out.has(v):
			out.append(v)
	return out


## Constructor shapes and `defaultName` of one DynamicVar subclass.
##
## The generator must call a constructor that (a) exists and (b) registers the var
## under the name the user picked. Guessing either one is how two shipped bugs
## happened:
##
##   * `new BlockVar(20m, ValueProp.Move)` — that overload exists, but it pins the
##     name to `defaultName` ("Block"), so `base.DynamicVars["Value4"]` threw
##     `KeyNotFoundException: 'Value4'` at play/upgrade time: the card gained no
##     block, the play action failed, and nothing said why.
##   * `new IntVar(0)` — `IntVar` only has `IntVar(string name, decimal amount)`,
##     so that did not even compile (CS1729). It is the type the 「＋ 添加变量」
##     button used to create.
##
## Reading the constructors off the game's own source makes the generator follow
## whatever overloads the installed game version actually has.
func _var_ctor_facts(text: String, tname: String) -> Dictionary:
	var cre := RegEx.create_from_string(
			"(?m)^\\s*public\\s+%s\\s*(?:<[^>]*>)?\\s*\\(([^)]*)\\)" % tname)
	var ctors: Array = []
	for m in cre.search_all(text):
		ctors.append(_ctor_param_types(m.get_string(1)))
	var dre := RegEx.create_from_string(
			"const\\s+string\\s+defaultName\\s*=\\s*\"([^\"]*)\"")
	var dm := dre.search(text)
	return {
		"default_name": dm.get_string(1) if dm != null else "",
		"ctors": ctors,
	}


## `["string name", "decimal block", "ValueProp props"]` -> `["string", "decimal", "ValueProp"]`.
static func _ctor_param_types(params: String) -> Array:
	var out: Array = []
	for raw in _split_param_list(params):
		var p := String(raw).strip_edges()
		if p.is_empty():
			continue
		# Drop a default value, then everything but the type.
		var eq := p.find("=")
		if eq >= 0:
			p = p.substr(0, eq).strip_edges()
		var cut := p.rfind(" ")
		out.append(p.substr(0, cut).strip_edges() if cut >= 0 else p)
	return out


## Split a parameter list on top-level commas only, so a generic parameter
## (`Func<CardModel, Creature?, decimal> calc`) is not torn in half.
static func _split_param_list(params: String) -> Array:
	var out: Array = []
	var depth := 0
	var cur := ""
	for i in params.length():
		var ch := params[i]
		if ch in ["<", "(", "[", "{"]:
			depth += 1
		elif ch in [">", ")", "]", "}"]:
			depth -= 1
		if ch == "," and depth <= 0:
			out.append(cur)
			cur = ""
			continue
		cur += ch
	if not cur.strip_edges().is_empty():
		out.append(cur)
	return out


func _parse_dynamic_var(path: String) -> void:
	var text := _read(path)
	var re := RegEx.create_from_string("(?m)^\\s*(?:public|internal)\\s+(?:sealed\\s+|abstract\\s+)*class\\s+([A-Za-z_][A-Za-z0-9_]*Var(?:<[^>]+>)?)\\s*:")
	for m in re.search_all(text):
		var full := m.get_string(1)
		var tname := full
		var generic := ""
		var lt := full.find("<")
		if lt >= 0:
			tname = full.substr(0, lt)
			generic = full.substr(lt + 1, full.length() - lt - 2)
		# The constructors come off the file *before* the type-parameter check below,
		# because `class PowerVar<T>` is skipped as a dropdown entry while its concrete
		# `PowerVar<SomePower>` forms (synthesized later) still need to know them.
		var facts := _var_ctor_facts(text, tname)
		if tname == "PowerVar":
			_powervar_facts = facts
		# `class PowerVar<T> : DynamicVar where T : PowerModel` declares a *type
		# parameter*, not a concrete type. Recording it verbatim put a literal
		# `T` into the dropdown, users picked `PowerVar<T>`, and the design stored
		# `"generic": "T"` — which the exporter then emitted as `new PowerVar<T>(2m)`,
		# i.e. C# that cannot compile (CS1061 on the missing `.power` member, since
		# the broken declaration has no such accessor). Drop the placeholder here;
		# the real, concrete instantiations come from `_parse_dynamic_var_set`.
		if _is_type_parameter(tname, generic):
			continue
		if _has_dynvar(tname, generic):
			continue
		_schema.dynamic_var_types.append({
			"type": tname, "generic": generic, "file": path,
			"default_name": facts["default_name"], "ctors": facts["ctors"],
		})


## Is `generic` just the declaring class's own type parameter?
##
## The declaration `class Foo<T>` names its parameter `T` (or `TKey`, `TValue`…),
## so a bare single-letter/`T`-prefixed identifier here is a placeholder rather
## than a real type. A usable generic always names a concrete class.
func _is_type_parameter(tname: String, generic: String) -> bool:
	if generic.is_empty():
		return false
	# `T`, `TKey`, `TValue`, `TResult` … are all declaration placeholders.
	if generic == "T" or generic.begins_with("T") and generic.length() <= 6 \
			and generic.substr(1).to_lower() == generic.substr(1):
		return true
	# A real generic argument is a known model type (ends in Power/Model) or a
	# dotted/qualified name. Anything that is not one of those is suspect.
	return false


## Scan `DynamicVarSet` for the accessors it exposes.
##
## This is the authoritative list of what `<something>.DynamicVars.<Name>` may
## legally be. The set is *closed*: it has `Vulnerable`, `Dexterity`, `Poison`
## … but no `power`, so an accessor the user invented has to go through the
## indexer (`DynamicVars["VulnerablePower"]`) instead of the property. Recording
## the mapping lets the exporter emit whichever form actually compiles.
func _parse_dynamic_var_set(path: String) -> void:
	var text := _strip_comments(_read(path))
	# `public PowerVar<VulnerablePower> Vulnerable => (PowerVar<VulnerablePower>)_vars["VulnerablePower"];`
	# `public RepeatVar Repeat => (RepeatVar)_vars["Repeat"];`
	#
	# The return type may itself be generic, so the type pattern has to accept an
	# optional `<...>` — otherwise the seven `PowerVar<XPower>` accessors (the
	# very ones this whole lookup exists for) are silently skipped.
	var re := RegEx.create_from_string(
			"(?m)^\\s*public\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?:<([^>]*)>)?\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*=>")
	for m in re.search_all(text):
		var type_name := m.get_string(1)
		var generic := m.get_string(2)
		var prop := m.get_string(3)
		# Skip the container plumbing (`Count`, `Keys`, `Values`) and the
		# indexer, which are not per-var accessors.
		if prop in ["Count", "Keys", "Values"]:
			continue
		_schema.dynamic_var_accessors.append({
			"property": prop,
			"type": type_name,
			"generic": generic,
			"file": path,
		})


## Offer one `PowerVar<XPower>` entry per concrete power the game exposes.
##
## `PowerVar<T>` is the *only* way to declare a power var, and its constraint
## `where T : PowerModel` means `T` must be a real power class — a bare `T` from
## the declaration is useless (and produced CS1061).
##
## Every concrete power is legal here, so the whole scanned power list is
## offered (256 entries), not just the handful `DynamicVarSet` happens to name.
## Restricting it to the accessor list technically compiles too, but it silently
## hides most of the game's buffs from the picker — which is a worse bug than
## offering a long list, because the user cannot tell anything is missing.
func _synthesize_power_vars() -> void:
	for p in _schema.powers:
		# Skip the game's test doubles (`...Models.Powers.Mocks`): the variable
		# picker should not offer stubs any more than the effect picker does.
		if bool(p.get("is_mock", false)) or bool(p.get("is_abstract", false)):
			continue
		var cls := String(p.get("class_name", "")).strip_edges()
		if cls.is_empty():
			continue
		# A PowerVar's generic must be a *Power* class; the scan also picks up a
		# few power-looking helpers that are not models, so filter defensively.
		if not cls.ends_with("Power"):
			continue
		if _has_dynvar("PowerVar", cls):
			continue
		_schema.dynamic_var_types.append({
			"type": "PowerVar",
			"generic": cls,
			"file": String(p.get("file", "")),
			"default_name": String(_powervar_facts.get("default_name", "")),
			"ctors": _powervar_facts.get("ctors", []),
		})


func _has_dynvar(t: String, g: String) -> bool:
	for d in _schema.dynamic_var_types:
		if String(d["type"]) == t and String(d.get("generic", "")) == g:
			return true
	return false


# ---------------------------------------------------------------------------
# Model fields & hooks
# ---------------------------------------------------------------------------

func _parse_model_fields(path: String, kind: String) -> void:
	var text := _strip_comments(_read(path))
	var body := _unbalanced_after_class(text)
	var re := RegEx.create_from_string("(?m)^\\s*(?:\\[[^\\]]*\\]\\s*)*(?:public|protected|internal)\\s+(?:static\\s+|virtual\\s+|abstract\\s+|override\\s+|sealed\\s+|async\\s+)*([A-Za-z0-9_<>,.\\[\\]? ]+?)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?:=>|\\{|\\()")
	var out: Array = []
	for m in re.search_all(body):
		var type_name := m.get_string(1).strip_edges()
		var name := m.get_string(2).strip_edges()
		if type_name.is_empty() or name.is_empty():
			continue
		out.append({"name": name, "type": type_name})
	if kind == "card":
		_schema.card_fields = out
	else:
		_schema.relic_fields = out


func _unbalanced_after_class(text: String) -> String:
	var i := text.find("class ")
	if i < 0:
		return text
	var brace := text.find("{", i)
	if brace < 0:
		return text
	return text.substr(brace)


func _parse_hooks(path: String) -> void:
	var text := _strip_comments(_read(path))
	var re := RegEx.create_from_string("(?m)^\\s*(public|protected|internal|private)\\s+virtual\\s+(?:async\\s+)?([A-Za-z0-9_<>,.\\[\\]?]+)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(([^)]*)\\)")
	for m in re.search_all(text):
		var access := m.get_string(1)
		var ret := m.get_string(2).strip_edges()
		var name := m.get_string(3)
		var params_raw := m.get_string(4).strip_edges()
		var params := _split_params(params_raw)
		var ann := _doc_for(text, name)
		_schema.hooks.append({
			"name": name,
			"access": access,
			"return_type": ret,
			"params": params,
			"signature": "%s %s(%s)" % [ret, name, params_raw],
			"doc": ann,
			"usable": false,
		})


static func _split_params(raw: String) -> Array:
	var out: Array = []
	if raw.strip_edges().is_empty():
		return out
	var depth := 0
	var current := ""
	for i in raw.length():
		var c := raw[i]
		if c == "<" or c == "(" or c == "[":
			depth += 1
		elif c == ">" or c == ")" or c == "]":
			depth -= 1
		if c == "," and depth == 0:
			out.append(current.strip_edges())
			current = ""
			continue
		current += c
	if not current.strip_edges().is_empty():
		out.append(current.strip_edges())
	return out


## The `_split_params` helper is used both as a static (from the scanner) and via
## instances; keep one implementation and forward.
static func split_params(raw: String) -> Array:
	return _split_params(raw)


static func _doc_for(text: String, name: String) -> String:
	var idx := text.find(" %s(" % name)
	if idx < 0:
		return ""
	var head := text.substr(maxi(0, idx - 700), 700)
	var m := RegEx.create_from_string("(?s)///\\s*<summary>(.*?)</summary>").search(head)
	if m == null:
		return ""
	var s := m.get_string(1)
	s = RegEx.create_from_string("(?m)^\\s*///\\s?").sub(s, "", true)
	return s.strip_edges()


## A hook is "usable" when it returns Task and takes only types the generated
## code can name without extra usings. Everything else stays visible but flagged,
## so the UI can explain why it is not offered.
func _mark_usable_hooks() -> void:
	var safe_types := RegEx.create_from_string("^[A-Za-z0-9_.<>,\\[\\]?]+$")
	var ok := ["Task", "System.Threading.Tasks.Task"]
	for h in _schema.hooks:
		var usable := ok.has(String(h["return_type"]))
		if usable:
			for p in h["params"]:
				var t := String(p)
				var sp := t.find(" ")
				var tn := t.substr(0, sp).strip_edges() if sp > 0 else t
				tn = tn.trim_prefix("this ").trim_prefix("ref ").trim_prefix("out ").trim_prefix("params ")
				if safe_types.search(tn) == null:
					usable = false
					break
		h["usable"] = usable
	_schema._reindex()


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

func _parse_commands(path: String) -> void:
	var text := _strip_comments(_read(path))
	var cls := ""
	var cm := RegEx.create_from_string("(?m)^\\s*(?:public|internal)\\s+(?:static\\s+|sealed\\s+|abstract\\s+)*class\\s+([A-Za-z_][A-Za-z0-9_]*)").search(text)
	if cm != null:
		cls = cm.get_string(1)
	if cls.is_empty():
		return
	var re := RegEx.create_from_string("(?m)^\\s*public\\s+static\\s+(?:async\\s+)?([A-Za-z0-9_<>,.\\[\\]?]+)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?:<[^>]*>)?\\s*\\(([^)]*)\\)")
	for m in re.search_all(text):
		var ret := m.get_string(1).strip_edges()
		var name := m.get_string(2)
		var params_raw := m.get_string(3).strip_edges()
		_schema.commands.append({
			"receiver": cls,
			"method": name,
			"returns": ret,
			"params": _split_params(params_raw),
			"signature": "%s %s(%s)" % [ret, name, params_raw],
			"file": path,
		})


# ---------------------------------------------------------------------------
# Localization
# ---------------------------------------------------------------------------

func _scan_localization(loc_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(loc_dir):
		_schema.warnings.append("找不到 localization 目录（本地化冲突检测将不可用）。")
		return
	var locales := DirAccess.get_directories_at(loc_dir)
	for locale in locales:
		var locale_dir := loc_dir.path_join(locale)
		for f in DirAccess.get_files_at(locale_dir):
			if not f.ends_with(".json"):
				continue
			var table := f.get_basename()
			var keys := _read_json_keys(locale_dir.path_join(f))
			if keys.is_empty():
				continue
			if not _schema.localization_keys.has(locale):
				_schema.localization_keys[locale] = {}
			(_schema.localization_keys[locale] as Dictionary)[table] = keys.keys()


## Read a localization table and return { key -> text }. Values may be nested
## objects in some tables, so only string leaves that look like keys are kept.
func _read_json_keys(path: String) -> Dictionary:
	var text := _read(path)
	if text.is_empty():
		return {}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		_schema.warnings.append("本地化文件解析失败：%s" % path.get_file())
		return {}
	var data: Variant = parser.data
	if not (data is Dictionary):
		return {}
	var out: Dictionary = {}
	for k in (data as Dictionary).keys():
		var v: Variant = (data as Dictionary)[k]
		if v is String or v is int or v is float:
			out[String(k)] = str(v)
		elif v is Dictionary:
			# Flatten one level: "TITLE": { "text": "..." }
			for k2 in (v as Dictionary).keys():
				var v2: Variant = (v as Dictionary)[k2]
				if v2 is String:
					out["%s.%s" % [k, k2]] = v2
	return out


## Localization tables that plausibly hold an enum member's display name,
## in priority order.
const LABEL_TABLES := ["enums", "card_keywords", "relic_rarities",
		"card_rarities", "card_types", "target_types", "value_props", "ui"]


## Resolve enum member labels from the game's own localization, e.g.
## CardRarity.Common -> the game's "COMMON.title" string when present.
func _resolve_enum_labels() -> void:
	var labels: Dictionary = {}
	for enum_name in _schema.enums.keys():
		for m in _schema.enums[enum_name]["members"]:
			var member := String(m["name"])
			var slug := CFIds.slugify(member)
			labels["%s.%s" % [enum_name, member]] = {
				"zhs": _lookup_label("zhs", slug),
				"eng": _lookup_label("eng", slug),
			}
	_schema.enum_labels = labels


## Try the usual places the game stores an enum member's display name.
func _lookup_label(locale: String, slug: String) -> String:
	for table in LABEL_TABLES:
		for suffix in [".title", ".name", ""]:
			var key := "%s%s" % [slug, suffix]
			if _schema.base_loc_has(locale, table, key):
				return _schema.loc(locale, table, key)
	return ""


## Attach localized display names to every scanned power.
##
## The full localization value tables are deliberately not cached (only their
## key sets are, to keep the scan fast), so the two small `powers` tables are
## read directly here. `powers.json` keys are `<ENTRY>.title`, and the entry is
## exactly `Slugify(<PowerClass>)` — the same string the scan already stores.
func _resolve_power_titles(loc_dir: String) -> void:
	if _schema.powers.is_empty():
		return
	var tables: Dictionary = {}
	for locale in ["zhs", "eng"]:
		var p := loc_dir.path_join(locale).path_join("powers.json")
		if FileAccess.file_exists(p):
			tables[locale] = _read_json_values(p)
	for p in _schema.powers:
		var entry := String(p.get("entry", ""))
		if entry.is_empty():
			continue
		for locale in tables.keys():
			var v := String((tables[locale] as Dictionary).get(entry + ".title", ""))
			p["title_%s" % locale] = v


## Read a flat localization table as { key -> text }, keeping real values.
func _read_json_values(path: String) -> Dictionary:
	var text := _read(path)
	if text.is_empty():
		return {}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {}
	var data: Variant = parser.data
	if not (data is Dictionary):
		return {}
	var out: Dictionary = {}
	for k in (data as Dictionary).keys():
		var v: Variant = (data as Dictionary)[k]
		if v is String:
			out[String(k)] = v
	return out


static func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t
