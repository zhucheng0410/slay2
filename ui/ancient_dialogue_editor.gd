class_name CFAncientDialogueEditor
extends RefCounted

## A detached draft: switching encounters retains edits; Cancel never changes
## the library. Only Save performs one undoable database mutation.
static func open(app: Node, character_id: String, owner_window: Window = null) -> void:
	var original: Dictionary = {}
	for character in app.db.custom_characters:
		if character["id"] == character_id:
			original = character
	if original.is_empty():
		return
	var draft := CFCharacters.normalized(original)
	var win := AcceptDialog.new()
	win.name = "AncientDialogueEditor"
	win.title = "先古之民对话 · " + String(draft["name"])
	win.size = Vector2i(820, 680)
	win.get_ok_button().text = "保存全部对话"
	win.dialog_hide_on_ok = false
	var root := VBoxContainer.new()
	root.custom_minimum_size.x = 760
	root.add_theme_constant_override("separation", 8)
	win.add_child(root)
	var help := Label.new()
	help.custom_minimum_size.x = 740
	help.text = "已为全部 9 位准备可编辑的原创示例台词。每位都有首次来访与重复来访两组。\n首次指该角色首次来访；游戏的全局首次相遇剧情仍优先。只填一种语言时会自动补足另一种。"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(help)
	var selectors := HBoxContainer.new()
	root.add_child(selectors)
	var ancient_select := OptionButton.new()
	ancient_select.name = "AncientSelect"
	for ancient in CFAncientDialogues.CATALOG:
		ancient_select.add_item(CFAncientDialogues.CATALOG[ancient])
	ancient_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selectors.add_child(ancient_select)
	var phase_select := OptionButton.new()
	phase_select.name = "AncientPhase"
	phase_select.add_item("首次来访")
	phase_select.add_item("重复来访（此后可反复使用）")
	selectors.add_child(phase_select)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 240
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.name = "AncientLines"
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 12)
	scroll.add_child(rows)
	var rebuild := func():
		var ancient: String = CFAncientDialogues.CATALOG.keys()[ancient_select.selected]
		var phase: String = CFAncientDialogues.PHASES[phase_select.selected]
		_build_lines(rows, draft["ancient_dialogues"][ancient][phase])
	ancient_select.item_selected.connect(func(_index): rebuild.call())
	phase_select.item_selected.connect(func(_index): rebuild.call())
	var add := Button.new()
	add.name = "AncientAddLine"
	add.text = "添加一句台词"
	add.pressed.connect(func():
		var ancient: String = CFAncientDialogues.CATALOG.keys()[ancient_select.selected]
		var phase: String = CFAncientDialogues.PHASES[phase_select.selected]
		draft["ancient_dialogues"][ancient][phase].append(CFAncientDialogues.new_line())
		rebuild.call())
	root.add_child(add)
	var tome_help := Label.new()
	tome_help.custom_minimum_size.x = 740
	tome_help.text = "达弗 · 尘封魔典奖励卡：选择专属卡牌。普通卡会导出为独立的先古副本，保留效果与升级，原卡不变。"
	tome_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(tome_help)
	var tome := OptionButton.new()
	tome.name = "AncientTomeCard"
	var automatic := draft.duplicate(true)
	automatic.erase("ancient_tome_card")
	var resolved := CFAncientDialogues.tome_card(automatic, app.db)
	tome.add_item("自动选择专属卡牌：" + (resolved if not resolved.is_empty() else "尚无卡牌，导出前需创建"))
	tome.set_item_metadata(0, "")
	for card in CFAncientDialogues.tome_candidates(draft, app.db):
		tome.add_item(String(card["id"]))
		tome.set_item_metadata(tome.item_count - 1, card["id"])
		if card["id"] == draft.get("ancient_tome_card", ""):
			tome.select(tome.item_count - 1)
	if not String(draft.get("ancient_tome_card", "")).is_empty() and tome.selected == 0:
		tome.add_item("已失效：" + String(draft["ancient_tome_card"]))
		tome.set_item_metadata(tome.item_count - 1, draft["ancient_tome_card"])
		tome.select(tome.item_count - 1)
	tome.item_selected.connect(func(index): draft["ancient_tome_card"] = tome.get_item_metadata(index))
	root.add_child(tome)
	var error := Label.new()
	error.custom_minimum_size.x = 740
	error.name = "AncientErrors"
	error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(error)
	win.confirmed.connect(func():
		var errors := CFAncientDialogues.validate(draft["ancient_dialogues"])
		if not String(draft.get("ancient_tome_card", "")).is_empty() and CFAncientDialogues.tome_card(draft, app.db).is_empty():
			errors.append("尘封魔典卡牌已失效，请重新选择。")
		if not errors.is_empty():
			error.text = "\n".join(errors.slice(0, 4))
			return
		app.db.update_custom_character(character_id, draft)
		app.call("_persist_authoring_library")
		win.queue_free())
	win.canceled.connect(func(): win.queue_free())
	(owner_window if owner_window != null else app).add_child(win)
	rebuild.call()
	win.popup_centered()


static func _build_lines(rows: VBoxContainer, lines: Array) -> void:
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
	for i in lines.size():
		var line: Dictionary = lines[i]
		var box := VBoxContainer.new()
		box.name = "AncientLine%d" % i
		rows.add_child(box)
		var bar := HBoxContainer.new()
		box.add_child(bar)
		var label := Label.new()
		label.text = "第 %d 句" % (i + 1)
		bar.add_child(label)
		var speaker := OptionButton.new()
		speaker.name = "Speaker"
		speaker.add_item("先古之民说")
		speaker.add_item("角色说")
		speaker.select(0 if line.get("speaker", "ancient") == "ancient" else 1)
		speaker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		speaker.item_selected.connect(func(index): line["speaker"] = "ancient" if index == 0 else "char")
		bar.add_child(speaker)
		for delta in [-1, 1]:
			var move := Button.new()
			move.text = "上移" if delta == -1 else "下移"
			move.disabled = i + delta < 0 or i + delta >= lines.size()
			move.pressed.connect(func():
				var other: Variant = lines[i + delta]
				lines[i + delta] = lines[i]
				lines[i] = other
				_build_lines(rows, lines))
			bar.add_child(move)
		var remove := Button.new()
		remove.name = "Remove"
		remove.text = "删除"
		remove.disabled = lines.size() <= 1
		remove.pressed.connect(func():
			lines.remove_at(i)
			_build_lines(rows, lines))
		bar.add_child(remove)
		for pair in [["text", "中文台词"], ["text_eng", "英文台词（可留空，使用中文）"]]:
			var key: String = pair[0]
			var input := TextEdit.new()
			input.name = key
			input.custom_minimum_size.y = 70
			input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			input.placeholder_text = pair[1]
			input.text = String(line.get(key, ""))
			input.text_changed.connect(func(): line[key] = input.text)
			box.add_child(input)
		if i < lines.size() - 1:
			for pair in [["next", "继续按钮中文（留空为“继续”）"], ["next_eng", "继续按钮英文（留空自动补足）"]]:
				var key: String = pair[0]
				var input := LineEdit.new()
				input.name = key
				input.placeholder_text = pair[1]
				input.text = String(line.get(key, ""))
				input.text_changed.connect(func(value): line[key] = value)
				box.add_child(input)
