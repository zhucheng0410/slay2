extends SceneTree

class IsolatedApp extends "res://ui/app.gd":
	func _save_settings() -> bool:
		return true
	func _load_last_design() -> void:
		pass
	func _reveal_export(_path: String) -> void:
		pass

var failures := 0
var checks := 0

func check(label: String, value: bool) -> void:
	checks += 1
	if not value:
		failures += 1
	print("[%s] %s" % ["OK" if value else "FAIL", label])

func nodes(node: Node) -> Array:
	var result: Array = [node]
	for child in node.get_children():
		result.append_array(nodes(child))
	return result

func button(node: Node, label: String) -> Button:
	for child in nodes(node):
		if child is Button and child.text == label:
			return child
	return null

func dialog(app: Node, prefix: String) -> AcceptDialog:
	for child in nodes(app):
		if child is AcceptDialog and child.title.begins_with(prefix):
			return child
	return null

func frames() -> void:
	for i in 4:
		await process_frame

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1280, 800)
	var app := IsolatedApp.new()
	root.add_child(app)
	for i in 20:
		await process_frame
	var schema := app.schema
	var db := app.db
	app.settings["last_design_file"] = "res://.forge_userdata/contentmanagement.json"
	db.load_from_json('{"mod_id":"ContentProbe","cards":[],"relics":[],"custom_characters":[{"id":"Hero","name":"测试角色","template":"Defect"},{"id":"KeepHero"}]}')
	var card := CFDesign.new_card(schema)
	card["id"] = "ProbeCard"
	card["pool"] = "HeroCardPool"
	card["vars"] = [CFDesign.new_var("Weak", "Power", "PowerVar", 2.0, "", "WeakPower")]
	card["effects"] = [CFDesign.new_effect("apply_power")]
	card["effects"][0].merge({"power": "TemporaryFocusPower", "amount_is_var": true, "amount_var": "Weak", "target": "all_enemies"}, true)
	card["deck"] = {"enabled": true, "character": "Hero", "copies": 2}
	CFDesign.normalize(schema, card)
	db.cards = [card]
	var relic := CFDesign.new_relic(schema)
	relic["id"] = "ProbeRelic"
	relic["pool"] = "HeroRelicPool"
	relic["deck"] = {"enabled": true, "character": "Hero"}
	CFDesign.normalize(schema, relic)
	db.relics = [relic]
	check("抽象状态被预检阻止", CFExporter.preflight(schema, db)["errors"].any(func(e): return "抽象状态" in e))
	check("状态和变量不一致会提示", CFExporter.preflight(schema, db)["warnings"].any(func(e): return "实际施加" in e))
	var options := CFEffects.power_options(schema)
	check("状态选择器排除抽象类型", not options.any(func(e): return e["value"] == "TemporaryFocusPower"))
	check("保留可用的具体临时集中状态", options.any(func(e): return e["value"] == "HotfixPower"))
	check("变量选择器排除抽象类型", not schema.dynamic_var_types.any(func(v): return v.get("generic") == "TemporaryFocusPower"))
	db.set_selection(CFDesign.KIND_CARD, 0)
	var effect_ui := app._effect_editor(CFDesign.KIND_CARD, 0, -1, 0, card["effects"][0])
	app.add_child(effect_ui)
	var align := button(effect_ui, "使用变量对应状态（虚弱）")
	check("效果编辑器提供状态纠正入口", align != null)
	if align != null:
		align.pressed.emit()
	check("纠正入口实际写入虚弱效果", db.cards[0]["effects"][0]["power"] == "WeakPower")
	effect_ui.queue_free()
	check("修正为虚弱后预检通过", not CFExporter.preflight(schema, db)["blocking"])
	db.cards[0]["vars"][0]["generic"] = "TemporaryFocusPower"
	check("旧抽象状态变量也会被阻止", CFExporter.preflight(schema, db)["blocking"])
	db.cards[0]["vars"][0]["generic"] = "WeakPower"
	for template in CFCharacters.TEMPLATES:
		var source := CFCharacters.normalized({"id": "Hero", "template": template})
		var initial := CFCharacters.initial_deck(schema, db, source)
		check("读取模板初始牌组 " + template, initial.any(func(row): return row["source"] == "game") and initial.any(func(row): return row["id"] == "ProbeCard"))
	# Drive the actual modal, including cancel and disk roundtrip.
	app._open_authoring_library()
	await frames()
	var library := dialog(app, "能力配方")
	check("角色库提供初始牌组与删除入口", button(library, "初始牌组") != null and button(library, "删除角色及池") != null)
	button(library, "初始牌组").pressed.emit()
	await frames()
	var editor := dialog(app, "初始牌组")
	check("初始牌组弹窗打开", editor != null)
	check("初始牌组窗口内容不超出可视宽度", nodes(editor).filter(func(n): return n is ScrollContainer).all(func(n): return n.get_child(0).size.x <= n.size.x + 2))
	var toggle: CheckBox = editor.find_child("CustomStartingDeck", true, false)
	toggle.button_pressed = true
	var rows := editor.find_child("StartingDeckRows", true, false)
	# Remove all inherited rows, then add one vanilla card and one authored card.
	while not rows.get_children().is_empty():
		button(rows.get_child(0), "移除").pressed.emit()
	editor.confirmed.emit()
	check("空初始牌组不能保存", not db.custom_characters[0].has("starting_deck"))
	var picker := editor.find_child("StartingCardPicker", true, false)
	var pick: Callable = picker.get_meta("cf_picked")
	pick.call({"value": "game:Zap"})
	button(editor, "添加卡牌").pressed.emit()
	pick.call({"value": "mod:ProbeCard"})
	button(editor, "添加卡牌").pressed.emit()
	var copies: SpinBox = editor.find_child("Copies_ProbeCard", true, false)
	copies.value = 3
	editor.confirmed.emit()
	await frames()
	var restored := CFDesignDb.new()
	restored.load_from_file(app.settings["last_design_file"])
	var saved: Array = restored.custom_characters[0]["starting_deck"]
	check("原版卡、自制卡及张数保存重开", saved.size() == 2 and saved[0]["source"] == "game" and saved[0]["id"] == "Zap" and saved[1]["source"] == "mod" and saved[1]["id"] == "ProbeCard" and int(saved[1]["copies"]) == 3)
	var emitted := CFCharacters.emit(db.custom_characters[0], db, schema)
	check("完整牌组不重复追加模板或旧注入", emitted.contains("i < 3;") and emitted.count("global::ContentProbe.ProbeCard") == 1 and not emitted.contains("Template.StartingDeck") and emitted.contains("global::MegaCrit.Sts2.Core.Models.Cards.Zap"))
	app._open_starting_deck_editor("Hero", library)
	await frames()
	editor = dialog(app, "初始牌组")
	check("重开弹窗显示自定义牌组", (editor.find_child("CustomStartingDeck", true, false) as CheckBox).button_pressed)
	(editor.find_child("Copies_ProbeCard", true, false) as SpinBox).value = 9
	editor.canceled.emit()
	await frames()
	check("取消编辑不修改牌组", db.custom_characters[0]["starting_deck"][1]["copies"] == 3)
	var bad_deck: Dictionary = db.custom_characters[0].duplicate(true)
	bad_deck["starting_deck"][0]["id"] = "NoSuchCard"
	check("缺失卡牌引用会被阻止", not CFCharacters.validate_starting_deck(schema, db, bad_deck).is_empty())
	bad_deck = db.custom_characters[0].duplicate(true)
	bad_deck["starting_deck"][0]["copies"] = -1
	check("非法初始张数会被阻止", not CFCharacters.validate_starting_deck(schema, db, bad_deck).is_empty())
	db.set_field(schema, CFDesign.KIND_CARD, 0, ["id"], "RenamedCard")
	check("卡牌改名同步初始牌组引用", db.custom_characters[0]["starting_deck"][1]["id"] == "RenamedCard")
	db.undo()
	check("改名撤销恢复引用", db.custom_characters[0]["starting_deck"][1]["id"] == "ProbeCard")
	# Keep another character with the same explicit deck through deletion/export.
	var keeper: Dictionary = db.custom_characters[1].duplicate(true)
	keeper["starting_deck"] = db.custom_characters[0]["starting_deck"].duplicate(true)
	db.update_custom_character("KeepHero", keeper)
	var export_options := app.settings.duplicate()
	export_options["out_dir"] = "res://exports/_contentmanagementtest"
	var first := CFExporter.export(schema, db, export_options)
	check("混合初始牌组成功导出", first["ok"])
	app._confirm_remove_character("Hero", library, func(): pass)
	await frames()
	var remove := dialog(app, "删除角色及两个池")
	remove.canceled.emit()
	await frames()
	check("取消删除不修改角色池", CFCharacters.contains(db, "Hero"))
	app._confirm_remove_character("Hero", library, func(): pass)
	await frames()
	dialog(app, "删除角色及两个池").confirmed.emit()
	await frames()
	restored.load_from_file(app.settings["last_design_file"])
	check("删除角色及两个池已持久化", not CFCharacters.contains(restored, "Hero") and not CFCharacters.owns_pool(restored, "HeroCardPool", false) and not CFCharacters.owns_pool(restored, "HeroRelicPool", true))
	check("删除保留卡牌和遗物并迁入模板池", restored.cards.size() == 1 and restored.relics.size() == 1 and restored.cards[0]["pool"] == "DefectCardPool" and restored.relics[0]["pool"] == "DefectRelicPool")
	check("清理开局关联且保留另一角色牌组", not restored.cards[0]["deck"]["enabled"] and restored.cards[0]["deck"]["character"] == "" and restored.custom_characters[0]["starting_deck"].size() == 2)
	db.undo()
	check("删除可整体撤销", CFCharacters.contains(db, "Hero") and db.cards[0]["pool"] == "HeroCardPool" and db.cards[0]["deck"]["enabled"])
	db.redo()
	var second := CFExporter.export(schema, db, export_options)
	check("删除后的工程重新导出", second["ok"])
	if not second["ok"]:
		print(second)
		quit(1)
		return
	var mod_dir := String(second["mod_dir"])
	var project := CFPaths.read_text(mod_dir.path_join("src/ContentProbe.csproj"))
	check("删除后旧角色及池不再参与编译", not project.contains('Include="Characters/Hero.cs"') and not project.contains('Include="CardPools/HeroCardPool.cs"'))
	var build := await app._run_build(mod_dir)
	check("混合初始牌组及删除池后的工程实际编译", build["ok"])
	if not build["ok"]:
		print(build)
	# Export the repaired user project separately, never alter settings or decks.
	var original := CFPaths.read_text("res://designs/main.json")
	db.load_from_json(original)
	export_options["out_dir"] = "res://exports/content-update"
	var user_export := CFExporter.export(schema, db, export_options)
	check("当前修复工程导出", user_export["ok"])
	if user_export["ok"]:
		var dir := String(user_export["mod_dir"])
		var source := CFPaths.read_text(dir.path_join("src/Cards/wudi.cs"))
		check("无敌卡实际施加虚弱和后续状态", source.contains("Apply<WeakPower>") and not source.contains("TemporaryFocusPower") and source.contains("Apply<IntangiblePower>") and source.contains("Apply<RegenPower>"))
		var user_build := await app._run_build(dir)
		check("修复后的用户工程实际编译", user_build["ok"])
		if not user_build["ok"]:
			print(user_build)
	check("功能测试未改写用户存档", original == CFPaths.read_text("res://designs/main.json"))
	app.queue_free()
	await process_frame
	print("===== CONTENT MANAGEMENT %s (%d checks) =====" % ["PASSED" if failures == 0 else "FAILED", checks])
	quit(0 if failures == 0 else 1)
