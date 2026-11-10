@tool
class_name CFAncientDialogues
extends RefCounted

## Playable Ancient encounters in the bundled 0.107.1 source, plus the final
## Architect event (which inherits EventModel, not AncientEventModel).
const CATALOG := {
	"NEOW": "涅奥", "DARV": "达弗", "PAEL": "佩尔", "OROBAS": "欧洛巴斯",
	"NONUPEIPE": "诺奴佩普", "TEZCATARA": "特兹卡塔拉", "TANX": "坦克斯",
	"VAKUU": "瓦库", "THE_ARCHITECT": "建筑师",
}
const PHASES := ["first", "repeat"]
const GREETINGS := {
	"NEOW": ["新的旅人，你准备好踏上这段旅途了吗？", "New traveler, are you ready for the journey?"],
	"DARV": ["旅人，看看这里有没有你需要的东西。", "Traveler, see if there is something here you need."],
	"PAEL": ["你来到这里，是为了寻找什么？", "What have you come here to find?"],
	"OROBAS": ["旅人，你愿意如何改变自己的命运？", "Traveler, how would you change your fate?"],
	"NONUPEIPE": ["一路走来，你一定经历了不少事情。", "You must have seen much on your way here."],
	"TEZCATARA": ["走近些，让我看看这位新的挑战者。", "Come closer. Let me see this new challenger."],
	"TANX": ["旅人，前方还有考验在等待着你。", "Traveler, more trials await you ahead."],
	"VAKUU": ["你已经走了很远。你还会继续吗？", "You have come far. Will you continue?"],
	"THE_ARCHITECT": ["你终于抵达了这里。", "At last, you have arrived."],
}

static func new_line(speaker: String = "ancient", zh: String = "", en: String = "") -> Dictionary:
	return {"speaker": speaker, "text": zh, "text_eng": en, "next": "", "next_eng": ""}


static func defaults(ancient: String) -> Dictionary:
	var greeting: Array = GREETINGS[ancient]
	return {
		"first": [new_line("ancient", greeting[0], greeting[1]), new_line("char", "我已准备好。", "I am ready.")],
		"repeat": [new_line("ancient", "我们又见面了，旅人。", "We meet again, traveler."), new_line("char", "我的旅途还在继续。", "My journey continues.")],
	}


## Fill missing records only. Empty authored sequences remain errors, so an
## accidental deletion cannot silently replace the author's work.
static func normalized(value: Variant) -> Dictionary:
	var result: Dictionary = value.duplicate(true) if value is Dictionary else {}
	for ancient in CATALOG:
		if not result.has(ancient):
			result[ancient] = defaults(ancient)
		elif result[ancient] is Dictionary:
			for phase in PHASES:
				if not result[ancient].has(phase):
					result[ancient][phase] = defaults(ancient)[phase]
	return result


static func validate(value: Variant) -> Array:
	var errors: Array = []
	if not value is Dictionary:
		return ["先古之民对话数据必须是对象。"]
	var data := normalized(value)
	for ancient in CATALOG:
		var record: Variant = data[ancient]
		for phase in PHASES:
			var label := "%s · %s" % [CATALOG[ancient], "首次来访" if phase == "first" else "重复来访"]
			if not record is Dictionary or not record.get(phase) is Array or record[phase].is_empty():
				errors.append(label + "至少需要一句台词。")
				continue
			for i in record[phase].size():
				var line: Variant = record[phase][i]
				if not line is Dictionary or not line.get("speaker", "") in ["ancient", "char"]:
					errors.append("%s第 %d 句的说话者无效。" % [label, i + 1])
					continue
				if not line.get("text", "") is String or not line.get("text_eng", "") is String:
					errors.append("%s第 %d 句台词必须是文本。" % [label, i + 1])
				elif String(line.get("text", "")).strip_edges().is_empty() and String(line.get("text_eng", "")).strip_edges().is_empty():
					errors.append("%s第 %d 句至少填写一种语言。" % [label, i + 1])
	return errors


static func translated(line: Dictionary, key: String, chinese: bool, fallback: String = "") -> String:
	var text := String(line.get(key if chinese else key + "_eng", ""))
	if text.strip_edges().is_empty():
		text = String(line.get(key + "_eng" if chinese else key, ""))
	return fallback if text.strip_edges().is_empty() else text


static func add_localization(tables: Dictionary, db: CFDesignDb) -> void:
	if db.custom_characters.is_empty():
		return
	# Explicit fallback tables keep dialogue structures identical in every game
	# language. RitsuLib 0.6.7 registers these via PopulateLocKeys automatically.
	for locale in CFSchema.ALL_LOCALES:
		if not tables.has(locale):
			tables[locale] = {}
		var table: Dictionary = tables[locale].get("ancients", {})
		for character in db.custom_characters:
			var data := normalized(character.get("ancient_dialogues", {}))
			var entry := CFCharacters.entry(db.mod_id, String(character["id"]))
			for ancient in CATALOG:
				for index in PHASES.size():
					var base := "%s.talk.%s.%d" % [ancient, entry, index]
					var lines: Array = data[ancient][PHASES[index]]
					table[base + "-visit"] = str(index)
					if ancient == "THE_ARCHITECT":
						table[base + "-startattack"] = "None"
						table[base + "-endattack"] = "Both"
					for i in lines.size():
						var key := "%s-%d%s" % [base, i, "r" if index == 1 else ""]
						table[key + "." + lines[i]["speaker"]] = translated(lines[i], "text", locale == "zhs")
						if i < lines.size() - 1:
							table[key + ".next"] = translated(lines[i], "next", locale == "zhs", "继续" if locale == "zhs" else "Continue")
			tables[locale]["ancients"] = table


static func tome_candidates(character: Dictionary, db: CFDesignDb) -> Array:
	return db.cards.filter(func(card): return card.get("pool", "") == character.get("card_pool", "") and card.get("type", "") in ["Attack", "Skill", "Power"])


static func tome_card(character: Dictionary, db: CFDesignDb) -> String:
	var selected := String(character.get("ancient_tome_card", ""))
	var candidates := tome_candidates(character, db)
	if not selected.is_empty():
		return selected if candidates.any(func(card): return card["id"] == selected) else ""
	for rarity in ["Ancient", "Rare", "Uncommon", "Common", "Basic"]:
		for card in candidates:
			if card.get("rarity", "") == rarity:
				return String(card["id"])
	return String(candidates[0]["id"]) if not candidates.is_empty() else ""


static func tome_copy_id(character: Dictionary) -> String:
	return CFCharacters.code_name(String(character["id"])) + "ForgeAncientTome"


## RitsuLib ignores non-Ancient registry candidates. If an author picks a
## normal card, export an Ancient edition without changing the original card
## or the saved design. Only the owned pool and Dusty Tome receive this copy.
static func prepare_export(db: CFDesignDb, schema: CFSchema) -> CFDesignDb:
	var result := CFDesignDb.new()
	result.load_from_json(db.to_json())
	for character in result.custom_characters:
		if not CFCharacters.is_independent(character) and String(character.get("ancient_tome_card", "")).is_empty():
			continue
		var selected := tome_card(character, result)
		if selected.is_empty():
			continue
		for card in result.cards.duplicate():
			if card["id"] != selected:
				continue
			if card["rarity"] == "Ancient":
				character["ancient_tome_card"] = selected
				break
			var copy: Dictionary = card.duplicate(true)
			copy["id"] = tome_copy_id(character)
			copy["rarity"] = "Ancient"
			copy["deck"] = {"enabled": false, "character": "", "copies": 1}
			for locale in copy["text"]:
				copy["text"][locale]["title"] = String(copy["text"][locale].get("title", selected)) + ("（先古）" if locale == "zhs" else " (Ancient)")
			CFDesign.normalize(schema, copy)
			result.cards.append(copy)
			character["ancient_tome_card"] = copy["id"]
			break
	return result
