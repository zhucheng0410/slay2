extends SceneTree

var failures := 0
var checks := 0

func check(label: String, value: bool) -> void:
	checks += 1
	if not value:
		failures += 1
	print("[%s] %s" % ["OK" if value else "FAIL", label])

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var main_hash := FileAccess.get_sha256("res://designs/main.json")
	var settings_hash := FileAccess.get_sha256(CFPaths.SETTINGS_PATH)
	var schema := CFSchema.new()
	CFSchemaScanner.scan(CFPaths.detect_source_root(), schema)
	var db := CFDesignDb.new()
	db.mod_id = "ForgeModelProbe"
	db.add_custom_character({"id": "Puppet", "visuals": CFCharacterVisuals.example()})
	var card := CFDesign.new_card(schema)
	card["id"] = "PuppetStrike"
	card["pool"] = "PuppetCardPool"
	card["rarity"] = "Common"
	card["deck"] = {"enabled": true, "character": "Puppet", "copies": 5}
	CFDesign.normalize(schema, card)
	db.cards = [card]
	var blank := CFDesignDb.new()
	blank.add_custom_character(CFCharacters.new_character({"id": "FreshHero"}))
	check("新角色使用独立模型且不借用起始牌组", blank.custom_characters[0]["independent"] and not blank.custom_characters[0]["use_base_deck"] and blank.custom_characters[0]["visuals"]["mode"] == "custom")
	check("新角色空白草稿可保存", CFCharacters.validate(schema, blank, false)["errors"].is_empty())
	check("新角色未配置卡牌时禁止导出", not CFCharacters.validate(schema, blank)["errors"].is_empty())
	check("旧角色默认使用原版外观", CFCharacters.normalized({"id": "Legacy"})["visuals"]["mode"] == "template")
	check("模型源文件通过依赖检查", CFCharacterVisuals.validate(db.custom_characters[0]["visuals"]).is_empty())
	var imported := CFCharacterVisuals.import_bundle(db.custom_characters[0]["visuals"])
	check("模型导入本地素材库", imported["ok"])
	if not imported["ok"]:
		print(imported)
		quit(1)
		return
	db.custom_characters[0]["visuals"] = imported["visuals"]
	check("保存的是素材副本路径", String(imported["visuals"]["asset_root"]).begins_with("res://designs/character_assets/"))
	check("相同素材复用存储且撤销不会覆盖文件", CFCharacterVisuals.import_bundle(CFCharacterVisuals.example())["visuals"]["asset_root"] == imported["visuals"]["asset_root"])
	db.save_to_file("res://.forge_userdata/model-roundtrip.json")
	var reopened := CFDesignDb.new()
	reopened.load_from_file("res://.forge_userdata/model-roundtrip.json")
	check("重开保留模型、动画、图片、角色池", reopened.custom_characters == JSON.parse_string(JSON.stringify(db.custom_characters)))
	var options := CFPaths.load_settings()
	options["out_dir"] = "res://exports/_modeltest"
	var report := CFExporter.export(schema, reopened, options)
	check("含自制模型的角色导出并回读成功", report["ok"])
	if not report["ok"]:
		print(report)
		quit(1)
		return
	var dir := String(report["mod_dir"])
	var pck := CFPckWriter.read_pck(dir.path_join(db.mod_id + ".pck"))
	check("贴图转换为无需导入缓存的压缩纹理", pck["files"].any(func(f): return String(f["path"]).ends_with("puppet.svg.ctex")))
	check("资源没有依赖源机器路径或导入缓存", not pck["files"].any(func(f): return String(f["path"]).contains(".godot") or String(f["path"]).contains("character_assets")))
	var path := CFCharacterVisuals.resource_path(db.mod_id, "Puppet", "battle.tscn")
	var scene := load(path) as PackedScene
	var puppet := scene.instantiate()
	root.add_child(puppet)
	await process_frame
	check("战斗场景和图像实例化", puppet.get_node("Visuals/Body").texture.get_width() == 240)
	check("战斗边界与定位节点可访问", puppet.get_node("%Bounds") is Control and puppet.get_node("%CenterPos") is Marker2D)
	var player: AnimationPlayer = puppet.get_node("AnimationPlayer")
	player.play("attack")
	player.seek(0.2, true)
	check("攻击动画实际移动模型", puppet.get_node("Visuals").position.x > 30)
	player.play("dead")
	player.seek(0.7, true)
	check("死亡动画实际改变姿态", puppet.get_node("Visuals").rotation < -1)
	player.play("idle")
	player.seek(0.0, true)
	check("复活/待机恢复位置与可见性", puppet.get_node("Visuals").position == Vector2.ZERO and puppet.get_node("Visuals").modulate.a == 1)
	puppet.queue_free()
	await process_frame
	for field in CFCharacterVisuals.PICTURES:
		var image_path := CFCharacterVisuals.resource_path(db.mod_id, "Puppet", imported["visuals"][field])
		var texture := load(image_path) as CompressedTexture2D
		check("游戏要求的具体纹理类型 " + field, texture != null)
		if texture != null:
			var original := Image.new()
			original.load(ProjectSettings.globalize_path(String(imported["visuals"]["asset_root"]).path_join(imported["visuals"][field])))
			original.convert(Image.FORMAT_RGBA8)
			check("图片尺寸、像素与透明度保留 " + field, texture.get_image().get_data() == original.get_data() and texture.get_size() == Vector2(original.get_size()))
	# Reproduce the user's save-after-export sequence, using isolated files.
	var settings_path := "res://.forge_userdata/post-pack-save/settings.cfg"
	var updated := options.duplicate(true)
	updated["last_design_file"] = "res://.forge_userdata/post-pack-save/design.json"
	check("挂载 PCK 后保存设置成功", CFPaths.save_settings(updated, settings_path) == OK)
	check("挂载 PCK 后设置实际写入磁盘", CFPaths.load_settings(settings_path)["last_design_file"] == updated["last_design_file"])
	updated["theme_mode"] = "light"
	check("再次保存设置成功", CFPaths.save_settings(updated, settings_path) == OK and CFPaths.load_settings(settings_path)["theme_mode"] == "light")
	reopened.mod_name = "导出后保存的设计"
	check("挂载 PCK 后保存角色设计成功", reopened.save_to_file(updated["last_design_file"])["ok"])
	var after_export := CFDesignDb.new()
	check("导出后的设计可重开且保留角色", after_export.load_from_file(updated["last_design_file"])["ok"] and after_export.mod_name == reopened.mod_name and after_export.custom_characters == reopened.custom_characters)
	# A blocked parent must report failure instead of claiming settings were saved.
	var blocked := "res://.forge_userdata/post-pack-save/not-a-directory"
	CFPaths.write_text(blocked, "file")
	check("无法写入设置时返回错误", CFPaths.save_settings(updated, blocked.path_join("settings.cfg")) != OK)
	var invalid: Dictionary = imported["visuals"].duplicate(true)
	invalid["battle_scene"] = "../escape.tscn"
	check("拒绝越界场景路径", not CFCharacterVisuals.validate(invalid).is_empty())
	invalid["battle_scene"] = "missing.tscn"
	check("拒绝缺失场景", not CFCharacterVisuals.validate(invalid).is_empty())
	invalid = imported["visuals"].duplicate(true)
	invalid["attack_delay"] = -1
	check("拒绝非法动画延迟", not CFCharacterVisuals.validate(invalid).is_empty())
	var c: Dictionary = reopened.custom_characters[0].duplicate(true)
	c["visuals"]["attack"] = "missing_animation"
	check("拒绝不存在的动作名称", not CFCharacterVisuals.scene_errors(c, db.mod_id).is_empty())
	c = reopened.custom_characters[0].duplicate(true)
	c["visuals"]["rest_scene"] = "battle.tscn"
	check("拒绝缺少营火交互节点的模型", not CFCharacterVisuals.scene_errors(c, db.mod_id).is_empty())
	var broken_root := ProjectSettings.globalize_path("res://.forge_userdata/broken-model")
	check("创建缺失依赖测试文件", CFPaths.write_text(broken_root.path_join("battle.tscn"), '[gd_scene load_steps=2 format=3]\n[ext_resource type="Texture2D" path="res://missing.png" id="1"]\n[node name="Root" type="Node2D"]\n'))
	var broken := CFCharacterVisuals.normalized({"mode": "custom", "asset_root": broken_root})
	check("拒绝场景内缺失的纹理依赖", not CFCharacterVisuals.validate(broken).is_empty())
	check("创建脚本依赖测试文件", CFPaths.write_text(broken_root.path_join("battle.tscn"), '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://model.gd" id="1"]\n[node name="Root" type="Node2D"]\nscript = ExtResource("1")\n'))
	check("回读资源包后仍能重新导入本地模型", CFCharacterVisuals.import_bundle(CFCharacterVisuals.example())["ok"])
	check("拒绝未打包的脚本依赖", not CFCharacterVisuals.validate(broken).is_empty())
	var static_character := reopened.custom_characters[0].duplicate(true) as Dictionary
	static_character["visuals"]["animated"] = false
	check("静态自制模型不生成动画状态机", not CFCharacters.emit(static_character, reopened, schema).contains("StandardCue"))
	var no_pck := options.duplicate()
	no_pck["include_pck"] = false
	check("模型禁止省略 PCK", not CFExporter.export(schema, reopened, no_pck)["ok"])
	var code := CFPaths.read_text(dir.path_join("src/Characters/Puppet.cs"))
	check("独立角色无原版角色实例和默认球位", not code.contains("ModelDb.Character<") and code.contains("BaseOrbSlotCount => 0") and code.contains("PlaceholderCharacterId => null") and code.contains("ShouldAlwaysShowStarCounter => false"))
	check("药水池独立且不含原版专属药水", CFPaths.read_text(dir.path_join("src/PotionPools/PuppetPotionPool.cs")).contains("Array.Empty<PotionModel>()"))
	for template in CFCharacters.TEMPLATES:
		var variant: Dictionary = reopened.custom_characters[0].duplicate(true)
		variant["template"] = template
		variant["include_base_relics"] = true
		variant["use_base_deck"] = true
		var generated := CFCharacters.emit(variant, reopened, schema)
		check("旧模板 " + template + " 不影响独立角色机制或池", not generated.contains("Template.") and not CFExporter.emit_custom_pool(reopened, variant, "PuppetRelicPool", true, reopened.mod_id).contains("Template."))
	check("自定义模型使用 RitsuLib 节点工厂与动画状态机", code.contains("CreateFromScenePath<NCreatureVisuals>") and code.contains("StandardCue"))
	check("自定义模型不调用原版骨骼动画", not code.contains("Template.GenerateAnimator"))
	check("角色注册仍可用于游戏选择", CFPaths.read_text(dir.path_join("src/ModEntry.cs")).contains("RegisterCharacter<global::ForgeModelProbe.Models.Characters.Puppet>"))
	var build := CFExporter.verify_build(ProjectSettings.globalize_path(dir))
	print(build.get("log", ""))
	check("真实游戏和 RitsuLib 程序集编译", build.get("ok", false))
	reopened.mod_id = "RenamedModelProbe"
	var renamed := CFExporter.export(schema, reopened, options)
	check("修改 Mod ID 后资源引用重新生成", renamed["ok"] and ResourceLoader.exists(CFCharacterVisuals.resource_path(reopened.mod_id, "Puppet", "battle.tscn")))
	check("测试未改用户设计或设置", main_hash == FileAccess.get_sha256("res://designs/main.json") and settings_hash == FileAccess.get_sha256(CFPaths.SETTINGS_PATH))
	print("===== CHARACTER MODEL %s (%d checks) =====" % ["PASSED" if failures == 0 else "FAILED", checks])
	quit(0 if failures == 0 else 1)
