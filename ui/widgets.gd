@tool
class_name CFWidgets
extends RefCounted

## Small helpers so the UI code stays about layout, not about DCC plumbing.
## Every card/pill is built from a StyleBox created here, because the tool runs
## standalone (no editor theme to inherit).

const BG := Color("#161a23")
const PANEL := Color("#1e2430")
const PANEL_2 := Color("#252c3a")
const BORDER := Color("#39435a")
const TEXT := Color("#e6e9f0")
const TEXT_DIM := Color("#98a2b8")
const ACCENT := Color("#e0b64a")
const ACCENT_DIM := Color("#6d5a22")
const OK := Color("#5fbf7f")
const WARN := Color("#e0b64a")
const ERR := Color("#e0605f")
const INFO := Color("#6aa9e0")

## Global font scale. Every font size in the UI goes through `fs()`, so bumping
## this one number enlarges the whole tool consistently. The base sizes below
## were designed for a 1600px-wide window; at 1280 they read small, hence 1.25.
const FONT_SCALE := 1.25


## Scale a design font size by `FONT_SCALE`.
##
## Every `add_theme_font_size_override("font_size", …)` must go through this —
## a raw literal would stay small while the rest of the UI grows, which is how
## you end up with one cramped label among otherwise comfortable text.
static func fs(base: int) -> int:
	return int(round(float(base) * FONT_SCALE))


static func sb(color: Color, radius: int = 6, width: int = 1) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = color
	b.set_corner_radius_all(radius)
	if width > 0:
		b.set_border_width_all(width)
		b.border_color = BORDER
	b.content_margin_left = 8
	b.content_margin_right = 8
	b.content_margin_top = 5
	b.content_margin_bottom = 5
	return b


static func flat(color: Color, radius: int = 6) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = color
	b.set_corner_radius_all(radius)
	b.content_margin_left = 8
	b.content_margin_right = 8
	b.content_margin_top = 5
	b.content_margin_bottom = 5
	return b


static func label(text: String, color: Color = TEXT, size: int = 14) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", fs(size))
	return l


static func dim(text: String, size: int = 12) -> Label:
	var l := label(text, TEXT_DIM, size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# A wrapping label with no width floor collapses to 1px wide and then
	# reports an absurd minimum *height*. Capping the height keeps a wrapping
	# label from ever dictating a row's height; it just crops instead.
	l.clip_text = true
	l.custom_minimum_size.x = 1
	l.max_lines_visible = 3
	return l


## A wrapping label for use inside a **fixed-width** column (the rail, a list row).
##
## Why this exists separately from `wrapped()` and `dim()`
## -----------------------------------------------------
## The columns have horizontal scrolling DISABLED, and with h-scroll off a
## `ScrollContainer` propagates its content's minimum width straight up the tree.
## A plain `label()` therefore cannot wrap (no `autowrap_mode`) and instead
## contributes its *full single-line width* as a hard minimum — so one long
## validation message widened the rail, then the split, then the whole window,
## pushing the UI off-screen.
##
## `dim()` cannot be used either: it pins `custom_minimum_size.x = 1`, which is
## right for a label negotiating space inside a *row*, but in a column it lets
## `AUTOWRAP_WORD_SMART` collapse to 1px and then report a nonsense minimum
## height (the 851px failure).
##
## This variant claims a real width floor (`min_w`) AND caps the height, so the
## text wraps at the column width, long messages stay readable, and the label can
## never dictate the layout's width or height.
##
## `min_w` also acts as the "wrap at this many pixels" hint: set it to the
## column's minimum width so the first line breaks where the column visually
## ends rather than at whatever width the splitter happens to give.
static func wrap_label(text: String, color: Color = TEXT, size: int = 12,
		min_w: int = 300, max_lines: int = 4) -> Label:
	var l := label(text, color, size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# A real floor (not 1px) so word-wrap has a width to wrap *within*.
	l.custom_minimum_size.x = min_w
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Cap visible lines: without this a pathological message would set an
	# enormous minimum height and stretch the row it sits in.
	l.max_lines_visible = max_lines
	return l


## A wrapping label that is safe inside horizontal rows: it claims a sensible
## minimum width so `AUTOWRAP_WORD_SMART` cannot collapse it to 1px and blow
## its height up to the whole column.
static func wrapped(text: String, color: Color = TEXT, size: int = 13, min_w: int = 160) -> Label:
	var l := label(text, color, size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = min_w
	return l


static func heading(text: String, size: int = 16) -> Label:
	var l := label(text, ACCENT, size)
	return l


static func button(text: String, primary: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", fs(13))
	if primary:
		b.add_theme_stylebox_override("normal", sb(ACCENT_DIM, 6, 1))
		b.add_theme_stylebox_override("hover", sb(ACCENT, 6, 1))
		b.add_theme_color_override("font_color", Color("#1b1f2a"))
		b.add_theme_color_override("font_hover_color", Color("#1b1f2a"))
	else:
		b.add_theme_stylebox_override("normal", sb(PANEL_2, 6, 1))
		b.add_theme_stylebox_override("hover", sb(BORDER, 6, 1))
		b.add_theme_color_override("font_color", TEXT)
	return b


static func field(value: String = "") -> LineEdit:
	var e := LineEdit.new()
	e.text = value
	e.add_theme_stylebox_override("normal", sb(BG, 5, 1))
	e.add_theme_stylebox_override("focus", sb(BG, 5, 1))
	e.add_theme_color_override("font_color", TEXT)
	e.add_theme_color_override("caret_color", ACCENT)
	e.add_theme_font_size_override("font_size", fs(13))
	return e


static func spin(value: float, min_v: float, max_v: float, step: float = 1.0) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.custom_arrow_step = step
	s.add_theme_stylebox_override("normal", sb(BG, 5, 1))
	s.add_theme_color_override("font_color", TEXT)
	s.add_theme_font_size_override("font_size", fs(13))
	return s


static func option(items: Array, selected: String = "") -> OptionButton:
	var o := OptionButton.new()
	for i in items.size():
		var item: Dictionary = items[i] if items[i] is Dictionary else {"value": items[i], "label": str(items[i])}
		o.add_item(String(item.get("label", item.get("value", ""))), i)
		o.set_item_metadata(i, item)
	o.add_theme_stylebox_override("normal", sb(BG, 5, 1))
	o.add_theme_stylebox_override("hover", sb(PANEL_2, 5, 1))
	o.add_theme_stylebox_override("pressed", sb(PANEL_2, 5, 1))
	o.add_theme_stylebox_override("focus", sb(BG, 5, 1))
	o.add_theme_color_override("font_color", TEXT)
	o.add_theme_font_size_override("font_size", fs(13))
	# **Cap the width a long item label can demand.**
	# An OptionButton sizes itself to its *longest* item, and one of ours is
	# `PowerVar<VulnerablePower>（易伤）`. Un-capped that single dropdown reported
	# a 677 px minimum, which propagated up (row → editor column → split) and
	# blew the split's minimum from 1196 to 1648 px. The split then could not fit
	# a 1280 px window, so the list column was laid out at x = -184 and its
	# content fell off the left edge of the screen. Capping + clipping keeps the
	# full text in the popup while the closed control stays a sane width.
	o.custom_minimum_size.x = 0
	o.clip_text = true
	o.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Select the requested value when present.
	for i in o.item_count:
		if String((o.get_item_metadata(i) as Dictionary).get("value", "")) == selected:
			o.select(i)
			break
	return o


## A drop-in replacement for `option()` that adds a search box.
##
## With 256 powers a plain `OptionButton` is unusable, so this widget pairs a
## LineEdit with a filtered result list. Everything it does is *internal*: typing
## only rebuilds its own result rows, never the surrounding editor. That matters
## because the editor frees and recreates its controls on every rebuild, which
## would steal focus from the box the user is typing in.
##
## Two ways to find an entry, both always available
## ------------------------------------------------
##   * **Type** to filter. Matching is a case-insensitive `contains` over the
##     `haystack` key (pre-lowercased) when present, else the label — so both
##     `易伤` and `vulnerable` find `VulnerablePower`.
##   * **Browse** with the mouse wheel. The list lives in a fixed-height
##     `ScrollContainer`, so an empty query scrolls through *every* item one at a
##     time — the old dropdown's wheel behaviour, which some entries are simply
##     easier to find by eye than by name.
##
## `rows_collapsed` / `rows_expanded` set the visible-height band; the ⇕ toggle
## flips between them so the picker can stay compact in a dense editor.
##
## Returns a `VBoxContainer`. Callers wire the result via
## `on_search_option_picked(ctrl, callback)`; the widget also exposes
## `search_option_value(ctrl)` to read the current selection back.
##
## A plain callback (rather than a signal) is deliberate: `RefCounted` cannot
## declare signals, and Godot's signal dispatch silently drops handlers whose
## arity does not match — an easy way to make a picker look dead.
static func search_option(items: Array, selected: String = "",
		rows_collapsed: int = 6, rows_expanded: int = 16) -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)

	root.set_meta("cf_items", items)
	root.set_meta("cf_selected", selected)
	root.set_meta("cf_picked", Callable())
	root.set_meta("cf_rows_collapsed", rows_collapsed)
	root.set_meta("cf_rows_expanded", rows_expanded)
	root.set_meta("cf_expanded", false)

	var box := LineEdit.new()
	box.placeholder_text = "搜索：中文名 / 英文名 / 类名（留空可滚轮浏览）"
	box.add_theme_stylebox_override("normal", sb(BG, 5, 1))
	box.add_theme_stylebox_override("focus", sb(PANEL_2, 5, 1))
	box.add_theme_color_override("font_color", TEXT)
	box.add_theme_color_override("font_placeholder_color", TEXT_DIM)
	box.add_theme_font_size_override("font_size", fs(13))
	root.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var current := Label.new()
	current.add_theme_color_override("font_color", ACCENT)
	current.add_theme_font_size_override("font_size", fs(12))
	current.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	current.clip_text = true
	current.max_lines_visible = 2
	current.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(current)
	var expand := Button.new()
	expand.text = "⇕ 展开"
	expand.tooltip_text = "展开/收起候选列表高度"
	expand.focus_mode = Control.FOCUS_NONE
	expand.add_theme_stylebox_override("normal", flat(PANEL, 5))
	expand.add_theme_stylebox_override("hover", flat(PANEL_2, 5))
	expand.add_theme_stylebox_override("pressed", flat(PANEL_2, 5))
	expand.add_theme_color_override("font_color", TEXT_DIM)
	expand.add_theme_font_size_override("font_size", fs(11))
	head.add_child(expand)
	root.add_child(head)

	# A fixed-height scroll viewport over the (possibly very long) result list.
	# Without the explicit height the ScrollContainer would ask for its content's
	# full height and the picker would grow to 256 rows tall.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	root.set_meta("cf_scroll", scroll)
	root.set_meta("cf_list", list)
	root.set_meta("cf_query", box)
	root.set_meta("cf_current", current)
	root.set_meta("cf_expand", expand)

	# Only *after* `cf_scroll` is published — the height helper reads it, and a
	# stray `get_meta` on a key that is not there yet logs an ERROR (it does not
	# abort, but it buries real errors in the log).
	_apply_search_option_height(root)

	# `.connect()` after `add_child()`: a control can re-emit on entering the tree.
	box.text_changed.connect(func(t: String) -> void:
		_filter_search_option(root, t))
	expand.pressed.connect(func() -> void:
		root.set_meta("cf_expanded", not bool(root.get_meta("cf_expanded", false)))
		_apply_search_option_height(root)
		_refresh_search_option_labels(root))

	_refresh_search_option(root)
	_filter_search_option(root, "")

	return root


## Row height used for the scroll viewport maths (button height + separation).
const SEARCH_ROW_H := 24


## Size the scroll viewport to the collapsed/expanded row band.
##
## `has_meta` guard rather than a bare `get_meta`: this runs during construction
## before every meta key exists, and a missing key logs an ERROR (the call does
## not abort, so it only pollutes the log — but that is exactly the kind of noise
## that buries a real failure later).
static func _apply_search_option_height(root: Node) -> void:
	if not root.has_meta("cf_scroll"):
		return
	var scroll: Node = root.get_meta("cf_scroll", null)
	if scroll == null or not (scroll is ScrollContainer):
		return
	var expanded := bool(root.get_meta("cf_expanded", false))
	var rows := int(root.get_meta(
			"cf_rows_expanded" if expanded else "cf_rows_collapsed", 6))
	(scroll as ScrollContainer).custom_minimum_size.y = maxi(1, rows) * SEARCH_ROW_H


## Refresh the "current" line, the row-band height and the ⇕ button caption.
static func _refresh_search_option_labels(root: Node) -> void:
	var expanded := bool(root.get_meta("cf_expanded", false))
	var btn: Variant = root.get_meta("cf_expand", null)
	if btn is Button:
		(btn as Button).text = "⇕ 收起" if expanded else "⇕ 展开"
	_apply_search_option_height(root)


## Lowercased match key for one option.
static func _search_key(item: Dictionary) -> String:
	if item.has("haystack"):
		return String(item["haystack"])
	return String(item.get("label", item.get("value", ""))).to_lower()


## Rebuild the result rows for `query`.
##
## **All** matches are added, not just the first screenful — the enclosing
## `ScrollContainer` is what bounds the visible area, so the wheel can browse the
## rest. (An earlier version capped the rows and showed a "还有 N 项" hint, which
## made wheel-browsing impossible past the cap: it looks like the list ends.)
static func _filter_search_option(root: Node, query: String) -> void:
	var list: Node = root.get_meta("cf_list")
	for c in list.get_children():
		c.queue_free()
	var q := query.strip_edges().to_lower()
	var all: Array = root.get_meta("cf_items", [])
	var total := 0
	for it in all:
		var d: Dictionary = it
		if not q.is_empty() and not _search_key(d).contains(q):
			continue
		total += 1
		var btn := Button.new()
		btn.text = String(d.get("label", d.get("value", "")))
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.clip_text = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size.y = SEARCH_ROW_H - 2
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_stylebox_override("normal", flat(PANEL, 5))
		btn.add_theme_stylebox_override("hover", flat(PANEL_2, 5))
		btn.add_theme_stylebox_override("pressed", flat(PANEL_2, 5))
		btn.add_theme_color_override("font_color", TEXT)
		btn.add_theme_font_size_override("font_size", fs(12))
		btn.pressed.connect(func() -> void:
			_pick_search_option(root, d))
		list.add_child(btn)
	if total == 0:
		var none := Label.new()
		none.text = "没有匹配的条目"
		none.add_theme_color_override("font_color", TEXT_DIM)
		none.add_theme_font_size_override("font_size", fs(11))
		list.add_child(none)
	# Reset the wheel to the top whenever the query changes, otherwise the
	# viewport keeps a stale scroll offset that can look empty.
	var scroll: Node = root.get_meta("cf_scroll", null)
	if scroll is ScrollContainer:
		(scroll as ScrollContainer).scroll_vertical = 0


## Record a pick, refresh the "current" line, then notify the caller's callback.
static func _pick_search_option(root: Node, item: Dictionary) -> void:
	root.set_meta("cf_selected", String(item.get("value", "")))
	_refresh_search_option(root)
	var cb: Callable = root.get_meta("cf_picked", Callable())
	if cb.is_valid():
		cb.call(item)


## Paint the `当前：…` line from whatever value is currently stored.
static func _refresh_search_option(root: Node) -> void:
	var sel := String(root.get_meta("cf_selected", ""))
	var all: Array = root.get_meta("cf_items", [])
	var shown := "（未选择）"
	if not sel.is_empty():
		# GDScript has no `for … else:` (Python's construct) — use an explicit
		# found flag, otherwise the `else` is a parse error.
		var found := false
		for it in all:
			if String((it as Dictionary).get("value", "")) == sel:
				shown = String((it as Dictionary).get("label", sel))
				found = true
				break
		if not found:
			# The stored value is not in the scanned list (e.g. the schema was
			# rescanned and a power disappeared). Show it raw rather than lying
			# with "（未选择）", so the user can see something is off.
			shown = sel
	var cur: Variant = root.get_meta("cf_current", null)
	if cur is Label:
		(cur as Label).text = "当前：" + shown
	_refresh_search_option_labels(root)


## Repaint the result rows for the currently stored selection, without changing
## the query. Used by tests and by callers that set the value externally.
static func refresh_search_option(ctrl: Node) -> void:
	_refresh_search_option(ctrl)


## Register the callback fired when the user picks a result.
static func on_search_option_picked(ctrl: Node, cb: Callable) -> void:
	ctrl.set_meta("cf_picked", cb)


## The currently stored value (empty string when nothing is chosen).
static func search_option_value(ctrl: Node) -> String:
	return String(ctrl.get_meta("cf_selected", ""))


static func check(text: String, pressed: bool = false) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = pressed
	c.add_theme_font_size_override("font_size", fs(12))
	c.add_theme_color_override("font_color", TEXT)
	return c


## Apply a configuration lambda to a freshly built control and return it.
## Used to keep construction chains readable: `W.tap(W.spin(...), func(s): ...)`.
static func tap(control: Control, config: Callable) -> Control:
	if config.is_valid():
		config.call(control)
	return control


## A row of `label: control`, right-aligned value column.
static func row(layout: Control, title: String, control: Control, hint: String = "") -> void:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(label(title, TEXT, 13))
	box.add_child(control)
	if not hint.is_empty():
		box.add_child(dim(hint, 11))
	layout.add_child(box)


static func panel(title: String = "") -> VBoxContainer:
	var outer := PanelContainer.new()
	outer.add_theme_stylebox_override("panel", sb(PANEL, 8, 1))
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	outer.add_child(box)
	if not title.is_empty():
		var h := heading(title)
		box.add_child(h)
		var sep := HSeparator.new()
		box.add_child(sep)
	# Caller adds children to the returned VBox; the panel is its parent.
	box.set_meta("panel", outer)
	return box


## Wrap a VBox in its styled PanelContainer.
static func wrap(box: VBoxContainer) -> PanelContainer:
	var p: PanelContainer = box.get_meta("panel")
	return p


static func scroll(child: Control) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(child)
	return s


static func severvity_color(sev: String) -> Color:
	match sev:
		"error": return ERR
		"warning": return WARN
		_: return INFO


static func tag(text: String, color: Color) -> Label:
	var l := label(text, color, 11)
	l.add_theme_stylebox_override("normal", flat(Color(color.r, color.g, color.b, 0.14), 4))
	return l


## A centred placeholder used when nothing is selected in the editor column.
static func panel_tip(text: String) -> PanelContainer:
	var outer := PanelContainer.new()
	var b := StyleBoxFlat.new()
	b.bg_color = PANEL
	b.set_corner_radius_all(8)
	b.set_border_width_all(1)
	b.border_color = BORDER
	b.content_margin_left = 18
	b.content_margin_right = 18
	b.content_margin_top = 40
	b.content_margin_bottom = 40
	outer.add_theme_stylebox_override("panel", b)
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	outer.add_child(box)
	var l := label(text, TEXT_DIM, 14)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(l)
	return outer


## A horizontal separator with a small caption, used to split editor sections.
static func section_sep(title: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.add_child(label(title, ACCENT, 13))
	var line := HSeparator.new()
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(line)
	return h
