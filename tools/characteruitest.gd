extends SceneTree

class IsolatedApp extends "res://ui/app.gd":
	func _save_settings() -> bool:
		return true
	func _load_last_design() -> void:
		pass

var failures := 0
var checks := 0

func check(label: String, value: bool) -> void:
	checks += 1
	if not value:
		failures += 1
	print("[%s] %s" % ["OK" if value else "FAIL", label])

func all_nodes(node: Node) -> Array:
	var result: Array = [node]
	for child in node.get_children():
		result.append_array(all_nodes(child))
	return result

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1280, 800)
	var app := IsolatedApp.new()
	root.add_child(app)
	for i in 20:
		await process_frame
	app.db.load_from_json('{"cards":[],"relics":[],"mod_id":"UiHeroMod","custom_characters":[{"id":"UiHero","name":"界面角色"}]}')
	app.settings["last_design_file"] = "res://.forge_userdata/character-ui.json"
	app.call("_open_authoring_library")
	for i in 4:
		await process_frame
	var library: AcceptDialog = null
	for node in all_nodes(app):
		if node is AcceptDialog and node.title == "能力配方与自定义角色":
			library = node
	check("能力库打开且有滚动容器", library != null and all_nodes(library).any(func(n): return n is ScrollContainer))
	var edit_button: Button = null
	for node in all_nodes(library):
		if node is Button and node.text == "编辑角色":
			edit_button = node
	check("已有角色可编辑", edit_button != null)
	edit_button.pressed.emit()
	for i in 4:
		await process_frame
	var editor: AcceptDialog = null
	for node in all_nodes(app):
		if node is AcceptDialog and node.title.begins_with("角色设置"):
			editor = node
	check("角色设置弹窗打开", editor != null)
	var name_field: LineEdit = editor.find_child("Character_name", true, false)
	name_field.text = "重开的角色"
	name_field.text_changed.emit(name_field.text)
	var description: TextEdit = editor.find_child("Character_description", true, false)
	description.text = "第一行\n第二行"
	description.text_changed.emit()
	for node in all_nodes(editor):
		if node is OptionButton:
			node.select(1)
			node.item_selected.emit(1)
		if node is SpinBox and node.value == 80:
			node.value = 72
	check("角色设置内容在滚动区域内", all_nodes(editor).any(func(n): return n is ScrollContainer and n.get_child(0).size.x <= n.size.x + 2))
	editor.confirmed.emit()
	for i in 4:
		await process_frame
	var reopened := CFDesignDb.new()
	check("弹窗保存至磁盘", bool(reopened.load_from_file("res://.forge_userdata/character-ui.json")["ok"]))
	var character: Dictionary = reopened.custom_characters[0]
	check("无需失焦也保存角色名称", character["name"] == "重开的角色")
	check("多行介绍完整保存", character["description"] == "第一行\n第二行")
	check("模板与生命设置生效", character["template"] == "Silent" and character["starting_hp"] == 72)
	check("修改角色保留池标识", character["card_pool"] == "UiHeroCardPool" and character["relic_pool"] == "UiHeroRelicPool")
	app.call("_open_character_editor", "UiHero", func(): pass, library)
	for i in 3:
		await process_frame
	for node in all_nodes(app):
		if node is AcceptDialog and node.title.begins_with("角色设置"):
			var field: LineEdit = node.find_child("Character_name", true, false)
			check("重开编辑器显示已保存数据", field.text == "重开的角色")
			node.canceled.emit()
	for i in 3:
		await process_frame
	app.db.add_custom_character({"id": "111", "name": "旧数字角色"})
	var starter := CFDesign.new_card(app.schema)
	starter["id"] = "RepairStarter"
	starter["pool"] = "111CardPool"
	starter["deck"] = {"enabled": true, "character": "111", "copies": 1}
	app.db.add_item(app.schema, CFDesign.KIND_CARD, starter)
	app.call("_open_character_editor", "111", func(): pass, library)
	for i in 3:
		await process_frame
	for node in all_nodes(app):
		if node is AcceptDialog and node.title == "角色设置 · 111":
			var repair: LineEdit = node.find_child("Character_id", true, false)
			check("旧数字标识有修复输入框", repair != null)
			repair.text = "Hero111"
			repair.text_changed.emit(repair.text)
			for field in ["card_pool", "relic_pool"]:
				var pool_input: LineEdit = node.find_child("Character_" + field, true, false)
				pool_input.text = "Hero111CardPool" if field == "card_pool" else "Hero111RelicPool"
				pool_input.text_changed.emit(pool_input.text)
			node.confirmed.emit()
	for i in 3:
		await process_frame
	reopened.load_from_file("res://.forge_userdata/character-ui.json")
	check("界面修复旧 ID 已持久化", CFCharacters.contains(reopened, "Hero111") and not CFCharacters.contains(reopened, "111"))
	check("界面修复保留并更新开局关联", not reopened.cards.is_empty() and reopened.cards[0]["deck"]["character"] == "Hero111")
	check("修复非法池名后卡牌所属池同步保存", not reopened.cards.is_empty() and reopened.cards[0]["pool"] == "Hero111CardPool")
	app.call("_open_character_editor", "UiHero", func(): pass, library)
	for i in 3:
		await process_frame
	for node in all_nodes(app):
		if node is AcceptDialog and node.title == "角色设置 · UiHero":
			editor = node
	var model_example: Button = editor.find_child("CharacterModelExample", true, false)
	check("界面提供自制模型示例", model_example != null)
	model_example.pressed.emit()
	for i in 3:
		await process_frame
	check("示例启用自定义模型", editor.find_child("CharacterCustomModel", true, false).button_pressed)
	check("显示场景和动画输入框", editor.find_child("CharacterModel_battle_scene", true, false).text == "battle.tscn" and editor.find_child("CharacterModel_attack", true, false).text == "attack")
	editor.confirmed.emit()
	for i in 3:
		await process_frame
	reopened.load_from_file("res://.forge_userdata/character-ui.json")
	var visuals: Dictionary = reopened.custom_characters[0]["visuals"]
	check("模型导入并保存到本地素材库", String(visuals["asset_root"]).begins_with("res://designs/character_assets/") and FileAccess.file_exists(String(visuals["asset_root"]).path_join("battle.tscn")))
	check("保存模型保留原有生命和卡池", reopened.custom_characters[0]["starting_hp"] == 72 and reopened.custom_characters[0]["card_pool"] == "UiHeroCardPool")
	app.call("_open_character_editor", "UiHero", func(): pass, library)
	for i in 3:
		await process_frame
	for node in all_nodes(app):
		if node is AcceptDialog and node.title == "角色设置 · UiHero":
			editor = node
	check("重开显示已保存模型", editor.find_child("CharacterCustomModel", true, false).button_pressed and editor.find_child("CharacterModelRoot", true, false).text == visuals["asset_root"])
	var battle: LineEdit = editor.find_child("CharacterModel_battle_scene", true, false)
	battle.text = "missing.tscn"
	battle.text_changed.emit(battle.text)
	editor.confirmed.emit()
	await process_frame
	check("错误模型路径阻止保存", is_instance_valid(editor) and app.db.custom_characters[0]["visuals"]["battle_scene"] == "battle.tscn")
	editor.canceled.emit()
	await process_frame
	check("取消模型编辑不修改保存内容", app.db.custom_characters[0]["visuals"]["battle_scene"] == "battle.tscn")
	check("旧角色改自制模型后保存为独立角色", app.db.custom_characters[0]["independent"] and not app.db.custom_characters[0]["include_base_relics"])
	var new_id: LineEdit = library.find_child("NewCharacterId", true, false)
	var new_name: LineEdit = library.find_child("NewCharacterName", true, false)
	new_id.text = "IndependentUiHero"
	new_name.text = "独立新角色"
	for node in all_nodes(library):
		if node is Button and node.text == "保存角色与两个池":
			node.pressed.emit()
	for i in 4:
		await process_frame
	var fresh: Dictionary = app.db.custom_characters[-1]
	check("界面新建空白独立角色成功", fresh["id"] == "IndependentUiHero" and fresh["independent"] and fresh["template"] == "Independent")
	check("新建角色素材已持久化且无模板起始内容", String(fresh["visuals"]["asset_root"]).begins_with("res://designs/character_assets/") and not fresh["use_base_deck"] and not fresh["use_base_relics"])
	app.call("_open_character_editor", "IndependentUiHero", func(): pass, library)
	for i in 4:
		await process_frame
	for node in all_nodes(app):
		if node is AcceptDialog and node.title == "角色设置 · IndependentUiHero":
			check("独立角色不显示五选一模板", not node.find_child("CharacterTemplate", true, false).visible)
			check("独立角色不显示原版池混入开关", not node.find_child("CharacterLegacy_include_base_relics", true, false).visible)
			node.confirmed.emit()
	for i in 3:
		await process_frame
	var fresh_db := CFDesignDb.new()
	fresh_db.load_from_file("res://.forge_userdata/character-ui.json")
	check("重开保留独立模式和空白内容配置", fresh_db.custom_characters[-1]["independent"] and not fresh_db.custom_characters[-1]["include_base_cards"])
	check("独立角色仍可删除", app.db.remove_custom_character(app.schema, "IndependentUiHero"))
	app.db.undo()
	check("独立角色删除可撤销", CFCharacters.contains(app.db, "IndependentUiHero"))
	app.queue_free()
	await process_frame
	print("===== CHARACTER UI %s (%d checks) =====" % ["PASSED" if failures == 0 else "FAILED", checks])
	quit(0 if failures == 0 else 1)
