@tool
class_name CFSchema
extends RefCounted

## The reverse-inferred description of the host game.
##
## Nothing in here is invented: every enum member, power, pool and hook was read
## out of the unpacked game source by [CFSchemaScanner]. The only baked-in
## knowledge is the set of *anchors* below — a C# type name such as "CardRarity" —
## and even those live in [member ROLE_ANCHORS] so they can be re-pointed from
## the UI without touching code.

## Semantic role -> C# enum type name.
const ROLE_ANCHORS := {
	"card_type": "CardType",
	"card_rarity": "CardRarity",
	"card_keyword": "CardKeyword",
	"card_tag": "CardTag",
	"target_type": "TargetType",
	"pile_type": "PileType",
	"pile_position": "CardPilePosition",
	"value_prop": "ValueProp",
	"relic_rarity": "RelicRarity",
	"power_type": "PowerType",
	"combat_side": "CombatSide",
}

## Localization bundle each model kind writes into. These are the game's real
## base table names — a mod may only merge into *existing* tables.
const LOC_TABLE := {"card": "cards", "relic": "relics"}
## Fields the game resolves for every entry of that table.
const LOC_FIELDS := {
	"card": ["title", "description"],
	"relic": ["title", "description", "flavor"],
}
const LOCALES := ["zhs", "eng"]

## Every game locale, for the optional "also write these locales" feature.
const ALL_LOCALES := ["eng", "zhs", "deu", "esp", "fra", "ita", "jpn", "kor",
		"pol", "ptb", "rus", "spa", "tha", "tur"]

var source_root: String = ""
var scanned_at: String = ""
var scan_ms: int = 0
var files_visited: int = 0

## Enum type name -> { namespace, full_name, file, members: [{name, value}] }
var enums: Dictionary = {}
## Role -> anchor enum name.
var role_anchors: Dictionary = {}
## "EnumType.Member" -> { zhs, eng } resolved labels.
var enum_labels: Dictionary = {}

## Card pools: { class_name, namespace, entry, title, character, is_colorless, file }
var card_pools: Array = []
## Relic pools: { class_name, namespace, entry, title, character, is_shared, file }
var relic_pools: Array = []
## Characters: { class_name, namespace, entry, title, file }
var characters: Array = []

## CardModel field/virtual metadata: { name, type, doc }
var card_fields: Array = []
## RelicModel the same.
var relic_fields: Array = []

## Overridable hooks on AbstractModel: { name, return_type, params: [String],
## signature, callable_from_card, callable_from_relic, doc }
var hooks: Array = []
## Hook name -> its record, for O(1) lookup.
var hook_index: Dictionary = {}

## Command methods discovered in Commands/*.cs:
## { receiver, method, signature, returns, params: [String], file }
var commands: Array = []
var command_index: Dictionary = {}

## PowerModel subclasses: { class_name, namespace, entry, title_zhs, title_eng, is_debuff, file }
var powers: Array = []

## DynamicVar subclasses usable on cards: { type, generic, file }
var dynamic_var_types: Array = []

## Members exposed by `DynamicVarSet`: { property, type, file }.
##
## The exporter needs this because `base.DynamicVars.<X>` only compiles for the
## handful of properties the game actually declares (`Vulnerable`, `Dexterity`,
## `Poison`, …). A variable the user names anything else has to be read through
## the indexer: `base.DynamicVars["VulnerablePower"]`.
var dynamic_var_accessors: Array = []

## The game's own content, for conflict detection & "copy from" import.
var existing_cards: Array = []
var existing_relics: Array = []

## Localization: locale -> { table -> { key -> text } }
var localization: Dictionary = {}
## Localization: locale -> { table -> [keys] } (indices kept small)
var localization_keys: Dictionary = {}

var errors: Array = []
var warnings: Array = []


func _init() -> void:
	role_anchors = ROLE_ANCHORS.duplicate(true)


## Drop everything a scan produced, keeping only the role anchors. Without this
## a re-scan would append to the existing arrays and double every count.
func reset() -> void:
	source_root = ""
	scanned_at = ""
	scan_ms = 0
	files_visited = 0
	enums = {}
	role_anchors = ROLE_ANCHORS.duplicate(true)
	enum_labels = {}
	card_pools = []
	relic_pools = []
	characters = []
	card_fields = []
	relic_fields = []
	hooks = []
	hook_index = {}
	commands = []
	command_index = {}
	powers = []
	dynamic_var_types = []
	dynamic_var_accessors = []
	existing_cards = []
	existing_relics = []
	localization = {}
	localization_keys = {}
	errors = []
	warnings = []


# ---------------------------------------------------------------------------
# Enum access
# ---------------------------------------------------------------------------

func has_enum(enum_name: String) -> bool:
	return enums.has(enum_name)


# ---------------------------------------------------------------------------
# Dynamic var accessors & localized names
# ---------------------------------------------------------------------------

## The `DynamicVarSet` property that yields `name`, or "" when there is none.
##
## `name` may be either the property itself (`Vulnerable`) or the underlying var
## key the game stores it under (`VulnerablePower`) — the two are not the same,
## and callers usually have the key. Matching is exact in both directions: the
## accessor list is closed and short, so a substring guess would happily turn
## `StrengthPower` into some other property.
##
## **Informational only — never emit generated code from this.** A property
## reads a *fixed* key (`Weak` reads `_vars["WeakPower"]`), which only matches
## the var if it was constructed with its default name. See [method dynvar_expr]
## for why the exported C# must not use the property form.
func dynvar_accessor_for(name: String) -> String:
	var n := name.strip_edges()
	if n.is_empty():
		return ""
	for a in dynamic_var_accessors:
		var prop := String(a.get("property", ""))
		if prop == n:
			return prop
	for a in dynamic_var_accessors:
		var prop := String(a.get("property", ""))
		if not prop.is_empty() and n == prop + "Power":
			return prop
	return ""


## How to read a dynamic var by name in generated C#.
##
## **Always the string indexer, keyed by the emitted var name.**
##
## The property form (`base.DynamicVars.Weak`) is the tempting one, and it is a
## trap: the property reads a *fixed* key — `Weak` is
## `(PowerVar<WeakPower>)_vars["WeakPower"]` — while the exporter builds every
## power var from the user's own variable name
## (`new PowerVar<WeakPower>("Weak", 2m)`), so the set actually holds `"Weak"`.
## The property then throws, from inside the generated `OnPlay`:
##
##     System.Collections.Generic.KeyNotFoundException:
##       The given key 'WeakPower' was not present in the dictionary.
##
## which the game reports as
##
##     GameAction PlayCardAction card: CARD.WUDI ... completed with exception
##
## — the card is drawn, played, and then does nothing at all. That is the
## "crafted card cannot be used in game" bug, reproduced from the game's own log.
##
## The indexer is correct for *every* var type: the key is exactly the name the
## generated `CanonicalVars` registers and the name the emitted text templates
## interpolate (`DynamicVars.AddTo` uses `DynamicVar.Name`), so the three can
## never drift apart. `BaseValue`, `IntValue` and `UpgradeValueBy` all live on
## the `DynamicVar` base, so nothing is lost by not knowing the concrete type.
func dynvar_expr(name: String) -> String:
	var n := name.strip_edges()
	if n.is_empty():
		return "base.DynamicVars[null]"
	return "base.DynamicVars[\"%s\"]" % n


## The constructor facts the scanner read out of one DynamicVar subclass.
##
## `{ "default_name": "Block", "ctors": [["decimal", "ValueProp"], ["string", "decimal", "ValueProp"]] }`
## — i.e. which overloads exist and what the short one names the var. Empty when
## the type is unknown, so callers fall back to their own defaults instead of
## inventing a constructor call. See `CFSchemaScanner._var_ctor_facts`.
func var_ctor_info(type_name: String, generic: String = "") -> Dictionary:
	for d in dynamic_var_types:
		if String(d.get("type", "")) != type_name:
			continue
		if String(d.get("generic", "")) != generic:
			continue
		if not d.has("ctors"):
			return {}
		return {"default_name": String(d.get("default_name", "")), "ctors": d.get("ctors", [])}
	return {}


## The C# namespace a type name lives in, read from the game's own source tree.
##
## A generated relic override repeats the base hook's parameter types verbatim,
## e.g. `AfterAttack(PlayerChoiceContext choiceContext, AttackCommand command)`.
## `AttackCommand` lives in `MegaCrit.Sts2.Core.Commands.Builders`, which the
## emitter's fixed using list does not cover — the relic then fails with CS0246
## just because the user picked that trigger.
##
## The index is built lazily (one directory walk, no file reads) and each name is
## only read when something actually asks for it.
var _type_files: Dictionary = {}
var _type_files_root := ""

func type_namespace(type_name: String) -> String:
	var t := type_name.strip_edges()
	if t.is_empty():
		return ""
	if _type_files_root != source_root:
		_type_files = {}
		_type_files_root = source_root
		_index_type_files(source_root.path_join("src"))
	if not _type_files.has(t):
		return ""
	var cached := String(_type_files[t])
	if cached.begins_with("@"):
		var ns := _namespace_from_file(cached.substr(1))
		_type_files[t] = ns
		return ns
	return cached

func _index_type_files(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while not n.is_empty():
		if n.begins_with("."):
			n = d.get_next()
			continue
		var full := dir.path_join(n)
		if d.current_is_dir():
			_index_type_files(full)
		elif n.ends_with(".cs"):
			var base := n.get_basename()
			if not _type_files.has(base):
				_type_files[base] = "@" + full
		n = d.get_next()
	d.list_dir_end()

func _namespace_from_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var text := CFPaths.read_text(path)
	var m := RegEx.create_from_string("(?m)^\\s*namespace\\s+([A-Za-z0-9_.]+)\\s*[;{]").search(text)
	if m != null:
		return m.get_string(1)
	# Fallback: the game's layout is `src/<a>/<b>/Type.cs` -> MegaCrit.Sts2.<a>.<b>.
	var p := path.replace("\\", "/")
	var i := p.find("/src/")
	if i < 0:
		return ""
	var parts := p.substr(i + 5).get_base_dir().split("/")
	var out: Array = ["MegaCrit", "Sts2"]
	for part in parts:
		if not String(part).is_empty():
			out.append(String(part))
	return ".".join(out)


## The CLR namespace a scanned power lives in.
##
## Almost every power is `MegaCrit.Sts2.Core.Models.Powers`, but the game's test
## doubles sit in the `...Models.Powers.Mocks` sub-namespace. A generated file
## that only says `using ...Models.Powers;` leaves a `PowerCmd.Apply<MockXPower>`
## or `new PowerVar<MockXPower>(...)` unresolved (CS0246), so the whole mod fails
## to compile. Unknown names fall back to the main namespace.
func power_namespace(power_class: String) -> String:
	var c := power_class.strip_edges()
	for p in powers:
		if String(p.get("class_name", "")) != c:
			continue
		var ns := String(p.get("namespace", ""))
		return ns if not ns.is_empty() else "MegaCrit.Sts2.Core.Models.Powers"
	return "MegaCrit.Sts2.Core.Models.Powers"


## The localized display name of a power, e.g. `VulnerablePower` -> `易伤`.
##
## Falls back to the class name with a `Power` suffix stripped, so a power the
## game does not localize still shows something readable.
func power_title(power_class: String, locale: String = "zhs") -> String:
	for p in powers:
		if String(p.get("class_name", "")) != power_class:
			continue
		var t := String(p.get("title_%s" % locale, ""))
		if not t.is_empty():
			return t
		if locale != "eng":
			var en := String(p.get("title_eng", ""))
			if not en.is_empty():
				return en
		break
	return power_class.trim_suffix("Power")


## English display name of a power, for a `中文名（English）` label.
func power_title_en(power_class: String) -> String:
	return power_title(power_class, "eng")


## `易伤（Vulnerable）` — the label used in pickers so a Chinese name can be
## matched back to the exact C# class the user has to reason about.
func power_label(power_class: String) -> String:
	var zh := power_title(power_class, "zhs")
	var en := power_title_en(power_class)
	if zh.is_empty() or zh == en:
		return power_class
	return "%s（%s）" % [zh, en]


func anchor_for(role: String) -> String:
	return String(role_anchors.get(role, ""))


## Members of the enum filling `role`, in declaration order. Returns [] (never a
## fabricated list) when the enum is unknown.
func members_for_role(role: String) -> Array:
	var anchor := anchor_for(role)
	if anchor.is_empty() or not enums.has(anchor):
		return []
	var out: Array = []
	for m in enums[anchor]["members"]:
		out.append(String(m["name"]))
	return out


## Member names excluding `None`, which is what a picker should offer.
func selectable_for_role(role: String) -> Array:
	var out: Array = []
	for m in members_for_role(role):
		if m != "None":
			out.append(m)
	return out


func label_for(role: String, member: String, locale: String = "zhs") -> String:
	var anchor := anchor_for(role)
	var key := "%s.%s" % [anchor, member]
	var labels: Dictionary = enum_labels.get(key, {})
	var t := String(labels.get(locale, ""))
	if t.strip_edges().is_empty():
		t = String(labels.get("eng", ""))
	if t.strip_edges().is_empty():
		t = member
	return t


# ---------------------------------------------------------------------------
# Pools
# ---------------------------------------------------------------------------

func pool_by_class(cls: String, relic: bool = false) -> Dictionary:
	var list := relic_pools if relic else card_pools
	for p in list:
		if String(p.get("class_name", "")) == cls:
			return p
	return {}


func pool_namespaces(relic: bool = false) -> Array:
	var out: Dictionary = {}
	for p in (relic_pools if relic else card_pools):
		out[String(p.get("namespace", ""))] = true
	var keys := out.keys()
	keys.sort()
	return keys


## Characters that actually own a card pool, for the starting-deck feature.
func deck_targets(custom_characters: Array = []) -> Array:
	var out: Array = []
	for c in characters:
		var cls := String(c.get("class_name", ""))
		var pool := ""
		for p in card_pools:
			if String(p.get("character", "")) == cls:
				pool = String(p.get("class_name", ""))
				break
		out.append({
			"class_name": cls,
			"namespace": String(c.get("namespace", "")),
			"entry": String(c.get("entry", "")),
			"title": String(c.get("title", cls)),
			"pool": pool,
		})
	for custom in custom_characters:
		var cls := String(custom.get("id", custom.get("class_name", "")))
		if cls.is_empty():
			continue
		var exists := false
		for target in out:
			if String(target.get("class_name", "")) == cls:
				exists = true
				break
		if exists:
			continue
		out.append({
			"class_name": cls,
			"namespace": String(custom.get("namespace", "")),
			"entry": String(custom.get("entry", cls)),
			"title": String(custom.get("name", cls)),
			"pool": String(custom.get("card_pool", "")),
			"custom": true,
		})
	out.sort_custom(func(a, b): return String(a["title"]) < String(b["title"]))
	return out


# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

func hook(name: String) -> Dictionary:
	return hook_index.get(name, {})


## Display name for the relic trigger picker. The C# hook name stays first so
## exported code and game logs remain easy to match; the Chinese explanation is
## appended for users who do not know the API vocabulary yet.
const HOOK_TRANSLATIONS := {
	"AfterObtained": "获得遗物后",
	"AfterRemoved": "移除遗物后",
	"AfterActEntered": "进入章节后",
	"BeforeCombatStart": "战斗开始前",
	"BeforeCombatStartLate": "战斗开始前（后置）",
	"AfterCombatEnd": "战斗结束后",
	"AfterCombatVictory": "战斗胜利后",
	"AfterCombatVictoryEarly": "战斗胜利后（前置）",
	"BeforeAttack": "攻击前",
	"AfterAttack": "攻击后",
	"BeforeCardPlayed": "打出卡牌前",
	"AfterCardPlayed": "打出卡牌后",
	"AfterCardPlayedLate": "打出卡牌后（后置）",
	"AfterCardDrawn": "抽到卡牌后",
	"AfterCardDiscarded": "弃牌后",
	"AfterCardExhausted": "消耗卡牌后",
	"AfterCardChangedPiles": "卡牌移动后",
	"AfterCardEnteredCombat": "卡牌进入战斗后",
	"AfterPlayerTurnStart": "玩家回合开始后",
	"AfterPlayerTurnStartEarly": "玩家回合开始后（前置）",
	"AfterPlayerTurnStartLate": "玩家回合开始后（后置）",
	"BeforeSideTurnStart": "阵营回合开始前",
	"BeforeSideTurnEnd": "阵营回合结束前",
	"BeforeSideTurnEndEarly": "阵营回合结束前（前置）",
	"BeforeSideTurnEndVeryEarly": "阵营回合结束前（最前置）",
	"AfterSideTurnStart": "阵营回合开始后",
	"AfterSideTurnEnd": "阵营回合结束后",
	"AfterSideTurnEndLate": "阵营回合结束后（后置）",
	"BeforeHandDraw": "抽牌前",
	"BeforeHandDrawLate": "抽牌前（后置）",
	"AfterHandEmptied": "手牌清空后",
	"AfterDamageGiven": "造成伤害后",
	"AfterDamageReceived": "受到伤害后",
	"AfterDamageReceivedLate": "受到伤害后（后置）",
	"BeforeDamageReceived": "受到伤害前",
	"AfterBlockGained": "获得格挡后",
	"BeforeBlockGained": "获得格挡前",
	"AfterBlockBroken": "格挡破碎后",
	"AfterBlockCleared": "格挡清除后",
	"AfterDeath": "死亡后",
	"BeforeDeath": "死亡前",
	"AfterDiedToDoom": "被末日击杀后",
	"AfterEnergySpent": "消耗能量后",
	"AfterEnergyReset": "能量重置后",
	"AfterEnergyResetLate": "能量重置后（后置）",
	"AfterEnergyGained": "获得能量后",
	"AfterGoldGained": "获得金币后",
	"AfterStarsGained": "获得星能后",
	"AfterStarsSpent": "消耗星能后",
	"AfterOrbChanneled": "引导充能球后",
	"AfterOrbEvoked": "激发充能球后",
	"AfterPotionUsed": "使用药水后",
	"AfterPotionDiscarded": "弃置药水后",
	"AfterPotionProcured": "获得药水后",
	"AfterRoomEntered": "进入房间后",
	"BeforeRoomEntered": "进入房间前",
	"AfterRestSiteHeal": "休息处治疗后",
	"AfterRestSiteSmith": "休息处锻造后",
	"AfterRewardTaken": "领取奖励后",
	"AfterShuffle": "洗牌后",
	"AfterForge": "锻造后",
	"AfterSummon": "召唤后",
	"AfterOstyRevived": "Osty复活后",
	"AfterCreatureAddedToCombat": "生物加入战斗后",
	"AfterCurrentHpChanged": "当前生命变化后",
	"AfterItemPurchased": "购买物品后",
	"AfterFlush": "清空手牌后",
	"BeforeFlush": "清空手牌前",
	"BeforeFlushLate": "清空手牌前（后置）",
	"AfterAutoPrePlayPhaseEntered": "自动出牌前阶段开始后",
	"AfterAutoPrePlayPhaseEnteredEarly": "自动出牌前阶段开始后（前置）",
	"AfterAutoPrePlayPhaseEnteredLate": "自动出牌前阶段开始后（后置）",
	"AfterAutoPostPlayPhaseEntered": "自动出牌后阶段开始后",
	"AfterTakingExtraTurn": "获得额外回合后",
	"AfterPreventingDeath": "阻止死亡后",
	"AfterPreventingDraw": "阻止抽牌后",
	"AfterPreventingBlockClear": "阻止清除格挡后",
	"ShouldDraw": "是否允许抽牌",
	"ShouldPlay": "是否允许打出",
	"ShouldDie": "是否允许死亡",
	"ShouldAllowHitting": "是否允许命中",
	"ShouldAllowTargeting": "是否允许指定目标",
	"ShouldClearBlock": "是否允许清除格挡",
	"ShouldAddToDeck": "是否允许加入牌组",
	"ModifyDamageAdditive": "修改伤害（加算）",
	"ModifyDamageMultiplicative": "修改伤害（乘算）",
	"ModifyDamageCap": "修改伤害上限",
	"ModifyBlockAdditive": "修改格挡（加算）",
	"ModifyBlockMultiplicative": "修改格挡（乘算）",
	"ModifyEnergyGain": "修改获得能量",
	"ModifyGoldGained": "修改获得金币",
	"ModifyHandDraw": "修改抽牌数量",
	"ModifyMaxEnergy": "修改最大能量",
	"ModifyXValue": "修改X数值",
}

## User-maintained trigger descriptions live in `翻译.txt` next to the project.
## Load them lazily so the editor always reflects that file while retaining the
## built-in table as a fallback when the file is absent or incomplete.
static var _file_hook_translations: Dictionary = {}
static var _file_hook_translations_loaded := false


static func _load_file_hook_translations() -> void:
	if _file_hook_translations_loaded:
		return
	_file_hook_translations_loaded = true
	var path := ProjectSettings.globalize_path("res://翻译.txt")
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var sep := line.find("：")
		if sep < 0:
			sep = line.find(":")
		if sep <= 0:
			continue
		var name := line.substr(0, sep).strip_edges()
		var text := line.substr(sep + 1).strip_edges()
		if text.ends_with("。") or text.ends_with("."):
			text = text.substr(0, text.length() - 1).strip_edges()
		if not name.is_empty() and not text.is_empty():
			_file_hook_translations[name] = text
	file.close()


func hook_label(name: String) -> String:
	var n := name.strip_edges()
	if n.is_empty():
		return ""
	_load_file_hook_translations()
	var zh := String(_file_hook_translations.get(n, HOOK_TRANSLATIONS.get(n, "")))
	if zh.is_empty():
		zh = _hook_fallback_translation(n)
	return n if zh.is_empty() else "%s（%s）" % [n, zh]


static func _hook_fallback_translation(name: String) -> String:
	var words: Array = []
	var re := RegEx.create_from_string("[A-Z][a-z0-9]*")
	for m in re.search_all(name):
		words.append(m.get_string())
	var dict := {
		"After": "之后", "Before": "之前", "Modify": "修改", "Should": "是否",
		"Try": "尝试", "Late": "后置", "Early": "前置", "Very": "最前置",
		"Act": "章节", "Combat": "战斗", "Attack": "攻击", "Card": "卡牌",
		"Played": "打出后", "Play": "打出", "Draw": "抽牌", "Discard": "弃牌",
		"Exhausted": "消耗后", "Damage": "伤害", "Received": "受到后", "Given": "造成后",
		"Block": "格挡", "Gained": "获得后", "Cleared": "清除后", "Broken": "破碎后",
		"Death": "死亡", "Died": "死亡后", "Energy": "能量", "Gold": "金币",
		"Stars": "星能", "Potion": "药水", "Room": "房间", "Entered": "进入后",
		"Player": "玩家", "Turn": "回合", "Side": "阵营", "Start": "开始",
		"End": "结束", "Shuffle": "洗牌", "Power": "能力", "Reward": "奖励",
		"Targeting": "指定目标", "Target": "目标", "Summon": "召唤", "Orb": "充能球",
		"Forge": "锻造", "Hp": "生命", "Current": "当前", "Changed": "变化后",
		"Preventing": "阻止", "Allow": "允许", "Add": "加入", "To": "到",
	}
	var out := ""
	for w in words:
		out += String(dict.get(String(w), ""))
	return out


## Hooks that a card's OnPlay-adjacent code can reasonably call, and that are
## safe to override in a generated subclass (return Task, no exotic params).
func usable_hooks() -> Array:
	var out: Array = []
	for h in hooks:
		if not bool(h.get("usable", false)):
			continue
		out.append(h)
	out.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	return out


# ---------------------------------------------------------------------------
# Localization
# ---------------------------------------------------------------------------

func loc(locale: String, table: String, key: String, fallback: String = "") -> String:
	var by_locale: Dictionary = localization.get(locale, {})
	var by_table: Dictionary = by_locale.get(table, {})
	var v := String(by_table.get(key, ""))
	if v.is_empty():
		var eng: Dictionary = localization.get("eng", {})
		v = String((eng.get(table, {}) as Dictionary).get(key, ""))
	return v if not v.is_empty() else fallback


## True when the game itself already defines this localization key.
func base_loc_has(locale: String, table: String, key: String) -> bool:
	var by_locale: Dictionary = localization.get(locale, {})
	var by_table: Dictionary = by_locale.get(table, {})
	return by_table.has(key)


func existing_card_ids() -> Dictionary:
	var out: Dictionary = {}
	for c in existing_cards:
		out[String(c.get("entry", ""))] = true
	return out


func existing_relic_ids() -> Dictionary:
	var out: Dictionary = {}
	for r in existing_relics:
		out[String(r.get("entry", ""))] = true
	return out


# ---------------------------------------------------------------------------
# Persistence (a plain JSON cache so startup is instant)
# ---------------------------------------------------------------------------

func to_cache_dict() -> Dictionary:
	return {
		"cache_version": 3,
		"source_root": source_root,
		"scanned_at": scanned_at,
		"scan_ms": scan_ms,
		"files_visited": files_visited,
		"enums": enums,
		"role_anchors": role_anchors,
		"enum_labels": enum_labels,
		"card_pools": card_pools,
		"relic_pools": relic_pools,
		"characters": characters,
		"card_fields": card_fields,
		"relic_fields": relic_fields,
		"hooks": hooks,
		"commands": commands,
		"powers": powers,
		"dynamic_var_types": dynamic_var_types,
		"dynamic_var_accessors": dynamic_var_accessors,
		"existing_cards": existing_cards,
		"existing_relics": existing_relics,
		"localization_keys": localization_keys,
		"errors": errors,
		"warnings": warnings,
	}


func load_cache_dict(d: Dictionary) -> bool:
	# v2 added the DynamicVar constructor facts (`default_name` / `ctors`); a v1
	# cache would leave `var_ctor_info` empty and silently fall back to guessing.
	if int(d.get("cache_version", 0)) != 3:
		return false
	reset()
	source_root = String(d.get("source_root", ""))
	scanned_at = String(d.get("scanned_at", ""))
	scan_ms = int(d.get("scan_ms", 0))
	files_visited = int(d.get("files_visited", 0))
	enums = d.get("enums", {})
	role_anchors = d.get("role_anchors", ROLE_ANCHORS.duplicate(true))
	enum_labels = d.get("enum_labels", {})
	card_pools = d.get("card_pools", [])
	relic_pools = d.get("relic_pools", [])
	characters = d.get("characters", [])
	card_fields = d.get("card_fields", [])
	relic_fields = d.get("relic_fields", [])
	hooks = d.get("hooks", [])
	commands = d.get("commands", [])
	powers = d.get("powers", [])
	dynamic_var_types = d.get("dynamic_var_types", [])
	dynamic_var_accessors = d.get("dynamic_var_accessors", [])
	existing_cards = d.get("existing_cards", [])
	existing_relics = d.get("existing_relics", [])
	localization_keys = d.get("localization_keys", {})
	errors = d.get("errors", [])
	warnings = d.get("warnings", [])
	_reindex()
	return true


func _reindex() -> void:
	hook_index = {}
	for h in hooks:
		hook_index[String(h.get("name", ""))] = h
	command_index = {}
	for c in commands:
		command_index["%s.%s" % [c.get("receiver", ""), c.get("method", "")]] = c


# ---------------------------------------------------------------------------
# Summary for the UI
# ---------------------------------------------------------------------------

func summary() -> String:
	if source_root.is_empty():
		return "未找到解包数据目录"
	return "%s · %d 个文件 · %d 枚举 · %d 卡池 · %d 遗物池 · %d 能力 · %d 触发时机 · %d 命令" % [
		scanned_at, files_visited, enums.size(), card_pools.size(),
		relic_pools.size(), powers.size(), hooks.size(), commands.size()]


## Compilation accepts abstract generic arguments, but the game cannot create them.
func power_error(class_name_: String) -> String:
	for power in powers:
		if String(power.get("class_name", "")) == class_name_:
			if bool(power.get("is_abstract", false)):
				return "%s 是抽象状态，无法直接施加，会中断后续效果。请选择具体状态。" % class_name_
			if bool(power.get("is_mock", false)):
				return "%s 是游戏测试替身，不能用于正式卡牌。" % class_name_
			return ""
	return "未找到状态 %s，请重新扫描游戏或选择有效状态。" % class_name_
