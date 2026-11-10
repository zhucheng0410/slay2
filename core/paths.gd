@tool
class_name CFPaths
extends RefCounted

## Path & settings resolution for CardRelicForge.
##
## The program lives in `<workspace>/StS2ModTool/CardRelicForge`, so the game
## dump and the sample mod are two levels up. Everything is resolved from
## `res://` plus a persisted settings file, so the whole folder can be moved.

const SETTINGS_PATH := "res://resources/settings.cfg"
const DESIGN_DIR := "res://designs"
const EXPORT_DIR := "res://exports"
const CACHE_PATH := "res://resources/schema_cache.json"

## Candidate names for the unpacked game data, in priority order.
const SOURCE_CANDIDATES := ["解包文件", "unpacked", "game_dump", "decompiled"]
## Candidate names for the reference mod whose layout our exports mirror.
const SAMPLE_MOD_CANDIDATES := ["3747501308", "sample_mod"]
## Candidate names for the Godot engine folder, used to locate GodotSharp.dll.
const ENGINE_CANDIDATES := [
	"Godot_v4.5.1-stable_mono_win64/Godot_v4.5.1-stable_mono_win64",
	"Godot_v4.5.1-stable_mono_win64",
]

## Where the game keeps its own assembly, relative to the game install dir.
const GAME_ASSEMBLY_REL := "data_sts2_windows_x86_64/sts2.dll"
## Common Steam install locations, probed only as a last resort.
const GAME_DIR_CANDIDATES := [
	"E:/steam/steamapps/common/Slay the Spire 2",
	"D:/steam/steamapps/common/Slay the Spire 2",
	"C:/Program Files (x86)/Steam/steamapps/common/Slay the Spire 2",
	"C:/Program Files/Steam/steamapps/common/Slay the Spire 2",
]
## Where the .NET SDK usually lives on Windows.
const DOTNET_CANDIDATES := [
	"C:/Program Files/dotnet/dotnet.exe",
	"C:/Program Files (x86)/dotnet/dotnet.exe",
	"D:/dotnet/dotnet.exe",
]


static func project_dir() -> String:
	return ProjectSettings.globalize_path("res://")


## `<workspace>/StS2ModTool`
static func tool_dir() -> String:
	return project_dir().trim_suffix("/").trim_suffix("\\").get_base_dir()


## `<workspace>`
static func workspace_dir() -> String:
	return tool_dir().get_base_dir()


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

## The directory that directly holds `src/Core` and `localization`.
static func detect_source_root() -> String:
	var roots: Array[String] = []
	var tool := tool_dir()
	var ws := workspace_dir()
	for name in SOURCE_CANDIDATES:
		roots.append(tool.path_join(name))
		roots.append(tool.path_join(name).path_join(".godot"))
		roots.append(ws.path_join(name))
		roots.append(ws.path_join(name).path_join(".godot"))
	roots.append(tool)
	roots.append(tool.path_join(".godot"))
	for r in roots:
		if DirAccess.dir_exists_absolute(r.path_join("src").path_join("Core")):
			return r
	for r in roots:
		if DirAccess.dir_exists_absolute(r.path_join("localization")):
			return r
	return ""


## The reference mod folder whose on-disk layout exports mimic.
static func detect_sample_mod() -> String:
	var tool := tool_dir()
	for name in SAMPLE_MOD_CANDIDATES:
		var p := tool.path_join(name)
		if DirAccess.dir_exists_absolute(p):
			return p
	return ""


## Folder holding GodotSharp.dll (for the generated csproj's HintPath).
static func detect_godotsharp_dir() -> String:
	var base := tool_dir()
	for rel in ENGINE_CANDIDATES:
		var p := base.path_join(rel).path_join("GodotSharp")
		if DirAccess.dir_exists_absolute(p):
			return p
	return ""


## A game install that actually contains sts2.dll.
static func detect_game_dir() -> String:
	for g in GAME_DIR_CANDIDATES:
		if FileAccess.file_exists(g.path_join(GAME_ASSEMBLY_REL)):
			return g
	return ""


## 0Harmony ships *next to* sts2.dll (in data_sts2_windows_x86_64/), not in the
## game root — a detail that silently breaks deck injection if you get it wrong.
static func harmony_path(game_assembly: String, game_dir: String) -> String:
	var asm_dir := game_assembly.get_base_dir()
	for c in [asm_dir.path_join("0Harmony.dll"), game_dir.path_join("0Harmony.dll"),
			game_dir.path_join("data_sts2_windows_x86_64").path_join("0Harmony.dll")]:
		if not c.is_empty() and FileAccess.file_exists(c):
			return c
	return ""


## The dotnet CLI, so the UI can offer a one-click "编译验证".
static func detect_dotnet() -> String:
	for c in DOTNET_CANDIDATES:
		if FileAccess.file_exists(c):
			return c
	# Fall back to whatever `dotnet` resolves to on PATH.
	return "dotnet"


static func default_settings() -> Dictionary:
	var source := detect_source_root()
	return {
		"source_root": source,
		"sample_mod": detect_sample_mod(),
		"godotsharp_dir": detect_godotsharp_dir(),
		"game_dir": detect_game_dir(),
		"game_assembly": _assembly_from_game_dir(detect_game_dir(), source),
		"compat_target": "0.107.1",
		"ritsulib_dir": detect_ritsulib_dir(),
		"theme_mode": "dark",
		"ui_scale": 0.0,
		"last_design_file": "%s/main.json" % DESIGN_DIR,
		"last_export_dir": EXPORT_DIR,
		"auto_scan": true,
	}


static func detect_ritsulib_dir() -> String:
	for root in [tool_dir().path_join("RitsuLib"), detect_game_dir().path_join("mods/RitsuLib"), detect_game_dir().path_join("mods/STS2-RitsuLib")]:
		if FileAccess.file_exists(root.path_join("RitsuLib.References.props")):
			return root
	return ""


static func _assembly_from_game_dir(game_dir: String, source_root: String) -> String:
	if not game_dir.is_empty():
		var p := game_dir.path_join(GAME_ASSEMBLY_REL)
		if FileAccess.file_exists(p):
			return p
	# Fall back to a compiled dump inside the workspace, if one exists.
	if source_root.is_empty():
		return ""
	var candidates: Array[String] = [
		source_root.path_join(".godot").path_join(".godot").path_join("mono").path_join("temp").path_join("bin").path_join("Debug").path_join("sts2.dll"),
		source_root.path_join(".godot").path_join("mono").path_join("temp").path_join("bin").path_join("Debug").path_join("sts2.dll"),
	]
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	return ""


# ---------------------------------------------------------------------------
# Settings persistence
# ---------------------------------------------------------------------------

static func load_settings(path: String = SETTINGS_PATH) -> Dictionary:
	var settings := default_settings()
	var cfg := ConfigFile.new()
	if cfg.load(ProjectSettings.globalize_path(path)) == OK:
		for key in settings.keys():
			if cfg.has_section_key("forge", key):
				settings[key] = cfg.get_value("forge", key)
	return settings


static func save_settings(settings: Dictionary, path: String = SETTINGS_PATH) -> Error:
	# Mounted export PCKs replace the res:// directory backend. Persistent writes
	# must go to the physical project directory, never the packed resource tree.
	path = ProjectSettings.globalize_path(path)
	var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if err != OK:
		return err
	var cfg := ConfigFile.new()
	for key in settings.keys():
		cfg.set_value("forge", key, settings[key])
	return cfg.save(path)


static func resolve_ui_scale(setting: float) -> float:
	if setting > 0.0:
		return clampf(setting, 0.75, 3.0)
	var h := float(DisplayServer.screen_get_size().y)
	if h >= 2000.0:
		return 1.5
	if h >= 1400.0:
		return 1.15
	return 1.0


static func ensure_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


static func read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


static func write_text(path: String, text: String) -> bool:
	path = ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("CFPaths: cannot write %s (err %d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(text)
	f.flush()
	var err := f.get_error()
	f.close()
	return err == OK
