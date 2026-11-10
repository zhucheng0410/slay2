extends SceneTree

class IsolatedApp extends "res://ui/app.gd":
	func _save_settings() -> bool:
		return true
	func _load_last_design() -> void:
		pass

var checks := 0
var failures := 0

func check(label: String, passed: bool) -> void:
	checks += 1
	if not passed:
		failures += 1
	print("[%s] %s" % ["OK" if passed else "FAIL", label])

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1280, 800)
	var db := CFDesignDb.new()
	db.mod_id = "DialogueProbe"
	db.add_custom_character({"id": "Hero"})
	db.add_custom_character({"id": "Other"})
	var data: Dictionary = db.custom_characters[0]["ancient_dialogues"]
	check("Old characters acquire all nine encounters", data.size() == 9)
	check("Default dialogues validate", CFAncientDialogues.validate(data).is_empty())
	data["DARV"]["first"][0]["text"] = "角色专属的台词\n第二行"
	data["DARV"]["first"][0]["text_eng"] = ""
	check("Character defaults do not share dictionaries", db.custom_characters[1]["ancient_dialogues"]["DARV"]["first"][0]["text"] != data["DARV"]["first"][0]["text"])
	var reopened := CFDesignDb.new()
	reopened.load_from_json(db.to_json())
	check("Authored multiline dialogue survives roundtrip", reopened.custom_characters[0]["ancient_dialogues"] == data)
	var broken := data.duplicate(true)
	broken["NEOW"]["repeat"] = []
	check("Empty repeating sequence rejected", not CFAncientDialogues.validate(broken).is_empty())
	broken = data.duplicate(true)
	broken["DARV"]["first"][0]["text"] = "  "
	check("Blank bilingual line rejected", not CFAncientDialogues.validate(broken).is_empty())
	broken = data.duplicate(true)
	broken["DARV"]["first"][0]["speaker"] = "invalid"
	check("Invalid speaker rejected", not CFAncientDialogues.validate(broken).is_empty())
	var tables := {}
	CFAncientDialogues.add_localization(tables, db)
	check("All game languages exported", tables.size() == CFSchema.ALL_LOCALES.size())
	var key := "DARV.talk.DIALOGUE_PROBE_CHARACTER_HERO.0-0.ancient"
	check("Missing English falls back to authored Chinese", tables["eng"]["ancients"][key] == data["DARV"]["first"][0]["text"])
	for ancient in CFAncientDialogues.CATALOG:
		var prefix: String = ancient + ".talk.DIALOGUE_PROBE_CHARACTER_HERO."
		check(ancient + " first/repeat text, buttons and visit metadata", tables["zhs"]["ancients"].has(prefix + "0-0.next") and tables["zhs"]["ancients"].has(prefix + "1-0r.next") and tables["zhs"]["ancients"][prefix + "1-visit"] == "1" and not tables["zhs"]["ancients"].has(prefix + "1-1r.next"))
	check("Architect completion metadata exported", tables["zhs"]["ancients"]["THE_ARCHITECT.talk.DIALOGUE_PROBE_CHARACTER_HERO.1-endattack"] == "Both")
	var schema := CFSchema.new()
	CFSchemaScanner.scan(CFPaths.detect_source_root(), schema)
	# Validate catalog against actual playable Act/ModelDb references, not just
	# direct inheritance (which would miss TheArchitect and include deprecated).
	var model_source := schema.source_root.path_join("src/Core/Models")
	var sources := CFPaths.read_text(model_source.path_join("ModelDb.cs"))
	for file in DirAccess.get_files_at(model_source.path_join("Acts")):
		if file.ends_with(".cs"):
			sources += CFPaths.read_text(model_source.path_join("Acts").path_join(file))
	for match in RegEx.create_from_string("AncientEvent<([A-Za-z0-9]+)>\\(\\)").search_all(sources):
		if match.get_string(1) == "T":
			continue
		check("Playable source Ancient covered: " + match.get_string(1), CFAncientDialogues.CATALOG.has(CFIds.slugify(match.get_string(1))))
	var card := CFDesign.new_card(schema)
	card["id"] = "OwnCard"
	card["pool"] = "HeroCardPool"
	card["type"] = "Skill"
	card["rarity"] = "Common"
	db.cards = [card]
	check("Tome auto-selects an owned playable card", CFAncientDialogues.tome_card(db.custom_characters[0], db) == "OwnCard")
	check("Tome never borrows another character's card", CFAncientDialogues.tome_card(db.custom_characters[1], db).is_empty())
	db.custom_characters[0]["ancient_tome_card"] = "OwnCard"
	var prepared := CFAncientDialogues.prepare_export(db, schema)
	check("Tome exports an Ancient edition", prepared.cards.size() == 2 and prepared.cards[1]["rarity"] == "Ancient" and prepared.custom_characters[0]["ancient_tome_card"] == "HeroForgeAncientTome")
	check("Tome edition preserves effects and upgrades", prepared.cards[1]["effects"] == db.cards[0]["effects"] and prepared.cards[1]["upgrade"] == db.cards[0]["upgrade"])
	check("Tome edition is not inserted into starting deck", not prepared.cards[1]["deck"]["enabled"])
	check("Export preparation never adds cards to the saved design", db.cards.size() == 1 and db.cards[0]["rarity"] == "Common" and db.custom_characters[0]["ancient_tome_card"] == "OwnCard")
	db.cards[0]["rarity"] = "Ancient"
	prepared = CFAncientDialogues.prepare_export(db, schema)
	check("Authored Ancient cards are registered directly", prepared.cards.size() == 1 and prepared.custom_characters[0]["ancient_tome_card"] == "OwnCard")
	db.cards[0]["rarity"] = "Common"
	db.custom_characters[0]["ancient_tome_card"] = "DeletedCard"
	check("Stale Tome reference is an error", CFCharacters.validate(schema, db, false)["errors"].any(func(e): return "尘封魔典" in e))
	db.custom_characters[0].erase("ancient_tome_card")
	var app := IsolatedApp.new()
	root.add_child(app)
	for i in 20:
		await process_frame
	app.db.load_from_json(db.to_json())
	app.settings["last_design_file"] = "res://.forge_userdata/ancient-ui.json"
	CFAncientDialogueEditor.open(app, "Hero")
	await process_frame
	var win: AcceptDialog = app.find_child("AncientDialogueEditor", true, false)
	for i in 3:
		await process_frame
	check("Dialogue window fits within requested height", win.size.y <= 800)
	var select: OptionButton = win.find_child("AncientSelect", true, false)
	check("Editor lists every Ancient including Architect", select.item_count == 9 and select.get_item_text(8) == "建筑师")
	var row: VBoxContainer = win.find_child("AncientLine0", true, false)
	var input: TextEdit = row.find_child("text", true, false)
	input.text = "无需失焦即可保存的新台词"
	input.text_changed.emit()
	select.select(8)
	select.item_selected.emit(8)
	select.select(0)
	select.item_selected.emit(0)
	row = win.find_child("AncientLine0", true, false)
	check("Switching Ancient preserves drafts", row.find_child("text", true, false).text == "无需失焦即可保存的新台词")
	win.find_child("AncientAddLine", true, false).pressed.emit()
	win.confirmed.emit()
	check("Blank added line blocks Save", not win.is_queued_for_deletion() and not win.find_child("AncientErrors", true, false).text.is_empty())
	row = win.find_child("AncientLine2", true, false)
	row.find_child("Remove", true, false).pressed.emit()
	win.confirmed.emit()
	await process_frame
	var disk := CFDesignDb.new()
	check("Editor saves to disk", disk.load_from_file("res://.forge_userdata/ancient-ui.json")["ok"])
	check("Saved text survives reopen", disk.custom_characters[0]["ancient_dialogues"]["NEOW"]["first"][0]["text"] == "无需失焦即可保存的新台词")
	app.db.undo()
	check("Dialogue edits can be undone", app.db.custom_characters[0]["ancient_dialogues"]["NEOW"]["first"][0]["text"] != "无需失焦即可保存的新台词")
	app.db.redo()
	var before: Array = app.db.custom_characters.duplicate(true)
	CFAncientDialogueEditor.open(app, "Hero")
	win = app.find_child("AncientDialogueEditor", true, false)
	row = win.find_child("AncientLine0", true, false)
	input = row.find_child("text", true, false)
	input.text = "取消的修改"
	input.text_changed.emit()
	win.canceled.emit()
	await process_frame
	check("Cancel does not mutate library", app.db.custom_characters == before)
	app.queue_free()
	await process_frame
	print("===== ANCIENT DIALOGUE TEST %s: %d checks, %d failures =====" % ["PASSED" if failures == 0 else "FAILED", checks, failures])
	quit(0 if failures == 0 else 1)
