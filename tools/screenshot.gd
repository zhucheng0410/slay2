@tool
extends SceneTree

## Renders the real window offscreen and writes a PNG, so we can eyeball the
## three-column layout without a human at the keyboard.

func _init() -> void:
	call_deferred("_go")


func _go() -> void:
	# **Do not force a window size here.** The app sizes *itself* in
	# `_apply_window_size()` (clamped to the real screen). Overriding `root.size`
	# made the harness disagree with the app: the app then resized the window
	# again, leaving the harness's rect stale, and the shot showed children laid
	# out at the wrong width. Letting the app drive keeps window == viewport.
	await process_frame
	var packed: PackedScene = load("res://scenes/main.tscn")
	var app: Node = packed.instantiate()
	root.add_child(app)
	# Wait for the deferred scan + example seeding to settle.
	var schema = app.get("schema")
	var db = app.get("db")
	for _i in 240:
		await process_frame
		if schema != null and not String(schema.source_root).is_empty() and db != null and not db.all_items().is_empty():
			break
	for _i in 6:
		await process_frame

	# Select the card so the editor and rail are populated in the shot.
	if db != null and db.cards.size() > 0:
		db.set_selection(CFDesign.KIND_CARD, 0)
		for _i in 8:
			await process_frame

	# Report the real geometry so a collapsed layout is diagnosable from logs.
	print("viewport=%s app.size=%s" % [str(root.get_visible_rect().size), str((app as Control).size)])
	var split := app.find_child("Root", true, false)
	if split != null:
		for c in split.get_children():
			if c is Control:
				print("  root>%s size=%s vflags=%d" % [c.name, str((c as Control).size), (c as Control).size_flags_vertical])

	await process_frame
	await process_frame
	var vp := root.get_viewport()
	await RenderingServer.frame_post_draw
	var img: Image = vp.get_texture().get_image()
	var err := img.save_png("res://exports/_ui_shot.png")
	print("shot saved err=%d size=%dx%d" % [err, img.get_width(), img.get_height()])
	quit(0)
