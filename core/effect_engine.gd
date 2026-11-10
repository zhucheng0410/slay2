@tool
class_name CFEffects
extends RefCounted

## The structured effect model: effect taxonomy, binding to the game's real
## command API, simulation, and C# code emission.
##
## ## Why the taxonomy is a table and not an enum
## Effect *kinds* ("damage", "block", …) are this tool's own vocabulary, not the
## game's. What must not be invented is the **binding** of a kind to a real game
## API. Every `receiver`/`method` pair below is validated against the command
## list scanned out of `src/Core/Commands/*.cs` by [CFSchemaScanner], and any
## binding that cannot be resolved is reported so the UI flags it instead of
## silently emitting broken code.

## Effect kind -> { id, label, group, receiver, method, needs, default_target, help }
##   needs: comma-separated subset of value, power, card, keyword, pile
const KINDS := [
	{
		"id": "damage", "label": "造成伤害", "group": "输出",
		"receiver": "DamageCmd", "method": "Attack",
		"needs": "value", "default_target": "card_target",
		"help": "走 DamageCmd.Attack 流式 API，用「段数」实现多段攻击；遗物没有 FromCard，会自动改用 CreatureCmd.Damage。",
	},
	{
		"id": "damage_direct", "label": "直接伤害（绕过攻击流程）", "group": "输出",
		"receiver": "CreatureCmd", "method": "Damage",
		"needs": "value", "default_target": "card_target",
		"help": "CreatureCmd.Damage，可指定 ValueProp（例如 Unblockable 无视格挡）。",
	},
	{
		"id": "block", "label": "获得格挡", "group": "防御",
		"receiver": "CreatureCmd", "method": "GainBlock",
		"needs": "value", "default_target": "self",
		"help": "CreatureCmd.GainBlock：把格挡给「目标」；目标选「自己」时就是打出这张牌的玩家。",
	},
	{
		"id": "heal", "label": "治疗", "group": "生命",
		"receiver": "CreatureCmd", "method": "Heal",
		"needs": "value", "default_target": "self",
		"help": "CreatureCmd.Heal。",
	},
	{
		"id": "gain_max_hp", "label": "提升最大生命", "group": "生命",
		"receiver": "CreatureCmd", "method": "GainMaxHp",
		"needs": "value", "default_target": "self",
		"help": "CreatureCmd.GainMaxHp。",
	},
	{
		"id": "energy", "label": "获得能量", "group": "资源",
		"receiver": "PlayerCmd", "method": "GainEnergy",
		"needs": "value", "default_target": "self",
		"help": "PlayerCmd.GainEnergy。",
	},
	{
		"id": "star", "label": "获得星能", "group": "资源",
		"receiver": "PlayerCmd", "method": "GainStars",
		"needs": "value", "default_target": "self",
		"help": "PlayerCmd.GainStars。",
	},
	{
		"id": "draw", "label": "抽牌", "group": "牌堆",
		"receiver": "CardPileCmd", "method": "Draw",
		"needs": "value", "default_target": "self",
		"help": "CardPileCmd.Draw。",
	},
	{
		"id": "discard", "label": "弃牌", "group": "牌堆",
		"receiver": "CardCmd", "method": "Discard",
		"needs": "value", "default_target": "self",
		"help": "从手牌中选 N 张弃掉（CardSelectCmd.FromHandForDiscard + CardCmd.Discard）。数值=张数。",
	},
	{
		"id": "exhaust", "label": "消耗", "group": "牌堆",
		"receiver": "CardCmd", "method": "Exhaust",
		"needs": "value", "default_target": "self",
		"help": "从手牌中选 N 张消耗（CardSelectCmd.FromHand + CardCmd.Exhaust）。数值=张数。",
	},
	{
		"id": "upgrade_card", "label": "升级卡牌", "group": "牌堆",
		"receiver": "CardCmd", "method": "Upgrade",
		"needs": "value", "default_target": "self",
		"help": "从手牌中选 N 张升级（CardSelectCmd.FromHand + CardCmd.Upgrade）。数值=张数。",
	},
	{
		"id": "generate_card", "label": "生成一张牌", "group": "牌堆",
		"receiver": "CardPileCmd", "method": "AddGeneratedCardToCombat",
		"needs": "card,pile", "default_target": "self",
		"help": "先 CombatState.CreateCard 再 CardPileCmd.AddGeneratedCardToCombat，需要指定牌 ID、目标牌堆与位置。",
	},
	{
		"id": "apply_power", "label": "施加 Buff / Debuff", "group": "增益减益",
		"receiver": "PowerCmd", "method": "Apply",
		"needs": "value,power", "default_target": "card_target",
		"help": "PowerCmd.Apply<TPower>，Power 取值来自扫描到的 PowerModel 子类。",
	},
	{
		"id": "add_keyword", "label": "给这张牌附加关键字", "group": "牌堆",
		"receiver": "CardCmd", "method": "ApplyKeyword",
		"needs": "keyword", "default_target": "self",
		"help": "给这张牌附加关键字（CardModel.AddKeyword）；只对卡牌有效，遗物上没有这个方法。",
	},
	{
		"id": "gain_gold", "label": "获得金币", "group": "资源",
		"receiver": "PlayerCmd", "method": "GainGold",
		"needs": "value", "default_target": "self",
		"help": "PlayerCmd.GainGold。",
	},
	{
		"id": "forge", "label": "锻造", "group": "资源",
		"receiver": "ForgeCmd", "method": "Forge",
		"needs": "value", "default_target": "self",
		"help": "ForgeCmd.Forge。",
	},
]

## Target vocabulary -> the C# expression used for it, plus the fluent suffix
## appended to an AttackCommand.
##
## `param` entries ("_creature", "_card", …) are resolved from the current
## relic trigger's parameter bindings, so a relic can address its own hook
## arguments instead of only the owner.
##
## Every list target reads the combat state through
## `base.Owner.Creature.CombatState`. `RelicModel` has **no** `CombatState`
## member at all — the game's own relic writes
## `base.Owner.Creature.CombatState.HittableEnemies` (CharonsAshes) — while
## `CardModel.CombatState` is nullable. One form, both scopes, no CS1061/CS0103.
##
## `list: true` marks the entries whose expression is an `IEnumerable<Creature>`.
## The commands that take a single `Creature` (GainBlock / Heal / GainMaxHp)
## then wrap the call in a `foreach`; the ones with an `IEnumerable<Creature>`
## overload (CreatureCmd.Damage, PowerCmd.Apply) must not be wrapped.
##
## `attack: ""` means `AttackCommand` cannot express the target: the whole API is
## `Targeting(Creature)`, `TargetingAllOpponents(ICombatState)` and
## `TargetingRandomOpponents(ICombatState)` — there is no ally/all-list variant.
## The emitter then falls back to `CreatureCmd.Damage`.
const TARGETS := [
	{"id": "card_target", "label": "卡牌目标", "expr": "cardPlay.Target", "attack": "Targeting(cardPlay.Target)"},
	{"id": "self", "label": "自己 / 拥有者", "expr": "base.Owner.Creature", "attack": "Targeting(base.Owner.Creature)"},
	{"id": "all_enemies", "label": "所有敌人", "expr": "base.Owner.Creature.CombatState.HittableEnemies", "attack": "TargetingAllOpponents(base.Owner.Creature.CombatState)", "list": true},
	{"id": "random_enemy", "label": "随机敌人", "expr": "base.Owner.Creature.CombatState.HittableEnemies.First()", "attack": "TargetingRandomOpponents(base.Owner.Creature.CombatState)"},
	{"id": "all_allies", "label": "所有友方（含自己）", "expr": "base.Owner.Creature.CombatState.Allies", "attack": "", "list": true},
]

const CONDITION_OPS := [">=", ">", "<=", "<", "==", "!="]
const LOOP_MODES := [
	{"id": "none", "label": "不循环"},
	{"id": "count", "label": "固定次数"},
	{"id": "var", "label": "按变量次数"},
	{"id": "hits", "label": "按段数"},
	{"id": "energy", "label": "按消耗的能量 (X)"},
]
const CHARGE_MODES := [
	{"id": "always", "label": "每次都触发"},
	{"id": "every_n", "label": "每 N 次触发"},
	{"id": "first_n", "label": "仅前 N 次"},
	{"id": "once", "label": "仅一次"},
]


static func kind_by_id(kind_id: String) -> Dictionary:
	for k in KINDS:
		if String(k["id"]) == kind_id:
			return k
	return {}


static func kind_ids() -> Array:
	var out: Array = []
	for k in KINDS:
		out.append(String(k["id"]))
	return out


static func kind_label(kind_id: String) -> String:
	var k := kind_by_id(kind_id)
	return String(k.get("label", kind_id)) if not k.is_empty() else kind_id


## Kinds grouped for the "add effect" menu: [{ group, kinds: [kind] }]
static func grouped_kinds() -> Array:
	var order: Array = []
	var by_group: Dictionary = {}
	for k in KINDS:
		var g := String(k["group"])
		if not by_group.has(g):
			by_group[g] = []
			order.append(g)
		(by_group[g] as Array).append(k)
	var out: Array = []
	for g in order:
		out.append({"group": g, "kinds": by_group[g]})
	return out


static func target_by_id(target_id: String) -> Dictionary:
	for t in TARGETS:
		if String(t["id"]) == target_id:
			return t
	return {}


## Human-readable label for a target id, falling back to the raw id so a card
## saved with an unknown/removed target still renders something.
static func target_label(target_id: String) -> String:
	var t := target_by_id(target_id)
	if t.is_empty():
		return target_id
	return String(t.get("label", target_id))


## Which "side" a target points at, used to colour the target chip.
##   "self"  → you (green)   "enemy" → opponents (red)   "any" → neutral (blue)
static func target_side(target_id: String) -> String:
	match target_id:
		"self":
			return "self"
		"all_enemies", "random_enemy":
			return "enemy"
		_:
			return "any"


# ---------------------------------------------------------------------------
# Binding resolution against the live schema
# ---------------------------------------------------------------------------

## Resolve every effect kind to a concrete method discovered in the game source.
## Returns { bindings: { kind -> { receiver, method, signature, found } },
##           missing: [kind] }
static func resolve_bindings(schema: CFSchema) -> Dictionary:
	var bindings: Dictionary = {}
	var missing: Array = []
	for k in KINDS:
		var kind_id := String(k["id"])
		var key := "%s.%s" % [k["receiver"], k["method"]]
		var found: Dictionary = schema.command_index.get(key, {})
		bindings[kind_id] = {
			"receiver": k["receiver"],
			"method": k["method"],
			"signature": String(found.get("signature", "")),
			"found": not found.is_empty(),
		}
		if found.is_empty():
			missing.append(kind_id)
	return {"bindings": bindings, "missing": missing}


## Every power the schema knows, as options for the Buff/Debuff picker.
##
## Each option carries everything a search box needs to match on, so the UI can
## filter without re-deriving strings per keystroke:
##   `value`   — the C# class name (`VulnerablePower`), what gets stored
##   `label`   — `易伤（Vulnerable）`, what the user sees
##   `zh`      — `易伤`, the localized Chinese title (also the primary search key)
##   `en`      — `Vulnerable`, the English title
##   `haystack`— a pre-lowercased blob of all of the above, for `contains()`
static func power_options(schema: CFSchema) -> Array:
	var out: Array = []
	for p in schema.powers:
		# `...Models.Powers.Mocks` holds the game's test doubles. They are real,
		# public types (so they compile), but they are stubs — picking one gives a
		# card that does nothing sensible in game, so the picker never offers them.
		if bool(p.get("is_mock", false)) or bool(p.get("is_abstract", false)):
			continue
		var cls := String(p.get("class_name", ""))
		var entry := String(p.get("entry", ""))
		# `power_title` reads the powers.json we load at scan time; `schema.loc`
		# only serves the (never-populated) value dict, so it would come back
		# empty and every row would read "  (VulnerablePower)".
		var zh := schema.power_title(cls, "zhs")
		var en := schema.power_title_en(cls)
		if zh.is_empty():
			zh = cls
		if en.is_empty():
			en = cls.trim_suffix("Power")
		out.append({
			"value": cls,
			"label": "%s（%s）" % [zh, cls],
			"zh": zh,
			"en": en,
			"entry": entry,
			"is_debuff": bool(p.get("is_debuff", false)),
			# Lowercased once here rather than per keystroke in the UI. Includes
			# the bare class name minus its `Power` suffix so typing "vulnerable"
			# finds `VulnerablePower` even when English and Chinese both differ.
			"haystack": ("%s %s %s %s" % [zh, en, cls, cls.trim_suffix("Power")]).to_lower(),
		})
	out.sort_custom(func(a, b): return String(a["label"]) < String(b["label"]))
	return out


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

static func default_context() -> Dictionary:
	return {
		"energy": 3.0, "hand": 5.0, "draw_pile": 10.0, "discard_pile": 3.0,
		"enemy_count": 1.0, "x_value": 0.0, "strength": 0.0, "dexterity": 0.0,
		"weak": 0.0, "vulnerable": 0.0, "trigger_index": 0.0,
	}


## Walk a card's effect list and total up the result. The numbers are an
## **estimate**: the model covers the modifiers the game documents on card text
## (Strength, Dexterity, Vulnerable, Weak) but not relic interactions.
static func simulate_card(card: Dictionary, ctx_in: Dictionary = {}) -> Dictionary:
	var ctx := default_context()
	for k in ctx_in.keys():
		ctx[k] = ctx_in[k]
	var energy_cost := float(card.get("cost", 0))
	if bool(card.get("has_x_cost", false)):
		energy_cost = float(ctx.get("x_value", 0.0))
		ctx["is_x_cost"] = true
	ctx["energy"] = float(ctx.get("energy", 3.0)) - energy_cost

	var state := _empty_state(ctx, -energy_cost)
	var log: Array = []
	var values := CFDesign.var_values(card, false)
	_walk_effects(card.get("effects", []), state, ctx, values, log, 0)

	return {
		"totals": _totals(state, energy_cost),
		"log": log,
		"notes": [
			"费用按 %s 计。" % ("X 费（X=%d）" % int(energy_cost) if bool(card.get("has_x_cost", false)) else str(int(energy_cost))),
			"伤害按 (基础值 + 力量) × 易伤加成 × 虚弱减成 × 段数 估算。",
			"未模拟遗物、能力牌与敌方格挡的交互。",
		],
	}


## Simulate one relic trigger firing once.
static func simulate_relic(relic: Dictionary, trigger_index: int, ctx_in: Dictionary = {}) -> Dictionary:
	var ctx := default_context()
	for k in ctx_in.keys():
		ctx[k] = ctx_in[k]
	var triggers: Array = relic.get("triggers", [])
	if trigger_index < 0 or trigger_index >= triggers.size():
		return {"totals": _totals(_empty_state(ctx, 0.0), 0.0), "log": [], "notes": []}
	var t: Dictionary = triggers[trigger_index]
	var state := _empty_state(ctx, 0.0)
	var log: Array = []
	var values := CFDesign.var_values(relic, false)
	log.append({"depth": 0, "kind": "trigger", "times": 1,
			"detail": "触发时机 %s" % String(t.get("hook", "?"))})
	_walk_effects(t.get("effects", []), state, ctx, values, log, 1)
	return {
		"totals": _totals(state, 0.0),
		"log": log,
		"notes": ["按该触发时机触发一次结算；「每 N 次」在此按一次计入。"],
	}


static func _empty_state(ctx: Dictionary, energy_delta: float) -> Dictionary:
	return {
		"damage": 0.0, "block": 0.0, "energy_delta": energy_delta, "drawn": 0.0,
		"discarded": 0.0, "exhausted": 0.0, "generated": 0.0, "heal": 0.0,
		"hp_loss": 0.0, "gold": 0.0, "powers": {}, "hand": float(ctx.get("hand", 5.0)),
	}


static func _totals(state: Dictionary, energy_cost: float) -> Dictionary:
	return {
		"damage": float(state["damage"]), "block": float(state["block"]),
		"energy_delta": float(state["energy_delta"]), "energy_cost": energy_cost,
		"drawn": float(state["drawn"]), "discarded": float(state["discarded"]),
		"exhausted": float(state["exhausted"]), "generated": float(state["generated"]),
		"heal": float(state["heal"]), "hp_loss": float(state["hp_loss"]),
		"gold": float(state["gold"]), "powers": state["powers"],
		"hand_after": maxf(0.0, float(state["hand"])),
	}


static func _walk_effects(effects: Array, state: Dictionary, ctx: Dictionary,
		values: Dictionary, log: Array, depth: int) -> void:
	for e in effects:
		if not bool(e.get("enabled", true)):
			continue
		var cond: Dictionary = e.get("condition", {})
		if not _eval_condition(cond, ctx, values):
			log.append({"depth": depth, "kind": String(e.get("kind", "")), "times": 0,
					"detail": "条件不满足，已跳过"})
			continue
		var times := _loop_count(e, ctx, values)
		if times <= 0:
			continue
		var detail := _apply_effect(e, state, ctx, values, times)
		log.append({"depth": depth, "kind": String(e.get("kind", "")),
				"times": times, "detail": detail})


static func _apply_effect(e: Dictionary, state: Dictionary, ctx: Dictionary,
		values: Dictionary, times: int) -> String:
	var kind := String(e.get("kind", ""))
	var amount := _effect_amount(e, values, ctx)
	match kind:
		"damage", "damage_direct":
			var per_hit := amount + float(ctx.get("strength", 0.0))
			if float(ctx.get("vulnerable", 0.0)) > 0.0:
				per_hit *= 1.5
			if float(ctx.get("weak", 0.0)) > 0.0:
				per_hit *= 0.75
			var hits := maxi(1, int(e.get("hits", 1)))
			var total := per_hit * float(hits) * float(times)
			state["damage"] = float(state["damage"]) + total
			return "%d 段 × %d 次，合计 %.1f 伤害" % [hits, times, total]
		"block":
			var b := (amount + float(ctx.get("dexterity", 0.0))) * float(times)
			state["block"] = float(state["block"]) + b
			return "合计 %.1f 格挡" % b
		"energy":
			var en := amount * float(times)
			state["energy_delta"] = float(state["energy_delta"]) + en
			return "合计 +%.1f 能量" % en
		"star":
			return "合计 +%.1f 星能" % (amount * float(times))
		"draw":
			var d := amount * float(times)
			state["drawn"] = float(state["drawn"]) + d
			state["hand"] = float(state["hand"]) + d
			return "抽 %d 张（共 %.0f 张）" % [int(amount), d]
		"discard":
			var dc := amount * float(times)
			state["discarded"] = float(state["discarded"]) + dc
			state["hand"] = maxf(0.0, float(state["hand"]) - dc)
			return "弃 %d 张（共 %.0f 张）" % [int(amount), dc]
		"exhaust":
			var ex := amount * float(times)
			state["exhausted"] = float(state["exhausted"]) + ex
			return "消耗 %.0f 张" % ex
		"generate_card":
			state["generated"] = float(state["generated"]) + float(times)
			return "生成 %d 张 %s" % [times, String(e.get("card_entry", "?"))]
		"apply_power":
			var pname := String(e.get("power", "?"))
			var powers: Dictionary = state["powers"]
			powers[pname] = float(powers.get(pname, 0.0)) + amount * float(times)
			return "%s %+.0f 层" % [pname, amount * float(times)]
		"heal":
			var h := amount * float(times)
			state["heal"] = float(state["heal"]) + h
			return "治疗 %.1f" % h
		"gain_max_hp":
			return "最大生命 +%.1f" % (amount * float(times))
		"gain_gold":
			var g := amount * float(times)
			state["gold"] = float(state["gold"]) + g
			return "获得 %.1f 金币" % g
		"add_keyword":
			return "附加关键字 %s × %d" % [e.get("keyword", "?"), times]
		"upgrade_card":
			return "升级卡牌 × %d" % times
		_:
			return "%s × %d" % [kind, times]


static func _effect_amount(e: Dictionary, values: Dictionary, ctx: Dictionary) -> float:
	if bool(e.get("amount_is_var", false)):
		var vname := String(e.get("amount_var", ""))
		if values.has(vname):
			var base := float(values[vname])
			if bool(ctx.get("is_x_cost", false)):
				base *= float(ctx.get("x_value", 0.0))
			return base
	return float(e.get("amount", 0.0))


static func _loop_count(e: Dictionary, ctx: Dictionary, values: Dictionary) -> int:
	var loop: Dictionary = e.get("loop", {})
	match String(loop.get("mode", "none")):
		"count": return maxi(0, int(loop.get("count", 1)))
		"hits": return maxi(0, int(e.get("hits", 1)))
		"var": return maxi(0, int(round(float(values.get(String(loop.get("var", "")), 0.0)))))
		"energy": return maxi(0, int(round(float(ctx.get("x_value", 0.0)))))
		_: return 1


## In the simulator, "loop" already produced `times`; a separate `hits` field is
## only used by the damage path.
static func _eval_condition(cond: Dictionary, ctx: Dictionary, values: Dictionary) -> bool:
	match String(cond.get("mode", "none")):
		"none": return true
		"expr":
			var left := _resolve_operand(_token(cond.get("left", "")), ctx, values)
			var right := _resolve_operand(_token(cond.get("right", "0")), ctx, values)
			match String(cond.get("op", ">=")):
				">=": return left >= right
				">": return left > right
				"<=": return left <= right
				"<": return left < right
				"==": return is_equal_approx(left, right)
				"!=": return not is_equal_approx(left, right)
			return true
	return true


static func _resolve_operand(token: String, ctx: Dictionary, values: Dictionary) -> float:
	var t := token.strip_edges()
	if t.is_empty():
		return 0.0
	if t.is_valid_float() or t.is_valid_int():
		return float(t)
	if values.has(t):
		return float(values[t])
	if ctx.has(t):
		return float(ctx[t])
	return 0.0


# ---------------------------------------------------------------------------
# C# emission
# ---------------------------------------------------------------------------

## Emit C# statements for one effect list. `ctx` carries:
##   ind          indentation string
##   choice_ctx   name of the PlayerChoiceContext variable
##   scope        "card" | "relic"
##   params       relic parameter bindings { var_name -> expression } (may be {})
##   card_play    name of the CardPlay variable, or "" when the scope has none
static func emit_effects(effects: Array, ctx: Dictionary) -> Array:
	var out: Array = []
	var ind := String(ctx.get("ind", "\t\t"))
	# Some effects declare a local (`generated`, a `foreach` creature variable, a
	# hit-count loop variable) directly in the method body. Two effects of the same
	# shape — say two 「生成一张牌」 — would then declare one name twice in the same
	# declaration space: CS0128, or CS0136 when one of them sits inside an
	# `if`/`for` block. `_uniq_name` hands out `name`, `name_2`, … per method body,
	# so the emitted C# always compiles. The first use keeps the plain name, which
	# keeps single-effect output (and the previews) unchanged.
	ctx = ctx.duplicate()
	ctx["used"] = {}
	for e in effects:
		if not bool(e.get("enabled", true)):
			out.append("%s// （已禁用）%s" % [ind, kind_label(String(e.get("kind", "")))])
			continue
		var lines := _emit_one(e, ind, ctx)
		var body := "\n".join(lines)
		var cond: Dictionary = e.get("condition", {})
		var has_cond := String(cond.get("mode", "none")) != "none"
		var loop: Dictionary = e.get("loop", {})
		var loop_mode := String(loop.get("mode", "none"))
		var has_loop := loop_mode in ["count", "var", "hits", "energy"]
		if has_cond:
			out.append("%sif (%s)" % [ind, _emit_condition(cond, ctx)])
			out.append("%s{" % ind)
			body = _indent(body, "\t")
		if has_loop:
			out.append("%sfor (int i = 0; i < %s; i++)" % [ind, _emit_loop_count(e, loop_mode, ctx)])
			out.append("%s{" % ind)
			body = _indent(body, "\t")
		out.append(body)
		if has_loop:
			out.append("%s}" % ind)
		if has_cond:
			out.append("%s}" % ind)
	return out


## Read a dynamic var by name, choosing the property or the indexer form.
##
## `DynamicVarSet` only declares a handful of named properties; everything else
## (which includes every power var, since its key is the power's class name) is
## reachable only through the string indexer. The user's variable *name* is not
## an accessor, so it must not be spliced in as `base.DynamicVars.<name>`.
##
## Without a schema (unit tests, truncated context) we fall back to the indexer:
## it is the form that works for the widest range of names, and it is exactly
## what the game itself uses for powers without a dedicated property.
static func dynvar_expr(name: String, ctx: Dictionary) -> String:
	var n := name.strip_edges()
	if n.is_empty():
		return "base.DynamicVars[\"\"]"
	var schema: Variant = ctx.get("schema")
	if schema is CFSchema:
		return (schema as CFSchema).dynvar_expr(n)
	return "base.DynamicVars[\"%s\"]" % n


static func _emit_loop_count(e: Dictionary, loop_mode: String, ctx: Dictionary = {}) -> String:
	var loop: Dictionary = e.get("loop", {})
	match loop_mode:
		"count": return "%d" % maxi(0, int(loop.get("count", 1)))
		"hits": return "%d" % maxi(1, int(e.get("hits", 1)))
		"var":
			# `loop.var` defaults to "" in CFDesign, so `.get(k, "Repeat")` is NOT
			# a safe fallback: an empty-but-present key returns "" and the old code
			# emitted `base.DynamicVars..IntValue` -> CS0029 + CS0103. Strip first,
			# and fall back to a literal 1 so generated C# is always valid.
			# CFDesign.validate flags this as an error before export; this is the
			# last line of defence.
			var name := String(loop.get("var", "")).strip_edges()
			if name.is_empty():
				return "1"
			return "%s.IntValue" % dynvar_expr(name, ctx)
		"energy": return "base.EnergyCost.GetResolved()"
		_: return "1"


static func _indent(block: String, extra: String) -> String:
	var lines := block.split("\n")
	var out: Array = []
	for l in lines:
		out.append(extra + l if not l.strip_edges().is_empty() else l)
	return "\n".join(out)


## A condition operand as an expression token.
##
## The design file is JSON, so `left` / `right` can hold a String *or* a number
## (the UI stores the right-hand side as a float). `String(2.0)` is not a valid
## conversion in GDScript — it raises "Invalid call. Nonexistent 'String'
## constructor", which aborted the whole emission and produced `if ()`: a card
## that does not compile, from a checkbox that looks perfectly reasonable.
static func _token(v: Variant) -> String:
	if v is String:
		return (v as String).strip_edges()
	if v is bool:
		return "1" if v else "0"
	if v is float or v is int:
		return str(v)
	return str(v).strip_edges()


static func _emit_condition(cond: Dictionary, ctx: Dictionary = {}) -> String:
	return "%s %s %s" % [_emit_operand(_token(cond.get("left", "0")), ctx),
			str(cond.get("op", ">=")), _emit_operand(_token(cond.get("right", "0")), ctx)]


static func _emit_operand(token: String, ctx: Dictionary = {}) -> String:
	var t := token.strip_edges()
	if t.is_empty():
		return "0m"
	if t.is_valid_float() or t.is_valid_int():
		return "%sm" % t
	return "%s.IntValue" % dynvar_expr(t, ctx)


## Resolve a target id to the C# expression to use, honouring relic parameter
## bindings and the special "trigger" pseudo-targets.
static func resolve_target(target_id: String, ctx: Dictionary) -> String:
	var params: Dictionary = ctx.get("params", {})
	if params.has(target_id):
		return String(params[target_id])
	var t := _target_spec(target_id, ctx)
	if not t.is_empty():
		var expr := String(t["expr"])
		# `cardPlay` only exists inside a card's OnPlay. A relic trigger that still
		# points at the card target must not emit a variable that is not in scope
		# (CS0103), so fall through to the owner instead.
		if not expr.contains("cardPlay") or not String(ctx.get("card_play", "")).is_empty():
			return expr
	# Fall back to the card's own target when we have one, else the owner.
	if not String(ctx.get("card_play", "")).is_empty():
		return "cardPlay.Target"
	return "base.Owner.Creature"


## The fluent suffix appended to `DamageCmd.Attack(...)`, or "" when the target
## cannot be expressed that way and the emitter has to use `CreatureCmd.Damage`.
static func resolve_attack_suffix(target_id: String, ctx: Dictionary) -> String:
	# `DamageCmd.Attack(...).FromCard(this)` takes a **CardModel**, so a relic
	# trigger cannot use the fluent attack API at all — `this` there is a
	# RelicModel and the generated file would not compile.
	if String(ctx.get("scope", "card")) == "relic":
		return ""
	var params: Dictionary = ctx.get("params", {})
	if params.has(target_id):
		return "Targeting(%s)" % String(params[target_id])
	var t := _target_spec(target_id, ctx)
	if not t.is_empty():
		var atk := String(t.get("attack", ""))
		if atk.is_empty():
			return ""
		if atk.contains("cardPlay") and String(ctx.get("card_play", "")).is_empty():
			return ""
		return atk
	return "Targeting(base.Owner.Creature)"


## The UI's "card target" is shorthand for the target shape declared by the
## card constructor. Multi-target cards do not provide a single
## `cardPlay.Target`; using that expression made generated AllEnemies cards throw
## before their first effect ran. Resolve it to the same combat-state expressions
## used by the explicit target choices.
static func _target_spec(target_id: String, ctx: Dictionary) -> Dictionary:
	if target_id != "card_target":
		return target_by_id(target_id)
	var card_target := String(ctx.get("card_target_type", ""))
	match card_target:
		"AllEnemies":
			return target_by_id("all_enemies")
		"RandomEnemy":
			return target_by_id("random_enemy")
		"AllAllies":
			return target_by_id("all_allies")
		"Self":
			return target_by_id("self")
	return target_by_id("card_target")


static func _emit_one(e: Dictionary, ind: String, ctx: Dictionary) -> Array:
	var kind := String(e.get("kind", ""))
	var choice := String(ctx.get("choice_ctx", "choiceContext"))
	var spec := kind_by_id(kind)
	var target_id := String(e.get("target", ""))
	if target_id.is_empty():
		target_id = String(spec.get("default_target", "self"))
	var target_expr := resolve_target(target_id, ctx)
	var target_is_list := bool(_target_spec(target_id, ctx).get("list", false))
	# `cardPlay` only exists inside a card's OnPlay; a relic hook has none, so the
	# API's `CardPlay?` argument becomes the null literal the signature expects.
	var cp_arg := "cardPlay" if not String(ctx.get("card_play", "")).is_empty() else "null"
	# `this` is a CardModel inside a card and a RelicModel inside a relic. Only the
	# parameters that are *typed* `CardModel?` (Damage's `dealer/cardSource` pair
	# and PowerCmd.Apply's `cardSource`) need the scope-dependent form.
	var source := "null" if String(ctx.get("scope", "card")) == "relic" else "this"
	var value := _emit_value(e, ctx)
	var out: Array = []
	match kind:
		"damage":
			var suffix := resolve_attack_suffix(target_id, ctx)
			var hits := maxi(1, int(e.get("hits", 1)))
			if not suffix.is_empty():
				var chain := "DamageCmd.Attack(%s).FromCard(this).%s" % [value, suffix]
				if hits > 1:
					chain += ".WithHitCount(%d)" % hits
				chain += ".WithHitFx(\"vfx/vfx_attack_slash\")"
				out.append("%sawait %s.Execute(%s);" % [ind, chain, choice])
			else:
				# No AttackCommand form for this target: a relic trigger has no `FromCard`
				# (its `this` is not a CardModel) and the fluent API has no ally-list
				# targeting. `CreatureCmd.Damage` is exactly what the game's own
				# relics use — see CharonsAshes.
				_emit_statement(out, ind, hits, _uniq_name(ctx, "hit"),
						"await CreatureCmd.Damage(%s, %s, %s, %s, base.Owner.Creature, %s);"
						% [choice, target_expr, value, _emit_value_prop(e), source])
		"damage_direct":
			out.append("%sawait CreatureCmd.Damage(%s, %s, %s, %s, base.Owner.Creature, %s);"
					% [ind, choice, target_expr, value, _emit_value_prop(e), source])
		"block":
			# The block goes to the **effect's target**, not blindly to the owner:
			# `CreatureCmd.GainBlock(creature, …)` takes the creature to shield as its
			# first argument, and `self` resolves to `base.Owner.Creature` — the
			# creature of the player who played the card. (%%s is the creature slot
			# `_emit_for_targets` fills in — with the loop variable for a list target.)
			_emit_for_targets(out, ind, target_expr, target_is_list, _uniq_name(ctx, "blockTarget"),
					"await CreatureCmd.GainBlock(%%s, %s, ValueProp.Move, %s);" % [value, cp_arg])
		"heal":
			_emit_for_targets(out, ind, target_expr, target_is_list, _uniq_name(ctx, "healTarget"),
					"await CreatureCmd.Heal(%%s, %s, true);" % value)
		"gain_max_hp":
			_emit_for_targets(out, ind, target_expr, target_is_list, _uniq_name(ctx, "maxHpTarget"),
					"await CreatureCmd.GainMaxHp(%%s, %s);" % value)
		"energy":
			out.append("%sawait PlayerCmd.GainEnergy(%s, base.Owner);" % [ind, value])
		"star":
			out.append("%sawait PlayerCmd.GainStars(%s, base.Owner);" % [ind, value])
		"draw":
			out.append("%sawait CardPileCmd.Draw(%s, %s, base.Owner);" % [ind, choice, value])
		"discard":
			# `CardCmd.Discard` takes *cards*, not a count — the API is
			# `Discard(PlayerChoiceContext, CardModel | IEnumerable<CardModel>)`. The
			# game's own cards pick first (Acrobatics, DaggerThrow), then discard.
			out.append("%sawait CardCmd.Discard(%s, await CardSelectCmd.FromHandForDiscard(" % [ind, choice])
			out.append("%s	%s, base.Owner, new CardSelectorPrefs(CardSelectorPrefs.DiscardSelectionPrompt, %s), null, this));"
					% [ind, choice, _emit_int_value(e, ctx)])
		"exhaust":
			# Exhaust also takes cards (`Exhaust(ctx, CardModel, …)`); "消耗 N 张" is a
			# selection, exactly like Purity/Brand/BurningPact do it.
			var exhaust_var := _uniq_name(ctx, "exhaustTarget")
			out.append("%sforeach (CardModel %s in await CardSelectCmd.FromHand(" % [ind, exhaust_var])
			out.append("%s	%s, base.Owner, new CardSelectorPrefs(CardSelectorPrefs.ExhaustSelectionPrompt, %s), null, this))"
					% [ind, choice, _emit_int_value(e, ctx)])
			out.append("%s{" % ind)
			out.append("%s	await CardCmd.Exhaust(%s, %s);" % [ind, choice, exhaust_var])
			out.append("%s}" % ind)
		"upgrade_card":
			# `CardCmd.Upgrade(CardModel)` is a plain void — not async, and it takes a
			# card, so the old `Upgrade(ctx, <decimal>, owner)` never existed.
			var upgrade_var := _uniq_name(ctx, "upgradeTarget")
			out.append("%sforeach (CardModel %s in await CardSelectCmd.FromHand(" % [ind, upgrade_var])
			out.append("%s	%s, base.Owner, new CardSelectorPrefs(CardSelectorPrefs.UpgradeSelectionPrompt, %s), null, this))"
					% [ind, choice, _emit_int_value(e, ctx)])
			out.append("%s{" % ind)
			out.append("%s	CardCmd.Upgrade(%s);" % [ind, upgrade_var])
			out.append("%s}" % ind)
		"gain_gold":
			# The third parameter is `bool wasStolenBack`, not a "play animation" flag:
			# passing `true` tells the game the gold was reclaimed from a thief.
			out.append("%sawait PlayerCmd.GainGold(%s, base.Owner);" % [ind, value])
		"forge":
			out.append("%sawait ForgeCmd.Forge(%s, base.Owner, this);" % [ind, value])
		"generate_card":
			# `AddGeneratedCardToCombat` takes ONE card, so the card is created first
			# (`ICombatState.CreateCard<T>(owner)`) and then added — the shape every
			# vanilla "add a card to hand" card uses.
			var entry := String(e.get("card_entry", ""))
			var cls := resolve_card_class(entry, ctx)
			var pile := String(e.get("pile", ""))
			if pile.is_empty():
				pile = "Discard"
			var pos := String(e.get("position", ""))
			if pos.is_empty():
				pos = "Bottom"
			var gen_var := _uniq_name(ctx, "generated")
			out.append("%s// 生成 %s 到 %s 的 %s 位置" % [ind, cls, pile, pos])
			out.append("%sCardModel %s = base.Owner.Creature.CombatState.CreateCard<%s>(base.Owner);" % [ind, gen_var, cls])
			out.append("%sawait CardPileCmd.AddGeneratedCardToCombat(%s, PileType.%s, base.Owner, CardPilePosition.%s);"
					% [ind, gen_var, pile, pos])
		"apply_power":
			var power := String(e.get("power", ""))
			if power.is_empty():
				out.append("%s// TODO: 未选择 Power，apply_power 未生成" % ind)
			else:
				out.append("%sawait PowerCmd.Apply<%s>(%s, %s, %s, base.Owner.Creature, %s);"
						% [ind, power, choice, target_expr, value, source])
		"add_keyword":
			if String(ctx.get("scope", "card")) == "relic":
				# `AddKeyword` is a CardModel member; a relic has no "this card".
				out.append("%s// TODO: 遗物没有「这张牌」，不能附加关键字（RelicModel 上没有 AddKeyword）" % ind)
			else:
				out.append("%sAddKeyword(CardKeyword.%s);" % [ind, e.get("keyword", "Exhaust")])
		_:
			out.append("%s// TODO: 未知效果类型 %s" % [ind, kind])
	return out


## A generated local name that is unique inside one method body.
##
## See `emit_effects`: the design file is user data, so the same effect (or two
## effects of the same shape) can legitimately appear twice in one trigger, and
## two identical declarations in one C# declaration space do not compile. The
## first caller keeps `base`; later ones get `base_2`, `base_3`, …
static func _uniq_name(ctx: Dictionary, base: String) -> String:
	var used: Variant = ctx.get("used")
	if not (used is Dictionary):
		return base
	var d: Dictionary = used
	if not d.has(base):
		d[base] = 1
		return base
	var n := int(d[base]) + 1
	d[base] = n
	return "%s_%d" % [base, n]


## Emit one statement per affected creature, wrapping it in a `foreach` when the
## target expression is a **list**.
##
## `CreatureCmd.GainBlock` / `Heal` / `GainMaxHp` take a single `Creature`, so
## handing them `...HittableEnemies` / `...Allies` was CS1503 — the effect did
## not compile and simply never appeared in game.
##
## `CreatureCmd.Damage` and `PowerCmd.Apply<T>` *do* have
## `IEnumerable<Creature>` overloads and must NOT be wrapped here.
##
## `call_template` is the statement with a single `%s` where the creature goes:
## the loop variable when wrapped, the target expression when not. (A template
## that carried the *list* expression into the per-creature call would be CS1503
## all over again — the emitted loop has to use its own variable.)
static func _emit_for_targets(out: Array, ind: String, target_expr: String,
		is_list: bool, loop_var: String, call_template: String) -> void:
	if is_list:
		out.append("%sforeach (Creature %s in %s)" % [ind, loop_var, target_expr])
		out.append("%s{" % ind)
		out.append("%s	%s" % [ind, call_template % loop_var])
		out.append("%s}" % ind)
	else:
		out.append("%s%s" % [ind, call_template % target_expr])


## Emit `statement`, wrapped in a loop when the effect asks for several hits.
##
## `CreatureCmd.Damage` has no hit-count parameter (that is an `AttackCommand`
## concept), so the "段数" field becomes an explicit loop on the fallback path.
static func _emit_statement(out: Array, ind: String, hits: int, loop_var: String,
		statement: String) -> void:
	if hits > 1:
		out.append("%sfor (int %s = 0; %s < %d; %s++)" % [ind, loop_var, loop_var, hits, loop_var])
		out.append("%s{" % ind)
		out.append("%s	%s" % [ind, statement])
		out.append("%s}" % ind)
	else:
		out.append("%s%s" % [ind, statement])


## An **int**-typed amount, for the APIs that take an `int` count
## (`CardSelectorPrefs`, `Purity`-style selections).
##
## `_emit_value` returns a `decimal` (`…m`), which is CS1503 in those positions;
## `DynamicVar.IntValue` is the int accessor the game itself uses.
static func _emit_int_value(e: Dictionary, ctx: Dictionary = {}) -> String:
	if bool(e.get("amount_is_var", false)):
		var v := String(e.get("amount_var", "")).strip_edges()
		if not v.is_empty():
			return "%s.IntValue" % dynvar_expr(v, ctx)
	return "%d" % int(e.get("amount", 0.0))


## The C# class of the card a `generate_card` effect creates.
##
## A game card's entry (`ALL_FOR_ONE`) has to be un-slugged back to its class
## (`AllForOne`), but one of **this mod's** cards is referenced by the design's
## own `id` verbatim — un-slugging `wudi` would emit the non-existent `Wudi`
## (CS0246). The exporter passes the map in `ctx["mod_cards"]`.
static func resolve_card_class(entry: String, ctx: Dictionary) -> String:
	var e := entry.strip_edges()
	if e.is_empty():
		return "CardModel"
	var mod_cards: Dictionary = ctx.get("mod_cards", {})
	if mod_cards.has(e):
		return String(mod_cards[e])
	var schema: Variant = ctx.get("schema")
	if schema is CFSchema:
		for c in (schema as CFSchema).existing_cards:
			if String(c.get("entry", "")) == e:
				return String(c.get("class_name", e))
			if String(c.get("class_name", "")) == e:
				return e
	return CFIds.unslugify(e)

static func _emit_value(e: Dictionary, ctx: Dictionary = {}) -> String:
	if bool(e.get("amount_is_var", false)):
		var v := String(e.get("amount_var", "")).strip_edges()
		if not v.is_empty():
			return "%s.BaseValue" % dynvar_expr(v, ctx)
	return "%sm" % _decimal(float(e.get("amount", 0.0)))


static func _emit_value_prop(e: Dictionary) -> String:
	var vp := String(e.get("value_prop", ""))
	return "ValueProp.Move" if vp.is_empty() else "ValueProp.%s" % vp


static func _decimal(v: float) -> String:
	return str(int(v)) if v == floor(v) else String.num(v, 2)


# ---------------------------------------------------------------------------
# Which usings a set of effects needs
# ---------------------------------------------------------------------------

static func usings_for(effects: Array, is_relic: bool) -> Array:
	var set: Dictionary = {
		"System": true,
		"System.Collections.Generic": true,
		"System.Threading.Tasks": true,
		"MegaCrit.Sts2.Core.Commands": true,
		"MegaCrit.Sts2.Core.Entities.Cards": true,
		"MegaCrit.Sts2.Core.GameActions.Multiplayer": true,
		"MegaCrit.Sts2.Core.Localization.DynamicVars": true,
		"MegaCrit.Sts2.Core.Models": true,
		"MegaCrit.Sts2.Core.ValueProps": true,
	}
	if is_relic:
		set["MegaCrit.Sts2.Core.Entities.Relics"] = true
	for e in effects:
		match String(e.get("kind", "")):
			"apply_power":
				set["MegaCrit.Sts2.Core.Models.Powers"] = true
			"block", "heal", "gain_max_hp", "damage_direct":
				set["MegaCrit.Sts2.Core.Entities.Creatures"] = true
			# CardCmd.Discard / Exhaust / Upgrade take *cards*, so the emitted code has
			# to pick them first: CardSelectorPrefs lives in CardSelection.
			"discard", "exhaust", "upgrade_card":
				set["MegaCrit.Sts2.Core.CardSelection"] = true
			"star", "energy", "gain_gold":
				set["MegaCrit.Sts2.Core.Entities.Players"] = true
			"generate_card":
				set["MegaCrit.Sts2.Core.Entities.Cards"] = true
		var t := String(e.get("target", ""))
		if t in ["all_enemies", "random_enemy", "all_allies"]:
			set["MegaCrit.Sts2.Core.Combat"] = true
			set["MegaCrit.Sts2.Core.Entities.Creatures"] = true
		if t == "random_enemy":
			set["System.Linq"] = true
	var keys := set.keys()
	keys.sort()
	return keys
