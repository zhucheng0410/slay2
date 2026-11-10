@tool
extends Control

## CardRelicForge — the application window.
##
## Three columns plus a preview/diagnostics rail:
##   1. list      — the cards and relics you authored
##   2. editor    — everything about the selected item (attributes, vars,
##                  effect chain, upgrade, starting-deck injection)
##   3. rail      — card face preview, validation, simulation and export
##
## The tool is a *runtime* Godot app, so every visual is built in code and every
## enum/value it offers comes from [CFSchema] (scanned out of the game), never
## from a hardcoded list.

const W := preload("res://ui/widgets.gd")

## Structural minimum widths of the three columns, and the design width the
## window *wants*.
##
## These are the floor the layout refuses to go below: the list must be wide
## enough to show a card name, the editor to show a two-column form, the rail to
## wrap a validation message. Their **sum** is therefore the app's real minimum
## width, and if the window opens narrower than that the split simply cannot
## shrink — the right-hand column (the rail) gets pushed off the screen edge.
##
## `viewport_width` in `project.godot` is the *design* size; a laptop with a
## smaller / scaled desktop clamps the window below it, which is exactly when
## the overflow shows up. `_apply_window_size()` reconciles the two on boot.
##
## The floors are deliberately modest: 180+380+240 = 800 plus the 32 px of
## margins/separations stays inside a 900 px desktop, so even a small laptop
## gets a window that fits rather than one hanging off the right edge.
const COL_LIST_MIN := 180
const COL_EDITOR_MIN := 380
const COL_RAIL_MIN := 240

## Separations: outer split + inner split (8 px each) plus the window margin the
## VBox root adds around the split (8 px each side).
const SPLIT_SEPARATION := 8
const ROOT_MARGIN := 8

## The size the window *prefers* when the screen is big enough. Kept in step
## with `window/size/viewport_*` in `project.godot` so the canvas and the window
## agree; `_apply_window_size()` clamps it down on smaller screens.
const DESIGN_WIDTH := 1280
const DESIGN_HEIGHT := 800
## Never shrink the window below this. Kept at/below the column floor sum so the
## window never opens narrower than its own content needs.
const WINDOW_MIN_WIDTH := 840
const WINDOW_MIN_HEIGHT := 620

## Slack left around the window so its own title bar / borders are not clipped by
## the screen edge when we open at the maximum size.
const WINDOW_EDGE_MARGIN := 24

var settings: Dictionary = {}
var schema: CFSchema = CFSchema.new()
var db: CFDesignDb = CFDesignDb.new()

## Live column widths. Start at the comfortable design values and are *shrunk*
## by `_apply_window_size()` when the screen cannot fit the full layout, so the
## app degrades (narrower columns) instead of overflowing the window edge.
var _col_list_w := 300
var _col_editor_w := 520
var _col_rail_w := 360
## The three PanelContainers, so a resize can re-apply the widths in place
## without rebuilding the whole shell.
var _col_panels: Array[PanelContainer] = []

## The two split containers (outer list|rest, inner editor|rail). Kept so
## `_reset_split_offsets()` can clear a stale divider offset after a resize —
## otherwise the first column is placed at a negative x and its content is
## pushed off the left edge of the screen.
var _outer_split: SplitContainer = null
var _right_split: SplitContainer = null

## Toolbar pieces that `_fit_toolbar_to()` may collapse on a narrow window.
var _toolbar_row: HBoxContainer = null
var _toolbar_brand: Label = null
var _toolbar_subtitle: Label = null
var _toolbar_save: Button = null
var _toolbar_saveas: Button = null
var _toolbar_open: Button = null
var _toolbar_sep_hist: VSeparator = null
var _toolbar_sep_scan: VSeparator = null
var _toolbar_rescan: Button = null

# -- widgets ---------------------------------------------------------------
var _list_box: VBoxContainer
var _editor_box: VBoxContainer
var _rail_box: VBoxContainer
var _status: Label
var _schema_label: Label
var _preview_box: VBoxContainer
var _issues_box: VBoxContainer

## ②文字（本地化）section: the localization keys the game will look up, and a
## live check of the `{...}` placeholders in the text.
##
## Both are built with the editor column but *updated in place* on every
## keystroke (see `_refresh_live_hints`): the column is deliberately never
## rebuilt while a field has focus, so a stale value is the alternative, and the
## whole point is to show a broken placeholder while it is still being typed.
## They are freed together with the column, so every use is guarded.
var _text_key_label: Label = null
var _text_hint: Label = null

## ①标识's derived `Entry：…` readout, refreshed for the same reason.
var _entry_label: Label = null

## Guards re-entrant rebuilds while a control writes its value back.
var _syncing := false

## Rebuild scheduling.
##
## Rebuilding a column frees every old child and creates new ones. That is only
## safe *outside* the engine's child-setup phase — but every editor widget emits
## its change signal from inside that phase, so a naive inline rebuild fails:
##   ERROR: Parent node is busy setting up children, `add_child()` failed.
##
## So a rebuild requested from a signal is never executed inline. It sets a flag
## and a single deferred pass at the end of the frame does the work. Repeated
## requests within one frame collapse into one rebuild.
var _rebuild_queued := false
var _rebuild_in_progress := false

## Nesting depth of "a widget is writing its value back into the database".
##
## A text field's `text_changed` -> `set_field` -> `normalize` chain runs while
## the widget's own signal is still being emitted, and `designs_changed` fans
## straight back into the editor. Without this guard the editor rebuilds its
## widgets *underneath* the control that is mid-write, so the LineEdit the user
## is typing into is destroyed on the very first keystroke: the caret vanishes
## and every following character is lost. All database writes funnel through
## `_write()` / `_write_quiet()`, which raise this flag.
var _write_depth := 0

## The mod directory produced by the most recent export, so 「编译验证」 knows
## what to build without asking again.
var _last_mod_dir := ""
var _build_in_progress := false
var _build_thread: Thread

## Context of the row the editor is currently building. Widget callbacks fire
## long after `_build_editor()` returns, so the paths they write to are captured
## here instead of being re-derived from `db.selected_item()` (which can move on
## while a callback is still queued).
var _ed_kind := ""
var _ed_index := -1

## Detached holder for controls that must survive a rebuild because they own the
## keyboard focus. See `_clear_column`.
var _limbo: Node = null

## path-key -> the Control currently rendering it. The database knows the *value*
## at a path but not which widget draws it, so the widget registers itself here
## when built and `_clear_column` uses this to spare the field being typed into.
var _live_widgets: Dictionary = {}

## Which item `_live_widgets` currently describes, as "<kind>#<index>". Paths are
## only unique *within* an item — every card has a ["text","zhs","description"]
## — so the map has to be thrown away when the selection moves.
var _live_scope := ""


func _ready() -> void:
	name = "CardRelicForge"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	settings = CFPaths.load_settings()
	# The database is a Resource that emits; every mutate path funnels through
	# these three signals so the three columns can never drift out of sync.
	db.selection_changed.connect(_on_selection_changed)
	db.designs_changed.connect(_on_designs_changed)
	db.dirty_changed.connect(_on_dirty_changed)
	_build_shell()
	_fit_to_viewport()
	get_viewport().size_changed.connect(_on_viewport_resized)
	_load_cached_schema()
	# Scan *before* seeding so the example content is built against the real
	# enum/pool/hook sets. scan_first() awaits its own coroutine.
	if bool(settings.get("auto_scan", true)):
		scan_first()


## A Control node does not stretch to the window on its own, so both this node
## and its two full-rect children are sized explicitly (and re-sized whenever
## the window changes). The helper defers the assignment because Godot warns
## when a non-anchored size is written while the parent is still 0-sized.
func _fit_to_viewport() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	_set_full_rect.call_deferred(self, vp.get_visible_rect().size)
	for c in get_children():
		if c is Control and (c.name == "BG" or c.name == "Root"):
			_set_full_rect.call_deferred(c, vp.get_visible_rect().size)


## The window changed size: keep the full-rect shell in step **and** re-fit the
## columns. Without the second part, shrinking the window leaves the columns at
## their old minimum widths and the rail slides off the right edge again.
func _on_viewport_resized() -> void:
	_fit_to_viewport()
	var vp := get_viewport()
	if vp != null:
		var w := int(vp.get_visible_rect().size.x)
		_fit_columns_to(w)
		_fit_toolbar_to(w)


func _set_full_rect(c: Control, vp_size: Vector2) -> void:
	if not is_instance_valid(c):
		return
	# Drive position/size purely through anchors + offsets. Writing `size`
	# directly on a full-rect anchored node makes Godot warn that the value
	# "will be overridden after _ready()"; offsets are the supported path.
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0



## Scan on boot, then seed/open the design. Awaiting keeps the ordering sane
## without blocking the first frame (the window is already visible).
func scan_first() -> void:
	await _do_scan()
	_load_last_design()
	# A design file may already have been open; otherwise seed the example.
	if db.all_items().is_empty() and db.custom_characters.is_empty() and db.abilities.is_empty() and not schema.source_root.is_empty():
		db.seed_example(schema)
		db.clear_history()
	_select_first_item()
	_rebuild_all()


## Select the first card (or, failing that, the first relic) after a design is
## loaded.
##
## Without this the editor and the whole right-hand rail stay empty on boot:
## the list shows your cards but nothing is chosen, so the middle column reads
## "从左侧选择一张卡牌…". That looks exactly like a broken app, and it is the
## state the tool used to open in whenever `designs/main.json` was reloaded.
func _select_first_item() -> void:
	if db.selected_index >= 0:
		return
	if not db.cards.is_empty():
		db.set_selection(CFDesign.KIND_CARD, 0)
	elif not db.relics.is_empty():
		db.set_selection(CFDesign.KIND_RELIC, 0)


func _on_selection_changed() -> void:
	if _syncing:
		return
	schedule_rebuild()


func _on_designs_changed() -> void:
	if _syncing:
		return
	schedule_rebuild()


func _on_dirty_changed(dirty: bool) -> void:
	if _status != null:
		_status.text = "● 有未保存修改" if dirty else "已保存"
		if _status.has_theme_color_override("font_color"):
			_status.add_theme_color_override("font_color", W.WARN if dirty else W.TEXT_DIM)



func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_settings()
		get_tree().quit()


# ---------------------------------------------------------------------------
# Shell
# ---------------------------------------------------------------------------

## The app node is a bare Control, which never lays its children out. Both
## direct children therefore need explicit full-rect anchors applied *after*
## they enter the tree, once the parent has a real size.
func _fill_parent(c: Control) -> void:
	c.anchor_left = 0.0
	c.anchor_top = 0.0
	c.anchor_right = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0
	c.grow_horizontal = Control.GROW_DIRECTION_BOTH
	c.grow_vertical = Control.GROW_DIRECTION_BOTH


func _build_shell() -> void:
	var bg := ColorRect.new()
	bg.color = W.BG
	bg.name = "BG"
	add_child(bg)
	_fill_parent(bg)

	var root := VBoxContainer.new()
	root.name = "Root"
	root.add_theme_constant_override("separation", 8)
	add_child(root)
	_fill_parent(root)

	root.add_child(_build_toolbar())

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 8)
	root.add_child(split)
	_outer_split = split

	# Column 1 — the item list.
	var left_pair := _column_panel()
	left_pair["panel"].custom_minimum_size.x = _col_list_w
	_col_panels.append(left_pair["panel"])
	_list_box = _column_box()
	left_pair["scroll"].add_child(_list_box)
	split.add_child(left_pair["panel"])

	# Column 2+3 — editor and rail share the rest.
	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_split.add_theme_constant_override("separation", 8)
	split.add_child(right_split)
	_right_split = right_split

	var mid_pair := _column_panel()
	mid_pair["panel"].custom_minimum_size.x = _col_editor_w
	_col_panels.append(mid_pair["panel"])
	_editor_box = _column_box()
	mid_pair["scroll"].add_child(_editor_box)
	right_split.add_child(mid_pair["panel"])

	var rail_pair := _column_panel()
	rail_pair["panel"].custom_minimum_size.x = _col_rail_w
	_col_panels.append(rail_pair["panel"])
	_rail_box = _column_box()
	rail_pair["scroll"].add_child(_rail_box)
	right_split.add_child(rail_pair["panel"])

	root.add_child(_build_statusbar())
	# `_ready()` runs before the OS window is necessarily realized, and a
	# `window_set_size` issued that early is discarded (the window then opens at
	# whatever `project.godot` asked for). Deferring one frame lets the resize
	# actually stick; the column/toolbar fit is applied immediately so the very
	# first frame is already correct.
	_apply_window_size()
	_apply_window_size.call_deferred()


## A styled, vertically scrolling column. Returns the outer panel and the inner
## scroll container so callers can size the panel and fill the scroll.
func _column_panel() -> Dictionary:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", W.sb(W.PANEL, 8, 1))
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	return {"panel": panel, "scroll": scroll}


## The VBox that holds a column's content, placed inside `_column_panel()`'s
## scroll container.
##
## **`size_flags_horizontal = EXPAND_FILL` is not optional.** With horizontal
## scrolling disabled a `ScrollContainer` sizes its child to the child's
## *minimum* width — not to the viewport. The list column's content has a small
## minimum (~171 px), so without this flag the list collapsed to 171 px inside a
## 368 px column: card names were clipped and the delete button sat jammed
## against the left edge. The flag makes the content actually fill the column.
func _column_box(separation: int = 8) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# **Do NOT set `size_flags_vertical = EXPAND_FILL` here.** A ScrollContainer
	# sizes its child to `max(child_min_height, viewport_height)`, but with the
	# vertical EXPAND flag the child is clamped to exactly the viewport height.
	# The column's content is taller than the window, so it then overflowed a
	# box that could not grow — the effect editor at the bottom was unreachable
	# and the scrollbar refused to move (`scroll_vertical` stayed 0). Leaving the
	# vertical flag at its default FILL lets the box take its natural height and
	# the column scrolls normally.
	return box


## Make the window and the three columns fit the screen the app was launched on.
##
## Why this exists
## --------------
## `project.godot` declares a *design* size (currently 1280x800). On a smaller or
## scaled desktop the OS clamps the real window, and because the three columns
## declare hard minimum widths their sum (300+520+360 + separations = 1196) is a
## floor the HSplitContainer cannot shrink past. The split then overflows and the
## right-hand rail is pushed off the screen edge — the "UI 突到屏幕外" symptom,
## which showed up as the title reading "ardRelicForge" (the leading "C" was
## clipped off the left edge).
##
## Three repairs, in order:
##   1. Clamp the window to the usable desktop rect, so a small screen gets a
##      window that actually fits instead of one hanging off the edges.
##   2. Shrink the three columns, but never below their usable floors.
##   3. Collapse the toolbar's optional buttons (see `_fit_toolbar_to`), since it
##      is a second, independent width floor.
func _apply_window_size() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var usable := _usable_window_size()

	# Leave a small margin so the window's own title bar / borders are not the
	# thing that ends up clipped.
	var budget := usable - Vector2(WINDOW_EDGE_MARGIN, WINDOW_EDGE_MARGIN)
	# Never open wider than the screen can show; never narrower than the point
	# where the three columns stop being usable.
	var want_w := clampi(int(DESIGN_WIDTH), WINDOW_MIN_WIDTH, maxi(WINDOW_MIN_WIDTH, int(budget.x)))
	var want_h := clampi(int(DESIGN_HEIGHT), WINDOW_MIN_HEIGHT, maxi(WINDOW_MIN_HEIGHT, int(budget.y)))

	if _window_is_standalone():
		# Only meaningful for a real OS window; no-op when embedded / headless.
		DisplayServer.window_set_min_size(Vector2i(
				mini(WINDOW_MIN_WIDTH, int(budget.x)),
				mini(WINDOW_MIN_HEIGHT, int(budget.y))))
		DisplayServer.window_set_size(Vector2i(want_w, want_h))
		# Centre it: an off-centre oversized window is what clips against the
		# screen edge in the first place.
		var screen := DisplayServer.screen_get_usable_rect(
				DisplayServer.window_get_current_screen())
		if screen.size.x > 0:
			DisplayServer.window_set_position(
					screen.position + (screen.size - Vector2i(want_w, want_h)) / 2)

	_fit_columns_to(want_w)
	_fit_toolbar_to(want_w)
	# The window size we just requested is applied by the OS a frame or two
	# later, and that relayout can leave the split dividers at a stale offset
	# (first column at a negative x → its content off-screen). Re-assert the
	# offsets once the resize has actually landed.
	_reset_split_offsets.call_deferred()
	_reset_split_offsets.call_deferred()


## Screen area available for the window, in pixels. Falls back to the viewport
## size when the display server cannot answer (headless, embedded game window).
func _usable_window_size() -> Vector2:
	if _window_is_standalone():
		var screen := DisplayServer.screen_get_usable_rect(
				DisplayServer.window_get_current_screen())
		if screen.size.x > 0 and screen.size.y > 0:
			return Vector2(screen.size)
	var vp := get_viewport()
	if vp != null:
		return vp.get_visible_rect().size
	return Vector2(DESIGN_WIDTH, DESIGN_HEIGHT)


## True when we are a real OS window that may be resized/repositioned by us.
## Embedded (editor plugin host) and headless runs must not touch the window.
func _window_is_standalone() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	# `is_embedded()` is the Window API for "hosted inside another window"
	# (editor play-in-window); the older `get_embedder()` name does not exist in
	# GDScript in 4.5.
	var w := get_window()
	if w != null and w.is_embedded():
		return false
	return true


## Re-apply the width to every column, shrinking the rail/editor/list in that
## order so the *editor* keeps its room as long as possible (it is the column
## you actually type into).
func _fit_columns_to(window_w: int) -> void:
	var avail := window_w - ROOT_MARGIN * 2 - SPLIT_SEPARATION * 2
	var widths := [_col_list_w, _col_editor_w, _col_rail_w]
	# Total the columns want, and the total they refuse to go below.
	var want := float(widths[0] + widths[1] + widths[2])
	var floors := [COL_LIST_MIN, COL_EDITOR_MIN, COL_RAIL_MIN]

	if want > float(avail):
		var excess := want - float(avail)
		# Trim from the widest flexible part first: rail, then editor, then list.
		var order := [2, 1, 0]
		for idx in order:
			if excess <= 0.0:
				break
			var room: float = float(widths[idx] - floors[idx])
			if room <= 0.0:
				continue
			var cut: float = minf(room, excess)
			widths[idx] = int(float(widths[idx]) - cut)
			excess -= cut

	_col_list_w = widths[0]
	_col_editor_w = widths[1]
	_col_rail_w = widths[2]
	for i in _col_panels.size():
		if i < 3 and is_instance_valid(_col_panels[i]):
			_col_panels[i].custom_minimum_size.x = widths[i]
	_reset_split_offsets()
	# The rail's wrapping labels derive their width from the rail panel, so a
	# narrower rail must be reflected before the next rebuild.
	_refresh_rail_wrap_width()


## Re-anchor the two split dividers so the first column always starts at x >= 0.
##
## **Why this is required.** An `HSplitContainer` remembers a drag *offset* for
## its divider. When the window (and therefore the split's own rect) changes —
## which happens on the boot-time `_apply_window_size()` and on every resize —
## that stale offset is kept. With offsets left over from a *wider* layout the
## first panel is placed at a **negative x** and its content is silently pushed
## off the left edge of the screen (measured: `list_panel x = -184`, i.e. the
## card list was 184 px off-screen while every size value looked correct).
##
## Resetting `split_offset` forces Godot to recompute the divider from the
## columns' minimum sizes, which after `_fit_columns_to` always sum to less than
## the available width — so the first column lands at x = 0.
##
## This is deferred one frame on purpose: `split_offset` is a *request*, and
## Godot applies it during the next layout pass. Setting it in the same frame as
## a window resize would be overwritten by that resize's own layout.
func _reset_split_offsets() -> void:
	_apply_split_offsets.call_deferred()


func _apply_split_offsets() -> void:
	for s in [_outer_split, _right_split]:
		if s != null and is_instance_valid(s):
			(s as SplitContainer).split_offset = 0


## Re-wrap the rail's long-text labels after the rail width changed. The labels
## themselves are rebuilt by the caller; this only keeps any *existing* rail
## content consistent if a resize happens without a full rebuild.
func _refresh_rail_wrap_width() -> void:
	queue_redraw()


func _build_toolbar() -> Control:
	var bar := PanelContainer.new()
	bar.name = "Toolbar"
	bar.add_theme_stylebox_override("panel", W.sb(W.PANEL, 8, 1))
	# The toolbar is a fixed-height strip: without SHRINK a PanelContainer
	# happily absorbs the whole column and squeezes the working area to nothing.
	bar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	bar.add_child(row)
	# Kept for `_fit_toolbar_to`: the pieces that can be hidden / collapsed when
	# the window is too narrow for the full strip.
	_toolbar_row = row

	# A single HBox cannot wrap, so its total child width is a *hard floor* on
	# the window — measured at 964 px with every button present, which overflows
	# a 900 px laptop on its own (independent of the three columns). The wordmark
	# and subtitle are the biggest, least essential part, so they are collapsed
	# first.
	_toolbar_brand = W.label("CardRelicForge", W.ACCENT, 18)
	row.add_child(_toolbar_brand)
	_toolbar_subtitle = W.dim("卡牌 / 遗物效果制作器", 12)
	row.add_child(_toolbar_subtitle)
	row.add_child(VSeparator.new())

	var b_new_card := W.button("＋ 卡牌")
	b_new_card.pressed.connect(func(): _add_new(false))
	row.add_child(b_new_card)
	var b_new_relic := W.button("＋ 遗物")
	b_new_relic.pressed.connect(func(): _add_new(true))
	row.add_child(b_new_relic)
	var b_library := W.button("能力 / 角色库")
	b_library.pressed.connect(_open_authoring_library)
	row.add_child(b_library)

	row.add_child(VSeparator.new())
	_toolbar_save = _mk("保存", func(): _save_design(false))
	row.add_child(_toolbar_save)
	# These three are the *narrowest* wins when space runs out: they duplicate
	# things reachable elsewhere (the file dialog, the rescan on boot), so they
	# hide before anything that has no other entry point.
	_toolbar_saveas = _mk("另存为", func(): _save_design(true))
	row.add_child(_toolbar_saveas)
	_toolbar_open = _mk("打开", _open_design)
	row.add_child(_toolbar_open)
	_toolbar_sep_hist = VSeparator.new()
	row.add_child(_toolbar_sep_hist)
	row.add_child(_mk("↶", func(): db.undo()))
	row.add_child(_mk("↷", func(): db.redo()))
	_toolbar_sep_scan = VSeparator.new()
	row.add_child(_toolbar_sep_scan)
	_toolbar_rescan = _mk("重新扫描游戏", func(): _do_scan())
	row.add_child(_toolbar_rescan)
	row.add_child(_mk("设置", _open_settings))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_schema_label = W.label("", W.TEXT_DIM, 11)
	row.add_child(_schema_label)
	return bar


## Collapse the toolbar's optional pieces so the strip stops forcing the window
## wider than the screen.
##
## The toolbar is one unbreakable `HBoxContainer`, so its summed child widths
## are a hard minimum for the whole window — measured 964 px with everything
## visible, which alone overflows a 900 px desktop. We shed in order of least
## loss: subtitle, then wordmark, then the duplicate file commands, then the
## history separators. `＋ 卡牌 / ＋ 遗物 / ↶ ↷ / 设置` always stay (they have no
## other entry point), and everything hidden is reachable from the menus/dialogs
## that remain.
func _fit_toolbar_to(window_w: int) -> void:
	if _toolbar_row == null:
		return
	var w := float(window_w)
	# Ordered from "keep longest" to "give up first"; each entry is the
	# visibility test for one group.
	# Thresholds measured against the *current* font scale. With `FONT_SCALE`
	# at 1.25 the full strip needs 1138 px, so every step is ~25% higher than
	# the 1.0-scale numbers were. Re-measure (probe `_fit_toolbar_to` at several
	# widths and compare against `width - 16`) whenever FONT_SCALE changes.
	# The authoring-library entry adds a permanent toolbar control; move the
	# collapse points by its measured width so narrow windows still fit.
	var show_sub := w >= 1220.0
	var show_brand := w >= 1210.0
	var show_files := w >= 1050.0
	var show_hist_sep := w >= 950.0
	var show_scan := w >= 920.0

	_show_opt(_toolbar_subtitle, show_sub)
	_show_opt(_toolbar_brand, show_brand)
	_show_opt(_toolbar_save, true)
	_show_opt(_toolbar_saveas, show_files)
	_show_opt(_toolbar_open, show_files)
	_show_opt(_toolbar_sep_hist, show_hist_sep)
	_show_opt(_toolbar_sep_scan, show_scan)
	_show_opt(_toolbar_rescan, show_scan)


## Show/hide a toolbar piece. Hidden nodes must also stop contributing width, so
## `visible = false` (Godot excludes invisible children from a container's
## minimum size) is exactly the right lever.
func _show_opt(c: Control, on: bool) -> void:
	if c != null and is_instance_valid(c):
		c.visible = on


func _mk(text: String, cb: Callable) -> Button:
	var b := W.button(text)
	b.pressed.connect(cb)
	return b


func _build_statusbar() -> Control:
	var bar := PanelContainer.new()
	bar.name = "Statusbar"
	bar.add_theme_stylebox_override("panel", W.sb(W.PANEL, 8, 1))
	bar.size_flags_vertical = Control.SIZE_SHRINK_END
	# The status line carries preflight dumps and error text, i.e. arbitrary
	# length. It lives in a full-width row, so it must wrap: without a width
	# floor the wrapping label collapses and reports a nonsense height, and
	# without `clip_text` a long message can still stretch the window.
	_status = W.label("就绪。", W.TEXT_DIM, 12)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 1
	_status.clip_text = true
	_status.max_lines_visible = 3
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_status)
	return bar


func _say(text: String, color: Color = W.TEXT_DIM) -> void:
	_status.text = text
	_status.tooltip_text = text
	_status.add_theme_color_override("font_color", color)


# ---------------------------------------------------------------------------
# Schema / design loading
# ---------------------------------------------------------------------------

func _load_cached_schema() -> void:
	var text := CFPaths.read_text(CFPaths.CACHE_PATH)
	if text.is_empty():
		return
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return
	if schema.load_cache_dict(parser.data as Dictionary):
		_refresh_schema_label()


func _cache_schema() -> void:
	var f := FileAccess.open(CFPaths.CACHE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(schema.to_cache_dict()))
	f.close()


func _load_last_design() -> void:
	var path := String(settings.get("last_design_file", ""))
	if path.is_empty() or not FileAccess.file_exists(path):
		if not schema.source_root.is_empty():
			db.seed_example(schema)
			db.clear_history()
			_say("已载入示例内容（九重打击 / 铁壁护符）。改完后点“导出”即可生成 Mod。")
		return
	var res := db.load_from_file(path)
	db.clear_history()
	if bool(res["ok"]):
		_say("已打开 %s" % path)
	else:
		_say("打开失败：%s" % res["error"], W.ERR)


func _refresh_schema_label() -> void:
	if schema.source_root.is_empty():
		_schema_label.text = "⚠ 尚未扫描游戏数据"
		_schema_label.add_theme_color_override("font_color", W.WARN)
		return
	_schema_label.text = "已扫描：%d 枚举 · %d 卡池 · %d 能力 · %d 触发时机" % [
		schema.enums.size(), schema.card_pools.size(), schema.powers.size(), schema.hooks.size()]
	_schema_label.add_theme_color_override("font_color", W.TEXT_DIM)


func _do_scan() -> void:
	_say("正在扫描解包数据……", W.ACCENT)
	await get_tree().process_frame
	var root := String(settings.get("source_root", ""))
	if root.is_empty():
		root = CFPaths.detect_source_root()
	if root.is_empty():
		_say("找不到解包数据目录。请在「设置」里手动指定。", W.ERR)
		return
	CFSchemaScanner.scan(root, schema)
	settings["source_root"] = root
	_cache_schema()
	_save_settings()
	_refresh_schema_label()
	if not schema.errors.is_empty():
		_say("扫描完成但有错误：%s" % str(schema.errors), W.ERR)
	else:
		_say("扫描完成：%s" % schema.summary(), W.OK)
	# A schema change can invalidate stored enum values, so re-normalise.
	for item in db.all_items():
		CFDesign.normalize(schema, item)
	_rebuild_all()


# ---------------------------------------------------------------------------
# Full rebuild
# ---------------------------------------------------------------------------
#
# Rebuilding a column means tearing down and recreating every child control.
# That is only safe *outside* the engine's child-setup phase, i.e. not from
# inside a signal emitted by one of the widgets being torn down. Every edit
# callback in this file is exactly that, so all rebuilds go through
# schedule_rebuild() -> _flush_rebuild(), which runs at the end of the frame.

## Queue a full column rebuild for the end of this frame. Safe to call from any
## signal handler. Duplicate requests within one frame collapse into one pass.
func schedule_rebuild() -> void:
	# Always defer the rebuild. OptionButton/SpinBox signals can arrive in a
	# burst while Godot is still laying out the control tree; rebuilding inline
	# makes every step pay for a full editor teardown and can re-enter add_child.
	# One deferred pass also coalesces rapid spinner changes into one refresh.
	if _rebuild_queued:
		return
	_rebuild_queued = true
	call_deferred("_flush_rebuild")


func _flush_rebuild() -> void:
	if _write_depth > 0:
		# A deferred flush fired while a write was still in flight; the write's
		# own exit path will re-queue. Dropping the flag here would strand both.
		return
	_rebuild_queued = false
	_rebuild_all()


func _rebuild_all() -> void:
	if _syncing or _rebuild_in_progress or _write_depth > 0:
		return
	_rebuild_in_progress = true
	_build_list()
	_build_editor()
	_build_rail()
	# A widget parked in limbo is only ever fetched back by the section that
	# rebuilds the same path. If that section is gone for good (the field was
	# removed, collapsed, or the item changed under it) the widget would sit in
	# limbo forever — invisible, but leaked. Sweep the ones nothing points at.
	_sweep_limbo()
	_rebuild_in_progress = false


## Free limbo residents that are no longer the registered widget for any path.
func _sweep_limbo() -> void:
	if not is_instance_valid(_limbo):
		return
	var keep: Dictionary = {}
	for k in _live_widgets.keys():
		var v: Variant = _live_widgets[k]
		if is_instance_valid(v):
			keep[(v as Object).get_instance_id()] = true
	for c in _limbo.get_children():
		if keep.has(c.get_instance_id()):
			continue
		_limbo.remove_child(c)
		c.queue_free()


## Clear a column before rebuilding it.
##
## `queue_free()`, not `free()`: a rebuild is triggered by a widget's own signal,
## and freeing that widget inline while its signal is still being emitted makes
## Godot abort with "Object was freed while a signal is being emitted from it".
## queue_free() defers the deletion to the end of the frame — which is exactly
## when our own deferred rebuild runs, so the freed controls are gone before the
## replacements are built and no duplicates survive the frame.
##
## Only the widget the user is typing into is spared; everything else is freed
## and rebuilt. `_live_field` / `_live_textarea` pick it back out of limbo when
## they rebuild the section it belongs to, which is what keeps the caret alive.
##
## The sparing is done by *descending* into the subtree, not by lifting the
## top-level child wholesale. A column's direct children are whole section
## panels (`W.wrap`) holding a dozen controls each, so re-parenting one of them
## dragged every sibling along with it: a spare TextEdit (say the `eng`
## description) travelled into limbo too, only the field that was actually
## focused got pulled back out, and the rest stayed stranded there for good —
## the editor silently lost text boxes as you typed. Recursing means the
## protected field alone is detached and its siblings are freed normally.
func _clear_column(box: Container) -> void:
	_clear_children(box)
	_prune_live_widgets()


## Recursive half of `_clear_column`: keeps the protected widget, frees the rest.
##
## `queue_free()` is only safe on a node that has *no* protected descendant.
## A node that merely *contains* the protected widget is unparented without
## being freed — its other children are handled on their own, so they are
## released while the one that holds the caret survives.
func _clear_children(box: Node) -> void:
	for c in box.get_children():
		if not is_instance_valid(c):
			continue
		if _is_protected_widget(c):
			# This *is* the field being typed into: detach it intact.
			box.remove_child(c)
			_limbo_add(c)
			continue
		if _subtree_holds_protected(c):
			# Ancestor of the protected field: keep the node, recurse into it.
			_clear_children(c)
			continue
		box.remove_child(c)
		c.queue_free()


## Is `n` the live widget backing the field the user is currently editing?
func _is_protected_widget(n: Node) -> bool:
	var live: Variant = _live_widgets.get(str(db.edit_path()))
	if live is Node and is_instance_valid(live):
		return live == n
	return false


## Does anything below `n` hold the protected widget? Walks `_live_widgets`
## rather than the tree: the protected field is the single entry whose path
## equals the published edit path, so one lookup answers it.
func _subtree_holds_protected(n: Node) -> bool:
	var live: Variant = _live_widgets.get(str(db.edit_path()))
	if live is Node and is_instance_valid(live):
		return n.is_ancestor_of(live)
	return false


## Park a control in the limbo node while its column is rebuilt, so it is not
## freed along with its siblings.
##
## Limbo is deliberately kept **out of the scene tree** (`_limbo` is never
## `add_child`-ed). A Control whose parent is a plain Node gets no layout from
## that parent, so it falls back to its own offsets and ends up painted near the
## origin — the "a second copy of the input box appears on the left of the
## window and will not go away" the user saw. Staying out of the tree means Godot
## never draws or lays out limbo's contents at all.
##
## The widget is also hidden on the way in and shown again on the way out: the
## tree membership alone decides rendering, but toggling `visible` keeps the
## invariant explicit and covers the frame in which the swap happens.
func _limbo_add(c: Node) -> void:
	if not is_instance_valid(_limbo):
		_limbo = Node.new()
		_limbo.name = "FocusLimbo"
	if c is CanvasItem:
		(c as CanvasItem).visible = false
	_limbo.add_child(c)


## Take the protected widget back out of limbo, ready to be re-parented.
##
## Returns null when the widget was freed (or never parked), so the caller can
## fall through to building a fresh one instead of adding a dangling node.
func _limbo_take(path: Array) -> Control:
	var live: Variant = _live_widgets.get(str(path))
	if not (live is Control) or not is_instance_valid(live):
		return null
	var c: Control = live
	var parent := c.get_parent()
	if parent != null:
		parent.remove_child(c)
	c.visible = true
	return c


## Forget widgets that have been freed, so `_live_widgets` cannot grow without
## bound or hand back a dangling reference.
func _prune_live_widgets() -> void:
	for k in _live_widgets.keys():
		if not is_instance_valid(_live_widgets[k]):
			_live_widgets.erase(k)


## Did this control (or anything below it) take the keyboard focus?
##
## Kept for callers that want a direct focus answer. The rebuild path no longer
## uses it: headless runs never hold the *real* focus, so `gui_get_focus_owner`
## returns null there and focus alone cannot distinguish "the field being typed
## into" from "an ordinary widget". `_clear_column` keys off the published edit
## path (`_is_protected_widget`) instead, which is correct in both cases.




func _build_list() -> void:
	_clear_column(_list_box)

	var header := HBoxContainer.new()
	header.add_child(W.heading("内容列表"))
	_list_box.add_child(header)

	for kind in [CFDesign.KIND_CARD, CFDesign.KIND_RELIC]:
		var items := db.items_for(kind)
		var title := "卡牌（%d）" % items.size() if kind == CFDesign.KIND_CARD else "遗物（%d）" % items.size()
		_list_box.add_child(W.label(title, W.ACCENT, 13))
		if items.is_empty():
			_list_box.add_child(W.dim("（空）", 11))
		for i in items.size():
			_list_box.add_child(_list_row(kind, i, items[i]))

	_list_box.add_child(VSeparator.new())
	var mod_box := VBoxContainer.new()
	mod_box.add_theme_constant_override("separation", 4)
	mod_box.add_child(W.label("Mod 信息", W.ACCENT, 13))
	mod_box.add_child(_bind_field("Mod ID", db.mod_id, func(v): db.mod_id = v; _mark_dirty_silent()))
	mod_box.add_child(_bind_field("名称", db.mod_name, func(v): db.mod_name = v; _mark_dirty_silent()))
	mod_box.add_child(_bind_field("作者", db.mod_author, func(v): db.mod_author = v; _mark_dirty_silent()))
	mod_box.add_child(_bind_field("版本", db.mod_version, func(v): db.mod_version = v; _mark_dirty_silent()))
	mod_box.add_child(_bind_field("最低游戏版本", db.min_game_version, func(v): db.min_game_version = v; _mark_dirty_silent()))
	_list_box.add_child(mod_box)


func _list_row(kind: String, index: int, item: Dictionary) -> Control:
	var selected := db.selected_kind == kind and db.selected_index == index
	var btn := Button.new()
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size.y = 34
	btn.add_theme_font_size_override("font_size", W.fs(13))
	var issues := CFDesign.validate(schema, item, db.all_items(), db.custom_characters)
	var counts := CFDesign.issue_counts(issues)
	var badge := ""
	if int(counts["errors"]) > 0:
		badge = "  ✕%d" % counts["errors"]
	elif int(counts["warnings"]) > 0:
		badge = "  !%d" % counts["warnings"]
	btn.text = "%s%s" % [CFDesign.display_name(item, "zhs"), badge]
	if selected:
		btn.add_theme_stylebox_override("normal", W.sb(W.ACCENT_DIM, 6, 1))
		btn.add_theme_stylebox_override("hover", W.sb(W.ACCENT_DIM, 6, 1))
	else:
		btn.add_theme_stylebox_override("normal", W.sb(W.PANEL_2, 6, 1))
		btn.add_theme_stylebox_override("hover", W.sb(W.BORDER, 6, 1))
	btn.add_theme_color_override("font_color", W.TEXT)
	if int(counts["errors"]) > 0:
		btn.add_theme_color_override("font_color", W.ERR)
	elif int(counts["warnings"]) > 0:
		btn.add_theme_color_override("font_color", W.WARN)
	btn.pressed.connect(func(): db.set_selection(kind, index))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(btn)

	var del := W.button("✕")
	del.tooltip_text = "删除"
	del.custom_minimum_size.x = 32
	del.pressed.connect(func():
		db.remove_item(kind, index)
		schedule_rebuild())
	row.add_child(del)
	return row


func _bind_field(title: String, value: String, setter: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var l := W.label(title, W.TEXT_DIM, 12)
	l.custom_minimum_size.x = 100
	row.add_child(l)
	var e := W.field(value)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.text_changed.connect(func(t): setter.call(t))
	row.add_child(e)
	return row


func _mark_dirty_silent() -> void:
	db._mark_dirty(true)


# ---------------------------------------------------------------------------
# Editor
# ---------------------------------------------------------------------------

func _build_editor() -> void:
	# Publish the item context *before* clearing: `_clear_column` needs it to
	# recognise which widget is the one the user is typing into. Deriving it
	# afterwards left `_ed_index == -1` during the clear, so the live field was
	# never recognised and got freed on the very first keystroke.
	_ed_kind = db.selected_kind
	_ed_index = db.selected_index
	# `_live_widgets` is keyed by design path, and two different cards share the
	# same paths (every card has ["text","zhs","description"]). Switching items
	# without dropping the map let the new card's editor adopt the *previous*
	# card's widget — stale text, and a caret pointing at a control that is
	# about to be freed.
	#
	# Drop the map *before* clearing, and clear the published edit path with it:
	# once the user picks another item nothing from the old one is protected any
	# more, so `_clear_column` is free to release every child (including the
	# field that had focus) instead of saving a widget that can never be reused.
	var scope := "%s#%d" % [_ed_kind, _ed_index]
	if scope != _live_scope:
		_live_scope = scope
		_live_widgets.clear()
		_write_depth += 1
		db.clear_edit_path()
		_write_depth -= 1
		if is_instance_valid(_limbo):
			for c in _limbo.get_children():
				_limbo.remove_child(c)
				c.queue_free()
	_clear_column(_editor_box)
	var item := db.selected_item()
	if item.is_empty():
		_editor_box.add_child(W.panel_tip("从左侧选择一张卡牌或一件遗物，或点「＋ 卡牌 / ＋ 遗物」新建。"))
		return
	var kind := String(item.get("kind", CFDesign.KIND_CARD))
	var index := db.selected_index

	_editor_box.add_child(_section_identity(kind, index, item))
	_editor_box.add_child(_section_text(kind, index, item))
	if kind == CFDesign.KIND_CARD:
		_editor_box.add_child(_section_card_attributes(index, item))
		_editor_box.add_child(_section_vars(index, item))
		_editor_box.add_child(_section_effects(kind, index, item, -1))
		_editor_box.add_child(_section_upgrade(index, item))
	else:
		_editor_box.add_child(_section_relic_attributes(index, item))
		_editor_box.add_child(_section_vars(index, item))
		_editor_box.add_child(_section_triggers(index, item))
	_editor_box.add_child(_section_deck(kind, index, item))


# ---------------------------------------------------------------------------
# Writing values back
# ---------------------------------------------------------------------------

## Every database write goes through here.
##
## `_write_depth` is what keeps a widget's own change signal from tearing that
## widget down: while the flag is raised, `_rebuild_all()` and `schedule_rebuild()`
## both bail out, so the control the user is interacting with survives the write.
## Whatever the write changed is picked up by the deferred pass that runs once it
## returns (see `_flush_rebuild`).
func _write(path: Array, value: Variant, action: String) -> void:
	_write_depth += 1
	db.set_field(schema, _ed_kind, _ed_index, path, value, action)
	_write_depth -= 1


## Same, but leaves the value uncommitted so a whole typing session collapses
## into a single undo step.
func _write_quiet(path: Array, value: Variant) -> void:
	_write_depth += 1
	db.set_field_quiet(schema, _ed_kind, _ed_index, path, value)
	_write_depth -= 1
	# The ②文字 section shows the derived localization keys and checks the
	# placeholders in them; both follow what was just typed, and neither can wait
	# for a rebuild (the section is not rebuilt mid-typing).
	if not path.is_empty() and (String(path[0]) == "text" or String(path[0]) == "id"):
		_refresh_live_hints()


## Commit any uncommitted typing, then publish the path of the field that now
## has focus. The path lives in the database (single source of truth) so the
## rebuild pass and the widgets cannot disagree about what is being edited.
func _on_edit_focus_entered(path: Array) -> void:
	_write_depth += 1
	db.flush_edit([])
	db.set_edit_path(path)
	_write_depth -= 1


## A text field lost focus: commit whatever was typed into it.
##
## Ignored while a rebuild is in flight. Rebuilding swaps widgets out, and Godot
## raises `focus_exited` for every focused control it frees on the way — so this
## fires for reasons that have nothing to do with the user tabbing away. Acting
## on it then is actively harmful: it clears the published edit path, and the
## *next* rebuild sees no protected field and frees the widget the user is still
## typing into. That is the "输入中被打断后，同一个描述框仍在（焦点未丢）"
## regression, where editing an unrelated field (the cost spinner) destroyed the
## caret in the description box.
##
## A genuine focus exit still lands after the rebuild finishes, so nothing is
## lost by skipping the ones that happen mid-rebuild.
func _on_edit_focus_exited(path: Array) -> void:
	if _rebuild_in_progress:
		return
	if not _same_path(path, db.edit_path()):
		return
	_write_depth += 1
	db.flush_edit(path)
	db.clear_edit_path()
	_write_depth -= 1
	_schedule_after_write()


func _same_path(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


func _schedule_after_write() -> void:
	_rebuild_queued = true
	call_deferred("_flush_rebuild")


func _section_title(text: String) -> Control:
	var l := W.label(text, W.ACCENT, 14)
	return l


func _section_identity(kind: String, index: int, item: Dictionary) -> Control:
	var box := W.panel("① 标识")
	# 用即时写入：ID 每敲一个字符都会重新生成 Entry，界面需要跟着刷新；
	# 同时靠数据库里记录的「正在编辑字段」让输入框在保持焦点时不被重建。
	box.add_child(_live_field("ID（决定类名与本地化键）", String(item.get("id", "")), ["id"]))
	# `_refresh_live_hints` keeps this line in step with the ID field while it is
	# being typed (the entry is derived on every keystroke by `_normalize_live`).
	_entry_label = W.dim("Entry：%s" % String(item.get("entry", "")), 11)
	box.add_child(_entry_label)
	var pool_items: Array = []
	for p in (schema.relic_pools if kind == CFDesign.KIND_RELIC else schema.card_pools):
		pool_items.append({"value": String(p.get("class_name", "")),
			"label": "%s%s" % [p.get("class_name", "?"),
				"  (%s)" % p.get("character", "") if not String(p.get("character", "")).is_empty() else ""]})
	for character in db.custom_characters:
		var custom_pool := String(character.get("relic_pool" if kind == CFDesign.KIND_RELIC else "card_pool", ""))
		if not custom_pool.is_empty():
			pool_items.append({"value": custom_pool,
				"label": "%s  （自定义：%s）" % [custom_pool, character.get("name", character.get("id", "角色"))]})
	if pool_items.is_empty():
		box.add_child(W.dim("⚠ 未扫描到任何卡池，请先「重新扫描游戏」。", 11))
	else:
		box.add_child(_bind_option("所属卡池", pool_items, String(item.get("pool", "")),
				func(v): db.set_field(schema, kind, index, ["pool"], v, "修改卡池")))
	return W.wrap(box)


func _section_text(kind: String, index: int, item: Dictionary) -> Control:
	var box := W.panel("② 文字（本地化）")
	# Spell out the keys the *game* derives from the C# class name. Text written
	# under any other key is simply never found — no error, no log line, just a
	# card with no name in game.
	_text_key_label = W.dim(_loc_keys_line(kind, String(item.get("entry", ""))), 11)
	box.add_child(_text_key_label)
	var fields: Array = CFSchema.LOC_FIELDS[kind] as Array
	for locale in CFSchema.LOCALES:
		box.add_child(W.label(locale, W.TEXT_DIM, 12))
		for f in fields:
			var current := String(((item.get("text", {}) as Dictionary).get(locale, {}) as Dictionary).get(f, ""))
			var is_long: bool = (f == "description" or f == "flavor")
			if is_long:
				# Long text goes through the live-edit binder: it is never
				# rebuilt while it has focus, which is what used to eat the
				# caret after a few keystrokes.
				var path: Array = ["text", locale, f]
				var lb := W.label(f, W.TEXT_DIM, 11)
				box.add_child(lb)
				box.add_child(_live_textarea(current, 62, path))
			else:
				box.add_child(_live_field(f, current, ["text", locale, f]))
	# Live placeholder check, refreshed per keystroke by `_refresh_live_hints`.
	_text_hint = W.wrap_label("", W.TEXT_DIM, 11, _editor_wrap_width(), 6)
	box.add_child(_text_hint)
	_refresh_live_hints()
	if kind == CFDesign.KIND_CARD:
		var hint := W.dim("占位符写法：{变量:diff()} 取数值、{变量} 取原值、"
				+ "{IfUpgraded:show:升级后|升级前}；格式化器只有 "
				+ CFDesign.FORMATTER_HINT + "；[gold]…[/gold] 是 BBCode。", 11)
		box.add_child(hint)
	return W.wrap(box)


## The localization keys the game will look up for one entry.
func _loc_keys_line(kind: String, entry: String) -> String:
	if entry.is_empty():
		return "本地化键：填好 ID 后生成（游戏用 C# 类名推导，即 Entry + 字段名）。"
	var keys: Array = []
	for f in CFSchema.LOC_FIELDS[kind]:
		keys.append(CFIds.loc_key(entry, f))
	return "游戏要的本地化键：%s" % "、".join(keys)


## Refresh the derived labels of the editor column *in place* — no rebuild.
##
## Called from `_write_quiet` for `text`/`id` writes. Assignment is the only
## safe option here: a rebuild would free the widget the user is typing into
## (which is the whole reason the focus-protection machinery exists), and the
## placeholder check is only useful if it reacts to each character.
func _refresh_live_hints() -> void:
	var item := db.selected_item()
	if item.is_empty():
		return
	var kind := String(item.get("kind", CFDesign.KIND_CARD))
	if is_instance_valid(_entry_label):
		_entry_label.text = "Entry：%s" % String(item.get("entry", ""))
	if is_instance_valid(_text_key_label):
		_text_key_label.text = _loc_keys_line(kind, String(item.get("entry", "")))
	if not is_instance_valid(_text_hint):
		_text_hint = null
		return
	var declared := CFDesign.declared_var_names(item)
	var problems: Array = []
	for locale in CFSchema.LOCALES:
		var table: Dictionary = item.get("text", {}) if item.get("text") is Dictionary else {}
		var entry_text: Dictionary = table.get(locale, {}) if table.get(locale) is Dictionary else {}
		for field in CFSchema.LOC_FIELDS[kind]:
			var msg := CFDesign.describe_placeholders(String(entry_text.get(field, "")), declared)
			if not msg.is_empty():
				problems.append("%s/%s：%s" % [locale, field, msg])
	if problems.is_empty():
		var tail := "（④动态变量 里还没有变量，描述里只能用固定文字）"
		if not declared.is_empty():
			tail = "可用变量：%s" % "、".join(declared)
		_text_hint.text = "✓ 占位符检查通过；" + tail
		_text_hint.add_theme_color_override("font_color", W.TEXT_DIM)
	else:
		_text_hint.text = "⚠ " + "\n⚠ ".join(problems)
		_text_hint.add_theme_color_override("font_color", W.WARN)


func _section_card_attributes(index: int, item: Dictionary) -> Control:
	var box := W.panel("③ 卡牌属性")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_spin_block("费用", float(item.get("cost", 1)), -1, 9, 1,
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["cost"], int(v), "修改费用")))
	row.add_child(_opt_block("类型", _role_items("card_type"), String(item.get("type", "")),
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["type"], v, "修改类型")))
	row.add_child(_opt_block("稀有度", _role_items("card_rarity"), String(item.get("rarity", "")),
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["rarity"], v, "修改稀有度")))
	row.add_child(_opt_block("目标", _role_items("target_type"), String(item.get("target", "")),
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["target"], v, "修改目标")))
	box.add_child(row)
	box.add_child(_flag_list("关键字", "card_keyword", item.get("keywords", []),
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["keywords"], v, "修改关键字")))
	box.add_child(_flag_list("标签", "card_tag", item.get("tags", []),
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["tags"], v, "修改标签")))
	var extras := HBoxContainer.new()
	extras.add_child(W.tap(W.check("X 费", bool(item.get("has_x_cost", false))), func(c):
		c.toggled.connect(func(on): db.set_field(schema, CFDesign.KIND_CARD, index, ["has_x_cost"], on, "修改 X 费"))))
	extras.add_child(W.tap(W.check("不在卡牌库显示", not bool((item.get("flags", {}) as Dictionary).get("show_in_card_library", true))), func(c):
		c.toggled.connect(func(on): db.set_field(schema, CFDesign.KIND_CARD, index, ["flags", "show_in_card_library"], not on, "修改显示"))))
	extras.add_child(W.tap(W.check("提供格挡（GainsBlock）", bool((item.get("flags", {}) as Dictionary).get("gains_block", false))), func(c):
		c.toggled.connect(func(on): db.set_field(schema, CFDesign.KIND_CARD, index, ["flags", "gains_block"], on, "修改 GainsBlock"))))
	box.add_child(extras)
	var sc := HBoxContainer.new()
	sc.add_theme_constant_override("separation", 8)
	sc.add_child(_spin_block("星能费用（-1 = 无）", float(item.get("star_cost", -1)), -1, 9, 1,
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["star_cost"], int(v), "修改星能费用")))
	sc.add_child(_spin_block("最大升级等级", float(item.get("max_upgrade_level", 1)), 1, 5, 1,
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["max_upgrade_level"], int(v), "修改升级等级")))
	box.add_child(sc)
	return W.wrap(box)


func _section_relic_attributes(index: int, item: Dictionary) -> Control:
	var box := W.panel("③ 遗物属性")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_opt_block("稀有度", _role_items("relic_rarity"), String(item.get("rarity", "")),
			func(v): db.set_field(schema, CFDesign.KIND_RELIC, index, ["rarity"], v, "修改稀有度")))
	row.add_child(_spin_block("计数器周期", float(item.get("counter_period", 3)), 1, 99, 1,
			func(v): db.set_field(schema, CFDesign.KIND_RELIC, index, ["counter_period"], int(v), "修改计数器")))
	box.add_child(row)
	var flags := HBoxContainer.new()
	flags.add_child(W.tap(W.check("可堆叠", bool(item.get("stackable", false))), func(c):
		c.toggled.connect(func(on): db.set_field(schema, CFDesign.KIND_RELIC, index, ["stackable"], on, "修改堆叠"))))
	flags.add_child(W.tap(W.check("显示计数器", bool(item.get("show_counter", false))), func(c):
		c.toggled.connect(func(on): db.set_field(schema, CFDesign.KIND_RELIC, index, ["show_counter"], on, "修改计数器显示"))))
	box.add_child(flags)
	return W.wrap(box)


func _section_vars(index: int, item: Dictionary) -> Control:
	var box := W.panel("④ 动态变量（CanonicalVars）")
	box.add_child(W.dim("变量给描述里的 {变量名} 提供数值；也可作为效果数值的来源。", 11))
	var vars: Array = item.get("vars", [])
	if vars.is_empty():
		box.add_child(W.dim("（无变量）", 11))
	for i in vars.size():
		box.add_child(_var_row(i, vars[i], item))
	var add := W.button("＋ 添加变量")
	add.pressed.connect(func():
		db.begin_action()
		vars.append(CFDesign.new_var("Value%d" % (vars.size() + 1), "Int", "IntVar", 0.0))
		db.commit_action("新增变量"))
	box.add_child(add)
	return W.wrap(box)


func _var_row(var_index: int, v: Dictionary, item: Dictionary) -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 6)

	# The row edits `vars[k]`. Which slot that actually is can shift (normalize
	# may rebuild an entry, and the user can delete a row above), so the slot is
	# re-resolved from the row's own identity on every write.
	var vpath := db._var_field_path(item, var_index, v)
	var vat: int = int(vpath[1])

	# 名称 — 即时写入（描述里的 {变量名} 要跟着刷新），但保持焦点时不被重建。
	var name_field := _live_field("名称", String(v.get("name", "")),
			["vars", vat, "name"], "变量名")
	cols.add_child(name_field)

	var type_items: Array = []
	for d in schema.dynamic_var_types:
		var t := String(d["type"])
		var g := String(d.get("generic", ""))
		# 类型名后面附上中文说明，方便对照（PowerVar<XPower> 显示为
		# `PowerVar<VulnerablePower>（易伤）`）。
		var lbl := t + ("<%s>" % g if not g.is_empty() else "")
		if t == "PowerVar" and not g.is_empty():
			lbl += "（%s）" % schema.power_title(g, "zhs")
		type_items.append({"value": "%s|%s" % [t, g], "label": lbl})
	if type_items.is_empty():
		type_items = [{"value": "IntVar|", "label": "IntVar"}, {"value": "DamageVar|", "label": "DamageVar"}]
	type_items.sort_custom(func(a, b): return String(a["label"]) < String(b["label"]))
	var current_type := "%s|%s" % [v.get("type", ""), v.get("generic", "")]
	var type_box := _compact("类型", W.option(type_items, current_type))
	cols.add_child(type_box)
	_pick_option(type_box, func(o):
		# 整条写入：normalize 会让 kind 与 type 相互推导，type 单独写会被
		# 邻居字段的写入盖掉 —— 这正是「类型只能保存几秒」的原因。
		o.item_selected.connect(func(i):
			var parts := String((o.get_item_metadata(i) as Dictionary)["value"]).split("|")
			_write_var(item, var_index, v, {
				"type": parts[0],
				"generic": parts[1] if parts.size() > 1 else "",
			}, "修改变量类型")))
	cols.add_child(_spin_block("基础值", float(v.get("base", 0.0)), -999, 999, 1.0,
			func(val): _write_var(item, var_index, v, {"base": float(val)}, "修改变量值")))
	cols.add_child(_spin_block("升级增量", float(v.get("upgrade_delta", 0.0)), -999, 999, 1.0,
			func(val): _write_var(item, var_index, v, {"upgrade_delta": float(val)}, "修改升级增量")))
	outer.add_child(cols)

	# 生成代码提示：变量名会怎样出现在 C# 里。
	# 变量名不是 `DynamicVarSet` 的属性（该集合是封闭的），所以多数情况下会走
	# 字符串索引器；这里把它显式画出来，用户才知道为什么有时是
	# `base.DynamicVars.Vulnerable`、有时是 `base.DynamicVars["power"]`。
	var vname := String(v.get("name", "")).strip_edges()
	if not vname.is_empty():
		var expr := schema.dynvar_expr(vname)
		var how := "属性" if expr.contains(".DynamicVars.") else "索引器"
		outer.add_child(W.label("生成：%s　（%s）" % [expr, how], W.TEXT_DIM, 11))

	var del := W.button("删除变量")
	del.pressed.connect(func():
		db.begin_action()
		(item["vars"] as Array).remove_at(var_index)
		db.commit_action("删除变量")
		schedule_rebuild())
	outer.add_child(del)
	return outer


## Write a full `vars` entry, merging `overrides` into the row's current values.
##
## Deliberately a whole-entry write: `CFDesign.normalize` derives `kind` from
## `type` and re-derives `value_prop` from `kind`, so writing one field at a
## time lets each write undo the previous one. That is what made the variable
## name and type appear to "stop saving after a few seconds".
func _write_var(item: Dictionary, var_index: int, v: Dictionary, overrides: Dictionary,
		action: String) -> void:
	var payload := CFDesignDb.var_payload(v, overrides)
	var path := db._var_field_path(item, var_index, payload)
	_write(path, payload, action)
	schedule_rebuild()


## Find the single option button inside a `_compact()` block and hand it to `cb`.
func _pick_option(block: Control, cb: Callable) -> void:
	for n in block.get_children():
		if n is OptionButton:
			cb.call(n)
			return

func _section_effects(kind: String, index: int, item: Dictionary, trigger_index: int) -> Control:
	var box := W.panel("⑤ 效果（打出时依次执行）" if trigger_index < 0 else "效果")
	box.add_child(W.dim("效果按顺序执行；每条可用「固定次数 / 按变量 / 按 X 费」循环，并可加条件。", 11))
	var effects: Array = item.get("effects", []) if trigger_index < 0 \
			else (item["triggers"][trigger_index] as Dictionary).get("effects", [])
	if effects.is_empty():
		box.add_child(W.dim("（还没有效果）", 11))
	for i in effects.size():
		box.add_child(_effect_editor(kind, index, trigger_index, i, effects[i]))
	box.add_child(_add_effect_row(kind, index, trigger_index))
	return W.wrap(box)


func _add_effect_row(kind: String, index: int, trigger_index: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var menu := MenuButton.new()
	menu.text = "＋ 添加效果"
	menu.focus_mode = Control.FOCUS_NONE
	menu.add_theme_stylebox_override("normal", W.sb(W.PANEL_2, 6, 1))
	menu.add_theme_stylebox_override("hover", W.sb(W.BORDER, 6, 1))
	menu.add_theme_color_override("font_color", W.TEXT)
	menu.add_theme_font_size_override("font_size", W.fs(13))
	var popup := menu.get_popup()
	for group in CFEffects.grouped_kinds():
		popup.add_separator(String(group["group"]))
		for k in group["kinds"]:
			popup.add_item(String(k["label"]), CFEffects.KINDS.find(k))
	popup.id_pressed.connect(func(id):
		var k: Dictionary = CFEffects.KINDS[id]
		db.add_effect(schema, kind, index, trigger_index, String(k["id"]))
		schedule_rebuild())
	row.add_child(menu)

	# Two one-click shortcuts for the most common shape: a card that hurts the
	# enemy *and* helps you. Both add a `apply_power` effect and set its target
	# in one go, so you do not have to add an effect and then hunt for the right
	# entry in the target dropdown. The chosen power is a sensible starting point
	# (易伤 for the enemy, 力量 for you) that you can change right below.
	row.add_child(_quick_effect_button(kind, index, trigger_index,
			"＋ 给敌人上 debuff", "all_enemies", "VulnerablePower"))
	row.add_child(_quick_effect_button(kind, index, trigger_index,
			"＋ 给自己上 buff", "self", "StrengthPower"))
	return row


## Add an `apply_power` effect pre-set to `target` (and, when the scanned schema
## knows it, `power`). Falls back gracefully when the game data does not expose
## the named power, so the button is never a dead end.
func _quick_effect_button(kind: String, index: int, trigger_index: int,
		text: String, target: String, power: String) -> Button:
	var b := W.button(text)
	b.pressed.connect(func():
		var eff_index := db.add_effect(schema, kind, index, trigger_index, "apply_power")
		if eff_index < 0:
			schedule_rebuild()
			return
		var base: Array = ["effects"] if trigger_index < 0 else ["triggers", trigger_index, "effects"]
		# Only pick a power the schema actually scanned; otherwise leave the
		# default so the effect stays valid and the user picks one.
		# `schema.powers` holds dictionaries (`class_name`, `entry`, …), not bare
		# strings — reading it as strings throws "Nonexistent 'String' constructor".
		var known := false
		for p in schema.powers:
			if p is Dictionary and String((p as Dictionary).get("class_name", "")) == power:
				known = true
				break
		var fields := {"target": target}
		if known:
			fields["power"] = power
		for k in fields.keys():
			var p: Array = base.duplicate()
			p.append(eff_index)
			p.append(k)
			db.set_field(schema, kind, index, p, fields[k], text.replace("＋ ", ""))
		schedule_rebuild())
	return b


func _effect_editor(kind: String, index: int, trigger_index: int, eff_index: int, e: Dictionary) -> Control:
	var outer := PanelContainer.new()
	outer.add_theme_stylebox_override("panel", W.sb(W.PANEL_2, 6, 1))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	outer.add_child(box)

	var path_head: Array = ["effects", eff_index]
	var write: Callable = func(field: String, value: Variant, action: String):
		var merged: Array = ["effects"] if trigger_index < 0 else ["triggers", trigger_index, "effects"]
		var p: Array = merged.duplicate()
		p.append(eff_index)
		p.append(field)
		db.set_field(schema, kind, index, p, value, action)

	var spec := CFEffects.kind_by_id(String(e.get("kind", "")))

	# Header: label + target + enable + delete
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(W.label(CFEffects.kind_label(String(e.get("kind", ""))), W.ACCENT, 13))
	# **Show the target here, not only inside the body.** A card that debuffs the
	# enemy *and* buffs you is the normal case for this tool, and with three or
	# four effects stacked you otherwise have to open each one to remember which
	# way it points. The colour also tells you at a glance: green = you, red =
	# the enemy, blue = neutral.
	var head_tgt := String(e.get("target", ""))
	if head_tgt.is_empty():
		head_tgt = String(spec.get("default_target", "self"))
	var tgt_chip := W.dim("→ %s" % CFEffects.target_label(head_tgt), 11)
	tgt_chip.add_theme_color_override("font_color", _target_color(head_tgt))
	head.add_child(tgt_chip)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var en := W.check("启用", bool(e.get("enabled", true)))
	en.toggled.connect(func(on):
		write.call("enabled", on, "启用/禁用效果")
		schedule_rebuild())
	head.add_child(en)
	var up := W.button("↑")
	up.pressed.connect(func(): _move_effect(kind, index, trigger_index, eff_index, -1))
	var dn := W.button("↓")
	dn.pressed.connect(func(): _move_effect(kind, index, trigger_index, eff_index, 1))
	head.add_child(up)
	head.add_child(dn)
	var del := W.button("✕")
	del.pressed.connect(func():
		db.remove_effect(kind, index, trigger_index, eff_index)
		schedule_rebuild())
	head.add_child(del)
	box.add_child(head)

	box.add_child(W.dim(String(spec.get("help", "")), 11))
	var needs := String(spec.get("needs", "none"))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)

	# Target
	var target_items: Array = []
	var bindings: Dictionary = {}
	if trigger_index >= 0:
		bindings = (item_triggers(db.selected_item())[trigger_index] as Dictionary).get("params", {})
	for p in bindings.keys():
		target_items.append({"value": String(p), "label": "触发参数 %s" % String(p)})
	for t in CFEffects.TARGETS:
		target_items.append({"value": String(t["id"]), "label": String(t["label"])})
	if trigger_index < 0:
		target_items = target_items.filter(func(t): return String(t["value"]) != "self" or true)
	var cur_target := String(e.get("target", ""))
	if cur_target.is_empty():
		cur_target = String(spec.get("default_target", "self"))
	grid.add_child(W.label("目标", W.TEXT_DIM, 12))
	grid.add_child(W.tap(W.option(target_items, cur_target), func(o):
		o.item_selected.connect(func(i):
			write.call("target", String((o.get_item_metadata(i) as Dictionary)["value"]), "修改目标")
			schedule_rebuild())))

	# Value
	if needs.contains("value"):
		grid.add_child(W.label("数值", W.TEXT_DIM, 12))
		var vrow := HBoxContainer.new()
		vrow.add_theme_constant_override("separation", 4)
		var is_var := bool(e.get("amount_is_var", false))
		var var_items: Array = [{"value": "", "label": "（直接填数值）"}]
		for v in db.selected_item().get("vars", []):
			var_items.append({"value": String(v["name"]), "label": "变量 %s" % String(v["name"])})
		var picker := W.option(var_items, String(e.get("amount_var", "")))
		picker.disabled = not is_var
		var amount := W.spin(float(e.get("amount", 0.0)), -999, 999, 1.0)
		amount.editable = not is_var
		picker.item_selected.connect(func(i):
			write.call("amount_var", String((picker.get_item_metadata(i) as Dictionary)["value"]), "修改数值来源")
			schedule_rebuild())
		amount.value_changed.connect(func(val):
			write.call("amount", float(val), "修改数值")
			schedule_rebuild())
		vrow.add_child(amount)
		vrow.add_child(picker)
		var usevar := W.check("用变量", is_var)
		usevar.toggled.connect(func(on):
			write.call("amount_is_var", on, "切换数值来源")
			schedule_rebuild())
		vrow.add_child(usevar)
		grid.add_child(vrow)

	# Hits
	if String(e.get("kind", "")) in ["damage", "damage_direct"]:
		grid.add_child(W.label("段数", W.TEXT_DIM, 12))
		grid.add_child(W.tap(W.spin(float(e.get("hits", 1)), 1, 99, 1), func(s):
			s.value_changed.connect(func(val):
				write.call("hits", int(val), "修改段数")
				schedule_rebuild())))

	# ValueProp
	if needs.contains("value") and String(spec.get("id", "")) in ["damage_direct"]:
		grid.add_child(W.label("伤害属性", W.TEXT_DIM, 12))
		grid.add_child(W.tap(W.option(_role_items("value_prop"), String(e.get("value_prop", ""))), func(o):
			o.item_selected.connect(func(i):
				write.call("value_prop", String((o.get_item_metadata(i) as Dictionary)["value"]), "修改 ValueProp"))))

	# Power —— 256 个候选，必须可搜。用 search_option 而不是普通下拉：
	# 搜索框只重建自己的结果行，不会触发整栏编辑器的重建（那会夺走焦点）。
	# 列表放在固定高度的滚动容器里，留空时可用滚轮逐个浏览全部 256 项。
	if needs.contains("power"):
		var cur_power := String(e.get("power", ""))
		var power_hint := "Power"
		if not cur_power.is_empty():
			power_hint = "Power（%s）" % schema.power_title(cur_power, "zhs")
		grid.add_child(W.label(power_hint, W.TEXT_DIM, 12))
		var powers := CFEffects.power_options(schema)
		if powers.is_empty():
			powers = [{"value": "", "label": "（未扫描到 Power）"}]
		var picker := W.search_option(powers, cur_power)
		W.on_search_option_picked(picker, func(item):
			write.call("power", String((item as Dictionary).get("value", "")), "修改 Power")
			schedule_rebuild())
		grid.add_child(picker)
		var power_error := schema.power_error(cur_power)
		if not power_error.is_empty():
			box.add_child(W.dim(power_error, 12))
		if bool(e.get("amount_is_var", false)):
			for variable in db.items_for(kind)[index].get("vars", []):
				if variable.get("name") == e.get("amount_var") and variable.get("type") == "PowerVar" and variable.get("generic") != cur_power:
					var expected := String(variable.get("generic", ""))
					box.add_child(W.dim("变量只提供层数：当前变量表示 %s，实际施加的是 %s。" % [schema.power_title(expected, "zhs"), schema.power_title(cur_power, "zhs")], 12))
					if schema.power_error(expected).is_empty():
						var fix := W.button("使用变量对应状态（%s）" % schema.power_title(expected, "zhs"))
						fix.pressed.connect(func():
							write.call("power", expected, "对齐状态与变量")
							schedule_rebuild())
						box.add_child(fix)

	# Keyword
	if needs.contains("keyword"):
		grid.add_child(W.label("关键字", W.TEXT_DIM, 12))
		grid.add_child(W.tap(W.option(_role_items("card_keyword"), String(e.get("keyword", ""))), func(o):
			o.item_selected.connect(func(i):
				write.call("keyword", String((o.get_item_metadata(i) as Dictionary)["value"]), "修改关键字"))))

	# Generate-card target
	if String(e.get("kind", "")) == "generate_card":
		grid.add_child(W.label("生成哪张牌", W.TEXT_DIM, 12))
		var card_items: Array = []
		for c in schema.existing_cards:
			card_items.append({"value": String(c["entry"]), "label": "%s  (%s)" % [String(c["entry"]), String(c["class_name"])]})
		for c in db.cards:
			card_items.append({"value": String(c["entry"]), "label": "%s  (本 Mod)" % String(c["entry"])})
		card_items.sort_custom(func(a, b): return String(a["label"]) < String(b["label"]))
		grid.add_child(W.tap(W.option(card_items, String(e.get("card_entry", ""))), func(o):
			o.item_selected.connect(func(i):
				write.call("card_entry", String((o.get_item_metadata(i) as Dictionary)["value"]), "修改生成牌"))))
		grid.add_child(W.label("目标牌堆", W.TEXT_DIM, 12))
		grid.add_child(W.tap(W.option(_role_items("pile_type"), String(e.get("pile", ""))), func(o):
			o.item_selected.connect(func(i):
				write.call("pile", String((o.get_item_metadata(i) as Dictionary)["value"]), "修改牌堆"))))
		grid.add_child(W.label("位置", W.TEXT_DIM, 12))
		grid.add_child(W.tap(W.option(_role_items("pile_position"), String(e.get("position", ""))), func(o):
			o.item_selected.connect(func(i):
				write.call("position", String((o.get_item_metadata(i) as Dictionary)["value"]), "修改位置"))))

	# Loop
	var loop: Dictionary = e.get("loop", {})
	grid.add_child(W.label("循环", W.TEXT_DIM, 12))
	var lrow := HBoxContainer.new()
	lrow.add_theme_constant_override("separation", 4)
	# Names of the variables declared on the item being edited. A "repeat by
	# variable" loop compiles to `base.DynamicVars.<Name>.IntValue`, so the name
	# must both be non-empty and actually exist — otherwise the exported C# does
	# not compile (CS0029/CS0103 for an empty name, CS1061 for a missing one).
	var var_names: Array = []
	for v in db.selected_item().get("vars", []):
		var vn := String((v as Dictionary).get("name", "")).strip_edges()
		if not vn.is_empty() and not var_names.has(vn):
			var_names.append(vn)

	var loop_items: Array = []
	for m in CFEffects.LOOP_MODES:
		loop_items.append({"value": String(m["id"]), "label": String(m["label"])})
	var loop_pick := W.option(loop_items, String(loop.get("mode", "none")))
	loop_pick.item_selected.connect(func(i):
		var new_mode := String((loop_pick.get_item_metadata(i) as Dictionary)["value"])
		var keep_var := String(loop.get("var", "")).strip_edges()
		# Switching INTO "var" mode must never leave the variable empty: the
		# previous value is "" for a fresh effect, which is exactly how the
		# broken `DynamicVars..IntValue` got exported. Adopt a declared variable
		# when the current one is unset or no longer exists.
		if new_mode == "var" and (keep_var.is_empty() or not var_names.has(keep_var)):
			keep_var = String(var_names[0]) if not var_names.is_empty() else ""
		write.call("loop", {"mode": new_mode,
			"count": int(loop.get("count", 1)), "var": keep_var}, "修改循环")
		schedule_rebuild())
	lrow.add_child(loop_pick)
	var mode := String(loop.get("mode", "none"))
	if mode == "count":
		lrow.add_child(W.tap(W.spin(float(loop.get("count", 1)), 0, 99, 1), func(s):
			s.value_changed.connect(func(val):
				write.call("loop", {"mode": "count", "count": int(val), "var": ""}, "修改循环次数"))))
	elif mode == "var":
		var vopts: Array = []
		for vn in var_names:
			vopts.append({"value": String(vn), "label": String(vn)})
		var cur_var := String(loop.get("var", "")).strip_edges()
		if vopts.is_empty():
			# Nothing to choose from — say so instead of showing an empty box.
			vopts.append({"value": "", "label": "（请先在上方添加数值）"})
		lrow.add_child(W.tap(W.option(vopts, cur_var), func(o):
			o.item_selected.connect(func(i):
				write.call("loop", {"mode": "var", "count": 1,
					"var": String((o.get_item_metadata(i) as Dictionary)["value"])}, "修改循环变量"))))
	grid.add_child(lrow)

	# Condition
	# 条件的右值原本是个数字微调框，于是设计文件里存的是 JSON 浮点数，而生成器
	# 用 String(2.0) 去转它 —— GDScript 里没有这个转换，直接抛
	# 「Invalid call. Nonexistent 'String' constructor」并生成 `if ()`，牌编不过。
	# 现在左右值都是文本框：既可以是数字，也可以是另一个变量的名字。
	var cond: Dictionary = e.get("condition", {})
	grid.add_child(W.label("条件", W.TEXT_DIM, 12))
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 4)
	var cond_on := W.check("满足条件才执行", String(cond.get("mode", "none")) != "none")
	cond_on.toggled.connect(func(on):
		write.call("condition", {"mode": "expr" if on else "none",
			"left": str(cond.get("left", "")), "op": str(cond.get("op", ">=")),
			"right": str(cond.get("right", ""))}, "修改条件")
		schedule_rebuild())
	crow.add_child(cond_on)
	if String(cond.get("mode", "none")) != "none":
		var lopts := W.field(str(cond.get("left", "")))
		lopts.custom_minimum_size.x = 70
		lopts.placeholder_text = "左值"
		lopts.text_changed.connect(func(t):
			write.call("condition", {"mode": "expr", "left": t,
				"op": str(cond.get("op", ">=")), "right": str(cond.get("right", ""))}, "修改条件"))
		crow.add_child(lopts)
		var op_items: Array = []
		for o in CFEffects.CONDITION_OPS:
			op_items.append({"value": o, "label": o})
		crow.add_child(W.tap(W.option(op_items, str(cond.get("op", ">="))), func(o):
			o.item_selected.connect(func(i):
				write.call("condition", {"mode": "expr", "left": str(cond.get("left", "")),
					"op": String((o.get_item_metadata(i) as Dictionary)["value"]),
					"right": str(cond.get("right", ""))}, "修改条件"))))
		var ropts := W.field(str(cond.get("right", "")))
		ropts.custom_minimum_size.x = 70
		ropts.placeholder_text = "右值 / 变量名"
		ropts.text_changed.connect(func(t):
			write.call("condition", {"mode": "expr", "left": str(cond.get("left", "")),
				"op": str(cond.get("op", ">=")), "right": t}, "修改条件"))
		crow.add_child(ropts)
	grid.add_child(crow)

	return outer


## Colour for the target chip in an effect header.
##   green = points at you (a buff), red = points at the enemy (a debuff),
##   blue = neutral / player-chosen at play time.
## Green/red here are *semantic* (helpful vs harmful), not the stock-market
## red-up/green-down convention — the tool is about what an effect does, and
## mixing the two would make "→ 自己" look like a loss.
func _target_color(target_id: String) -> Color:
	match CFEffects.target_side(target_id):
		"self":
			return W.OK
		"enemy":
			return W.ERR
		_:
			return W.INFO


func item_triggers(item: Dictionary) -> Array:
	return item.get("triggers", []) if item.get("kind", "") == CFDesign.KIND_RELIC else []


func _move_effect(kind: String, index: int, trigger_index: int, eff_index: int, delta: int) -> void:
	var list := db.items_for(kind)
	if index < 0 or index >= list.size():
		return
	var target: Array = (list[index] as Dictionary).get("effects", []) if trigger_index < 0 \
			else ((list[index]["triggers"][trigger_index] as Dictionary).get("effects", []))
	var to := eff_index + delta
	if to < 0 or to >= target.size():
		return
	db.begin_action()
	var item: Variant = target[eff_index]
	target.remove_at(eff_index)
	target.insert(to, item)
	db.commit_action("调整效果顺序")
	schedule_rebuild()
	schedule_rebuild()


# ---------------------------------------------------------------------------
# Triggers (relics only)
# ---------------------------------------------------------------------------

func _section_triggers(index: int, item: Dictionary) -> Control:
	var box := W.panel("⑤ 触发时机")
	var usable := schema.usable_hooks()
	var triggers: Array = item.get("triggers", [])
	if usable.is_empty():
		box.add_child(W.dim("⚠ 未扫描到可用触发时机，请先「重新扫描游戏」。", 11))
	for i in triggers.size():
		box.add_child(_trigger_editor(index, i, triggers[i], usable))
	var add := W.button("＋ 添加触发时机")
	add.pressed.connect(func():
		db.add_trigger(schema, index)
		schedule_rebuild())
	box.add_child(add)
	return W.wrap(box)


func _trigger_editor(index: int, t_index: int, t: Dictionary, usable: Array) -> Control:
	var outer := PanelContainer.new()
	outer.add_theme_stylebox_override("panel", W.sb(W.PANEL_2, 6, 1))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	outer.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(W.label("触发 %d" % (t_index + 1), W.ACCENT, 13))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var del := W.button("✕")
	del.pressed.connect(func():
		db.remove_trigger(index, t_index)
		schedule_rebuild())
	head.add_child(del)
	box.add_child(head)

	var hook_items: Array = []
	for h in usable:
		var hook_name := String(h["name"])
		hook_items.append({"value": hook_name, "label": schema.hook_label(hook_name)})
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(W.tap(W.option(hook_items, String(t.get("hook", ""))), func(o):
		o.item_selected.connect(func(i):
			var hook := String((o.get_item_metadata(i) as Dictionary)["value"])
			db.begin_action()
			t["hook"] = hook
			t["params"] = CFDesign._default_param_bindings(schema, hook)
			db.commit_action("修改触发时机")
			schedule_rebuild())))
	var charge: Dictionary = t.get("charge", {})
	var charge_items: Array = []
	for c in CFEffects.CHARGE_MODES:
		charge_items.append({"value": String(c["id"]), "label": String(c["label"])})
	row.add_child(W.tap(W.option(charge_items, String(charge.get("mode", "always"))), func(o):
		o.item_selected.connect(func(i):
			var mode := String((o.get_item_metadata(i) as Dictionary)["value"])
			db.set_field(schema, CFDesign.KIND_RELIC, index, ["triggers", t_index, "charge"],
				{"mode": mode, "n": int(charge.get("n", 1))}, "修改触发次数")
			schedule_rebuild())))
	if String(charge.get("mode", "always")) != "always":
		row.add_child(W.tap(W.spin(float(charge.get("n", 1)), 1, 99, 1), func(s):
			s.value_changed.connect(func(val):
				db.set_field(schema, CFDesign.KIND_RELIC, index, ["triggers", t_index, "charge"],
					{"mode": String(charge.get("mode", "always")), "n": int(val)}, "修改触发次数"))))
	box.add_child(row)

	var hook_def := schema.hook(String(t.get("hook", "")))
	if not hook_def.is_empty():
		box.add_child(W.dim("签名：%s" % String(hook_def.get("signature", "")), 11))
		if not String(hook_def.get("doc", "")).is_empty():
			var doc := W.dim(String(hook_def["doc"]).substr(0, 260), 11)
			box.add_child(doc)

	# Effects of this trigger.
	var effects: Array = t.get("effects", [])
	if effects.is_empty():
		box.add_child(W.dim("（这个触发时机还没有效果）", 11))
	for i in effects.size():
		box.add_child(_effect_editor(CFDesign.KIND_RELIC, index, t_index, i, effects[i]))
	box.add_child(_add_effect_row(CFDesign.KIND_RELIC, index, t_index))
	return outer


# ---------------------------------------------------------------------------
# Upgrade & starting content
# ---------------------------------------------------------------------------

func _section_upgrade(index: int, item: Dictionary) -> Control:
	var box := W.panel("⑥ 升级")
	var up: Dictionary = item.get("upgrade", {})
	box.add_child(_spin_block("费用变化（负数 = 降费）", float(up.get("cost_delta", 0)), -3, 3, 1,
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["upgrade", "cost_delta"], int(v), "修改升级费用")))
	box.add_child(W.dim("变量升级增量在上面的「动态变量」里设置。", 11))
	box.add_child(_flag_list("升级后移除关键字", "card_keyword", up.get("keywords_remove", []),
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["upgrade", "keywords_remove"], v, "修改升级移除")))
	box.add_child(_flag_list("升级后添加关键字", "card_keyword", up.get("keywords_add", []),
			func(v): db.set_field(schema, CFDesign.KIND_CARD, index, ["upgrade", "keywords_add"], v, "修改升级添加")))
	var ov: Dictionary = up.get("text_override", {})
	var cur := String((ov.get("zhs", {}) as Dictionary).get("description", ""))
	box.add_child(W.dim("升级后描述（留空则沿用原描述 + {IfUpgraded:…} 规则）", 11))
	box.add_child(_live_textarea(cur, 52, ["upgrade", "text_override", "zhs", "description"]))
	return W.wrap(box)


func _section_deck_hint(kind: String) -> String:
	if kind == CFDesign.KIND_CARD:
		return "把这张牌加入角色开局。完整自定义牌组请到「能力 / 角色库 → 初始牌组」编辑。"
	return "让某个角色开局就携带这件遗物（导出时生成 Harmony 补丁）。"


func _section_deck(kind: String, index: int, item: Dictionary) -> Control:
	var box := W.panel("⑦ 开局注入")
	var deck: Dictionary = item.get("deck", {})
	box.add_child(W.dim(_section_deck_hint(kind), 11))
	var targets := schema.deck_targets(db.custom_characters)
	if targets.is_empty():
		box.add_child(W.dim("⚠ 未扫描到角色，请先「重新扫描游戏」。", 11))
		return W.wrap(box)
	if kind == CFDesign.KIND_CARD:
		for character in db.custom_characters:
			if character.get("id") == deck.get("character") and character.has("starting_deck"):
				box.add_child(W.dim("此角色已启用完整自定义初始牌组，本处的旧开局注入不再追加。", 12))
				var edit := W.button("编辑该角色初始牌组")
				edit.pressed.connect(func(): _open_starting_deck_editor(String(character["id"])))
				box.add_child(edit)
	var enable := W.check("启用开局注入", bool(deck.get("enabled", false)))
	enable.toggled.connect(func(on):
		db.set_field(schema, kind, index, ["deck", "enabled"], on, "切换开局注入")
		schedule_rebuild())
	box.add_child(enable)
	if bool(deck.get("enabled", false)):
		var opts: Array = []
		for t in targets:
			opts.append({"value": String(t["class_name"]), "label": "%s  (%s)" % [String(t["title"]), String(t["class_name"])]})
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(W.tap(W.option(opts, String(deck.get("character", ""))), func(o):
			o.item_selected.connect(func(i):
				db.set_field(schema, kind, index, ["deck", "character"],
					String((o.get_item_metadata(i) as Dictionary)["value"]), "选择角色")
				schedule_rebuild())))
		if kind == CFDesign.KIND_CARD:
			row.add_child(W.tap(W.spin(float(deck.get("copies", 1)), 1, 10, 1), func(s):
				s.value_changed.connect(func(val):
					db.set_field(schema, kind, index, ["deck", "copies"], int(val), "修改份数"))))
		box.add_child(row)
		box.add_child(W.dim("注意：角色的卡池必须是「%s」自己的池，否则这张牌不会出现在该角色的奖励里。"
				% String(deck.get("character", "?")), 11))
	return W.wrap(box)


# ---------------------------------------------------------------------------
# Rail: preview, validation, simulation, export
# ---------------------------------------------------------------------------

func _build_rail() -> void:
	_clear_column(_rail_box)
	_rail_box.add_child(_rail_preview())
	_rail_box.add_child(_rail_issues())
	_rail_box.add_child(_rail_export())


func _rail_preview() -> Control:
	var box := W.panel("预览")
	var item := db.selected_item()
	if item.is_empty():
		box.add_child(W.dim("（未选择内容）", 11))
		return W.wrap(box)
	var kind := String(item.get("kind", CFDesign.KIND_CARD))

	# A simple card / relic face rendered with the tool's own theme.
	var face := PanelContainer.new()
	face.add_theme_stylebox_override("panel", W.sb(W.PANEL_2, 8, 1))
	var fb := VBoxContainer.new()
	fb.add_theme_constant_override("separation", 4)
	face.add_child(fb)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	if kind == CFDesign.KIND_CARD:
		var cost := str(item.get("cost", 0))
		if bool(item.get("has_x_cost", false)):
			cost = "X"
		title_row.add_child(W.tag(" %s " % cost, W.ACCENT))
	title_row.add_child(W.label(CFDesign.render_title(item, "zhs"), W.TEXT, 15))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(sp)
	title_row.add_child(W.dim(String(item.get("rarity", "")), 11))
	fb.add_child(title_row)
	if kind == CFDesign.KIND_CARD:
		fb.add_child(W.dim("%s · %s · %s" % [item.get("type", ""), item.get("pool", ""), item.get("target", "")], 11))
	else:
		fb.add_child(W.dim("%s · %s" % [item.get("rarity", ""), item.get("pool", "")], 11))
	var desc := CFDesign.render_description(item, "zhs", false)
	# Same overflow hazard as the issue list: a card description is arbitrary
	# length. A plain label would set the rail's minimum width to the whole
	# unwrapped sentence and shove the window off-screen.
	fb.add_child(W.wrap_label(String(desc["plain"]), W.TEXT, 13, _rail_wrap_width(), 5))
	if kind == CFDesign.KIND_CARD:
		var up_desc := CFDesign.render_description(item, "zhs", true)
		if String(up_desc["plain"]) != String(desc["plain"]):
			fb.add_child(W.dim("升级后：%s" % String(up_desc["plain"]), 11))
		if not (item.get("keywords", []) as Array).is_empty():
			fb.add_child(W.dim("关键字：%s" % ", ".join(item["keywords"]), 11))
	box.add_child(face)

	# Simulation
	var sim: Dictionary
	if kind == CFDesign.KIND_CARD:
		sim = CFEffects.simulate_card(item)
	else:
		sim = CFEffects.simulate_relic(item, 0)
	var totals: Dictionary = sim["totals"]
	var parts: Array = []
	if absf(float(totals["damage"])) > 0.001:
		parts.append("伤害 %.0f" % totals["damage"])
	if absf(float(totals["block"])) > 0.001:
		parts.append("格挡 %.0f" % totals["block"])
	if absf(float(totals["drawn"])) > 0.001:
		parts.append("抽牌 %.0f" % totals["drawn"])
	if absf(float(totals["discarded"])) > 0.001:
		parts.append("弃牌 %.0f" % totals["discarded"])
	if absf(float(totals["energy_delta"])) > 0.001:
		parts.append("能量 %+.0f" % totals["energy_delta"])
	if absf(float(totals["heal"])) > 0.001:
		parts.append("治疗 %.0f" % totals["heal"])
	if absf(float(totals["exhausted"])) > 0.001:
		parts.append("消耗 %.0f" % totals["exhausted"])
	if absf(float(totals["generated"])) > 0.001:
		parts.append("生成 %.0f" % totals["generated"])
	for pname in (totals["powers"] as Dictionary).keys():
		parts.append("%s %+.0f" % [pname, totals["powers"][pname]])
	var summary := "估算：无直接数值变化" if parts.is_empty() else "估算：%s" % " · ".join(parts)
	box.add_child(W.wrap_label(summary, W.OK, 12, _rail_wrap_width(), 3))
	for note in sim["notes"]:
		box.add_child(W.dim("· %s" % note, 11))
	return W.wrap(box)


func _rail_issues() -> Control:
	var box := W.panel("校验")
	var item := db.selected_item()
	if item.is_empty():
		return W.wrap(box)
	var issues := CFDesign.validate(schema, item, db.all_items(), db.custom_characters)
	var counts := CFDesign.issue_counts(issues)
	box.add_child(W.label("✕ %d 个错误 · ! %d 个警告 · i %d 条提示"
			% [counts["errors"], counts["warnings"], counts["infos"]],
			W.ERR if int(counts["errors"]) > 0 else (W.WARN if int(counts["warnings"]) > 0 else W.OK), 12))
	# Issue text is arbitrarily long and interpolates user-entered names, so it
	# MUST wrap at the rail's width. A plain `label()` has no `autowrap_mode` and
	# contributes its full single-line width as a hard minimum; because the
	# columns disable horizontal scrolling, that minimum propagates up through
	# the rail panel into the split and pushes the whole window off-screen.
	# `wrap_label` supplies a real width floor + a line cap, so one long message
	# wraps onto a second line instead of widening the layout.
	for issue in issues:
		box.add_child(W.wrap_label("· %s" % CFDesign.describe_issue(issue),
				W.severvity_color(String(issue["severity"])), 11, _rail_wrap_width(), 4))
	return W.wrap(box)


## Width the rail's wrapping labels should wrap at.
##
## Derived from the live rail panel width (`_col_rail_w`, which
## `_apply_window_size()` may have shrunk) minus the panel/scroll padding —
## rather than hard-coding 360, which would over-wrap or under-wrap the moment
## the window is narrower than the design size.
func _rail_wrap_width() -> int:
	var panel_w := _col_rail_w
	if not _col_panels.is_empty() and _col_panels.size() >= 3 \
			and is_instance_valid(_col_panels[2]):
		panel_w = int(_col_panels[2].custom_minimum_size.x)
	return maxi(120, panel_w - 56)


## Same idea for the editor column, used by the ②文字 placeholder check.
func _editor_wrap_width() -> int:
	var panel_w := _col_editor_w
	if not _col_panels.is_empty() and _col_panels.size() >= 2 \
			and is_instance_valid(_col_panels[1]):
		panel_w = int(_col_panels[1].custom_minimum_size.x)
	return maxi(160, panel_w - 56)


func _rail_export() -> Control:
	var box := W.panel("导出为 Mod")
	box.add_child(W.dim("生成完整的 Mod 目录（manifest + C# 源码 + csproj + 本地化 pck + 构建脚本）。", 11))
	var out_row := HBoxContainer.new()
	out_row.add_theme_constant_override("separation", 6)
	var out_edit := W.field(String(settings.get("last_export_dir", CFPaths.EXPORT_DIR)))
	out_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	out_row.add_child(out_edit)
	box.add_child(out_row)
	var force := W.check("忽略错误强制导出", false)
	box.add_child(force)
	var run := W.button("预检", false)
	run.pressed.connect(func():
		var r := CFExporter.preflight(schema, db)
		_say(_format_preflight(r), W.ERR if bool(r["blocking"]) else W.OK))
	var export := W.button("导出 Mod", true)
	export.pressed.connect(func(): _do_export(out_edit.text, force.button_pressed))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(run)
	row.add_child(export)
	box.add_child(row)
	var verify := W.button("编译验证（dotnet build）")
	verify.pressed.connect(func(): _do_verify(out_edit.text, force.button_pressed))
	box.add_child(verify)
	var build := W.button("导出并编译", true)
	build.tooltip_text = "先导出，再用真实游戏程序集编译并把 DLL 放到 Mod 根目录"
	build.pressed.connect(func(): _do_export_and_build(out_edit.text, force.button_pressed))
	box.add_child(build)
	box.add_child(W.dim("导出后到 mods 目录执行 build.ps1 即可编译并安装。「编译验证」会就地跑一次 dotnet build，用真实游戏程序集检查能不能编过。", 11))
	return W.wrap(box)


func _format_preflight(r: Dictionary) -> String:
	var lines: Array = []
	lines.append("预检：%d 错误 / %d 警告 / %d 提示" % [
		(r["errors"] as Array).size(), (r["warnings"] as Array).size(), (r["infos"] as Array).size()])
	for e in (r["errors"] as Array).slice(0, 5):
		lines.append("✕ %s" % e)
	for w in (r["warnings"] as Array).slice(0, 3):
		lines.append("! %s" % w)
	return "\n".join(lines)


func _do_export(out_dir: String, force: bool, reveal: bool = true) -> Dictionary:
	if _build_in_progress:
		return {"ok": false, "error": "正在编译，请等待完成。"}
	_last_mod_dir = ""
	var r := CFExporter.export(schema, db, {
		"out_dir": ProjectSettings.globalize_path(out_dir) if out_dir.begins_with("res://") else out_dir,
		"force": force,
		"include_pck": true,
		"game_assembly": String(settings.get("game_assembly", "")),
		"godotsharp_dir": String(settings.get("godotsharp_dir", "")),
		"game_dir": String(settings.get("game_dir", "")),
		"compat_target": String(settings.get("compat_target", "")),
		"ritsulib_dir": String(settings.get("ritsulib_dir", "")),
	})
	if bool(r["ok"]):
		settings["last_export_dir"] = out_dir
		_last_mod_dir = String(r["mod_dir"])
		_save_settings()
		var msg := "导出成功：%s（%s 个文件）" % [r["mod_dir"], r.get("files_written", 0)]
		if bool(r.get("needs_build", false)):
			# Critical: the folder now has <id>.json + <id>.pck but no <id>.dll.
			# Copying it to mods/ as-is yields a mod that loads but adds nothing.
			msg += "\n\n⚠ 还不能直接拷进 mods！\n" \
					+ "现在只有 json + pck，没有 dll —— 游戏会报 " \
					+ "“declares that it should load an assembly, but no assembly … was found”，" \
					+ "卡牌不会出现。\n" \
					+ "请先在本文件夹运行 build.cmd（或点右边「编译验证」）生成 <id>.dll，" \
					+ "再把整个文件夹拷到 mods/。"
			_say(msg, W.WARN)
		else:
			_say(msg, W.OK)
		# Open the folder in the OS file manager so the result is immediately visible.
		if reveal:
			_reveal_export(String(r["mod_dir"]))
	else:
		var lines: Array = [String(r.get("error", "未知错误"))]
		for e in (r["errors"] as Array).slice(0, 4):
			lines.append("✕ %s" % e)
		_say("\n".join(lines), W.ERR)
	return r


func _reveal_export(mod_dir: String) -> void:
	OS.shell_show_in_file_manager(mod_dir)


## Both build actions compile a fresh snapshot at the requested destination.
func _do_verify(out_dir: String, force: bool) -> void:
	await _do_export_and_build(out_dir, force)


func _do_export_and_build(out_dir: String, force: bool) -> void:
	if _build_in_progress:
		_say("正在编译，请等待完成。", W.ACCENT)
		return
	var exported := _do_export(out_dir, force, false)
	if not bool(exported.get("ok", false)):
		return
	var mod_dir := String(exported["mod_dir"])
	_build_in_progress = true
	_say("正在编译并整理可安装 Mod：%s ……" % mod_dir, W.ACCENT)
	var result := await _run_build(mod_dir)
	_build_in_progress = false
	if bool(result.get("ok", false)):
		_say("导出并编译完成：%s\nDLL 已就位，可将此文件夹复制到游戏 mods 文件夹。" % mod_dir, W.OK)
		_reveal_export(mod_dir)
	else:
		var shown: Array[String] = [String(result.get("error", "编译失败"))]
		# Keep the first compiler diagnostics; the summary at the end often
		# contains only counts and elapsed time.
		for line in String(result.get("log", "")).split("\n"):
			if "error " in line.to_lower() and not line in shown:
				shown.append(line.strip_edges())
				if shown.size() >= 5:
					break
		if not String(result.get("log_path", "")).is_empty():
			shown.append("完整日志：" + String(result["log_path"]))
		_say("导出成功，但编译失败：\n" + "\n".join(shown), W.ERR)


func _run_build(mod_dir: String) -> Dictionary:
	_build_thread = Thread.new()
	var started := _build_thread.start(CFExporter.verify_build.bind(mod_dir))
	if started != OK:
		_build_thread = null
		return {"ok": false, "error": "无法启动编译任务：%d" % started}
	while _build_thread.is_alive():
		await get_tree().create_timer(0.1).timeout
	var result: Dictionary = _build_thread.wait_to_finish()
	_build_thread = null
	return result


func _exit_tree() -> void:
	if _build_thread != null and _build_thread.is_started():
		_build_thread.wait_to_finish()
	_build_thread = null


# ---------------------------------------------------------------------------
# New / open / save
# ---------------------------------------------------------------------------

func _add_new(relic: bool) -> void:
	var base := "NewRelic" if relic else "NewCard"
	var id := base
	var n := 1
	while db.find_index_by_id(CFDesign.KIND_RELIC if relic else CFDesign.KIND_CARD, id) >= 0:
		n += 1
		id = "%s%d" % [base, n]
	var item := CFDesign.new_relic(schema) if relic else CFDesign.new_card(schema)
	item["id"] = id
	item["text"]["zhs"]["title"] = id
	item["text"]["eng"]["title"] = id
	db.add_item(schema, CFDesign.KIND_RELIC if relic else CFDesign.KIND_CARD, item)
	schedule_rebuild()


## Reusable authored content lives in CFDesignDb and is serialized alongside
## cards/relics. Ability recipes are captured from the existing effect editor,
## so they use the same verified effect and variable model as exported cards.
func _open_authoring_library() -> void:
	var win := AcceptDialog.new()
	win.title = "能力配方与自定义角色"
	win.size = Vector2i(760, 640)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	win.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	var library_scroll := ScrollContainer.new()
	library_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(library_scroll)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	library_scroll.add_child(root)
	root.add_child(W.label("可复用能力配方", W.ACCENT, 16))
	root.add_child(W.dim("从当前选中的卡牌保存变量和效果组合；点击配方可追加到当前卡牌。", 11))
	var ability_form := HBoxContainer.new()
	var ability_id := W.field("")
	ability_id.placeholder_text = "能力标识，例如 DrawAndBlock"
	ability_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ability_title := W.field("")
	ability_title.placeholder_text = "显示名称"
	ability_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ability_form.add_child(ability_id)
	ability_form.add_child(ability_title)
	var save_ability := W.button("保存当前卡牌效果")
	save_ability.pressed.connect(func():
		var item := db.selected_item()
		if item.is_empty() or String(item.get("kind", "")) != CFDesign.KIND_CARD:
			_say("请先选择一张卡牌，再保存能力配方。", W.WARN)
			return
		var id := ability_id.text.strip_edges()
		if id.is_empty():
			_say("请填写能力标识。", W.WARN)
			return
		db.save_ability_from_item(item, id, ability_title.text.strip_edges() if not ability_title.text.strip_edges().is_empty() else id)
		_persist_authoring_library()
		_rebuild_authoring_library(root, win, ability_id, ability_title)
	)
	ability_form.add_child(save_ability)
	root.add_child(ability_form)
	var ability_rows := VBoxContainer.new()
	ability_rows.name = "AbilityRows"
	root.add_child(ability_rows)
	root.add_child(HSeparator.new())
	root.add_child(W.label("自定义角色与卡池", W.ACCENT, 16))
	root.add_child(W.dim("新角色默认独立创建，使用可替换的锻造木偶模型，不继承原版角色机制或专属内容。创建后配置自己的初始牌组和奖励卡池。", 11))
	var character_form := GridContainer.new()
	character_form.columns = 2
	var character_id := W.field("")
	character_id.name = "NewCharacterId"
	character_id.placeholder_text = "角色标识，例如 MoonWitch"
	var character_name := W.field("")
	character_name.name = "NewCharacterName"
	character_name.placeholder_text = "角色名称"
	var card_pool := W.field("")
	card_pool.placeholder_text = "角色卡池标识，例如 MoonWitchCardPool"
	var relic_pool := W.field("")
	relic_pool.placeholder_text = "角色遗物池标识，例如 MoonWitchRelicPool"
	for pair in [["角色标识", character_id], ["角色名称", character_name], ["卡牌池", card_pool], ["遗物池", relic_pool]]:
		character_form.add_child(W.label(pair[0], W.TEXT_DIM, 12))
		character_form.add_child(pair[1])
	root.add_child(character_form)
	var save_character := W.button("保存角色与两个池")
	save_character.pressed.connect(func():
		var id := character_id.text.strip_edges()
		if not CFIds.is_valid_cs_identifier(id):
			_say("角色标识须为有效的英文字母/数字/下划线名称，不能以数字开头。", W.WARN)
			return
		var card_id := card_pool.text.strip_edges()
		var relic_id := relic_pool.text.strip_edges()
		var character_record := {"id": id, "name": character_name.text.strip_edges(),
			"namespace": "%s.Models.Characters" % db.mod_id,
			"card_pool": card_id if not card_id.is_empty() else id + "CardPool",
			"relic_pool": relic_id if not relic_id.is_empty() else id + "RelicPool",
			"created": Time.get_datetime_string_from_system()}
		character_record = CFCharacters.new_character(character_record)
		if CFCharacters.contains(db, id):
			_say("该角色已存在，请点击列表中的「编辑角色」。", W.WARN)
			return
		var probe := CFDesignDb.new()
		probe.load_from_json(db.to_json())
		probe.custom_characters.append(CFCharacters.normalized(character_record))
		var validation := CFCharacters.validate(schema, probe, false)
		if not validation["errors"].is_empty():
			_say("\n".join(validation["errors"]), W.WARN)
			return
		var imported := CFCharacterVisuals.import_bundle(character_record["visuals"])
		if not imported["ok"]:
			_say(imported["error"], W.WARN)
			return
		character_record["visuals"] = imported["visuals"]
		db.add_custom_character(character_record)
		_persist_authoring_library()
		_rebuild_authoring_library(root, win, ability_id, ability_title)
	)
	root.add_child(save_character)
	var character_rows := VBoxContainer.new()
	character_rows.name = "CharacterRows"
	root.add_child(character_rows)
	_rebuild_authoring_library(root, win, ability_id, ability_title)
	add_child(win)
	win.confirmed.connect(func(): win.queue_free())
	win.canceled.connect(func(): win.queue_free())
	win.popup_centered()


func _rebuild_authoring_library(root: VBoxContainer, win: AcceptDialog, ability_id: LineEdit, ability_title: LineEdit) -> void:
	var ability_rows := root.find_child("AbilityRows", true, false) as VBoxContainer
	var character_rows := root.find_child("CharacterRows", true, false) as VBoxContainer
	if ability_rows == null or character_rows == null:
		return
	for child in ability_rows.get_children():
		child.queue_free()
	for child in character_rows.get_children():
		child.queue_free()
	for i in db.abilities.size():
		var ability: Dictionary = db.abilities[i]
		var row := HBoxContainer.new()
		row.add_child(W.dim("%s · %d 个变量 · %d 个效果" % [ability.get("title", ability.get("id", "")), ability.get("vars", []).size(), ability.get("effects", []).size()], 12))
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(spacer)
		var apply := W.button("应用到当前卡牌")
		var ability_index := i
		apply.pressed.connect(func():
			if db.selected_kind != CFDesign.KIND_CARD:
				_say("请选择卡牌后应用能力配方。", W.WARN)
				return
			if db.apply_ability_to_card(db.selected_index, ability_index):
				schedule_rebuild()
				_say("能力配方已追加到当前卡牌。", W.OK)
		)
		row.add_child(apply)
		var remove := W.button("删除")
		remove.pressed.connect(func():
			var next := db.abilities.duplicate(true)
			next.remove_at(ability_index)
			db.mutate("删除能力配方", func(): db.abilities = next)
			_persist_authoring_library()
			_rebuild_authoring_library(root, win, ability_id, ability_title)
		)
		row.add_child(remove)
		ability_rows.add_child(row)
	if db.abilities.is_empty():
		ability_rows.add_child(W.dim("尚无保存的能力配方。", 11))
	for i in db.custom_characters.size():
		var character: Dictionary = db.custom_characters[i]
		var row := HBoxContainer.new()
		var label := W.dim("%s · %s\n卡牌池：%s · 遗物池：%s" % [character.get("name", ""), character.get("id", ""), character.get("card_pool", ""), character.get("relic_pool", "")], 12)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var edit := W.button("编辑角色")
		edit.pressed.connect(func():
			_open_character_editor(String(character["id"]), func():
				_rebuild_authoring_library(root, win, ability_id, ability_title), win))
		row.add_child(edit)
		var starter := W.button("初始牌组")
		starter.pressed.connect(func(): _open_starting_deck_editor(String(character["id"]), win))
		row.add_child(starter)
		var dialogues := W.button("先古之民对话")
		dialogues.pressed.connect(func(): CFAncientDialogueEditor.open(self, String(character["id"]), win))
		row.add_child(dialogues)
		var remove := W.button("删除角色及池")
		remove.pressed.connect(func():
			_confirm_remove_character(String(character["id"]), win, func():
				_rebuild_authoring_library(root, win, ability_id, ability_title)))
		row.add_child(remove)
		character_rows.add_child(row)
	if db.custom_characters.is_empty():
		character_rows.add_child(W.dim("尚无自定义角色。", 11))


func _open_character_editor(character_id: String, on_saved: Callable, owner_window: Window = null) -> void:
	var original: Dictionary = {}
	for character in db.custom_characters:
		if String(character.get("id", "")) == character_id:
			original = character
	if original.is_empty():
		return
	var draft := CFCharacters.normalized(original)
	var win := AcceptDialog.new()
	win.title = "角色设置 · %s" % character_id
	win.size = Vector2i(700, 640)
	win.get_ok_button().text = "保存角色"
	win.dialog_hide_on_ok = false
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	win.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 9)
	scroll.add_child(box)
	if CFIds.is_valid_cs_identifier(character_id):
		box.add_child(W.dim("标识 %s 保持不变，用于游戏存档。修改名称不影响卡池关联。" % character_id, 12))
	else:
		box.add_child(W.dim("旧标识 %s：纯数字可直接导出，也可改为英文字母开头的名称，例如 Hero111。其它非法标识需要修复。开局关联会同步更新。" % character_id, 12))
		var repair_id := W.field(character_id)
		repair_id.name = "Character_id"
		repair_id.text_changed.connect(func(value): draft["id"] = value.strip_edges())
		box.add_child(repair_id)
	for pair in [["card_pool", "旧卡牌池标识"], ["relic_pool", "旧遗物池标识"]]:
		var key := String(pair[0])
		if not CFIds.is_valid_cs_identifier(String(draft[key])):
			box.add_child(W.dim("%s不合法，请填写英文字母开头的名称；已有内容的池关联会一起更新。" % pair[1], 12))
			var input := W.field(String(draft[key]))
			input.name = "Character_" + key
			input.text_changed.connect(func(value): draft[key] = value.strip_edges())
			box.add_child(input)
	for pair in [["name", "中文名称"], ["name_eng", "英文名称"], ["description", "中文介绍"], ["description_eng", "英文介绍"]]:
		var key := String(pair[0])
		box.add_child(W.label(String(pair[1]), W.TEXT_DIM, 12))
		if key.begins_with("description"):
			var input := TextEdit.new()
			input.name = "Character_" + key
			input.custom_minimum_size.y = 64
			input.text = String(draft[key])
			input.text_changed.connect(func(): draft[key] = input.text)
			box.add_child(input)
		else:
			var input := W.field(String(draft[key]))
			input.name = "Character_" + key
			input.text_changed.connect(func(value): draft[key] = value)
			box.add_child(input)
	var templates: Array = []
	for template in CFCharacters.TEMPLATES:
		var titles := {"Ironclad": "铁甲战士", "Silent": "静默猎手", "Regent": "储君", "Necrobinder": "亡灵契约师", "Defect": "故障机器人"}
		templates.append({"value": template, "label": "%s（%s）" % [titles[template], template]})
	var template_option := _bind_option("旧版原版外观（改用自制模型后转为独立角色）", templates, String(draft["template"]), func(value): draft["template"] = value)
	template_option.name = "CharacterTemplate"
	box.add_child(template_option)
	var model_box := VBoxContainer.new()
	box.add_child(model_box)
	_build_character_visual_editor(model_box, draft, win)
	for pair in [["starting_hp", "初始生命", 1], ["starting_gold", "初始金币", 0], ["max_energy", "每回合能量", 1]]:
		var key := String(pair[0])
		box.add_child(_spin_block(String(pair[1]), float(draft[key]), int(pair[2]), 9999, 1, func(value): draft[key] = int(value)))
	for pair in [["use_base_deck", "保留模板起始牌组（再追加自定义开局卡）"], ["use_base_relics", "保留模板初始遗物（再追加自定义开局遗物）"], ["include_base_cards", "奖励卡池加入模板卡牌"], ["include_base_relics", "遗物池加入模板遗物"]]:
		var key := String(pair[0])
		var check := CheckBox.new()
		check.name = "CharacterLegacy_" + key
		check.text = String(pair[1])
		check.button_pressed = bool(draft[key])
		check.toggled.connect(func(value): draft[key] = value)
		if key == "use_base_deck" and draft.has("starting_deck"):
			check.disabled = true
			check.text = "已使用完整自定义初始牌组（在角色库的「初始牌组」中编辑）"
		box.add_child(check)
	var help := W.dim("专属卡池：%s\n专属遗物池：%s\n在卡牌/遗物编辑器中选择此池，再勾选「开局注入」可加入起始内容。也可在角色库编辑完整初始牌组。\n角色可先保存为草稿；导出前需配置初始牌组和奖励卡牌。\n导出角色需要完整的 RitsuLib 0.6.7，可在「设置」指定位置。" % [draft["card_pool"], draft["relic_pool"]], 12)
	help.max_lines_visible = -1
	box.add_child(help)
	var error_label := W.dim("", 12)
	box.add_child(error_label)
	win.confirmed.connect(func():
		var probe := CFDesignDb.new()
		probe.load_from_json(db.to_json())
		probe.update_custom_character(character_id, draft)
		var validation := CFCharacters.validate(schema, probe, false)
		if not validation["errors"].is_empty():
			error_label.text = "\n".join(validation["errors"])
			return
		var imported := CFCharacterVisuals.import_bundle(draft["visuals"])
		if not imported["ok"]:
			error_label.text = imported["error"]
			return
		draft["visuals"] = imported["visuals"]
		db.update_custom_character(character_id, draft)
		_persist_authoring_library()
		on_saved.call()
		win.queue_free())
	win.canceled.connect(func(): win.queue_free())
	if owner_window != null:
		owner_window.add_child(win)
	else:
		add_child(win)
	win.popup_centered()


func _sync_character_independence(box: VBoxContainer, draft: Dictionary) -> void:
	var independent := CFCharacters.is_independent(draft)
	var template := box.get_parent().find_child("CharacterTemplate", true, false)
	if template != null:
		template.visible = not independent
	for key in ["use_base_deck", "use_base_relics", "include_base_cards", "include_base_relics"]:
		var legacy := box.get_parent().find_child("CharacterLegacy_" + key, true, false)
		if legacy != null:
			legacy.visible = not independent
		if independent:
			draft[key] = false
	if independent:
		draft["independent"] = true


func _build_character_visual_editor(box: VBoxContainer, draft: Dictionary, win: Window) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()
	var v: Dictionary = draft["visuals"]
	var custom := CheckBox.new()
	custom.name = "CharacterCustomModel"
	custom.text = "使用独立角色与自制模型"
	custom.button_pressed = v["mode"] == "custom"
	custom.disabled = CFCharacters.is_independent(draft)
	custom.toggled.connect(func(value):
		v["mode"] = "custom" if value else "template"
		_build_character_visual_editor.call_deferred(box, draft, win))
	box.add_child(custom)
	var example := Button.new()
	example.text = "使用自制模型示例：锻造木偶"
	example.name = "CharacterModelExample"
	example.pressed.connect(func():
		draft["visuals"] = CFCharacterVisuals.example()
		_build_character_visual_editor.call_deferred(box, draft, win))
	box.add_child(example)
	_sync_character_independence.call_deferred(box, draft)
	if v["mode"] != "custom":
		return
	var hint := W.dim("独立角色：基础充能球栏位为 0，不默认启用星星计数或原版专属内容。生命、能量、初始牌组和两个池由你配置。\n模型文件夹包含战斗场景和相关素材；保存时复制到本地素材库。选填素材留空时使用制作器自带素材。", 12)
	hint.max_lines_visible = -1
	box.add_child(hint)
	var folder := W.field(String(v["asset_root"]))
	folder.name = "CharacterModelRoot"
	folder.placeholder_text = "选择独立模型文件夹 / Godot 模型工程目录"
	folder.text_changed.connect(func(value): v["asset_root"] = value.strip_edges().replace("\\", "/"))
	box.add_child(folder)
	var browse := Button.new()
	browse.text = "选择模型文件夹…"
	browse.pressed.connect(func():
		var dlg := FileDialog.new()
		dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		dlg.access = FileDialog.ACCESS_FILESYSTEM
		dlg.title = "选择包含 battle.tscn 和素材的模型文件夹"
		dlg.size = Vector2i(850, 600)
		dlg.dir_selected.connect(func(path):
			v["asset_root"] = path.replace("\\", "/")
			folder.text = v["asset_root"]
			dlg.queue_free())
		dlg.canceled.connect(func(): dlg.queue_free())
		win.add_child(dlg)
		dlg.popup_centered())
	box.add_child(browse)
	for pair in [["battle_scene", "战斗模型 .tscn（必填）"], ["merchant_scene", "商店模型 .tscn（选填）"],
		["rest_scene", "休息处模型 .tscn（选填）"], ["icon", "头像 / 地图图标（选填图片）"],
		["select_icon", "选角按钮立绘（选填图片）"], ["select_background", "选角背景（选填图片）"]]:
		var key := String(pair[0])
		box.add_child(W.label(String(pair[1]), W.TEXT_DIM, 12))
		var input := W.field(String(v[key]))
		input.name = "CharacterModel_" + key
		input.placeholder_text = "相对模型文件夹的路径；选填项留空使用制作器自带素材"
		input.text_changed.connect(func(value): v[key] = value.strip_edges().replace("\\", "/"))
		box.add_child(input)
	var animated := CheckBox.new()
	animated.name = "CharacterModelAnimated"
	animated.text = "连接战斗动画（AnimationPlayer / AnimatedSprite2D）；静态模型可关闭"
	animated.button_pressed = bool(v["animated"])
	animated.toggled.connect(func(value): v["animated"] = value)
	box.add_child(animated)
	for pair in [["idle", "待机"], ["attack", "攻击"], ["cast", "施放"], ["hit", "受击"], ["dead", "死亡"]]:
		var key := String(pair[0])
		box.add_child(W.label(String(pair[1]) + "动画名称", W.TEXT_DIM, 12))
		var input := W.field(String(v[key]))
		input.name = "CharacterModel_" + key
		input.text_changed.connect(func(value): v[key] = value.strip_edges())
		box.add_child(input)
	for pair in [["attack_delay", "攻击效果延迟（秒）"], ["cast_delay", "施放效果延迟（秒）"]]:
		var key := String(pair[0])
		box.add_child(_spin_block(String(pair[1]), float(v[key]), 0, 10, 0.05, func(value): v[key] = value))
	var help := W.dim("模型支持无脚本 Godot 场景、图片及着色器；动画使用待机/攻击/施放/受击/死亡映射。战斗根节点需包含 Visuals、Bounds、CenterPos、IntentPos。导出时会检查节点、动画和素材依赖。详细制作说明见 CHARACTER_MODELS.md。", 12)
	help.max_lines_visible = -1
	box.add_child(help)


func _persist_authoring_library() -> void:
	var path := String(settings.get("last_design_file", ""))
	if path.is_empty():
		path = ProjectSettings.globalize_path("res://designs/main.json")
	var result := db.save_to_file(path)
	if bool(result.get("ok", false)):
		settings["last_design_file"] = path
		_save_settings()
		_say("能力 / 角色资料已保存：%s" % path, W.OK)
	else:
		_say("资料已加入当前设计，但保存失败：%s" % result.get("error", "未知错误"), W.ERR)


func _open_design() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.add_filter("*.json", "设计文件")
	dlg.current_dir = ProjectSettings.globalize_path(CFPaths.DESIGN_DIR)
	dlg.size = Vector2i(900, 620)
	dlg.file_selected.connect(func(path):
		var res := db.load_from_file(path)
		if bool(res["ok"]):
			settings["last_design_file"] = path
			_save_settings()
			_say("已打开 %s" % path)
			# Land on something so the editor is never blank after opening a file.
			_select_first_item()
			schedule_rebuild()
		else:
			_say("打开失败：%s" % res["error"], W.ERR)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


func _save_design(ask: bool) -> void:
	var path := String(settings.get("last_design_file", ""))
	if ask or path.is_empty():
		var dlg := FileDialog.new()
		dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		dlg.access = FileDialog.ACCESS_FILESYSTEM
		dlg.add_filter("*.json", "设计文件")
		dlg.current_dir = ProjectSettings.globalize_path(CFPaths.DESIGN_DIR)
		dlg.current_file = "main.json"
		dlg.size = Vector2i(900, 620)
		dlg.file_selected.connect(func(p):
			settings["last_design_file"] = p
			_save_to(p)
			dlg.queue_free())
		dlg.canceled.connect(func(): dlg.queue_free())
		add_child(dlg)
		dlg.popup_centered()
		return
	_save_to(path)


func _save_to(path: String) -> void:
	var res := db.save_to_file(path)
	if bool(res["ok"]):
		settings["last_design_file"] = path
		_save_settings()
		_say("已保存到 %s" % path, W.OK)
	else:
		_say("保存失败：%s" % res["error"], W.ERR)


func _open_settings() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "设置"
	dlg.size = Vector2i(760, 440)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	dlg.add_child(box)
	box.add_child(W.dim("请填写完整路径；每项说明了需要定位的文件或文件夹。", 11))
	box.add_child(W.dim("解包数据目录：填写文件夹路径；文件夹内必须有 src/Core/ 和 localization/。", 12))
	box.add_child(_setting_field("source_root", "D:/.../解包文件/.godot", "目标：文件夹，内含 src/Core 与 localization"))
	box.add_child(W.dim("游戏安装目录：填写文件夹路径；文件夹内必须有 data_sts2_windows_x86_64/。", 12))
	box.add_child(_setting_field("game_dir", "E:/steam/steamapps/common/Slay the Spire 2", "目标：游戏安装文件夹"))
	box.add_child(W.dim("游戏程序集：填写文件 sts2.dll 的完整路径；留空则自动推导。", 12))
	box.add_child(_setting_field("game_assembly", "D:/.../data_sts2_windows_x86_64/sts2.dll", "目标：文件 sts2.dll"))
	box.add_child(W.dim("GodotSharp：填写文件夹路径；文件夹内必须有 GodotSharp.dll。", 12))
	box.add_child(_setting_field("godotsharp_dir", "D:/.../GodotSharp", "目标：文件夹，内含 GodotSharp.dll"))
	box.add_child(W.dim("角色导出依赖：完整的 RitsuLib 0.6.7 文件夹，内含 compat/、shared/ 和 RitsuLib.References.props。", 12))
	box.add_child(_setting_field("ritsulib_dir", "D:/.../RitsuLib", "目标：完整 RitsuLib 文件夹"))
	dlg.confirmed.connect(func():
		if not _save_settings():
			return
		_say("设置已保存。")
		_do_scan()
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


func _setting_field(key: String, placeholder: String, hint: String = "") -> Control:
	var e := W.field(String(settings.get(key, "")))
	e.placeholder_text = placeholder
	e.tooltip_text = hint
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.text_changed.connect(func(t): settings[key] = t)
	return e


func _save_settings() -> bool:
	var err := CFPaths.save_settings(settings)
	if err != OK:
		_say("设置保存失败（%s）：%s" % [error_string(err), ProjectSettings.globalize_path(CFPaths.SETTINGS_PATH)])
	return err == OK


# ---------------------------------------------------------------------------
# Convenience builders
# ---------------------------------------------------------------------------

func _bind_edit(title: String, value: String, cb: Callable) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(W.label(title, W.TEXT_DIM, 12))
	var e := W.field(value)
	# Connect only AFTER add_child(). Adding a LineEdit to the tree can make
	# Godot emit text/focus notifications during the parent's own child-setup
	# phase; if our handler already ran at that moment it would call back into
	# the editor and rebuild it mid-setup, which the engine rejects with
	# "Parent node is busy setting up children".
	box.add_child(e)
	e.text_submitted.connect(func(t): cb.call(t))
	e.focus_exited.connect(func(): cb.call(e.text))
	return box


# ---------------------------------------------------------------------------
# Live-edit binders
# ---------------------------------------------------------------------------
#
# These three are the ones the user *types into*, so they follow a different
# contract from the rest of the editors:
#
#   * every keystroke is written straight into the design, but the write does
#     not push an undo step — the whole typing session collapses into one when
#     the field loses focus;
#   * the field publishes its path to the database while it has focus, so the
#     rebuild pass knows to leave it alone. Without that, the first keystroke
#     rebuilt the column, freed the LineEdit the user was typing into and the
#     caret was gone a second later.
#
# Rebuilds still happen for everything *around* the focused field (preview,
# validation, list) — the focused widget is simply skipped.

## A text field that keeps focus and survives rebuilds. `path` is the design
## path it edits, e.g. ["text","zhs","description"].
##
## The focus-keeping widget is looked up in `_live_widgets`, which maps a design
## path to the *control* rendering it. It must not be read back through
## `db.get_field()`: that returns the stored *value* (a String), never a
## Control, so the reuse branch silently never fired and the field was rebuilt
## on every keystroke — the caret went with it.
func _live_field(title: String, value: String, path: Array, placeholder: String = "") -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(W.label(title, W.TEXT_DIM, 12))
	if bool(db.is_editing(path)):
		# The user is typing here right now: reuse the live widget verbatim.
		# Rebuilding it (or even just re-assigning `text`) would drop the caret
		# to the start of the string.
		var le := _limbo_take(path) as LineEdit
		if le != null:
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			box.add_child(le)
			return box
	var e := W.field(value)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not placeholder.is_empty():
		e.placeholder_text = placeholder
	box.add_child(e)
	_live_widgets[str(path)] = e
	# Read `e.text` rather than taking the signal argument: `text_changed` passes
	# the new string, but the emitted value can be stale when several edits land
	# in one frame, and the widget is the source of truth.
	e.text_changed.connect(func(_t): _write_quiet(path, e.text))
	e.text_submitted.connect(func(_t):
		_write_quiet(path, e.text)
		_write_depth += 1
		db.flush_edit(path)
		db.clear_edit_path()
		_write_depth -= 1
		_schedule_after_write())
	e.focus_entered.connect(func(): _on_edit_focus_entered(path))
	e.focus_exited.connect(func(): _on_edit_focus_exited(path))
	return box


## A multi-line text area with the same live-edit contract as `_live_field`.
##
## The focused TextEdit is parked in limbo by `_clear_column` while the rest of
## the column is rebuilt, so it is pulled back out here rather than recreated —
## re-assigning `text` (or building a fresh TextEdit) would send the caret back
## to the start of the string, which is the "keeps losing focus after a few
## seconds" the user reported.
func _live_textarea(value: String, height: int, path: Array) -> TextEdit:
	if bool(db.is_editing(path)):
		var te_live := _limbo_take(path) as TextEdit
		if te_live != null:
			te_live.custom_minimum_size.y = height
			return te_live
	var ta := TextEdit.new()
	ta.text = value
	ta.custom_minimum_size.y = height
	ta.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	ta.add_theme_stylebox_override("normal", W.sb(W.BG, 5, 1))
	ta.add_theme_stylebox_override("focus", W.sb(W.BG, 5, 1))
	ta.add_theme_color_override("font_color", W.TEXT)
	ta.add_theme_font_size_override("font_size", W.fs(13))
	_live_widgets[str(path)] = ta
	# `TextEdit.text_changed` takes **no** arguments (unlike
	# `LineEdit.text_changed`, which carries the new text). The lambda must match
	# the signal's real signature: connect a one-argument callable to this
	# zero-argument signal and Godot refuses the call with
	#   "Method expected 1 argument(s), but called with 0"
	# — the connection still reports as intact (`is_connected()` is true and the
	# callable resolves), but the handler never runs, so every keystroke is
	# silently dropped and the text box snaps back to its stored value the moment
	# the field is rebuilt. Reading `ta.text` (rather than a signal argument) also
	# makes the widget the source of truth when several edits land in one frame.
	ta.text_changed.connect(func(): _write_quiet(path, ta.text))
	ta.focus_entered.connect(func(): _on_edit_focus_entered(path))
	ta.focus_exited.connect(func(): _on_edit_focus_exited(path))
	return ta


func _bind_option(title: String, items: Array, selected: String, cb: Callable) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(W.label(title, W.TEXT_DIM, 12))
	var o := W.option(items, selected)
	# Same ordering rule as _bind_edit: connect after the node is in the tree.
	box.add_child(o)
	o.item_selected.connect(func(i): cb.call(String((o.get_item_metadata(i) as Dictionary)["value"])))
	return box


func _compact(title: String, control: Control, _cb: Variant = null) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(W.label(title, W.TEXT_DIM, 11))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(control)
	return box


func _spin_block(title: String, value: float, min_v: float, max_v: float, step: float, cb: Callable) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(W.label(title, W.TEXT_DIM, 11))
	var s := W.spin(value, min_v, max_v, step)
	s.value_changed.connect(func(v): cb.call(v))
	box.add_child(s)
	return box


func _opt_block(title: String, items: Array, selected: String, cb: Callable) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	box.add_child(W.label(title, W.TEXT_DIM, 11))
	var o := W.option(items, selected)
	o.item_selected.connect(func(i): cb.call(String((o.get_item_metadata(i) as Dictionary)["value"])))
	box.add_child(o)
	return box


## Enum-backed option list for a semantic role.
func _role_items(role: String, include_none: bool = false) -> Array:
	var out: Array = []
	var anchor := schema.anchor_for(role)
	for m in schema.members_for_role(role):
		if m == "None" and not include_none:
			continue
		out.append({"value": m, "label": "%s  (%s)" % [schema.label_for(role, m, "zhs"), m]})
	if out.is_empty():
		out.append({"value": "", "label": "（schema 中无此项）"})
	return out


## A wrap of toggle buttons for a list-valued enum field.
func _flag_list(title: String, role: String, selected: Array, cb: Callable) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(W.label(title, W.TEXT_DIM, 11))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	for m in schema.members_for_role(role):
		if m == "None":
			continue
		var on := selected.has(m)
		var b := Button.new()
		b.text = "%s%s" % ["✓ " if on else "", schema.label_for(role, m, "zhs")]
		b.toggle_mode = true
		b.button_pressed = on
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", W.fs(11))
		b.add_theme_color_override("font_color", W.TEXT if on else W.TEXT_DIM)
		b.add_theme_color_override("font_pressed_color", Color("#1b1f2a"))
		b.add_theme_color_override("font_hover_color", W.TEXT)
		b.add_theme_stylebox_override("normal", W.sb(W.PANEL_2, 4, 1))
		b.add_theme_stylebox_override("hover", W.sb(W.BORDER, 4, 1))
		b.add_theme_stylebox_override("pressed", W.sb(W.ACCENT_DIM, 4, 1))
		b.toggled.connect(func(pressed):
			var list: Array = (selected as Array).duplicate()
			if pressed and not list.has(m):
				list.append(m)
			elif not pressed and list.has(m):
				list.erase(m)
			cb.call(list)
			schedule_rebuild())
		flow.add_child(b)
	box.add_child(flow)
	return box


func _open_starting_deck_editor(character_id: String, owner_window: Window = null) -> void:
	var original: Dictionary = {}
	for character in db.custom_characters:
		if character["id"] == character_id:
			original = character
	if original.is_empty():
		return
	var draft := CFCharacters.normalized(original)
	var entries := CFCharacters.initial_deck(schema, db, draft)
	var win := AcceptDialog.new()
	win.title = "初始牌组 · " + String(draft["name"])
	win.size = Vector2i(720, 680)
	win.get_ok_button().text = "保存初始牌组"
	win.dialog_hide_on_ok = false
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	win.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var enabled := W.check("使用自定义完整初始牌组", draft.has("starting_deck"))
	enabled.name = "CustomStartingDeck"
	box.add_child(enabled)
	box.add_child(W.dim("开启后，只使用下面的卡牌和张数，不再追加模板牌组或旧开局注入。关闭后恢复原有开局设置。", 12))
	var content := VBoxContainer.new()
	box.add_child(content)
	content.visible = enabled.button_pressed
	enabled.toggled.connect(func(on): content.visible = on)
	var options: Array = []
	for card in db.cards:
		options.append({"value": "mod:" + String(card["id"]), "label": "%s · %s（自制）" % [card.get("text", {}).get("zhs", {}).get("title", card["id"]), card["id"]]})
	var localized: Variant = JSON.parse_string(CFPaths.read_text(schema.source_root.path_join("localization/zhs/cards.json")))
	var titles: Dictionary = localized if localized is Dictionary else {}
	for card in schema.existing_cards:
		if String(card.get("namespace", "")).ends_with(".Mocks"):
			continue
		var title := String(titles.get(String(card["entry"]) + ".title", card["class_name"]))
		options.append({"value": "game:" + String(card["class_name"]), "label": "%s · %s（原版）" % [title, card["class_name"]]})
	var picker := W.search_option(options, "")
	picker.name = "StartingCardPicker"
	content.add_child(picker)
	var selected := {"value": ""}
	W.on_search_option_picked(picker, func(choice): selected["value"] = choice["value"])
	var rows := VBoxContainer.new()
	rows.name = "StartingDeckRows"
	var total := W.label("", W.ACCENT, 13)
	var refresh := func(): _refresh_starting_deck_rows(rows, entries, options, total)
	var add := W.button("添加卡牌")
	add.pressed.connect(func():
		var value := String(selected["value"])
		if value.is_empty():
			return
		var parts := value.split(":", true, 1)
		var found := false
		for row in entries:
			if row["source"] == parts[0] and row["id"] == parts[1]:
				row["copies"] = mini(99, int(row["copies"]) + 1)
				found = true
		if not found:
			entries.append({"source": parts[0], "id": parts[1], "copies": 1})
		refresh.call())
	content.add_child(add)
	content.add_child(total)
	content.add_child(rows)
	refresh.call()
	var error_label := W.dim("", 12)
	box.add_child(error_label)
	win.confirmed.connect(func():
		if enabled.button_pressed:
			draft["starting_deck"] = entries.duplicate(true)
			var errors := CFCharacters.validate_starting_deck(schema, db, draft)
			if not errors.is_empty():
				error_label.text = "\n".join(errors)
				return
		else:
			draft.erase("starting_deck")
			if not bool(draft["use_base_deck"]) and CFCharacters.starting_items(db.cards, character_id).is_empty():
				error_label.text = "原有开局设置没有任何卡牌，请保留自定义牌组，或先在角色设置中启用模板起始牌组。"
				return
		db.update_custom_character(character_id, draft)
		_persist_authoring_library()
		schedule_rebuild()
		win.queue_free())
	win.canceled.connect(func(): win.queue_free())
	if owner_window != null:
		owner_window.add_child(win)
	else:
		add_child(win)
	win.popup_centered()


func _refresh_starting_deck_rows(rows: VBoxContainer, entries: Array, options: Array, total: Label) -> void:
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
	var update_total := func():
		var count := 0
		for entry in entries:
			count += int(entry["copies"])
		total.text = "初始牌组：%d 张" % count
	update_total.call()
	for i in entries.size():
		var entry: Dictionary = entries[i]
		var value := "%s:%s" % [entry["source"], entry["id"]]
		var title := value + "（未找到）"
		for option in options:
			if option["value"] == value:
				title = option["label"]
		var row := HBoxContainer.new()
		var label := W.label(title, W.TEXT, 12)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		label.tooltip_text = title
		row.add_child(label)
		var copies := W.spin(int(entry["copies"]), 1, 99, 1)
		copies.name = "Copies_" + String(entry["id"])
		copies.value_changed.connect(func(value_):
			entry["copies"] = int(value_)
			update_total.call())
		row.add_child(copies)
		var remove := W.button("移除")
		var at := i
		remove.pressed.connect(func():
			entries.remove_at(at)
			_refresh_starting_deck_rows(rows, entries, options, total))
		row.add_child(remove)
		rows.add_child(row)


func _confirm_remove_character(id: String, owner_window: Window, on_removed: Callable) -> void:
	var character: Dictionary = {}
	for record in db.custom_characters:
		if record["id"] == id:
			character = record
	if character.is_empty():
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "删除角色及两个池"
	dialog.dialog_text = "删除角色「%s」及卡牌池 %s、遗物池 %s。\n其中的自制卡牌和遗物保留，并转入 %s 的模板池。\n该角色的开局关联会解除；可用撤销恢复。" % [character["name"], character["card_pool"], character["relic_pool"], character["template"]]
	if CFCharacters.is_independent(character):
		dialog.dialog_text = "删除独立角色「%s」及两个池。\n自制卡牌保留并转入无色卡池，遗物保留并转入通用遗物池。\n该角色的开局关联会解除；可用撤销恢复。" % character["name"]
	dialog.get_ok_button().text = "删除角色及池，保留内容"
	dialog.confirmed.connect(func():
		if db.remove_custom_character(schema, id):
			_persist_authoring_library()
			schedule_rebuild()
			on_removed.call()
		else:
			_say("删除失败：找不到角色或模板，请重新扫描游戏。", W.ERR)
		dialog.queue_free())
	dialog.canceled.connect(func(): dialog.queue_free())
	owner_window.add_child(dialog)
	dialog.popup_centered()
