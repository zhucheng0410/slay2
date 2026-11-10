@tool
class_name CFCharacters
extends RefCounted

## Playable characters built against the bundled RitsuLib 0.6.7 API.
## Old pool-only records acquire defaults without changing their stable model IDs.
const TEMPLATES := ["Ironclad", "Silent", "Regent", "Necrobinder", "Defect"]
const RITSU_VERSION := "0.6.7"


static func is_independent(c: Dictionary) -> bool:
	return bool(c.get("independent", false)) or c.get("visuals", {}).get("mode", "template") == "custom"


static func new_character(record: Dictionary) -> Dictionary:
	var c := record.duplicate(true)
	c["independent"] = true
	c["visuals"] = CFCharacterVisuals.example()
	return normalized(c)


static func public_stem(value: String) -> String:
	# RitsuLib uses acronym-aware boundaries, unlike the vanilla Slugify rule.
	var result := RegEx.create_from_string("[^a-zA-Z0-9]+").sub(value.strip_edges(), "_", true)
	result = RegEx.create_from_string("([A-Z]+)([A-Z][a-z])").sub(result, "$1_$2", true)
	result = RegEx.create_from_string("([a-z0-9])([A-Z])").sub(result, "$1_$2", true)
	result = RegEx.create_from_string("_+").sub(result, "_", true)
	return result.trim_prefix("_").trim_suffix("_").to_upper()


static func entry(mod_id: String, character_id: String) -> String:
	return "%s_CHARACTER_%s" % [public_stem(mod_id), public_stem(code_name(character_id))]


## The old pool editor accepted numeric character IDs. Keep saved references
## intact, but use a legal class name consistently in code and localization.
static func code_name(id: String) -> String:
	if RegEx.create_from_string("^[0-9]+$").search(id) != null:
		return "Character" + id
	return id


static func normalized(record: Dictionary) -> Dictionary:
	var c := record.duplicate(true)
	var id := String(c.get("id", "")).strip_edges()
	c["id"] = id
	var defaults := {"name": id, "name_eng": id, "description": "自定义角色。",
		"description_eng": "A custom character.", "card_pool": id + "CardPool",
		"relic_pool": id + "RelicPool", "template": "Ironclad", "starting_hp": 80,
		"starting_gold": 99, "max_energy": 3, "use_base_deck": true,
		"use_base_relics": true, "include_base_cards": true, "include_base_relics": true}
	for key in defaults:
		if not c.has(key):
			c[key] = defaults[key]
	for key in ["name", "name_eng"]:
		if String(c[key]).strip_edges().is_empty():
			c[key] = id
	c["visuals"] = CFCharacterVisuals.normalized(c.get("visuals", {}))
	c["ancient_dialogues"] = CFAncientDialogues.normalized(c.get("ancient_dialogues", {}))
	c["independent"] = is_independent(c)
	if c["independent"]:
		c["template"] = "Independent"
		# Old custom-model records silently inherited a vanilla character. Migrate
		# the effective settings while keeping IDs and explicit starting decks.
		for key in ["use_base_deck", "use_base_relics", "include_base_cards", "include_base_relics"]:
			c[key] = false
	return c


static func contains(db: CFDesignDb, id: String) -> bool:
	for c in db.custom_characters:
		if String(c.get("id", "")) == id:
			return true
	return false


static func owns_pool(db: CFDesignDb, pool: String, relic: bool) -> bool:
	for c in db.custom_characters:
		if String(c.get("relic_pool" if relic else "card_pool", "")) == pool:
			return true
	return false


static func validate(schema: CFSchema, db: CFDesignDb, require_content: bool = true) -> Dictionary:
	var errors: Array = []
	var warnings: Array = []
	var names := {}
	var entries := {}
	for item in db.all_items():
		names[String(item.get("id", ""))] = true
	for original in db.custom_characters:
		var c := normalized(original)
		var id := String(c["id"])
		if c["independent"] or not String(c.get("ancient_tome_card", "")).is_empty():
			var generated_id := CFAncientDialogues.tome_copy_id(c)
			if names.has(generated_id):
				errors.append("角色 %s 的尘封魔典导出副本标识与已有内容冲突：%s" % [id, generated_id])
			names[generated_id] = true
		for error in CFAncientDialogues.validate(c["ancient_dialogues"]):
			errors.append("角色 %s：%s" % [id, error])
		if not String(c.get("ancient_tome_card", "")).is_empty() and CFAncientDialogues.tome_card(c, db).is_empty():
			errors.append("角色 %s 的尘封魔典卡牌已删除或不在专属卡池中，请重新选择。" % id)
		var fields := ["id", "card_pool", "relic_pool"]
		if c["independent"]:
			c["potion_pool"] = code_name(id) + "PotionPool"
			fields.append("potion_pool")
		for field in fields:
			var value := String(c[field])
			if field == "id":
				value = code_name(value)
				if value != id:
					warnings.append("旧角色标识 %s 导出为 %s；保存的标识和开局关联保持不变。" % [id, value])
			if not CFIds.is_valid_cs_identifier(value):
				errors.append("角色 %s 的 %s 必须是合法的 C# 标识符：%s" % [id, field, value])
			if names.has(value):
				errors.append("角色/池/卡牌/遗物标识重复：%s" % value)
			names[value] = true
			var entry := public_stem(value) if field == "id" else CFIds.slugify(value)
			if entries.has(entry):
				errors.append("角色或池的模型键重复：%s" % entry)
			entries[entry] = true
		for vanilla in schema.characters:
			if CFIds.slugify(String(vanilla.get("class_name", ""))) == CFIds.slugify(id):
				errors.append("角色 %s 与游戏已有角色的模型键冲突。" % id)
		for field in ["card_pool", "relic_pool"]:
			var pools: Array = schema.relic_pools if field == "relic_pool" else schema.card_pools
			for pool in pools:
				if CFIds.slugify(String(pool.get("class_name", ""))) == CFIds.slugify(String(c[field])):
					errors.append("角色 %s 的池 %s 与游戏已有池冲突。" % [id, c[field]])
		if not c["independent"] and not String(c["template"]) in TEMPLATES:
			errors.append("角色 %s 的外观模板无效。" % id)
		for error in CFCharacterVisuals.validate(c["visuals"]):
			errors.append("角色 %s：%s" % [id, error])
		if c["independent"] and c["visuals"]["mode"] != "custom":
			errors.append("独立角色 %s 需要自定义模型，可先使用锻造木偶示例。" % id)
		for field in ["starting_hp", "starting_gold", "max_energy"]:
			var minimum := 0 if field == "starting_gold" else 1
			if not (c[field] is float or c[field] is int) or float(c[field]) != floor(float(c[field])) or float(c[field]) < minimum or float(c[field]) > 9999:
				errors.append("角色 %s 的 %s 必须是 %d～9999 的整数。" % [id, field, minimum])
		if not require_content:
			continue # Drafts may be saved before their card pool is authored.
		if c["independent"] and CFAncientDialogues.tome_card(c, db).is_empty():
			errors.append("角色 %s 需要一张专属攻击/技能/能力牌作为达弗的尘封魔典奖励。" % id)
		elif c["independent"] and String(c.get("ancient_tome_card", "")).is_empty():
			warnings.append("角色 %s 的尘封魔典将使用专属卡牌 %s；可在先古之民对话中指定。" % [id, CFAncientDialogues.tome_card(c, db)])
		var starters := starting_items(db.cards, id)
		if c.has("starting_deck"):
			errors.append_array(validate_starting_deck(schema, db, c))
		elif not bool(c["use_base_deck"]) and starters.is_empty():
			errors.append("角色 %s 没有初始牌组，请编辑初始牌组或勾选自制卡牌的开局注入。" % id)
		if not bool(c["include_base_cards"]):
			var reward_count := 0
			for card in db.cards:
				if String(card.get("pool", "")) == String(c["card_pool"]) and String(card.get("rarity", "")) in ["Common", "Uncommon", "Rare"]:
					reward_count += 1
			if reward_count == 0:
				errors.append("角色 %s 的独立卡池没有可奖励的普通/罕见/稀有卡牌，请添加奖励卡牌。" % id)
			elif reward_count < 3:
				warnings.append("角色 %s 的奖励卡少于三张，请补充各稀有度卡牌后再进行完整跑局。" % id)
	return {"errors": errors, "warnings": warnings}


static func starting_items(items: Array, id: String) -> Array:
	return items.filter(func(item):
		var deck: Dictionary = item.get("deck", {})
		return bool(deck.get("enabled", false)) and String(deck.get("character", "")) == id)


static func emit(c0: Dictionary, db: CFDesignDb, schema: CFSchema = null) -> String:
	var c := normalized(c0)
	var template := String(c["template"])
	var independent := bool(c["independent"])
	var potion_pool := code_name(String(c["id"])) + "PotionPool" if independent else template + "PotionPool"
	var lines: Array = ["using System.Collections.Generic;", "using System.Linq;", "using Godot;",
		"using MegaCrit.Sts2.Core.Animation;", "using MegaCrit.Sts2.Core.Bindings.MegaSpine;",
		"using MegaCrit.Sts2.Core.Entities.Characters;", "using MegaCrit.Sts2.Core.Models;",
		"using MegaCrit.Sts2.Core.Models.Characters;", "using MegaCrit.Sts2.Core.Models.PotionPools;",
		"using MegaCrit.Sts2.Core.Nodes.Combat;", "using STS2RitsuLib.Scaffolding.Godot;",
		"using STS2RitsuLib.Scaffolding.Visuals.StateMachine;",
		"using STS2RitsuLib.Scaffolding.Characters;", "using %s.Models.CardPools;" % db.mod_id,
		"using %s.Models.RelicPools;" % db.mod_id, "", "namespace %s.Models.Characters;" % db.mod_id, "",
		"public sealed class %s : ModCharacterTemplate<%s, %s, %s>" % [code_name(String(c["id"])), c["card_pool"], c["relic_pool"], "global::%s.Models.PotionPools.%s" % [db.mod_id, potion_pool] if independent else potion_pool], "{"]
	if not independent:
		lines.append("\tprivate static CharacterModel Template => ModelDb.Character<%s>();" % template)
	lines.append_array([
		"\tpublic override bool RequiresEpochAndTimeline => false;",
		"\tpublic override string%s PlaceholderCharacterId => %s;" % ["?" if independent else "", "null" if independent else JSON.stringify(template.to_lower())],
		"\tpublic override CharacterGender Gender => %s;" % ("CharacterGender.Neutral" if independent else "Template.Gender"),
		"\tpublic override Color NameColor => %s;" % ('new Color("75CFC5")' if independent else "Template.NameColor"),
		"\tpublic override int StartingHp => %d;" % int(c["starting_hp"]),
		"\tpublic override int StartingGold => %d;" % int(c["starting_gold"]),
		"\tpublic override int MaxEnergy => %d;" % int(c["max_energy"]),
		"\tpublic override int BaseOrbSlotCount => 0;",
		"\tpublic override bool ShouldAlwaysShowStarCounter => false;",
		"\tpublic override Color EnergyLabelOutlineColor => new Color(\"183C40\");",
		"\tpublic override Color MapDrawingColor => new Color(\"2A8279\");",
		"\tpublic override List<string> GetArchitectAttackVfx() => new() { \"vfx/vfx_attack_blunt\" };", ""])
	if c["visuals"]["mode"] == "template":
		lines.append("\tpublic override float AttackAnimDelay => Template.AttackAnimDelay;")
		lines.append("\tpublic override float CastAnimDelay => Template.CastAnimDelay;")
	lines.append_array(CFCharacterVisuals.emit(c, db.mod_id))
	for relic in [false, true]:
		var model := "Relic" if relic else "Card"
		var suffix := "Relics" if relic else "Deck"
		var use_base := bool(c["use_base_relics" if relic else "use_base_deck"])
		var sources := starting_items(db.relics if relic else db.cards, String(c["id"]))
		lines.append("\tprotected override IEnumerable<%sModel> LocalStarting%s" % [model, suffix])
		lines.append("\t{")
		lines.append("\t\tget")
		lines.append("\t\t{")
		if not relic and c.has("starting_deck"):
			for row in c["starting_deck"]:
				var ns := db.mod_id
				if row["source"] == "game":
					ns = "MegaCrit.Sts2.Core.Models.Cards"
					if schema != null:
						for card in schema.existing_cards:
							if card["class_name"] == row["id"]:
								ns = card["namespace"]
				lines.append("\t\t\tfor (int i = 0; i < %d; i++) yield return ModelDb.Card<global::%s.%s>();" % [int(row["copies"]), ns, row["id"]])
			use_base = false
			sources = []
		if use_base:
			lines.append("\t\t\tforeach (var item in Template.Starting%s) yield return item;" % suffix)
		for item in sources:
			var copies := 1 if relic else maxi(1, int(item.get("deck", {}).get("copies", 1)))
			lines.append("\t\t\tfor (int i = 0; i < %d; i++) yield return ModelDb.%s<global::%s.%s>();" % [copies, model, db.mod_id, item["id"]])
		lines.append("\t\t\tyield break;")
		lines.append("\t\t}")
		lines.append("\t}")
	lines.append("}")
	return "\n".join(lines) + "\n"


static func add_localization(tables: Dictionary, db: CFDesignDb, schema: CFSchema) -> void:
	for locale in CFSchema.LOCALES:
		if not tables.has(locale):
			tables[locale] = {}
		var chars: Dictionary = tables[locale].get("characters", {})
		for original in db.custom_characters:
			var c := normalized(original)
			var entry := entry(db.mod_id, String(c["id"]))
			# Copy incidental dialogue/pronoun strings as well, so vanilla UI/events
			# can request the new ID without missing localization keys.
			var base_text: Variant = JSON.parse_string(CFPaths.read_text(schema.source_root.path_join("localization/%s/characters.json" % locale)))
			if base_text is Dictionary and not c["independent"]:
				var prefix := CFIds.slugify(String(c["template"])) + "."
				for key in base_text:
					if String(key).begins_with(prefix):
						chars[entry + "." + String(key).trim_prefix(prefix)] = base_text[key]
			if c["independent"]:
				var chinese: bool = locale in ["zhs", "zht"]
				for key in ["pronounObject", "pronounSubject"]:
					chars[entry + "." + key] = "其" if chinese else ("them" if key == "pronounObject" else "they")
				chars[entry + ".possessiveAdjective"] = "其" if chinese else "their"
				chars[entry + ".pronounPossessive"] = "其" if chinese else "theirs"
				chars[entry + ".eventDeathPrevention"] = "旅途仍将继续。" if chinese else "The journey continues."
				chars[entry + ".unlockText"] = "已解锁。" if chinese else "Unlocked."
			var title := String(c["name"] if locale in ["zhs", "zht"] else c["name_eng"])
			chars[entry + ".title"] = title
			chars[entry + ".titleObject"] = title
			chars[entry + ".description"] = c["description"] if locale in ["zhs", "zht"] else c["description_eng"]
			chars[entry + ".cardsModifierTitle"] = title + ("卡牌" if locale in ["zhs", "zht"] else " Cards")
			chars[entry + ".cardsModifierDescription"] = title + ("的卡牌会出现在奖励和商店中。" if locale in ["zhs", "zht"] else " cards appear in rewards and shops.")
		if not chars.is_empty():
			tables[locale]["characters"] = chars


static func reference_error(root: String, target: String) -> String:
	if not target in ["0.107.1", "0.109.0", "0.110.0", "0.111.0"]:
		return "当前 RitsuLib 接入尚未验证游戏 API 版本 %s。" % target
	for rel in ["RitsuLib.References.props", "compat/%s/STS2-RitsuLib.dll" % target,
		"compat/%s/STS2-RitsuLib.Runtime.dll" % target, "shared/STS2-RitsuLib.Shared.dll",
		"shared/STS2-RitsuLib.Ui.dll", "shared/STS2-RitsuLib.Settings.dll"]:
		if not FileAccess.file_exists(root.path_join(rel)):
			return "缺少 RitsuLib 依赖：%s。请在设置中指定完整 RitsuLib 文件夹。" % root.path_join(rel)
	var manifest: Variant = JSON.parse_string(CFPaths.read_text(root.path_join("mod_manifest.json")))
	if not manifest is Dictionary or String(manifest.get("version", "")) != RITSU_VERSION:
		return "当前角色导出已对接 RitsuLib %s，请选择该版本的完整文件夹。" % RITSU_VERSION
	return ""


static func initial_deck(schema: CFSchema, db: CFDesignDb, character: Dictionary) -> Array:
	character = normalized(character)
	if character.has("starting_deck"):
		return character["starting_deck"].duplicate(true)
	var result: Array = []
	if bool(character.get("use_base_deck", true)):
		for template in schema.characters:
			if template["class_name"] == character.get("template", "Ironclad"):
				result = template.get("starting_deck", []).duplicate(true)
	for item in starting_items(db.cards, String(character["id"])):
		result.append({"source": "mod", "id": item["id"], "copies": item["deck"].get("copies", 1)})
	# Consolidate duplicates so authors can edit the number of copies directly.
	var merged: Array = []
	for row in result:
		var existing := -1
		for i in merged.size():
			if merged[i]["source"] == row["source"] and merged[i]["id"] == row["id"]:
				existing = i
		if existing < 0:
			merged.append(row.duplicate(true))
		else:
			merged[existing]["copies"] += int(row["copies"])
	return merged


static func validate_starting_deck(schema: CFSchema, db: CFDesignDb, character: Dictionary) -> Array:
	var errors: Array = []
	var deck: Variant = character.get("starting_deck", [])
	if not deck is Array or deck.is_empty():
		return ["角色 %s 的自定义初始牌组不能为空。" % character["id"]]
	for row in deck:
		if not row is Dictionary:
			errors.append("初始牌组条目格式错误。")
			continue
		var source := String(row.get("source", ""))
		var id := String(row.get("id", ""))
		var copies: Variant = row.get("copies", 0)
		if not (copies is int or copies is float) or float(copies) != floor(float(copies)) or float(copies) < 1 or float(copies) > 99:
			errors.append("初始牌组 %s 的张数必须是 1～99 的整数。" % id)
		var found := false
		if source == "mod":
			found = db.cards.any(func(card): return String(card.get("id", "")) == id)
		elif source == "game":
			found = schema.existing_cards.any(func(card): return String(card.get("class_name", "")) == id)
		if not found:
			errors.append("角色 %s 的初始牌组找不到 %s 卡牌 %s，请重新选择。" % [character["id"], source, id])
	return errors
