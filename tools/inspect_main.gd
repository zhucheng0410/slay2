@tool
extends SceneTree
func _init() -> void:
	var s := CFSchema.new(); CFSchemaScanner.scan(CFPaths.detect_source_root(), s)
	var db := CFDesignDb.new(); db.load_from_file(ProjectSettings.globalize_path("res://designs/main.json"))
	var c: Dictionary = db.cards[0]
	print("target=", c.get("target"))
	for e in c.get("effects", []): print("effect target=", e.get("target"), " kind=", e.get("kind"))
	var src := CFExporter.emit_card(s, c, "Probe")
	for line in src.split("\n"):
		if line.contains("Apply<") or line.contains("ThrowIfNull"):
			print(line)
	quit(0)
