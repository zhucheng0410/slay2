@tool
extends SceneTree

## 「生成出来的 C# 到底能不能编过？」—— 这个问题只有编译器能回答。
##
## selftest / uitest 断言的是生成的**字符串**，它们保证不了那些 API 真的存在、重载
## 真的匹配、类型真的解析得到。这个脚本把**所有**效果 × **所有**目标 × **所有**
## Buff 做成一个真实的 mod，再用 `dotnet build` 真编一遍：
##
##   * 一张牌：16 种效果 × 5 种目标，另外加上变量驱动、按变量循环、带条件、
##     两个「生成一张牌」（局部变量唯一性）等写法；
##   * 一张牌：全部 256 个 Power 各施加一次（`PowerCmd.Apply<T>`）；
##   * 一张牌：全部 256 个 Power 各当一个 `PowerVar<T>` 变量；
##   * 一件遗物：所有效果 × 所有目标（挂在带 PlayerChoiceContext 的触发时机上）；
##   * 一张牌生成另一张本 mod 的牌（类名解析：`wudi` 不能变成 `Wudi`）。
##
## 它是「卡牌在游戏里根本用不了」这类问题的关卡：`CardCmd.Discard` 收的是牌不是
## 数量、遗物里没有 `AddKeyword`、`PowerVar<T>` 的子命名空间没 import、一张牌里
## 两个「生成一张牌」重复声明局部变量…… 全都是它先抓到的。
##
## 需要本机装好游戏（`sts2.dll`）与 dotnet。跑法：
##
##   Godot_..._console.exe --headless --path <CardRelicForge> --script res://tools/compiletest.gd
##
## 退出码 0 = 生成的 C# 编译通过。产物在 exports/_compiletest/（每次跑之前清空）。

const OUT_DIR := "res://exports/_compiletest"
const MOD_ID := "compiletest"


func _init() -> void:
	var root := CFPaths.detect_source_root()
	var schema := CFSchema.new()
	CFSchemaScanner.scan(root, schema)
	print("scan: powers=%d cards=%d hooks=%d"
			% [schema.powers.size(), schema.existing_cards.size(), schema.hooks.size()])

	var db := CFDesignDb.new()
	db.mod_id = MOD_ID
	db.mod_name = "CompileTest"
	db.mod_author = "forge"
	db.cards.clear()
	db.relics.clear()

	# (1) 一张牌：所有效果 × 所有目标。
	var card := CFDesign.new_card(schema)
	card["id"] = "CompileCard"
	card["entry"] = "COMPILE_CARD"
	card["text"]["zhs"]["title"] = "全效果"
	card["text"]["eng"]["title"] = "CompileCard"
	card["flags"]["gains_block"] = true
	card["vars"] = [
		CFDesign.new_var("D", "Damage", "DamageVar", 6.0, "Move"),
		CFDesign.new_var("B", "Block", "BlockVar", 5.0, "Move"),
		CFDesign.new_var("P", "Power", "PowerVar", 2.0, "", "VulnerablePower"),
		CFDesign.new_var("R", "Repeat", "RepeatVar", 2.0),
	]
	var effects: Array = []
	for k in CFEffects.KINDS:
		for t in CFEffects.TARGETS:
			effects.append(_effect(schema, String(k["id"]), String(t["id"])))
	# 变量驱动 / 按变量循环 / 带条件 / 段数循环。
	var v1 := _effect(schema, "damage", "card_target")
	v1["amount_is_var"] = true
	v1["amount_var"] = "D"
	v1["hits"] = 3
	effects.append(v1)
	var v2 := _effect(schema, "block", "self")
	v2["amount_is_var"] = true
	v2["amount_var"] = "B"
	effects.append(v2)
	var v3 := _effect(schema, "apply_power", "card_target")
	v3["amount_is_var"] = true
	v3["amount_var"] = "P"
	effects.append(v3)
	var v4 := _effect(schema, "block", "self")
	v4["loop"] = {"mode": "var", "count": 1, "var": "R"}
	effects.append(v4)
	var v5 := _effect(schema, "draw", "self")
	v5["condition"] = {"mode": "expr", "left": "R", "op": ">=", "right": 2.0, "note": ""}
	effects.append(v5)
	# 第二个「生成一张牌」：同一个方法体里两个局部变量不能重名（CS0128）。
	effects.append(_effect(schema, "generate_card", "self"))
	card["effects"] = effects
	db.cards.append(card)

	# (2) 一张牌：全部 Buff 都施加一遍（每个 Apply<T> 都要能编过）。
	var buff := CFDesign.new_card(schema)
	buff["id"] = "CompileBuffs"
	buff["entry"] = "COMPILE_BUFFS"
	buff["text"]["zhs"]["title"] = "全 Buff"
	buff["text"]["eng"]["title"] = "CompileBuffs"
	buff["vars"] = []
	var beffs: Array = []
	for p in schema.powers:
		var cls := String((p as Dictionary).get("class_name", "")).strip_edges()
		if cls.is_empty():
			continue
		var e2 := _effect(schema, "apply_power", "self")
		e2["power"] = cls
		beffs.append(e2)
	buff["effects"] = beffs
	db.cards.append(buff)

	# (3) 一张牌：全部 Power 都当 PowerVar<T> 变量声明（每个构造函数都要能编过）。
	var pv := CFDesign.new_card(schema)
	pv["id"] = "CompileVars"
	pv["entry"] = "COMPILE_VARS"
	pv["text"]["zhs"]["title"] = "全变量"
	pv["text"]["eng"]["title"] = "CompileVars"
	pv["effects"] = []
	var pvars: Array = []
	for p in schema.powers:
		var cls2 := String((p as Dictionary).get("class_name", "")).strip_edges()
		if cls2.is_empty():
			continue
		pvars.append(CFDesign.new_var(cls2, "Power", "PowerVar", 1.0, "", cls2))
	pv["vars"] = pvars
	db.cards.append(pv)

	# (4) 一件遗物：所有效果（挂在带 PlayerChoiceContext 的触发时机上）。
	var hook_name := ""
	for h in schema.usable_hooks():
		var has_ctx := false
		for prm in (h.get("params", []) as Array):
			if String(prm).contains("PlayerChoiceContext"):
				has_ctx = true
		if has_ctx:
			hook_name = String(h["name"])
			break
	var relic := CFDesign.new_relic(schema)
	relic["id"] = "CompileRelic"
	relic["entry"] = "COMPILE_RELIC"
	relic["text"]["zhs"]["title"] = "全效果遗物"
	relic["text"]["eng"]["title"] = "CompileRelic"
	var reffs: Array = []
	for k in CFEffects.KINDS:
		for t in CFEffects.TARGETS:
			# 遗物没有「这张牌」，且不能修改牌关键字：两类效果都
			# 应该由预检排除，否则这个真实编译夹具会故意生成非法代码。
			if String(t["id"]) == "card_target" or String(k["id"]) == "add_keyword":
				continue
			reffs.append(_effect(schema, String(k["id"]), String(t["id"])))
	relic["triggers"] = [{
		"hook": hook_name,
		"params": CFDesign._default_param_bindings(schema, hook_name),
		"condition": CFDesign.new_condition(),
		"charge": {"mode": "always", "n": 1},
		"loop": {"mode": "none", "count": 1, "var": ""},
		"effects": reffs,
		"note": "",
	}]
	relic["vars"] = [CFDesign.new_var("RD", "Damage", "DamageVar", 4.0, "Move")]
	# Also compile the StartingRelics Harmony patch. The game getter returns
	# IReadOnlyList<RelicModel>, which must be preserved exactly in the postfix.
	var targets := schema.deck_targets()
	if not targets.is_empty():
		relic["deck"] = {"enabled": true, "character": String((targets[0] as Dictionary)["class_name"]), "copies": 1}
	db.relics.append(relic)

	# (5) 一张牌生成另一张本 mod 的牌（类名解析：wudi 不能变成 Wudi）。
	var gen := CFDesign.new_card(schema)
	gen["id"] = "wudi"
	gen["entry"] = "WUDI"
	gen["text"]["zhs"]["title"] = "生成测试"
	gen["text"]["eng"]["title"] = "Gen"
	gen["vars"] = []
	gen["effects"] = [_effect(schema, "generate_card", "self")]
	gen["effects"][0]["card_entry"] = "COMPILE_CARD"
	db.cards.append(gen)

	# 每次重跑都从空目录开始，免得删掉一半的旧 .cs 混进这一次的编译。
	var out_dir := ProjectSettings.globalize_path(OUT_DIR)
	_rm_rf(out_dir)
	var report := CFExporter.export(schema, db, {"out_dir": out_dir, "force": true, "include_pck": true})
	print("export ok=%s err=%s errors=%d"
			% [report.get("ok"), report.get("error"), (report.get("errors", []) as Array).size()])
	for i in (report.get("errors", []) as Array):
		print("  ERROR: %s" % JSON.stringify(i))
	for i in (report.get("warnings", []) as Array):
		print("  WARN: %s" % JSON.stringify(i))
	var vb := CFExporter.verify_build(out_dir.path_join(MOD_ID))
	print("build ok=%s error=%s" % [vb.get("ok"), vb.get("error")])
	if not bool(vb.get("ok", false)):
		print("---- build log ----")
		print(String(vb.get("log", "")))
	quit(0 if bool(vb.get("ok", false)) else 1)


func _effect(schema: CFSchema, kind: String, target: String) -> Dictionary:
	var e := CFDesign.new_effect(kind)
	e["amount"] = 3.0
	e["target"] = target
	e["pile"] = "Hand"
	e["position"] = "Bottom"
	if not schema.powers.is_empty():
		e["power"] = String((schema.powers[0] as Dictionary).get("class_name", ""))
	var kws := schema.members_for_role("card_keyword")
	e["keyword"] = String(kws[0]) if not kws.is_empty() else "Exhaust"
	if not schema.existing_cards.is_empty():
		e["card_entry"] = String((schema.existing_cards[0] as Dictionary).get("entry", ""))
	return e


## 删掉这个脚本自己的产物目录。只允许删 `exports/_compiletest`，别的一律不动。
func _rm_rf(path: String) -> void:
	if not path.replace("\\", "/").ends_with("/exports/_compiletest"):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while not n.is_empty():
		var full := path.path_join(n)
		if d.current_is_dir():
			_rm_rf(full)
		else:
			DirAccess.remove_absolute(full)
		n = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)
