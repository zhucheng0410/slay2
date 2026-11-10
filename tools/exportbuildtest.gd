extends SceneTree

## Exercises the actual UI flow without opening Explorer or saving preferences.
class IsolatedApp extends "res://ui/app.gd":
	var build_paths: Array[String] = []
	var real_build := false
	func _save_settings() -> bool:
		return true
	func _load_last_design() -> void:
		pass
	func _reveal_export(_path: String) -> void:
		pass
	func _run_build(path: String) -> Dictionary:
		build_paths.append(path)
		if real_build:
			return await super._run_build(path)
		await get_tree().process_frame
		return {"ok": true}

var failures := 0
var checks := 0

func check(label: String, value: bool) -> void:
	checks += 1
	if not value:
		failures += 1
	print("[%s] %s" % ["OK" if value else "FAIL", label])

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var app := IsolatedApp.new()
	root.add_child(app)
	for i in 20:
		await process_frame
	app.db.load_from_json('{"cards":[],"relics":[],"mod_id":"ExportProbe","custom_characters":[{"id":"111","card_pool":"LegacyCards","relic_pool":"LegacyRelics"}]}')
	var out := ProjectSettings.globalize_path("res://exports/_exportbuildtest")
	var report := CFExporter.preflight(app.schema, app.db)
	check("旧数字角色不阻断预检", not report["blocking"])
	app.db.custom_characters.append(CFCharacters.normalized({"id": "Character111"}))
	check("数字别名与其他类冲突会阻止导出", CFExporter.preflight(app.schema, app.db)["blocking"])
	app.db.custom_characters.pop_back()
	var starter := CFDesign.new_card(app.schema)
	starter["id"] = "LegacyStarter"
	starter["pool"] = "LegacyCards"
	starter["deck"] = {"enabled": true, "character": "111", "copies": 2}
	app.db.cards = [starter]
	var code := CFCharacters.emit(app.db.custom_characters[0], app.db)
	check("数字角色类名合法且开局关联保持", code.contains("class Character111 :") and code.contains("global::ExportProbe.LegacyStarter"))
	check("角色本地化与实际类名一致", CFCharacters.entry("ExportProbe", "111") == "EXPORT_PROBE_CHARACTER_CHARACTER111")
	await app._do_export_and_build(out, false)
	check("成功导出编译本次目录", app.build_paths == [out.path_join("ExportProbe")])
	app.db.mod_id = "invalid id"
	await app._do_export_and_build(out, false)
	check("导出失败不编译旧目录且保留错误", app.build_paths.size() == 1 and app._last_mod_dir.is_empty() and app._status.text.contains("已中止导出"))
	app.db.mod_id = "MovedProbe"
	await app._do_verify(out.path_join("changed"), false)
	check("编译验证使用新的目录和 Mod ID", app.build_paths[-1] == out.path_join("changed/MovedProbe"))
	app._build_in_progress = true
	await app._do_export_and_build(out, false)
	check("编译期间重复点击不启动第二次构建", app.build_paths.size() == 2)
	app._build_in_progress = false
	check("完整状态可从提示读取", app._status.tooltip_text == app._status.text)
	# Read the user's design into memory only. Never save it or their settings.
	var original := CFPaths.read_text("res://designs/main.json")
	check("读取当前工程副本", app.db.load_from_json(original)["ok"])
	app.real_build = true
	var current_dir := out.path_join(app.db.mod_id)
	# A previous forced export could have left an invalid numeric class behind.
	CFPaths.write_text(current_dir.path_join("src/Characters/111.cs"), "public class 111 { }\n")
	await app._do_export_and_build(out, false)
	print(app._status.text)
	check("当前用户工程完整编译成功", app._status.text.begins_with("导出并编译完成"))
	check("生成准确的 Mod DLL", FileAccess.file_exists(current_dir.path_join(app.db.mod_id + ".dll")))
	check("编译日志保存", FileAccess.file_exists(current_dir.path_join("build.log")))
	check("旧角色文件不参与编译", not CFPaths.read_text(current_dir.path_join("src/%s.csproj" % app.db.mod_id)).contains('Include="Characters/111.cs"'))
	check("用户原始存档保持不变", CFPaths.read_text("res://designs/main.json") == original)
	app.queue_free()
	await process_frame
	print("===== EXPORT BUILD TEST %s (%d checks) =====" % ["PASSED" if failures == 0 else "FAILED", checks])
	quit(0 if failures == 0 else 1)
