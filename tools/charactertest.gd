extends SceneTree

## Isolated migration/export/build regression; never writes designs/main.json.
var failures := 0
var checks := 0

func check(label: String, value: bool) -> void:
	checks += 1
	if not value:
		failures += 1
	print("[%s] %s" % ["OK" if value else "FAIL", label])

func _init() -> void:
	var schema := CFSchema.new()
	CFSchemaScanner.scan(CFPaths.detect_source_root(), schema)
	var db := CFDesignDb.new()
	db.mod_id = "ForgeCharacterProbe"
	var legacy := {"id": "LegacyHero", "name": "旧角色", "card_pool": "LegacyCards", "relic_pool": "LegacyRelics", "namespace": "OldMod.Models.Characters"}
	db.add_custom_character(legacy)
	check("旧记录默认成为可用角色", db.custom_characters[0]["max_energy"] == 3)
	for template in CFCharacters.TEMPLATES:
		db.add_custom_character({"id": "Hero" + template, "name": "测试" + template, "template": template})
	var c: Dictionary = db.custom_characters[0].duplicate(true)
	c["starting_hp"] = 65
	c["max_energy"] = 4
	c["use_base_deck"] = false
	c["use_base_relics"] = false
	db.add_custom_character(c)
	var card := CFDesign.new_card(schema)
	card["id"] = "ProbeDraw"
	card["pool"] = "LegacyCards"
	card["type"] = "Skill"
	card["rarity"] = "Common"
	card["vars"] = [CFDesign.new_var("Draw", "Cards", "CardsVar", 2.0)]
	card["effects"] = [CFDesign.new_effect("draw")]
	card["effects"][0]["amount_is_var"] = true
	card["effects"][0]["amount_var"] = "Draw"
	card["deck"] = {"enabled": true, "character": "LegacyHero", "copies": 3}
	CFDesign.normalize(schema, card)
	db.cards = [card]
	db.save_ability_from_item(card, "DrawRecipe", "抽两张牌")
	var relic := CFDesign.new_relic(schema)
	relic["id"] = "ProbeRelic"
	relic["pool"] = "LegacyRelics"
	relic["deck"] = {"enabled": true, "character": "LegacyHero", "copies": 1}
	CFDesign.normalize(schema, relic)
	db.relics = [relic]
	var disk_path := "res://.forge_userdata/character-roundtrip.json"
	check("保存能力、角色、卡池和遗物池", bool(db.save_to_file(disk_path)["ok"]))
	var reopened := CFDesignDb.new()
	check("从磁盘重开", bool(reopened.load_from_file(disk_path)["ok"]))
	check("角色数值和能力变量保持", reopened.custom_characters[0]["starting_hp"] == 65 and reopened.custom_characters[0]["max_energy"] == 4 and reopened.abilities[0]["vars"][0]["name"] == "Draw")
	check("池关联与开局份数保持", reopened.cards[0]["pool"] == "LegacyCards" and reopened.cards[0]["deck"]["copies"] == 3 and reopened.relics[0]["pool"] == "LegacyRelics")
	var settings := CFPaths.load_settings()
	var options := settings.duplicate()
	options["out_dir"] = "res://exports/_charactertest"
	CFPaths.write_text("res://exports/_charactertest/ForgeCharacterProbe/src/Patches/StartingContentPatches.cs",
		"using HarmonyLib;\nnamespace ForgeCharacterProbe.Patches;\ninternal static class StartingContentPatches { private static Harmony? oldPatch; }\n")
	var report := CFExporter.export(schema, reopened, options)
	check("角色工程导出", bool(report.get("ok", false)))
	if not bool(report.get("ok", false)):
		print(report)
		quit(1)
		return
	var dir := String(report["mod_dir"])
	check("空自制池也有生成的类", FileAccess.file_exists(dir.path_join("src/CardPools/HeroSilentCardPool.cs")) and FileAccess.file_exists(dir.path_join("src/RelicPools/HeroSilentRelicPool.cs")))
	var manifest: Dictionary = JSON.parse_string(CFPaths.read_text(dir.path_join(db.mod_id + ".json")))
	check("清单声明 RitsuLib 依赖", manifest["dependencies"][0]["id"] == "STS2-RitsuLib")
	check("PCK 可加载", ProjectSettings.load_resource_pack(dir.path_join(db.mod_id + ".pck")))
	var loc: Dictionary = JSON.parse_string(CFPaths.read_text("res://ForgeCharacterProbe/localization/zhs/characters.json"))
	check("角色中文名按 RitsuLib 的实际 ID 装入 PCK", loc.get("FORGE_CHARACTER_PROBE_CHARACTER_LEGACY_HERO.title") == "旧角色" and loc.has("FORGE_CHARACTER_PROBE_CHARACTER_LEGACY_HERO.description"))
	check("无自定义角色 Harmony 补丁", CFExporter.collect_patches(schema, reopened).is_empty())
	check("重导出不编译已退役的旧开局补丁", CFPaths.read_text(dir.path_join("src/ForgeCharacterProbe.csproj")).contains("Compile Remove=\"Patches/StartingContentPatches.cs\""))
	var code := CFPaths.read_text(dir.path_join("src/Characters/LegacyHero.cs"))
	check("新 Mod ID 生效且开局不混入模板", code.contains("global::ForgeCharacterProbe.ProbeDraw") and not code.contains("Template.StartingDeck"))
	# Validate errors without touching the persisted valid document.
	var invalid := CFDesignDb.new()
	invalid.add_custom_character({"id": "class"})
	check("非法标识被阻止", CFExporter.preflight(schema, invalid)["blocking"])
	invalid.custom_characters = [{"id": "Ironclad"}]
	check("原版角色 ID 冲突被阻止", CFExporter.preflight(schema, invalid)["blocking"])
	invalid.custom_characters = [{"id": "Hero", "use_base_deck": false}]
	check("空开局被阻止", CFExporter.preflight(schema, invalid)["blocking"])
	invalid.custom_characters = [{"id": "Hero", "include_base_cards": false}]
	check("空奖励池被阻止", CFExporter.preflight(schema, invalid)["blocking"])
	var broken_options := options.duplicate()
	broken_options["ritsulib_dir"] = "res://missing-ritsulib"
	broken_options["dry_run"] = true
	check("依赖缺失阻止导出", not CFExporter.export(schema, reopened, broken_options)["ok"])
	var repair := CFDesignDb.new()
	repair.custom_characters = [{"id": "111", "card_pool": "OldCards", "relic_pool": "OldRelics"}]
	repair.cards = [{"deck": {"enabled": true, "character": "111"}}]
	repair.update_custom_character("111", {"id": "Hero111", "card_pool": "OldCards", "relic_pool": "OldRelics"})
	check("修复旧数字标识同步更新开局关联", repair.custom_characters[0]["id"] == "Hero111" and repair.cards[0]["deck"]["character"] == "Hero111")
	repair.undo()
	check("标识修复可整体撤销", repair.custom_characters[0]["id"] == "111" and repair.cards[0]["deck"]["character"] == "111")
	var only_character := CFDesignDb.new()
	only_character.mod_id = "CharacterOnly"
	only_character.add_custom_character({"id": "EmptyContentHero"})
	var only_report := CFExporter.export(schema, only_character, options)
	check("仅含角色的项目也能导出资源包并要求编译", only_report["ok"] and only_report["pck"]["ok"] and only_report["needs_build"])
	# Compile all five templates against the installed game and RitsuLib.
	var build := CFExporter.verify_build(ProjectSettings.globalize_path(dir))
	print(build.get("log", ""))
	check("真实游戏程序集编译", bool(build.get("ok", false)))
	if bool(build.get("ok", false)):
		check("DLL 放置到可安装目录", FileAccess.file_exists(dir.path_join(db.mod_id + ".dll")))
	print("===== CHARACTER TEST %s (%d checks) =====" % ["PASSED" if failures == 0 else "FAILED", checks])
	quit(0 if failures == 0 else 1)
