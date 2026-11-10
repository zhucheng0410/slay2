@tool
extends SceneTree

## Headless smoke test for the UI layer. Instantiates scenes/main.tscn, drives a
## few interactions and asserts the widgets were created. Any GDScript parse or
## runtime error in ui/*.gd makes this fail loudly.

var _fails := 0
var _checks := 0

## The widget factory module. `ui/app.gd` aliases it as `W` the same way; it is a
## plain preload (not a `class_name`) so every consumer must declare it itself.
const W := preload("res://ui/widgets.gd")


func _ok(cond: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if cond:
		print("  [ok]   %s%s" % [what, ("  " + detail) if detail != "" else ""])
	else:
		_fails += 1
		print("  [FAIL] %s%s" % [what, ("  " + detail) if detail != "" else ""])


func _find(node: Node, pred: Callable) -> Node:
	if pred.call(node):
		return node
	for c in node.get_children():
		var r := _find(c, pred)
		if r != null:
			return r
	return null


func _walk(node: Node, out: Array) -> void:
	out.append(node)
	for c in node.get_children():
		_walk(c, out)


func _all(root: Node) -> Array:
	var a: Array = []
	_walk(root, a)
	return a


func _non_ascii_count(text: String) -> int:
	var n := 0
	for i in text.length():
		if text.unicode_at(i) > 127:
			n += 1
	return n


## Text of every result-row Button inside a `W.search_option` widget.
##
## The widget keeps its rows in the `cf_list` child. Only Buttons are rows — a
## Label there is the "没有匹配的条目" empty state, not a result.
func _search_rows(picker: Node) -> Array:
	var out: Array = []
	var list: Node = picker.get_meta("cf_list", null)
	if list == null:
		return out
	for c in list.get_children():
		if c is Button:
			out.append((c as Button).text)
	return out


## The rightmost column panel (the rail: preview / validation / export).
##
## Identified by `custom_minimum_size.x == 360`, which `_column_panel` callers set
## in `_build_layout`; the mid column is 520 and the list is 300, so this is
## unambiguous. Used to measure the rail's *actual* rendered width, which is what
## catches "a long label widened the column".
func _find_rail_panel(root: Node) -> Control:
	var best: Control = null
	var best_x := -1.0
	for n in _all(root):
		if n is PanelContainer:
			var c := n as Control
			if is_equal_approx(c.custom_minimum_size.x, 360.0):
				# Rightmost wins (there is only one, but be explicit).
				if c.global_position.x > best_x:
					best_x = c.global_position.x
					best = c
	return best


## Does any Label under the picker contain `needle`?
##
## Recursive on purpose: the "当前：…" line sits inside the header row next to the
## ⇕ expand button, so a direct-child scan would miss it and the assertion would
## fail for a layout reason rather than a behaviour one.
func _search_has_text(picker: Node, needle: String) -> bool:
	if picker is Label and (picker as Label).text.contains(needle):
		return true
	for c in picker.get_children():
		if _search_has_text(c, needle):
			return true
	return false


## Type `text` into a text control the way a keyboard does, one character per
## frame, then let the frame settle.
##
## Why the two classes are driven differently
## ------------------------------------------
## `TextEdit` and `LineEdit` do not behave the same under a `--script`
## `SceneTree` run, and the difference is *not* headless-specific (it reproduces
## with a real window too):
##
##   * `TextEdit.text_changed` fires normally — from `insert_text_at_caret()`
##     and from a bare `text` assignment. So for a `TextEdit` we just insert and
##     let the engine raise the signal, exactly like a keyboard would.
##   * `LineEdit.text_changed` **never fires** in this harness, no matter how the
##     text is mutated (`insert_text_at_caret`, `.text = ...`, `set_text`). The
##     widget's text does change; only the notification is missing, because a
##     `--script` run never brings up the input/textarea machinery the LineEdit
##     notifies through. Verified with a standalone probe.
##
## That makes `insert_text_at_caret()` an unusable oracle for `LineEdit`: the
## text would appear in the widget while the bound field stayed empty, and the
## test would "fail" against correct production code.
##
## So for a `LineEdit` we mutate the text and then invoke the handler the widget
## is *actually connected to* — read straight out of
## `text_changed.get_connections()`. That is deliberately not the same as
## `text_changed.emit()`: a hand-emitted signal is routed by *arity*, so it would
## keep a mismatched handler looking alive. Calling the recorded callable with
## the signal's real argument count instead reproduces the exact call the engine
## makes, and a wrong-arity connection (the bug this suite exists to catch) is
## silently skipped by the engine in production — so we skip it here too, which
## is what makes the round-trip assertion fail when the bug is present.
func _type_into(app: Node, path: Array, text: String) -> Control:
	var ctl: Control = _live_control(app, path)
	if ctl == null:
		return null
	ctl.grab_focus()
	# `TextEdit` and `LineEdit` do *not* share a clearing API: `TextEdit` has
	# `delete_selection()`, `LineEdit` has neither `delete_selection()` nor
	# `selection_from`/`selection_to`. Calling the wrong one aborts the coroutine
	# mid-way (the error is not fatal, but the widget keeps its old text while
	# the caller believes it cleared) — and the abandoned coroutine is how this
	# suite used to hang with no output. Clear each class through its own API.
	if ctl is TextEdit:
		var te: TextEdit = ctl
		te.select_all()
		te.delete_selection()
	else:
		var le: LineEdit = ctl
		le.select_all()
		le.delete_text(0, le.text.length())
	await process_frame
	ctl = _live_control(app, path)
	if ctl == null:
		return null
	if ctl is TextEdit:
		for ch in text:
			(ctl as TextEdit).insert_text_at_caret(ch)
			await process_frame
			ctl = _live_control(app, path)
			if ctl == null:
				break
	else:
		# See the note above: the engine will not raise this signal here, so
		# rebuild the text ourselves and replay the recorded handler each step.
		var le: LineEdit = ctl
		for ch in text:
			le.insert_text_at_caret(ch)
			_fire_line_edit_changed(le)
			await process_frame
			ctl = _live_control(app, path)
			if ctl == null:
				break
			le = ctl as LineEdit
			if le == null:
				break
	for _i in 3:
		await process_frame
	return ctl


## The live widget registered for a design path, or null when it is gone.
func _live_control(app: Node, path: Array) -> Control:
	var lw: Dictionary = app.get("_live_widgets")
	if not lw.has(str(path)):
		return null
	var v: Variant = lw[str(path)]
	if v is Control and is_instance_valid(v):
		return v
	return null


## Structural equality for design paths (mirrors the app's own helper).
func _same_path(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


## Replay the handler a `LineEdit` is connected to, the way the engine would.
##
## `LineEdit.text_changed` will not fire under a `--script` run (see the long
## note on `_type_into`), so we look the connection up and call it ourselves.
##
## Two things this deliberately does *not* do:
##   * it does not `emit()` the signal — a hand-emitted signal is dispatched by
##     arity, so a mis-wired handler would be resurrected instead of skipped;
##   * it does not pass the text as an argument to a handler that takes none —
##     `Callable.callv` with the exact argument count the engine uses means a
##     handler whose arity does not match the signal throws the same
##     "Method expected N argument(s)" error the real editor would hit, and the
##     field stays empty. That is what makes this a real regression check.
func _fire_line_edit_changed(le: LineEdit) -> void:
	var args: Array = [le.text]  # LineEdit.text_changed carries the new text.
	for conn in le.text_changed.get_connections():
		var cb: Callable = conn["callable"]
		if not cb.is_valid():
			continue
		cb.callv(args)


## Exporting persists `last_export_dir` into `resources/settings.cfg`. Snapshot the
## file's exact bytes up front and write them back on **every** exit path, so a test
## run can never silently repoint the user's export folder at a throwaway
## `exports/<TestMod>` directory.
var _settings_backup: PackedByteArray = PackedByteArray()
var _settings_path := ""


func _finish(code: int) -> void:
	if not _settings_backup.is_empty():
		var f := FileAccess.open(_settings_path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_settings_backup)
			f.close()
	quit(code)


func _init() -> void:
	print("\n===== CardRelicForge UI smoke test =====")
	_settings_path = ProjectSettings.globalize_path(CFPaths.SETTINGS_PATH)
	if FileAccess.file_exists(_settings_path):
		_settings_backup = FileAccess.get_file_as_bytes(_settings_path)

	# **Give the root viewport a realistic size before anything else.**
	#
	# In `--script` SceneTree mode the root viewport is NOT sized to the window —
	# it defaults to a tiny 100x100 rect. Every layout assertion would then be
	# measuring a 100x100 canvas: the SplitContainer cannot fit its 1196 px of
	# minimum into 100 px, so it expands past the viewport and a list button
	# measures ~1759 px. That is why an earlier version of the "columns fill
	# their scroll viewport" check passed even with the collapse bug injected.
	# Pin the rect to the design size so geometry checks are meaningful.
	var vp_win := root
	if vp_win is Window:
		(vp_win as Window).size = Vector2i(1280, 800)
	await process_frame
	await process_frame

	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		print("  [FAIL] 无法加载 res://scenes/main.tscn")
		print("\n===== FAILED =====")
		_finish(1)
		return
	_ok(true, "加载 main.tscn")

	var app: Node = packed.instantiate()
	if app == null:
		print("  [FAIL] 实例化 main.tscn 失败")
		print("\n===== FAILED =====")
		_finish(1)
		return
	_ok(true, "实例化 main.tscn", app.get_class())

	root.add_child(app)
	_ok(true, "挂载到场景树")

	# Wait for the deferred schema scan and example seeding (a few hundred ms).
	var schema = app.get("schema")
	var db = app.get("db")
	for _i in 200:
		await process_frame
		if schema != null and not String(schema.source_root).is_empty() and db != null and not db.all_items().is_empty():
			break
	await process_frame

	# Tests below assume the documented one-card/one-relic fixture. Never use
	# the author's last opened design as test input (it may have any contents).
	if db != null and schema != null:
		db.load_from_json('{"mod_id":"UITestMod","cards":[],"relics":[]}')
		db.seed_example(schema)
		db.set_selection(CFDesign.KIND_CARD, 0)
		app.call("_rebuild_all")
		await process_frame
		await process_frame

	# ── 列内容必须**填满**自己的列（列表被压到 171px 的坑）────────────
	# 放在这里、而不是穿插在后面的交互用例里：后面那些用例会反复
	# `_rebuild_all`，断言跑在「重建进行中」的瞬态上会量到 1795px 这种
	# 中间值 —— 注入 bug 也会假通过。**必须在布局稳定后量**。
	#
	# 机制：ScrollContainer 在「禁用横向滚动」时按**内容最小宽度**给子节点
	# 定宽，而不是按视口。列表栏内容最小宽度只有 ~171px，所以没有
	# `size_flags_horizontal = EXPAND_FILL` 时内容会塌成 171px 塞在 368px 的
	# 栏里 —— 卡名被裁、删除按钮贴左边（用户截图里就是这个症状）。
	# **必须量真实渲染宽度，只查标志位不够**。
	#
	# **headless 下必须跳过**：无头模式不做真实布局，尺寸全是占位值，
	# 断言会误报（135px）。真实窗口（去掉 `--headless`）才是有效环境。
	var has_real_layout := DisplayServer.get_name() != "headless"
	if not has_real_layout:
		print("  [skip] 布局类断言（headless 不做真实布局，需去掉 --headless 运行）")
	if has_real_layout:
		for _w in 4:
			await process_frame
		var collapsed: Array = []
		for n in _all(app):
			if n is ScrollContainer:
				var sc := n as Control
				if sc.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
					continue
				if sc.get_child_count() == 0:
					continue
				var inner := sc.get_child(0) as Control
				if inner == null or not inner.visible:
					continue
				# 竖滚动条合法占 ~8px，所以按比例判「塌陷」而不是固定容差：
				# 老 bug 是 171/368 = 46%。
				if inner.size.x < sc.size.x * 0.9:
					collapsed.append("%.0f/%.0f" % [inner.size.x, sc.size.x])
		_ok(collapsed.is_empty(),
				"各列内容填满滚动视口（列表不再塌成 171px）",
				"塌陷: %s" % (", ".join(collapsed) if not collapsed.is_empty() else "无"))

		# 列表栏里那张卡牌按钮必须横跨整个内容宽度，而不是缩成一小条。
		var list_btn: Button = null
		for n in _all(app):
			if n is Button and String((n as Button).text).begins_with("NewCard1"):
				list_btn = n as Button
				break
		if list_btn != null:
			_ok(list_btn.size.x >= 200.0,
					"列表里的卡牌条目横跨整列（不是一条小按钮）",
					"%.0f px（下限 200）" % list_btn.size.x)

		# ── 选卡后布局不能「撑破自己的分割容器」────────────────────────
		# 选中卡牌会重建编辑器，而编辑器里那个**变量类型下拉框**曾把
		# `PowerVar<VulnerablePower>（易伤）` 的整串文字当成自己的最小宽度
		# （677px），一路上传到分割容器 → 分割最小宽度从 1196 涨到 **1648**。
		# 1648 > 视口 1280，分割无法收缩，第一栏就被摆到 **x = -184**，
		# 内容整体掉出屏幕左侧 —— 用户截图里「界面到哪去了」的真因。
		#
		# 断言「分割的最小宽度 ≤ 视口宽度」+「第一栏 global_position.x ≥ 0」，
		# 两条都必须量真实几何。
		db.set_selection(CFDesign.KIND_CARD, 0)
		app.call("_rebuild_all")
		for _w in 6:
			await process_frame
		var vp_w := app.get_viewport().get_visible_rect().size.x
		var outer: SplitContainer = null
		for n in _all(app):
			if n is SplitContainer:
				outer = n as SplitContainer
				break
		if outer != null:
			var split_min := outer.get_combined_minimum_size().x
			_ok(split_min <= vp_w + 1.0,
					"选中卡牌后分割容器仍能塞进视口（最小宽度没被下拉框撑大）",
					"最小 %.0f ≤ 视口 %.0f" % [split_min, vp_w])
		var first_panel: Control = null
		for n in _all(app):
			if n is PanelContainer and is_equal_approx((n as Control).custom_minimum_size.x, 300.0):
				first_panel = n as Control
				break
		if first_panel != null:
			_ok(first_panel.global_position.x >= -0.5,
					"第一栏（列表）不被摆到屏幕左侧之外",
					"x = %.0f（下限 0）" % first_panel.global_position.x)

	var nodes := _all(app)
	var buttons := 0
	var labels := 0
	var sliders := 0
	var fields := 0
	var optionboxes := 0
	var checks := 0
	var splits := 0
	var scrolls := 0
	for n in nodes:
		if n is Button: buttons += 1
		elif n is Label: labels += 1
		elif n is SpinBox: sliders += 1
		elif n is LineEdit: fields += 1
		elif n is OptionButton: optionboxes += 1
		elif n is CheckBox: checks += 1
		elif n is HSplitContainer or n is VSplitContainer: splits += 1
		elif n is ScrollContainer: scrolls += 1

	print("  控件统计: Button=%d Label=%d SpinBox=%d LineEdit=%d OptionButton=%d CheckBox=%d Split=%d Scroll=%d"
		% [buttons, labels, sliders, fields, optionboxes, checks, splits, scrolls])

	_ok(buttons >= 8, "工具栏与操作按钮已创建", "Button=%d" % buttons)
	_ok(labels >= 15, "文本/标签已创建", "Label=%d" % labels)
	_ok(fields >= 2, "输入框已创建", "LineEdit=%d" % fields)
	_ok(splits >= 1, "三栏分割容器已创建", "Split=%d" % splits)
	_ok(scrolls >= 2, "滚动容器已创建", "Scroll=%d" % scrolls)

	# The app should have scanned the schema on boot.
	_ok(schema != null, "启动时已扫描 schema")
	if schema != null:
		_ok(schema.existing_cards.size() > 100, "识别到游戏自带卡牌", "%d 张" % schema.existing_cards.size())
		_ok(schema.existing_relics.size() > 100, "识别到游戏自带遗物", "%d 件" % schema.existing_relics.size())
		_ok(schema.hooks.size() > 100, "识别到钩子时机", "%d 个" % schema.hooks.size())
		_ok(schema.powers.size() > 100, "识别到 Power 列表", "%d 个" % schema.powers.size())
		# 中文翻译要真的能取到 —— Power 选择器与变量行都靠它。
		# 这里钉住「Power 的本地化标题」这条路：早期用的是 schema.loc()，
		# 但它查的是那个从未被填充的值字典，永远返回空串。
		_ok(schema.power_title("VulnerablePower", "zhs") == "易伤",
				"Power 中文名可解析", schema.power_title("VulnerablePower", "zhs"))
		_ok(schema.power_title("VulnerablePower", "eng") == "Vulnerable",
				"Power 英文名可解析", schema.power_title("VulnerablePower", "eng"))
		_ok(schema.power_label("VulnerablePower") == "易伤（Vulnerable）",
				"Power 标签形如 中文（English）", schema.power_label("VulnerablePower"))
		var power_opts := CFEffects.power_options(schema)
		var vulnerable_opt: Dictionary = {}
		for o in power_opts:
			if String(o.get("value", "")) == "VulnerablePower":
				vulnerable_opt = o
				break
		_ok(not vulnerable_opt.is_empty(), "Power 下拉项含 VulnerablePower")
		if not vulnerable_opt.is_empty():
			_ok(String(vulnerable_opt.get("label", "")).contains("易伤"),
					"Power 下拉项已带中文翻译", String(vulnerable_opt.get("label", "")))
		# DynamicVarSet 访问器必须扫描到，且要包含 PowerVar 那几个 ——
		# 泛型盲的正则会把它们全漏掉（这就是 CS1061 的一半成因）。
		_ok(not schema.dynamic_var_accessors.is_empty(), "已扫描到 DynamicVarSet 访问器",
				"%d 个" % schema.dynamic_var_accessors.size())
		_ok(schema.dynvar_accessor_for("VulnerablePower") == "Vulnerable",
				"PowerVar 访问器可反查（正则支持泛型返回类型）",
				schema.dynvar_accessor_for("VulnerablePower"))
		_ok(schema.dynvar_expr("power") == "base.DynamicVars[\"power\"]",
				"无属性时变量名走索引器", schema.dynvar_expr("power"))
		# 「能力牌」选项列表必须来自**完整**的 Power 扫描（256 个），而不仅仅是
		# DynamicVarSet 恰好命名的那 6 个访问器 —— 早期版本只镜像访问器表，
		# 用户看到的下拉框里几乎没有几个 buff，却无从察觉少了东西。
		var pv_types: Array = []
		for t in schema.dynamic_var_types:
			if String(t.get("type", "")) == "PowerVar":
				pv_types.append(String(t.get("generic", "")))
		_ok(pv_types.size() >= 200, "PowerVar 变量类型覆盖全部 Power",
				"%d 个" % pv_types.size())
		_ok("VulnerablePower" in pv_types, "PowerVar 列表含 VulnerablePower")
		_ok("StrengthPower" in pv_types, "PowerVar 列表含 StrengthPower")
		# 绝不出现裸类型参数 T —— 那会直接生成 `new PowerVar<T>(2m)` 编译不过。
		_ok(not ("T" in pv_types), "PowerVar 列表不含裸类型参数 T")
		_ok(not ("PowerModel" in pv_types), "PowerVar 列表不含抽象基类 PowerModel")
		# 每个候选都必须是可编译的具体 Power 类。
		var bad_pv: Array = []
		for g in pv_types:
			if not String(g).ends_with("Power"):
				bad_pv.append(g)
		_ok(bad_pv.is_empty(), "PowerVar 泛型均为具体 Power 类",
				"%d 个非法：%s" % [bad_pv.size(), str(bad_pv.slice(0, 5))])

		# --- 搜索用 haystack ---------------------------------------------------
		# Power 选择器的搜索框匹配 haystack，必须同时覆盖中文、英文和类名。
		if not vulnerable_opt.is_empty():
			var hay := String(vulnerable_opt.get("haystack", ""))
			_ok(hay.contains("易伤") and hay.contains("vulnerable"),
					"Power 选项 haystack 含中英文", hay)
			# haystack 必须**预先小写**，否则 contains() 区分大小写会漏匹配。
			_ok(hay == hay.to_lower(), "Power haystack 已预小写")

		# --- search_option 控件（卡牌效果的 Power 搜索 + 滚轮浏览）-------------
		# 该控件用 `set_meta("cf_picked")` 而非信号：RefCounted 不能声明信号，
		# 且 Godot 会静默丢弃 arity 不匹配的 handler，让选择器看起来是死的。
		#
		# 必须挂到 `app`（一个 Control）下，不能挂到裸 SceneTree：没有 Control
		# 父级时控件不参与布局，会画在窗口左上角变成「幽灵控件」。
		var picker := W.search_option(power_opts, "", 6, 16)
		app.add_child(picker)
		_ok(picker is VBoxContainer, "search_option 返回 VBoxContainer")
		_ok(W.search_option_value(picker) == "", "初始无选中值")

		# 浏览模式（留空）：**全部**条目都要在列表里，由外层滚动容器限制可见高度。
		# 早期版本只放前 8 行 + 「还有 N 项」提示，导致滚轮翻不过第 8 行 ——
		# 看起来像「列表到头了」。这里钉住「行数 == 候选总数」。
		var rows_all := _search_rows(picker)
		_ok(rows_all.size() == power_opts.size(),
				"留空时列出全部候选（供滚轮浏览）",
				"%d 行 / 共 %d 项" % [rows_all.size(), power_opts.size()])
		var scroll: Node = picker.get_meta("cf_scroll", null)
		_ok(scroll is ScrollContainer, "结果列表放在 ScrollContainer 里（可滚轮）")
		if scroll is ScrollContainer:
			_ok((scroll as ScrollContainer).horizontal_scroll_mode
					== ScrollContainer.SCROLL_MODE_DISABLED,
					"滚动容器禁用横向滚动（避免撑宽界面）")
			_ok((scroll as ScrollContainer).custom_minimum_size.y > 0,
					"滚动容器有固定高度（不会长成 256 行）",
					"%.0f px" % (scroll as ScrollContainer).custom_minimum_size.y)

		# 展开/收起：切换后高度要变，按钮文案要跟着变。
		var h_collapsed := (scroll as ScrollContainer).custom_minimum_size.y
		var expand_btn: Button = null
		for c in picker.get_children():
			if c is HBoxContainer:
				for g in (c as Node).get_children():
					if g is Button:
						expand_btn = g
		_ok(expand_btn != null, "存在展开/收起按钮")
		if expand_btn != null and scroll is ScrollContainer:
			expand_btn.pressed.emit()
			var h_expanded := (scroll as ScrollContainer).custom_minimum_size.y
			_ok(h_expanded > h_collapsed, "展开后列表变高",
					"%.0f -> %.0f px" % [h_collapsed, h_expanded])
			_ok(expand_btn.text.contains("收起"), "展开后按钮文案变为「收起」",
					expand_btn.text)
			expand_btn.pressed.emit()
			_ok((scroll as ScrollContainer).custom_minimum_size.y == h_collapsed,
					"再次点击恢复收起高度")

		# 过滤：中文词元「易伤」要能命中 VulnerablePower。
		W._filter_search_option(picker, "易伤")
		await process_frame
		var rows_zh := _search_rows(picker)
		_ok(rows_zh.size() >= 1, "按中文「易伤」能搜到结果", "%d 行" % rows_zh.size())
		_ok(rows_zh.size() < power_opts.size(), "过滤后行数少于候选总数",
				"%d < %d" % [rows_zh.size(), power_opts.size()])
		var found_zh := false
		for r in rows_zh:
			if String(r).contains("易伤"):
				found_zh = true
		_ok(found_zh, "中文搜索结果里确实有易伤", str(rows_zh.slice(0, 3)))

		# 过滤：英文「strength」要能命中 StrengthPower（大小写不敏感）。
		W._filter_search_option(picker, "strength")
		await process_frame
		var rows_en := _search_rows(picker)
		_ok(rows_en.size() >= 1, "按英文 strength 能搜到结果", "%d 行" % rows_en.size())

		# 过滤：类名子串也要能命中。
		W._filter_search_option(picker, "vulnerable")
		await process_frame
		_ok(_search_rows(picker).size() >= 1, "按类名 vulnerable 能搜到结果")

		# 过滤：乱串必须给出「没有匹配」而不是静默空列表。
		W._filter_search_option(picker, "zzz_no_such_power_zzz")
		await process_frame
		_ok(_search_rows(picker).is_empty(), "无匹配时结果列表为空")
		_ok(_search_has_text(picker, "没有匹配的条目"), "无匹配时显示提示文案")

		# 选择：点击一行要写回 cf_selected 并触发回调。
		W._filter_search_option(picker, "vulnerable")
		await process_frame
		var picked_holder := {"value": "<none>"}
		W.on_search_option_picked(picker, func(item: Dictionary) -> void:
			picked_holder["value"] = String(item.get("value", "")))
		var first_btn: Button = null
		for c in (picker.get_meta("cf_list") as Node).get_children():
			if c is Button:
				first_btn = c
				break
		_ok(first_btn != null, "搜索结果里能找到可点击的行")
		if first_btn != null:
			first_btn.pressed.emit()
			_ok(W.search_option_value(picker) == "VulnerablePower",
					"点击结果后选中的是 VulnerablePower",
					W.search_option_value(picker))
			_ok(String(picked_holder["value"]) == "VulnerablePower",
					"点击结果后回调收到 VulnerablePower", String(picked_holder["value"]))
			_ok(_search_has_text(picker, "当前："),
					"选中后显示「当前：」行")
		picker.queue_free()

		# --- 输入延迟：set_field_quiet 不再整卡 normalize ----------------------
		# 旧的安静写入每敲一个键都把整张卡重新 normalize（遍历所有变量与效果、
		# 重算 art、刷新 modified 时间戳），本地化文本框因此卡顿。现在它只做
		# 单字段的廉价推导，整卡 normalize 推迟到 flush/save/export。
		if db != null and db.cards.size() > 0:
			var c: Dictionary = db.cards[0]
			var before_mod := String(c.get("modified", ""))
			# 写一个与 modified 无关的字段：若仍走整卡 normalize，时间戳会变。
			db.set_field_quiet(schema, CFDesign.KIND_CARD, 0,
					["text", "zhs", "description"], "延迟测试")
			var after_mod := String(db.cards[0].get("modified", ""))
			_ok(after_mod == before_mod,
					"安静写入不再刷新 modified（未整卡 normalize）",
					"%s -> %s" % [before_mod, after_mod])
			_ok(String((db.cards[0]["text"]["zhs"] as Dictionary).get("description", "")) == "延迟测试",
					"安静写入确实存下了文本")
			_ok(db._needs_normalize.get(CFDesign.KIND_CARD, false),
					"安静写入后标记为「待 normalize」")
			# flush 必须补齐整卡 normalize（undo 快照需要一致的条目）。
			db.flush_edit([])
			_ok(not db._needs_normalize.get(CFDesign.KIND_CARD, false),
					"flush_edit 后清除「待 normalize」标记")
			_ok(String(db.cards[0].get("modified", "")) != before_mod,
					"flush_edit 补上了 modified 时间戳",
					String(db.cards[0].get("modified", "")))
			# 还原，别把测试写入留给后续断言。
			db.cards[0]["text"]["zhs"]["description"] = ""
			db.clear_edit_path()

		# --- 右栏不因长文本把窗口撑出屏幕 --------------------------------------
		# 三列的横向滚动是 DISABLED 的，而 h-scroll 关闭时 ScrollContainer 会把
		# 内容的**最小宽度**一路上传。校验信息的旧写法用裸 `W.label()`：没有
		# autowrap，于是把「整行未折行的长度」当成硬最小宽度 → 右栏变宽 →
		# 分割容器变宽 → 整个窗口溢出屏幕。
		# 现在改用 `W.wrap_label()`（有真实宽度下限 + 行数上限）。
		var long_issue := "这是一条很长很长的校验信息" + "很长".repeat(80)
		var wl := W.wrap_label("· %s" % long_issue, W.TEXT, 11, 300, 4)
		app.add_child(wl)
		_ok(wl.autowrap_mode != TextServer.AUTOWRAP_OFF,
				"wrap_label 开启自动换行（长文本会折到第二行）")
		_ok(wl.custom_minimum_size.x >= 120,
				"wrap_label 有真实宽度下限（不会塌成 1px）",
				"%.0f" % wl.custom_minimum_size.x)
		_ok(wl.custom_minimum_size.x <= 340,
				"wrap_label 的宽度下限不超过右栏宽度",
				"%.0f <= 340" % wl.custom_minimum_size.x)
		_ok(wl.max_lines_visible > 0,
				"wrap_label 限制可见行数（长文本不会把行撑高）",
				"%d 行" % wl.max_lines_visible)
		wl.queue_free()

		var rail_wrap: int = int(app.call("_rail_wrap_width"))
		_ok(rail_wrap > 0 and rail_wrap < 400,
				"_rail_wrap_width 给出合理的换行宽度",
				"%d px" % rail_wrap)

		# **这条才是真正抓 bug 的断言**：把一条超长校验信息塞进右栏，然后测
		# 右栏面板的**实际渲染宽度**。旧写法会把它从 360 撑到 1100+ px。
		# 只断言 label 的属性不够 —— 属性对但布局仍可能被别处撑开。
		#
		# 真实布局断言：headless 下尺寸是占位值，跳过。
		var long_id := "超长卡牌标识" + "很长".repeat(60)
		var saved_id := String(db.cards[0].get("id", ""))
		db.cards[0]["id"] = long_id
		db.set_selection(CFDesign.KIND_CARD, 0)
		app.call("_rebuild_all")
		for _w in 5:
			await process_frame
		if has_real_layout:
			var rail_panel := _find_rail_panel(app)
			_ok(rail_panel != null, "找到右栏面板")
			if rail_panel != null:
				var width := (rail_panel as Control).size.x
				_ok(width <= 420.0,
						"超长校验信息下右栏宽度仍接近其最小宽度",
						"%.0f px（上限 420）" % width)
				_ok(width < app.get_viewport().get_visible_rect().size.x,
						"右栏不超出窗口宽度",
						"%.0f < %.0f" % [width, app.get_viewport().get_visible_rect().size.x])
		# 还原，别把测试写入留给后续断言。
		db.cards[0]["id"] = saved_id

		# ── 窗口自适配（「UI 突到屏幕外」的第二重真因）──────────────────────
		# project.godot 要 1600x940；小屏笔记本（或 150% 缩放）装不下，
		# 三栏的硬最小值之和 1180+ 就成了无法收缩的地板，右栏被推出屏幕。
		# 下面模拟小屏，断言「三栏之和永远塞得进窗口」。
		var overflow_at: Array = []
		for sim_w in [1600, 1366, 1280, 1024, 900]:
			app.call("_fit_columns_to", sim_w)
			var total: int = int(app.get("_col_list_w")) \
					+ int(app.get("_col_editor_w")) + int(app.get("_col_rail_w"))
			# 16 px 是 VBox 根的两侧留白，16 px 是两个 split 的间距。
			if total > sim_w - 32 + 1:
				overflow_at.append("%d→%d" % [sim_w, total])
		_ok(overflow_at.is_empty(),
				"缩小窗口时三栏总宽永远塞得进窗口（不再把右栏挤出屏幕）",
				"溢出: %s" % (", ".join(overflow_at) if not overflow_at.is_empty() else "无"))
		app.call("_fit_columns_to", 1600)

		# 工具栏是一整条不可换行的 HBox：它自己也能把窗口撑宽。
		var tb_overflow_at: Array = []
		for sim_w in [1600, 1280, 1100, 1000, 900, 840]:
			app.call("_fit_toolbar_to", sim_w)
			await process_frame
			var tb_min := 0.0
			for n in _all(app):
				if n is PanelContainer and String((n as Node).name) == "Toolbar":
					tb_min = (n as Control).get_combined_minimum_size().x
					break
			if tb_min > float(sim_w) - 16.0:
				tb_overflow_at.append("%d→%.0f" % [sim_w, tb_min])
		_ok(tb_overflow_at.is_empty(),
				"缩小窗口时工具栏自动收起次要按钮（不会撑宽窗口）",
				"溢出: %s" % (", ".join(tb_overflow_at) if not tb_overflow_at.is_empty() else "无"))
		app.call("_fit_toolbar_to", 1600)

		# 三栏有下界：再怎么缩也不会缩到不可用。
		app.call("_fit_columns_to", 400)
		_ok(int(app.get("_col_list_w")) >= 180
				and int(app.get("_col_editor_w")) >= 380
				and int(app.get("_col_rail_w")) >= 240,
				"列宽收缩有下限（不会缩成 0）",
				"%d / %d / %d" % [int(app.get("_col_list_w")),
						int(app.get("_col_editor_w")), int(app.get("_col_rail_w"))])
		app.call("_fit_columns_to", 1600)

		# 窗口本身会被钳制到屏幕内（本机屏幕很大，断言逻辑即可）。
		_ok(int(app.get("WINDOW_MIN_WIDTH")) <= 1600,
				"窗口最小宽度不高于设计宽度",
				"%d" % int(app.get("WINDOW_MIN_WIDTH")))
		var usable: Vector2 = app.call("_usable_window_size")
		_ok(usable.x > 0.0 and usable.y > 0.0,
				"能取到可用屏幕尺寸（用于钳制窗口）",
				"%.0f x %.0f" % [usable.x, usable.y])

		_ok(not schema.deck_targets().is_empty(), "识别到开局注入目标角色", "%d 个" % schema.deck_targets().size())
		# A re-scan must REPLACE, never append: stale caches used to triple these.
		var cards_before: int = schema.existing_cards.size()
		var root_before: String = String(schema.source_root)
		schema.reset()
		_ok(schema.existing_cards.is_empty(), "reset() 清空扫描结果", "%d -> %d" % [cards_before, schema.existing_cards.size()])
		CFSchemaScanner.scan(root_before, schema)
		_ok(schema.existing_cards.size() == cards_before,
			"重复扫描不累加（幂等）", "%d == %d" % [schema.existing_cards.size(), cards_before])
		_ok(not schema.scanned_at.is_empty(), "扫描时间戳已写入", schema.scanned_at)

	_ok(db != null, "设计库已创建")
	if db != null:
		# Don't depend on whatever `designs/main.json` happens to hold — the test
		# needs one card AND one relic to exercise both editors, so if the
		# auto-loaded design lacks a relic, re-seed the example on top of it.
		var loaded_cards: int = db.cards.size()
		var loaded_relics: int = db.relics.size()
		if loaded_cards == 0 or loaded_relics == 0:
			db.seed_example(schema)
		_ok(db.cards.size() >= 1, "设计库中有卡牌",
				"%d 张（载入时 %d）" % [db.cards.size(), loaded_cards])
		_ok(db.relics.size() >= 1, "设计库中有遗物",
				"%d 件（载入时 %d）" % [db.relics.size(), loaded_relics])
		# The card the rest of the test drives must exist and be selected.
		db.set_selection(CFDesign.KIND_CARD, 0)
		await process_frame
		await process_frame

	# Selecting a card must render the full editor: dropdowns, spinboxes,
	# triggers, upgrade and deck sections all become live controls.
	#
	# The "extra text" check is scoped to the editor column and starts from an empty
	# selection. A *global* node count barely moves when the editor grows (the list
	# and the rail dominate it), and re-selecting the already-selected card is a
	# no-op — so the old global comparison only passed by accident of whatever the
	# list happened to hold at that moment.
	if db != null and db.cards.size() > 0:
		db.set_selection(CFDesign.KIND_CARD, -1)
		app.call("_rebuild_all")
		await process_frame
		await process_frame
		var ebox: Node = app.get("_editor_box")
		var editor_labels_before := 0
		for n in _all(ebox):
			if n is Label:
				editor_labels_before += 1
		db.set_selection(CFDesign.KIND_CARD, 0)
		app.call("_rebuild_all")
		await process_frame
		await process_frame
		var n2 := _all(app)
		var opt2 := 0
		var spin2 := 0
		var check2 := 0
		var labels2 := 0
		var editor_labels_after := 0
		for n in n2:
			if n is OptionButton: opt2 += 1
			elif n is SpinBox: spin2 += 1
			elif n is CheckBox: check2 += 1
			elif n is Label: labels2 += 1
		for n in _all(ebox):
			if n is Label:
				editor_labels_after += 1
		print("  选中卡牌后: OptionButton=%d SpinBox=%d CheckBox=%d Label=%d" % [opt2, spin2, check2, labels2])
		_ok(opt2 >= 3, "卡牌编辑器渲染下拉选择", "OptionButton=%d" % opt2)
		_ok(spin2 >= 3, "卡牌编辑器渲染数值输入", "SpinBox=%d" % spin2)
		_ok(check2 >= 2, "卡牌编辑器渲染开关", "CheckBox=%d" % check2)
		_ok(editor_labels_after > editor_labels_before, "卡牌编辑器渲染附加文本",
			"编辑器 Label %d -> %d" % [editor_labels_before, editor_labels_after])

	# --- 编辑一个字段会触发整栏重建，这曾经炸出一堆 ---------------------------
	#   ERROR: Parent node is busy setting up children, `add_child()` failed.
	# 原因：编辑控件在**信号回调内**直接调用了 _build_editor()/_build_rail()，
	# 而那时引擎正处在「构建子节点」阶段，add_child 会被拒绝。
	# 现在所有重建都排到帧末（schedule_rebuild -> _flush_rebuild），同一帧内
	# 多次请求还会合并成一次。
	#
	# 注意：必须触发**真实控件信号**才算复现 —— 直接调 db.set_field() 是在脚本
	# 顶层跑的，不在 Godot 的子节点构建阶段里，即使有 bug 也不会报错。
	if db != null and db.cards.size() > 0:
		var before_items: int = db.all_items().size()
		# 在编辑器里找一个开关（CheckBox 的 toggled 会直接写字段并重建界面）。
		var toggle: CheckBox = null
		for n in _all(app):
			if n is CheckBox and n.is_visible_in_tree():
				toggle = n
				break
		_ok(toggle != null, "找到可交互的编辑器开关")
		if toggle != null:
			var was: bool = toggle.button_pressed
			# 在信号回调里重建，正是当初报错的路径。
			toggle.toggled.emit(not was)
			await process_frame
			await process_frame
			_ok(true, "触发控件信号 + 重建未报 add_child 错误")
			# 同一帧内连续触发多次，验证重建被合并、不重复建控件。
			# 注意：每次触发都会重建编辑器，旧的开关被释放，
			# 所以每轮都要重新抓一个当前活着的开关。
			for i in 3:
				var t2: CheckBox = null
				for n in _all(app):
					if n is CheckBox and n.is_visible_in_tree() and is_instance_valid(n):
						t2 = n
						break
				if t2 == null:
					break
				t2.toggled.emit(i % 2 == 0)
			await process_frame
			await process_frame
			_ok(true, "同帧多次触发重建被合并")
		_ok(db.all_items().size() == before_items, "编辑不改变条目数量", "%d" % db.all_items().size())
		# 重建必须干净：编辑器里不能出现重复的区块标题（旧的没被 free 掉就会重复）。
		var dup := 0
		var seen := {}
		for n in _all(app):
			if n is Label and String(n.text).begins_with("① 标识"):
				if seen.has("id"):
					dup += 1
				seen["id"] = true
		_ok(dup == 0, "重建后编辑器无重复区块（旧子节点已释放）", "重复=%d" % dup)

		# --- 循环方式切到「按变量」时必须自动选上一个变量 -------------------
		# 曾经的 bug：切换 mode 时原样保留旧的 var（新建效果时是空串），
		# 用户不再动下拉框就直接导出 -> 生成
		#   for (int i = 0; i < base.DynamicVars..IntValue; i++)
		# 编译报 CS0029 + CS0103。现在切到 var 模式会自动采用一个已声明的变量。
		#
		# 关键：必须先制造「全新效果」的状态（mode=none 且 var 为空串）。
		# 示例卡牌的 effect[0] 本来就有 var="Repeat"，直接切 mode 的话旧代码
		# 「原样保留」也能碰巧通过 —— 那样测的就是空断言（踩过）。
		db.set_field(schema, CFDesign.KIND_CARD, 0, ["effects", 0, "loop"],
				{"mode": "none", "count": 1, "var": ""}, "准备循环回归")
		await process_frame
		await process_frame
		var pre_effs: Array = db.selected_item().get("effects", [])
		var pre_var := ""
		if not pre_effs.is_empty():
			pre_var = String(((pre_effs[0] as Dictionary).get("loop", {}) as Dictionary).get("var", ""))
		_ok(pre_var.is_empty(), "已把循环变量清空（模拟全新效果）", "var=“%s”" % pre_var)

		# 识别方式：循环下拉框是唯一同时含 "energy" 与 "var" 两个取值的下拉框
		# （其余下拉框的取值集合都不同），比按 item_count 匹配更稳。
		var loop_pick: OptionButton = null
		var seen_options: Array = []
		for n in _all(app):
			if n is OptionButton and is_instance_valid(n) and n.is_visible_in_tree():
				var vals: Array = []
				for i in n.item_count:
					var md = n.get_item_metadata(i)
					vals.append(String((md as Dictionary).get("value", "?")) if md is Dictionary else "?")
				seen_options.append(vals)
				if vals.has("var") and vals.has("energy") and loop_pick == null:
					loop_pick = n
		_ok(loop_pick != null, "找到循环方式下拉框",
				"可见下拉框取值: %s" % str(seen_options))
		if loop_pick != null:
			var var_idx := -1
			for i in loop_pick.item_count:
				if String((loop_pick.get_item_metadata(i) as Dictionary)["value"]) == "var":
					var_idx = i
					break
			_ok(var_idx >= 0, "循环下拉框含「按变量」选项")
			if var_idx >= 0:
				loop_pick.item_selected.emit(var_idx)
				await process_frame
				await process_frame
				var item: Dictionary = db.selected_item()
				var effs: Array = item.get("effects", [])
				var got_mode := ""
				var got_var := ""
				if not effs.is_empty():
					var lp: Dictionary = (effs[0] as Dictionary).get("loop", {})
					got_mode = String(lp.get("mode", ""))
					got_var = String(lp.get("var", "")).strip_edges()
				_ok(got_mode == "var", "循环方式已切到 var", got_mode)
				_ok(not got_var.is_empty(),
						"切到「按变量」后自动选中了变量（不再留空）", "var=“%s”" % got_var)
				# 该变量必须真实存在，否则生成的 C# 仍编不过。
				var declared := false
				for v in item.get("vars", []):
					if String((v as Dictionary).get("name", "")) == got_var:
						declared = true
				_ok(declared, "自动选中的变量确实已声明", got_var)
				# 生成的 C# 里不能出现空变量名的成员访问。
				var src_loop := CFExporter.emit_card(schema, item, "UITestMod")
				_ok(not src_loop.contains("DynamicVars.."),
						"生成代码不含 `DynamicVars..`（回归 CS0029/CS0103）")
				var errs_loop := 0
				for it in CFDesign.validate(schema, item, db.all_items()):
					if String(it["severity"]) == CFDesign.SEV_ERROR:
						errs_loop += 1
				_ok(errs_loop == 0, "切换后该卡牌校验无错误", "%d 个错误" % errs_loop)
				# 复原，避免影响后续断言。
				# 触发信号会让界面重建，`loop_pick` 已经被 queue_free —— 必须
				# 重新抓一个活着的下拉框，否则会报
				#   Invalid access to property 'item_count' on 'previously freed'
				# 并让进程卡住（这一条踩过）。
				await process_frame
				await process_frame
				var loop_pick2: OptionButton = null
				for n in _all(app):
					if n is OptionButton and is_instance_valid(n) and n.is_visible_in_tree():
						var v2: Array = []
						for i in n.item_count:
							var md2 = n.get_item_metadata(i)
							v2.append(String((md2 as Dictionary).get("value", "?")) if md2 is Dictionary else "?")
						if v2.has("var") and v2.has("energy"):
							loop_pick2 = n
							break
				if loop_pick2 != null:
					for i in loop_pick2.item_count:
						if String((loop_pick2.get_item_metadata(i) as Dictionary)["value"]) == "none":
							loop_pick2.item_selected.emit(i)
							break
					await process_frame
					await process_frame

	# 模拟「信号回调内触发重建」最真实的一路：把选中项切来切去再改字段，
	# 期间不应出现任何 add_child 失败（Godot 会打到 stderr，由外层 grep 兜底）。
	if db != null and db.cards.size() > 0 and db.relics.size() > 0:
		for _i in 5:
			db.set_selection(CFDesign.KIND_CARD, 0)
			await process_frame
			db.set_selection(CFDesign.KIND_RELIC, 0)
			await process_frame
			for n in _all(app):
				if n is CheckBox and n.is_visible_in_tree():
					n.toggled.emit(not n.button_pressed)
					break
			await process_frame
		_ok(true, "反复切换选中 + 编辑不崩溃")

	# ------------------------------------------------------------------
	# 焦点保持回归：「描述写几秒后光标就没了，没法连续输入」。
	#
	# 旧行为：description 的 TextEdit 每敲一个字符就 schedule_rebuild()，
	# 整栏被拆掉重建 —— 正在输入的那个 TextEdit 被 queue_free，焦点/caret
	# 随之消失，后续字符全丢。
	#
	# 复现姿势：先 focus_entered（发布路径），再连发 text_changed，
	# 中间插入重建（模拟 / 也验证它被正确跳过），最后确认：
	#   1. 同一个 TextEdit 实例仍然活着、仍在树里；
	#   2. 用户敲进去的每个字符都还在。
	# ------------------------------------------------------------------
	if db != null and db.cards.size() > 0:
		db.set_selection(CFDesign.KIND_CARD, 0)
		await process_frame
		await process_frame

		var desc_path: Array = ["text", "zhs", "description"]
		var ebox: Node = app.get("_editor_box") as Node
		_ok(ebox != null, "拿到编辑器容器")
		# Look the widget up by the path it edits, not "the first TextEdit in the
		# tree". The editor legitimately renders several long-text boxes (zhs/eng
		# description, upgrade override), and a plain tree walk returns whichever
		# one the traversal happens to reach first — which is how an earlier
		# version of this test typed into the upgrade-override box, then asserted
		# against the main description and "found" the bug it had caused itself.
		var live_map: Dictionary = app.get("_live_widgets")
		var ta: TextEdit = live_map.get(str(desc_path)) if live_map.has(str(desc_path)) else null
		if ta != null and not is_instance_valid(ta):
			ta = null
		# A user clears the box and types from scratch; appending to whatever was
		# already there would make the "all characters kept" assertion meaningless.
		var typed := "造成3点伤害并抽1张牌。"
		_ok(ta != null, "找到描述输入框（TextEdit）")
		if ta != null:
			var ta_id: int = ta.get_instance_id()
			ta.grab_focus()
			ta.focus_entered.emit()
			_ok(bool(db.is_editing(desc_path)), "聚焦后数据库记录了正在编辑的字段",
					str(db.edit_path()))

			# Type through the engine's own insert path, one character per frame.
			# Read the value back through the database — that is the whole point
			# of the regression: the widget can show text the design never got.
			ta = await _type_into(app, desc_path, typed) as TextEdit
			var saved := String(db.get_field(CFDesign.KIND_CARD, 0, desc_path))
			_ok(saved == typed, "连续输入全部保留（焦点未被抢走）",
					"期望 %d 字符，实得 %d: “%s”" % [typed.length(), saved.length(), saved])

			# 同一个实例必须还在树里 —— 被重建掉的话这里就不是它了。
			var still_same := false
			for n in _all(ebox):
				if n is TextEdit and is_instance_valid(n) and n.get_instance_id() == ta_id:
					still_same = n.is_inside_tree()
					break
			_ok(still_same, "输入期间 TextEdit 实例未被重建/释放")

			# 重建不能把别的长文本框弄丢，也不能把它们遗留在 limbo 里。
			#
			# 旧 bug：_clear_column 把「包含受保护控件的整个顶层子节点」搬进
			# limbo —— 一个 section 面板里有好几个 TextEdit，只有真正被聚焦的
			# 那一个被接回来，其余永远滞留在 limbo：可见文本框从 3 个掉成 2 个
			# （改中文描述，英文描述框就消失了），而且 limbo 无限膨胀。
			# 一条正常的卡牌编辑器渲染 3 个长文本框：zhs 描述、eng 描述、
			# 升级后覆写描述。这里只数**编辑器里**的，不加 limbo：
			# 稳定态（已 await 过几帧）重建早该结束，任何控件都不该留在
			# limbo。若把 limbo 的也算进来，「编辑器少 1 + limbo 多 1」会
			# 凑成 3 而假通过 —— 这个坑踩过。
			var desc_boxes := 0
			for n in _all(ebox):
				if n is TextEdit and is_instance_valid(n) and n.is_visible_in_tree():
					desc_boxes += 1
			_ok(desc_boxes == 3, "编辑器里的长文本框一个没少（zhs/eng 描述 + 升级覆写）",
					"%d 个" % desc_boxes)

			var limbo: Node = app.get("_limbo")
			var stranded := 0
			if limbo != null:
				for n in _all(limbo):
					if n is TextEdit or n is LineEdit:
						stranded += 1
			_ok(stranded == 0, "没有输入框滞留在 limbo（焦点容器不吞兄弟控件）",
					"%d 个" % stranded)

			# ------------------------------------------------------------------
			# 每个本地化字段都能落库：「eng 英文描述改完就变回原样」。
			#
			# 根因是信号签名写错：`TextEdit.text_changed` **不带参数**，而
			# `LineEdit.text_changed` **带**新文本。之前给 TextEdit 接了
			# `func(_t)` 的一参回调，Godot 抛
			#   Method expected 1 argument(s), but called with 0
			# 并直接**跳过该回调**（`is_connected()` 仍返回 true，看着一切正常），
			# 于是每一次按键都静默丢弃 —— 界面显示着新文字，数据库里还是旧值，
			# 一旦重建就从"存储值"重画，表现为「改完就变回原样」。
			#
			# 必须逐个 locale/field 都测：zhs 与 eng 走的是同一个 binder，
			# 只测一个会漏掉「另一个 locale 其实从没生效过」这类问题。
			# 输入统一走 `_type_into`（引擎的真实插入路径），不要手 emit 信号。
			# ------------------------------------------------------------------
			for loc in CFSchema.LOCALES:
				for f in ["title", "description"]:
					var pth: Array = ["text", loc, f]
					var want := "LOC_%s_%s" % [loc, f]
					var ctl := _live_control(app, pth)
					if ctl == null:
						_ok(false, "本地化字段控件存在 %s" % str(pth))
						continue
					# headless 下没有真实焦点，手动发布编辑路径，保护链路才生效。
					ctl.focus_entered.emit()
					await process_frame
					ctl = await _type_into(app, pth, want)
					var got := String(db.get_field(CFDesign.KIND_CARD, 0, pth))
					_ok(got == want, "本地化字段可保存 %s" % str(pth),
							"期望 “%s”，实得 “%s”" % [want, got])
					if ctl != null and is_instance_valid(ctl):
						if ctl is TextEdit:
							(ctl as TextEdit).focus_exited.emit()
						else:
							(ctl as LineEdit).text_submitted.emit((ctl as LineEdit).text)
					# `is_instance_valid` is not a formality: emitting a signal
					# above may have rebuilt the column and freed `ctl`, and
					# touching a freed instance on the next line is the exact
					# `previously freed` error that wedges this suite.
					await process_frame
					await process_frame
				# Leaving the loop with a field still published as "being edited"
				# keeps its widget out of the normal free path; the next rebuild
				# then swaps a control out from under the assertions below. The
				# restore write is deliberately *not* published, but drop the
				# path anyway so every iteration starts clean.
				db.clear_edit_path()
				await process_frame

			# 复原 zhs 描述，后面的断言依赖它仍是刚才输入的内容。
			db.set_field(schema, CFDesign.KIND_CARD, 0, desc_path, typed, "复原")
			await process_frame


			# 失焦要落盘进撤销历史（一次输入 = 一步撤销）。
			#
			# The point is the *uncommitted* typing path: `_write_quiet` (one call
			# per keystroke) leaves the pending snapshot open, and the focus-exit
			# handler is what collapses it into a single undo step. So the field
			# has to be typed into for real here — publishing focus and emitting
			# `focus_exited` on an untended field has nothing to commit and the
			# assertion would be vacuous either way.
			#
			# `ta` is whatever `_type_into` handed back many rebuilds ago and is
			# very likely freed by now (the locale loop above ran a dozen more
			# edits through the same column). Re-fetch the live widget instead of
			# poking the stale handle — a freed instance here aborts the coroutine
			# silently and hangs the whole run.
			var ta_now := _live_control(app, desc_path)
			_ok(ta_now != null, "失焦回归：拿到活着的描述框")
			db.clear_history()
			if ta_now != null:
				ta_now.focus_entered.emit()
				await process_frame
			var typed_undo := "撤销测试文本"
			ta_now = await _type_into(app, desc_path, typed_undo) as TextEdit
			if ta_now != null and is_instance_valid(ta_now):
				ta_now.focus_exited.emit()
			await process_frame
			_ok(db.can_undo(), "失焦后整段输入合成一步撤销")
			_ok(not bool(db.is_editing(desc_path)), "失焦后清空「正在编辑」路径")
			if db.can_undo():
				db.undo()
				await process_frame
				var undone := String(db.get_field(CFDesign.KIND_CARD, 0, desc_path))
				_ok(undone != typed_undo, "撤销回退了这段输入", "%d 字符" % undone.length())

			# ------------------------------------------------------------------
			# 输入卡顿回归：本地化输入每敲一个字都深拷贝整份设计。
			#
			# `set_field_quiet` 以前每个按键都调 `begin_action()`，而它立刻
			# `snapshot()` —— 即每敲一个字符就把所有卡牌+遗物 `duplicate(true)`
			# 一遍（31 张牌实测 5.15 ms/键，就是②文字输入框发顿的根因）。
			#
			# 现在改成惰性：只有本组第一次写入才拍快照。断言用 `snapshot_count`
			# （=整份文档深拷贝次数），与计时无关，不会在慢机器上摇摆。
			# ------------------------------------------------------------------
			db.clear_history()
			# 先记下"整组开始前"的值：撤销必须回到这里，而不是最后一个字符之前。
			var pre_group := String(db.get_field(CFDesign.KIND_CARD, 0, desc_path))
			var snap_before: int = db.snapshot_count
			for i in 5:
				db.set_field_quiet(schema, CFDesign.KIND_CARD, 0, desc_path, "惰性%d" % i)
			var snap_delta: int = db.snapshot_count - snap_before
			_ok(snap_delta == 1, "连续 5 次输入只深拷贝 1 次（每键快照即卡顿根因）",
					"实际 %d 次" % snap_delta)
			_ok(db.has_uncommitted_edit(), "连续输入期间编辑组保持开启")
			_ok(String(db.get_field(CFDesign.KIND_CARD, 0, desc_path)) == "惰性4",
					"连续输入期间字段即时可读")
			db.flush_edit([])
			await process_frame
			_ok(db.can_undo(), "连续输入整体合成一步撤销")
			if db.can_undo():
				db.undo()
				await process_frame
				var restored := String(db.get_field(CFDesign.KIND_CARD, 0, desc_path))
				_ok(restored == pre_group, "撤销回到整组输入之前（而非只退回一个字）",
						"期望 “%s”，实得 “%s”" % [pre_group, restored])

			# ------------------------------------------------------------------
			# ②文字 的实时占位符检查：敲进一个游戏不认识的格式化器必须当场报出来。
			#
			# 游戏侧的真实表现是整条文字渲染失败（卡面一个字都没有），日志只有
			#   Localization formatting error! No formatter with name 'difff' found
			# 而工具以前照样导出。这里走 app 的按键路径（`_write_quiet`），因为
			# 刷新就是挂在那儿的。
			# ------------------------------------------------------------------
			var hint = app.get("_text_hint")
			_ok(hint is Label and is_instance_valid(hint), "②文字 有实时占位符检查行")
			var key_label = app.get("_text_key_label")
			_ok(key_label is Label and is_instance_valid(key_label) \
					and String(key_label.text).contains(".title"),
					"②文字 显示游戏要用的本地化键",
					String(key_label.text) if is_instance_valid(key_label) else "标签已被释放")
			var desc_backup := String(db.get_field(CFDesign.KIND_CARD, 0, desc_path))
			app.call("_write_quiet", desc_path, "造成{Damage:difff()}点伤害。")
			await process_frame
			hint = app.get("_text_hint")
			var hint_text := String(hint.text) if is_instance_valid(hint) else "标签已被释放"
			_ok(hint_text.contains("difff") and hint_text.contains("游戏不认识"),
					"坏格式化器当场出现在检查行里，并说明后果", hint_text)
			app.call("_write_quiet", desc_path, "造成{Damage:diff()}点伤害。")
			await process_frame
			hint = app.get("_text_hint")
			hint_text = String(hint.text) if is_instance_valid(hint) else "标签已被释放"
			_ok(hint_text.begins_with("✓"), "改回正确写法后检查行通过", hint_text)
			db.set_field(schema, CFDesign.KIND_CARD, 0, desc_path, desc_backup, "复原")
			await process_frame

			# ------------------------------------------------------------------
			# 幽灵输入框回归：「选中输入框后界面左边冒出相同的框，还消不掉」。
			#
			# 原因：limbo 是个普通 Node，被 add_child 挂在 app(Control) 下。
			# Control 的父级不是 Control 就拿不到布局，于是控件退回自己的
			# offsets，被画在窗口左上角；而且它在树里、visible=true，所以
			# 看得见也点得到，重建后也一直留在那儿遮挡界面。
			#
			# 修法：limbo 完全不进场景树，且控件进出时切换 visible。
			# 断言两件事：(1) limbo 自己不在树里；(2) 任何被暂存的控件都不可见。
			# ------------------------------------------------------------------
			var limbo_tree: Node = app.get("_limbo")
			_ok(limbo_tree == null or not limbo_tree.is_inside_tree(),
					"limbo 不在场景树里（否则其内容会被画到界面左上角）")

			# 真正把控件推进 limbo：让编辑器重建，且期间保持字段处于编辑态。
			#
			# 必须**重新抓一个活着的控件**：上一段的 db.undo() 已经触发重建，
			# 原来的 `ta` 早被 queue_free，再读它会报
			#   Cannot call method 'get_instance_id' on a previously freed instance
			# 并让整个进程挂住不退出（踩过）。
			var lw_g: Dictionary = app.get("_live_widgets")
			var ta_g: TextEdit = lw_g.get(str(desc_path)) if lw_g.has(str(desc_path)) else null
			if ta_g != null and not is_instance_valid(ta_g):
				ta_g = null
			_ok(ta_g != null, "幽灵框回归：拿到活着的描述框")
			if ta_g != null:
				var ghost_id := ta_g.get_instance_id()
				ta_g.focus_entered.emit()
				await process_frame
				# 直接把控件推进 limbo 再检查。
				#
				# 不能用 schedule_rebuild() 来制造这一刻：它是同步执行的
				# （_flush_rebuild -> _build_editor 当帧跑完），返回时控件早已
				# 被取回编辑器，limbo 空了 —— 断言就变成空断言（踩过）。
				# 这里直接调 _limbo_add，测的正是「暂存期间会不会产生幽灵框」。
				ta_g.get_parent().remove_child(ta_g)
				app.call("_limbo_add", ta_g)
				var visible_ghosts := 0
				var total_in_limbo := 0
				var limbo_ghost: Node = app.get("_limbo")
				if limbo_ghost != null:
					for n in _all(limbo_ghost):
						if n is Control:
							total_in_limbo += 1
							if (n as Control).visible:
								visible_ghosts += 1
				_ok(total_in_limbo >= 1, "控件确实被推进了 limbo（断言有效的前提）",
						"%d 个" % total_in_limbo)
				_ok(visible_ghosts == 0, "被暂存的控件在 limbo 内不可见（不产生幽灵框）",
						"不可见=%d 可见=%d" % [total_in_limbo - visible_ghosts, visible_ghosts])
				# 取回：走和编辑器一样的路径，必须恢复可见。
				# 取回后要挂回编辑器，否则它就是脱离树的孤儿（脱离树的控件
				# 不渲染，这里只能靠 visible 判断状态）。
				var back_ctl: Variant = app.call("_limbo_take", desc_path)
				_ok(back_ctl is Control and (back_ctl as Control).visible,
						"取回后控件恢复可见（不会「消失」）")
				var same_back: bool = back_ctl is Control and is_instance_valid(back_ctl) \
						and (back_ctl as Control).get_instance_id() == ghost_id
				_ok(same_back, "取回的是同一个控件实例")
				ta_g = back_ctl as TextEdit
				var holder := VBoxContainer.new()
				app.get("_editor_box").add_child(holder)
				if ta_g != null and is_instance_valid(ta_g):
					holder.add_child(ta_g)
				# 放回编辑器，别把后面的用例晾着。
				db.clear_edit_path()
				app.call("schedule_rebuild")
				await process_frame
				await process_frame

			# ------------------------------------------------------------------
			# 输入过程中被别处的写入打断（例如顺手拖一下费用）。
			#
			# 这是用户报的「打字几秒后光标/内容就没了」的核心路径：一次和当前
			# 输入无关的重建，会把正在编辑的控件连同它所在的整个 section 面板
			# 一起搬走。旧代码用「整个顶层子节点」做保护单位，于是同一面板里
			# 的 eng 描述框跟着进 limbo 再也没回来（可见文本框 3 -> 2），
			# limbo 还会无限堆积。
			# ------------------------------------------------------------------
			db.set_selection(CFDesign.KIND_CARD, 0)
			await process_frame
			await process_frame
			var lw2: Dictionary = app.get("_live_widgets")
			var ta_re: TextEdit = lw2.get(str(desc_path)) if lw2.has(str(desc_path)) else null
			if ta_re != null and not is_instance_valid(ta_re):
				ta_re = null
			_ok(ta_re != null, "打断回归：重新拿到描述框")
			if ta_re != null:
				var boxes_before := 0
				for n in _all(ebox):
					if n is TextEdit and is_instance_valid(n) and n.is_visible_in_tree():
						boxes_before += 1
				var typed2 := "打断测试内容"
				# headless 下 grab_focus 不产生真实焦点，edit_path 得手动发布，
				# 否则「正在编辑」的保护链路根本不生效，测的就不是这条路径。
				if ta_re != null:
					ta_re.focus_entered.emit()
					await process_frame
				ta_re = await _type_into(app, desc_path, typed2) as TextEdit
				_ok(String(db.get_field(CFDesign.KIND_CARD, 0, desc_path)) == typed2,
						"打断回归：输入已落库")
				# 抓实例 id 必须在输入之后：_type_into 里会先清空再逐字插入，
				# 那几步本身就可能触发重建，之前抓的 id 会指向被释放的控件。
				var keep_id := ta_re.get_instance_id() if ta_re != null else -1

				db.set_field(schema, CFDesign.KIND_CARD, 0, ["cost"], 3, "回归：输入中改费用")
				for _i in 4:
					await process_frame

				var live_after: Variant = (app.get("_live_widgets") as Dictionary).get(str(desc_path))
				var same_field: bool = false
				if live_after is TextEdit and is_instance_valid(live_after):
					var le_after: TextEdit = live_after
					same_field = le_after.get_instance_id() == keep_id and le_after.is_inside_tree()
				_ok(same_field, "输入中被打断后，同一个描述框仍在（焦点未丢）")
				_ok(String(db.get_field(CFDesign.KIND_CARD, 0, desc_path)) == typed2,
						"输入中被打断后，已输入内容仍在")
				var boxes_after := 0
				for n in _all(ebox):
					if n is TextEdit and is_instance_valid(n) and n.is_visible_in_tree():
						boxes_after += 1
				_ok(boxes_after == boxes_before, "输入中被打断后，其余长文本框没被卷走",
						"%d -> %d" % [boxes_before, boxes_after])
				var stranded2 := 0
				var limbo2: Node = app.get("_limbo")
				if limbo2 != null:
					for n in _all(limbo2):
						if n is TextEdit or n is LineEdit:
							stranded2 += 1
				_ok(stranded2 == 0, "输入中被打断后，没有输入框滞留 limbo",
						"%d 个" % stranded2)

		# ------------------------------------------------------------------
		# 迟到的焦点丢失事件不能清掉「当前」正在编辑的字段。
		#
		# 用户从标题框切到描述框时，标题框的 focus_exited 往往在描述框已经
		# 发布之后才到达（控件被释放/交接都是帧末的事）。如果 focus_exited
		# 无条件 clear_edit_path()，就会把刚发布的描述框保护一起抹掉 ——
		# 下一个重建立刻把描述框连同光标一起丢掉。
		#
		# 断言：发布 B（描述）之后，补发一条属于 A（标题）的 focus_exited，
		# B 必须仍是「正在编辑」的字段。只测 B 自己的离开事件是不够的
		# （那条确实该清），必须用**过期的**路径去触发。
		# ------------------------------------------------------------------
		var late_a: Array = ["text", "zhs", "title"]
		var late_b: Array = ["text", "zhs", "description"]
		db.set_edit_path(late_b)
		var stale_ctl := _live_control(app, late_a)
		_ok(stale_ctl != null, "迟到失焦回归：拿到标题框")
		# Assert *synchronously*, before any frame boundary: the handler also
		# schedules a deferred rebuild, and a rebuild republishes nothing but can
		# rebuild the column — waiting a frame would let unrelated churn rewrite
		# the state we are checking and turn this into a false pass.
		app.call("_on_edit_focus_exited", late_a)
		_ok(_same_path(db.edit_path(), late_b),
				"过期字段的失焦事件不会清掉当前编辑字段", str(db.edit_path()))
		# And the opposite: the *current* field's own exit must still clear it.
		app.call("_on_edit_focus_exited", late_b)
		_ok(db.edit_path().is_empty(),
				"当前字段自己的失焦事件正常清空编辑路径", str(db.edit_path()))
		db.clear_edit_path()
		await process_frame

	# ------------------------------------------------------------------
	# 变量行回归：「变量值改完只能保存几秒」。
	#
	# 旧行为有两处：字段逐个写入时互相覆盖（normalize 让 kind/type/value_prop
	# 相互推导），以及行内 LineEdit 在信号回调里被重建。
	# ------------------------------------------------------------------
	if db != null and db.cards.size() > 0:
		db.set_selection(CFDesign.KIND_CARD, 0)
		await process_frame
		await process_frame
		var item: Dictionary = db.selected_item()
		var vars: Array = item.get("vars", [])
		_ok(vars.size() >= 1, "示例卡牌含有变量可编辑", "%d 个" % vars.size())
		if vars.size() >= 1:
			var vidx := 0
			var vitem: Dictionary = vars[vidx]
			var name_path: Array = db._var_field_path(item, vidx, vitem)
			var deep: Array = name_path.duplicate()
			deep.append("name")

			# (a) 名称输入框：聚焦后连续输入，必须保持同一实例。
			# 按设计路径精确取控件；用「整棵树里文本相同」来匹配会串到别的框
			# （变量名常常和别的字段重名）。
			var ne: LineEdit = _live_control(app, deep) as LineEdit
			_ok(ne != null, "找到变量「名称」输入框")
			if ne != null:
				var ne_id: int = ne.get_instance_id()
				ne.focus_entered.emit()
				await process_frame
				_ok(bool(db.is_editing(deep)), "聚焦变量名后记录了编辑路径",
						str(db.edit_path()))
				var target := "HitCount"
				ne = await _type_into(app, deep, target) as LineEdit
				var saved_name := String(db.get_field(CFDesign.KIND_CARD, 0, deep))
				_ok(saved_name == target, "变量名连续输入被完整保存",
						"期望 “%s”，实得 “%s”" % [target, saved_name])
				var ne_alive := _live_control(app, deep) != null \
						and (_live_control(app, deep) as Control).get_instance_id() == ne_id
				_ok(ne_alive, "变量名输入期间控件未被重建")
				if ne != null:
					ne.focus_exited.emit()
				await process_frame

			# (b) 类型下拉框：切换后必须真的存下来，且不被后续写入覆盖。
			var item2: Dictionary = db.selected_item()
			var v2: Dictionary = (item2.get("vars", []) as Array)[0]
			var deep_type: Array = db._var_field_path(item2, 0, v2)
			deep_type.append("type")
			var type_pick: OptionButton = null
			for n in _all(app):
				if n is OptionButton and is_instance_valid(n) and n.is_visible_in_tree():
					var vals: Array = []
					for i in n.item_count:
						var md = n.get_item_metadata(i)
						vals.append(String((md as Dictionary).get("value", "?")) if md is Dictionary else "?")
					if vals.has("IntVar|") and vals.has("DamageVar|"):
						type_pick = n
						break
			_ok(type_pick != null, "找到变量「类型」下拉框")
			if type_pick != null:
				var want_idx := -1
				for i in type_pick.item_count:
					if String((type_pick.get_item_metadata(i) as Dictionary)["value"]) == "IntVar|":
						want_idx = i
						break
				_ok(want_idx >= 0, "类型下拉框含 IntVar 选项")
				if want_idx >= 0:
					type_pick.item_selected.emit(want_idx)
					for _i in 4:
						await process_frame
					var got_type := String(db.get_field(CFDesign.KIND_CARD, 0, deep_type))
					_ok(got_type == "IntVar", "变量类型切换后已保存", got_type)

					# 再改基础值 —— 旧代码会在这一步把类型冲掉。
					var item3: Dictionary = db.selected_item()
					var v3: Dictionary = (item3.get("vars", []) as Array)[0]
					var deep_base: Array = db._var_field_path(item3, 0, v3)
					deep_base.append("base")
					db.set_field(schema, CFDesign.KIND_CARD, 0, deep_base, 12.0, "回归：改基础值")
					for _i in 3:
						await process_frame
					var type_after := String(db.get_field(CFDesign.KIND_CARD, 0, deep_type))
					_ok(type_after == "IntVar",
							"改基础值后类型仍在（旧代码会丢）", type_after)

	# --- 关键复现：在**引擎的子节点构建阶段**触发重建 -------------------------
	# 这才是当初报 "Parent node is busy setting up children" 的真条件。
	# 仅从脚本顶层 emit 信号是复现不出来的 —— 必须在某节点的
	# child_entered_tree 回调里改写字段，让 designs_changed 在父节点仍处于
	# setup 阶段时到达。如果重建仍是内联执行，这里会直接崩（实测 segfault）。
	if db != null and db.cards.size() > 0:
		var ebox: Node = app.get("_editor_box") as Node
		_ok(ebox != null, "拿到编辑器容器")
		if ebox != null:
			var hits: Array = [0]
			var probe := func(_n: Node) -> void:
				hits[0] = int(hits[0]) + 1
				if int(hits[0]) <= 3:
					db.set_field(schema, CFDesign.KIND_CARD, 0, ["cost"], 1 + int(hits[0]), "setup-probe")
			ebox.child_entered_tree.connect(probe)
			db.set_field(schema, CFDesign.KIND_CARD, 0, ["cost"], 2, "setup-trigger")
			for _i in 4:
				await process_frame
			ebox.child_entered_tree.disconnect(probe)
			_ok(hits[0] > 0, "setup 阶段回调确实被触发", "%d 次" % hits[0])
			_ok(true, "setup 阶段触发重建未崩溃（重建已延后到帧末）")

	# Relics get a trigger editor instead of an effect chain.
	if db != null and db.relics.size() > 0:
		db.set_selection(CFDesign.KIND_RELIC, 0)
		await process_frame
		await process_frame
		var n3 := _all(app)
		var found := false
		for n in n3:
			if n is Label and String(n.text).find("触发") >= 0:
				found = true
				break
		_ok(found, "选中遗物后触发时机编辑器已渲染")

	# Validation + preview should never crash, and the seeded example must be clean.
	if db != null:
		var res: Dictionary = db.validate_all(schema)
		var summary: Dictionary = res.get("summary", {})
		print("  校验汇总: errors=%d warnings=%d infos=%d"
			% [int(summary.get("errors", -1)), int(summary.get("warnings", -1)), int(summary.get("infos", -1))])
		_ok(int(summary.get("errors", -1)) == 0, "示例内容无错误", "errors=%d" % int(summary.get("errors", -1)))
		_ok(res.has(CFDesign.KIND_CARD) and res.has(CFDesign.KIND_RELIC), "校验覆盖卡牌与遗物")

	# Driving the real export button must produce a complete, loadable mod.
	# The exporter nests the mod under its own id, so the folder is <out>/<mod_id>.
	if db != null and schema != null and not String(schema.source_root).is_empty():
		var out_dir := ProjectSettings.globalize_path("res://exports/UITestMod")
		app.call("_do_export", out_dir, true)
		await process_frame
		var mod_dir := out_dir.path_join(db.mod_id)
		var names: Array = [db.mod_id + ".json", db.mod_id + ".pck", "build.ps1", "build.cmd",
			"README.md", "src/" + db.mod_id + ".csproj", "src/ModEntry.cs",
			"forge-paths.txt", "EXPORT_REPORT.md"]
		var missing: Array = []
		for f in names:
			if not FileAccess.file_exists(mod_dir.path_join(f)):
				missing.append(f)
		_ok(missing.is_empty(), "界面导出生成全部必要文件", "缺失=%s" % str(missing))
		var pck_path := mod_dir.path_join(db.mod_id + ".pck")
		if FileAccess.file_exists(pck_path):
			var parsed: Dictionary = CFPckWriter.read_pck(pck_path)
			_ok(not (parsed.get("files", []) as Array).is_empty(), "界面导出的 pck 可解析",
				"%d 个文件" % (parsed.get("files", []) as Array).size())
		var ps1 := mod_dir.path_join("build.ps1")
		if FileAccess.file_exists(ps1):
			_ok(_non_ascii_count(FileAccess.get_file_as_string(ps1)) == 0,
				"界面导出的 build.ps1 为纯 ASCII")

		# 导出的目录里必须放得下 dll —— 也就是「dll 输出」和「mod 输出」是同
		# 一个文件夹。Godot.NET.Sdk 把编译产物钉死在 src/.godot/mono/temp/bin/，
		# 所以 verify_build 负责把它搬回 mod 根目录；这里检查搬运逻辑本身。
		#
		# 只断言 `_stage_dll` 的返回值与提示文件的移除 —— 不要断言「根目录存在
		# dll」，那会被上一次运行的残留文件假通过。
		var fake_src := mod_dir.path_join("src/.godot/mono/temp/bin/Release")
		DirAccess.make_dir_recursive_absolute(fake_src)
		var fake_dll := fake_src.path_join("%s.dll" % db.mod_id)
		var wf := FileAccess.open(fake_dll, FileAccess.WRITE)
		if wf != null:
			wf.store_string("MZ fake dll")
			wf.close()
		var sentinel := mod_dir.path_join("!!! 先编译再安装 !!!.txt")
		_ok(FileAccess.file_exists(sentinel), "导出后存在「先编译再安装」提示")
		var staged := CFExporter._stage_dll(mod_dir, fake_dll)
		_ok(staged == mod_dir.path_join("%s.dll" % db.mod_id),
				"dll 会被搬到 mod 根目录（与 json/pck 同级）", staged)
		_ok(not FileAccess.file_exists(sentinel),
				"dll 就位后移除「先编译再安装」提示")

	# Save / reload round trip: everything the user typed must survive a restart.
	if db != null:
		var design_path := ProjectSettings.globalize_path("res://designs/_uitest.json")
		var save_res: Dictionary = db.save_to_file(design_path)
		_ok(bool(save_res.get("ok", false)), "保存设计文件", String(save_res.get("error", "")))
		if FileAccess.file_exists(design_path):
			var card_id := String((db.cards[0] as Dictionary).get("id", ""))
			var relic_id := String((db.relics[0] as Dictionary).get("id", ""))
			var reload := CFDesignDb.new()
			var open_res: Dictionary = reload.load_from_file(design_path)
			_ok(bool(open_res.get("ok", false)), "重新载入设计文件", String(open_res.get("error", "")))
			_ok(reload.cards.size() == 1 and String((reload.cards[0] as Dictionary).get("id", "")) == card_id,
				"卡牌往返一致", card_id)
			_ok(reload.relics.size() == 1 and String((reload.relics[0] as Dictionary).get("id", "")) == relic_id,
				"遗物往返一致", relic_id)
			_ok(String(reload.mod_id) == String(db.mod_id), "Mod ID 往返一致", String(db.mod_id))
			DirAccess.remove_absolute(design_path)

	# Starting-deck injection: turning it on must emit a Harmony patch, add the
	# 0Harmony reference, and produce sources that actually compile.
	if db != null and schema != null and not schema.deck_targets().is_empty():
		var target := String((schema.deck_targets()[0] as Dictionary)["class_name"])
		db.mutate("测试开局注入", func():
			(db.cards[0] as Dictionary)["deck"] = {"enabled": true, "character": target, "copies": 2}
			(db.relics[0] as Dictionary)["deck"] = {"enabled": true, "character": target, "copies": 1})
		var inj_dir := ProjectSettings.globalize_path("res://exports/InjTest")
		app.call("_do_export", inj_dir, true)
		await process_frame
		var inj_mod := inj_dir.path_join(db.mod_id)
		var patch_path := inj_mod.path_join("src/Patches/StartingContentPatches.cs")
		_ok(FileAccess.file_exists(patch_path), "开局注入生成 Harmony 补丁源文件", target)
		if FileAccess.file_exists(patch_path):
			var src := FileAccess.get_file_as_string(patch_path)
			_ok(src.contains("get_StartingDeck"), "补丁挂在 get_StartingDeck 上")
			_ok(src.contains("get_StartingRelics"), "补丁挂在 get_StartingRelics 上")
			_ok(src.contains("ref IReadOnlyList<RelicModel> __result"),
					"StartingRelics 补丁使用游戏真实返回类型")
			_ok(src.contains("__result = __result.Concat(added).ToList();"),
					"StartingRelics 补丁返回具体列表")
			_ok(src.contains("PatchGetter(harmony, \"%s\", " % target), "补丁运行时按角色名查找目标", target)
			_ok(not src.contains("HarmonyPatch(typeof("), "补丁不把角色名编译期绑定为 C# 类型")
			_ok(src.contains("harmony.Patch(getter, postfix:"), "补丁运行时安装 Harmony Postfix")
		var csproj := inj_mod.path_join("src/" + db.mod_id + ".csproj")
		if FileAccess.file_exists(csproj):
			var cj := FileAccess.get_file_as_string(csproj)
			_ok(cj.contains("0Harmony"), "csproj 引用了 0Harmony")
			_ok(cj.contains("<Private>false</Private>"), "0Harmony 不复制到输出（Private=false）")
			# 0Harmony.dll 在 data_sts2_windows_x86_64/ 里，和 sts2.dll 同级。
			# 曾经写成 $(GameDir)/0Harmony.dll（游戏根目录）→ CS0246。
			_ok(cj.contains("GameAssemblyDir"), "0Harmony 路径从 sts2.dll 反推（不是游戏根目录）")
			_ok(not cj.contains("$(GameDir)/0Harmony.dll"), "没有把 0Harmony 指向游戏根目录")
		var entry := inj_mod.path_join("src/ModEntry.cs")
		if FileAccess.file_exists(entry):
			var es := FileAccess.get_file_as_string(entry)
			_ok(es.contains("StartingContentPatches.ApplyAll"), "ModEntry 调用补丁入口")
			_ok(es.contains("[ModInitializer(nameof(Initialize))]"), "ModEntry 仍为类级 ModInitializer")

		# 终极验证：用真实游戏程序集就地编译。
		# 跑 `dotnet build` 会拉起子进程，在某些无头环境里退出时会挂住，
		# 所以默认跳过；需要完整验证时设 FORGE_VERIFY_BUILD=1 再跑。
		if OS.get_environment("FORGE_VERIFY_BUILD") == "1":
			var vb := CFExporter.verify_build(inj_mod)
			_ok(bool(vb.get("ok", false)), "开局注入 Mod 编译通过（dotnet build）",
				String(vb.get("error", "")) if not bool(vb.get("ok", false)) else String(vb.get("dll", "")))
			_finish(_fails if _fails > 0 else 0)
		else:
			print("  [skip] 编译验证（设 FORGE_VERIFY_BUILD=1 启用）")

	# ------------------------------------------------------------------
	# 启动器健康检查。
	# 这一组全是「用户双击 run.cmd 能不能开起来」相关的坑，踩过一次：
	#   - Windows 默认 ExecutionPolicy=Restricted，run.cmd 必须自己带 -ExecutionPolicy
	#     Bypass（或用纯批处理），否则报 SecurityError / UnauthorizedAccess。
	#   - .cmd / .ps1 必须是纯 ASCII 无 BOM，且 .cmd 用 CRLF（PowerShell 5.1 /
	#     cmd.exe 对编码与换行都很挑）。
	#   - 不能把 197 KB 的 *_console.exe 壳当引擎。
	#   - forge-paths.txt 是「可选覆盖」，主路径靠 %~dp0 自动探测（批处理读 UTF-8
	#     会乱码，所以它必须保持纯 ASCII）。
	# ------------------------------------------------------------------
	var tool_dir := CFPaths.project_dir().trim_suffix("/").trim_suffix("\\")
	for f in ["run.cmd", "run.ps1", "forge-paths.txt"]:
		var p := tool_dir.path_join(f)
		_ok(FileAccess.file_exists(p), "启动器文件存在 " + f)
		if FileAccess.file_exists(p):
			var bytes := FileAccess.get_file_as_bytes(p)
			var bad := 0
			for i in bytes.size():
				if bytes[i] > 127:
					bad += 1
			_ok(bad == 0, f + " 为纯 ASCII（PowerShell/cmd 编码兼容）", "%d 个非 ASCII 字节" % bad)
			_ok(not (bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF),
				f + " 无 UTF-8 BOM")

	var cmd_path := tool_dir.path_join("run.cmd")
	if FileAccess.file_exists(cmd_path):
		var cb := FileAccess.get_file_as_bytes(cmd_path)
		var lf_only := 0
		for i in cb.size():
			if cb[i] == 0x0A and (i == 0 or cb[i - 1] != 0x0D):
				lf_only += 1
		_ok(lf_only == 0, "run.cmd 使用 CRLF 换行", "%d 个裸 LF" % lf_only)
		var cs := FileAccess.get_file_as_string(cmd_path)
		# 纯批处理路线不需要 PowerShell；若哪天改回调用 .ps1，也必须带 Bypass。
		var needs_ps := cs.contains("run.ps1") or cs.contains("powershell")
		_ok((not needs_ps) or cs.contains("ExecutionPolicy Bypass"),
			"run.cmd 若调用 PowerShell 则必须显式 Bypass 执行策略")
		# cmd.exe 能识别 REM，但 PowerShell 不能 —— 两个脚本别用错注释语法。
		var ps_path := tool_dir.path_join("run.ps1")
		if FileAccess.file_exists(ps_path):
			var ps_s := FileAccess.get_file_as_string(ps_path)
			var has_rem := false
			for ln in ps_s.split("\n"):
				if ln.strip_edges().to_upper().begins_with("REM "):
					has_rem = true
					break
			_ok(not has_rem, "run.ps1 没有误用 REM 注释（PowerShell 会当成命令执行）")
		# 引擎必须靠 %~dp0 探测（路径含中文时批处理读文件会乱码）。
		_ok(cs.contains("%~dp0"), "run.cmd 从 %~dp0 推导路径（不依赖读文件）")
		_ok(cs.contains("_console.exe"), "run.cmd 会自动纠正 *_console.exe 壳")

	var csproj_path := tool_dir.path_join("CardRelicForge.csproj")
	_ok(FileAccess.file_exists(csproj_path), "占位 C# 工程存在（满足 mono 程序集探测）")
	if FileAccess.file_exists(csproj_path):
		var cj := FileAccess.get_file_as_string(csproj_path)
		# 不加这行，SDK 会把 exports/<Mod>/src/*.cs 也编进来 → 一堆 CS0246。
		_ok(cj.contains("Compile Remove"), "占位工程排除了工程外源码（避免误编 exports）")
		_ok(cj.contains("exports/"), "占位工程明确排除 exports/ 目录")

	print("")
	if _fails == 0:
		print("===== PASSED =====  %d 项检查" % _checks)
		_finish(0)
	else:
		print("===== FAILED =====  %d/%d 项失败" % [_fails, _checks])
		_finish(1)
