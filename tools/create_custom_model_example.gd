extends SceneTree

func _init() -> void:
	var schema := CFSchema.new()
	CFSchemaScanner.scan(CFPaths.detect_source_root(), schema)
	var db := CFDesignDb.new()
	var loaded := db.load_from_file("res://designs/CharacterExample.json")
	if not loaded["ok"]:
		push_error(loaded["error"])
		quit(1)
		return
	db.mod_id = "ForgeCustomModelExample"
	db.mod_version = "1.0.2"
	db.mod_name = "锻造木偶 · 自定义模型示例"
	db.mod_description = "独立可选角色、自制战斗模型和动画、选角图、卡牌池与遗物池。"
	var imported := CFCharacterVisuals.import_bundle(CFCharacterVisuals.example())
	if not imported["ok"]:
		push_error(imported["error"])
		quit(1)
		return
	var c: Dictionary = db.custom_characters[0]
	c["name"] = "锻造木偶"
	c["name_eng"] = "The Forge Puppet"
	c["description"] = "被点亮的炉心，驱动着木制躯壳。\n以抽牌和格挡的组合，探索自己的旅途。"
	c["description_eng"] = "A wooden body awakened by a forge heart.\nDraw and defend to find your own path."
	c["visuals"] = imported["visuals"]
	db.custom_characters[0] = CFCharacters.normalized(c)
	var saved := db.save_to_file("res://designs/CustomModelExample.json")
	if not saved["ok"]:
		push_error(saved["error"])
		quit(1)
		return
	var options := CFPaths.load_settings()
	options["out_dir"] = "res://exports"
	var report := CFExporter.export(schema, db, options)
	if not report["ok"]:
		push_error(report["error"])
		quit(1)
		return
	var build := CFExporter.verify_build(ProjectSettings.globalize_path(report["mod_dir"]))
	print(build.get("log", ""))
	var picture := Image.new()
	picture.load(CFCharacterVisuals.EXAMPLE.path_join("puppet.svg"))
	picture.save_png(ProjectSettings.globalize_path("res://exports/ForgeCustomModelExample/model-preview.png"))
	print("CUSTOM MODEL EXAMPLE: ", build.get("ok", false))
	quit(0 if build.get("ok", false) else 1)
