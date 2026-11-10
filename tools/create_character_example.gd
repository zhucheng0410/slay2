extends SceneTree

## Generates a separate editable example; never changes main.json or settings.
func _init() -> void:
	var schema := CFSchema.new()
	CFSchemaScanner.scan(CFPaths.detect_source_root(), schema)
	var db := CFDesignDb.new()
	db.seed_example(schema)
	db.mod_id = "ForgeCharacterExample"
	db.mod_name = "锻造旅者 · 自定义角色示例"
	db.mod_description = "独立角色、卡牌池、遗物池和组合能力示例。外观借用铁甲战士。"
	db.add_custom_character({"id": "ForgeWanderer", "name": "锻造旅者", "name_eng": "The Forge Wanderer",
		"description": "以自制卡牌踏上旅途。\n通过抽牌与格挡的组合寻找机会。",
		"description_eng": "A wanderer wielding custom cards.\nFinds opportunities through draw and defense.",
		"starting_hp": 72, "use_base_deck": false, "use_base_relics": false})
	var strike := CFDesign.new_card(schema)
	strike["id"] = "ForgeStrike"
	strike["type"] = "Attack"
	strike["rarity"] = "Basic"
	strike["vars"] = [CFDesign.new_var("Damage", "Damage", "DamageVar", 6.0, "Move")]
	strike["text"]["zhs"] = {"title": "锻击", "description": "造成 {Damage:diff()} 点伤害。"}
	strike["text"]["eng"] = {"title": "Forged Strike", "description": "Deal {Damage:diff()} damage."}
	strike["effects"] = [effect("damage", "Damage", "card_target")]
	strike["deck"] = {"enabled": true, "character": "ForgeWanderer", "copies": 5}
	var guard := CFDesign.new_card(schema)
	guard["id"] = "ForgeGuard"
	guard["type"] = "Skill"
	guard["target"] = "Self"
	guard["rarity"] = "Basic"
	guard["flags"]["gains_block"] = true
	guard["vars"] = [CFDesign.new_var("Block", "Block", "BlockVar", 5.0, "Move")]
	guard["text"]["zhs"] = {"title": "护身", "description": "获得 {Block:diff()} 点格挡。"}
	guard["text"]["eng"] = {"title": "Forged Guard", "description": "Gain {Block:diff()} Block."}
	guard["effects"] = [effect("block", "Block", "self")]
	guard["deck"] = {"enabled": true, "character": "ForgeWanderer", "copies": 4}
	var insight := guard.duplicate(true)
	insight["id"] = "ForgeInsight"
	insight["rarity"] = "Common"
	insight["vars"].append(CFDesign.new_var("Draw", "Cards", "CardsVar", 2.0))
	insight["effects"].append(effect("draw", "Draw", "self"))
	insight["text"]["zhs"] = {"title": "沉着思考", "description": "获得 {Block:diff()} 点格挡。抽 {Draw} 张牌。"}
	insight["text"]["eng"] = {"title": "Composed Insight", "description": "Gain {Block:diff()} Block. Draw {Draw} cards."}
	insight["deck"]["copies"] = 1
	db.cards = [strike, guard, insight]
	for card in db.cards:
		card["pool"] = "ForgeWandererCardPool"
		CFDesign.normalize(schema, card)
	var relic: Dictionary = db.relics[0]
	relic["id"] = "ForgeKeepsake"
	relic["pool"] = "ForgeWandererRelicPool"
	relic["rarity"] = "Starter"
	relic["vars"][0]["base"] = 3.0
	relic["text"]["zhs"]["title"] = "旅者护符"
	relic["text"]["eng"]["title"] = "Wanderer's Keepsake"
	relic["deck"] = {"enabled": true, "character": "ForgeWanderer"}
	CFDesign.normalize(schema, relic)
	db.save_ability_from_item(insight, "DrawAndGuard", "抽牌与格挡")
	var saved := db.save_to_file("res://designs/CharacterExample.json")
	if not saved["ok"]:
		push_error(saved["error"])
		quit(1)
		return
	var options := CFPaths.load_settings()
	options["out_dir"] = "res://exports"
	var report := CFExporter.export(schema, db, options)
	if not report["ok"]:
		print(report)
		quit(1)
		return
	var build := CFExporter.verify_build(ProjectSettings.globalize_path(report["mod_dir"]))
	print(build.get("log", ""))
	print("EXAMPLE BUILD: ", build.get("ok", false))
	quit(0 if build.get("ok", false) else 1)

func effect(kind: String, variable: String, target: String) -> Dictionary:
	var result := CFDesign.new_effect(kind)
	result["amount_is_var"] = true
	result["amount_var"] = variable
	result["target"] = target
	return result
