@tool
class_name CFExporter
extends RefCounted

## Turns the design database into a mod the game's own loader accepts.
##
## ## What the game actually requires
## Verified in `解包文件/.godot/src/Core/Modding/`:
##
##   * the mod lives in `<game exe dir>/mods/<folder>/`
##   * the manifest is **any** `*.json` in that folder (here `<ModId>.json`),
##     with exactly the fields in `ModManifest.cs`; only `id` is enforced
##   * `<id>.dll` and `<id>.pck` must sit next to the manifest
##   * a new card/relic needs a compiled C# `CardModel`/`RelicModel` subclass,
##     discovered by `ReflectionHelper.GetSubtypesInMods<AbstractModel>()` and
##     registered into a pool by `ModHelper.AddModelToPool<TPool, TModel>()`
##     from a `[ModInitializer("Method")]`-annotated **class**
##   * localization may only be added into an **existing** base table, at
##     `res://<id>/localization/<lang>/<table>.json`
##
## So the exporter emits a complete, buildable mod project: manifest, generated
## C# sources, localization, a `.pck`, build scripts and a report.

const FORMAT_VERSION := 1
## Kept ASCII-only: the generated build script is written for Windows
## PowerShell 5.1, which reads a BOM-less `.ps1` as ANSI.
const PS1_HEADER := "# Builds this mod into a loadable form and copies it into the game's mods folder.\n"


# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

## Conflict / validity detection. Nothing is written here.
static func preflight(schema: CFSchema, db: CFDesignDb) -> Dictionary:
	var errors: Array = []
	var warnings: Array = []
	var infos: Array = []
	var per_item := db.validate_all(schema)
	var summary: Dictionary = per_item.get("summary", {"errors": 0, "warnings": 0, "infos": 0})

	for kind in [CFDesign.KIND_CARD, CFDesign.KIND_RELIC]:
		var list := db.items_for(kind)
		var label := "遗物" if kind == CFDesign.KIND_RELIC else "卡牌"
		for i in list.size():
			for issue in (per_item[kind] as Dictionary).get(i, []):
				var text := "%s #%d (%s) %s" % [label, i + 1,
						String(list[i].get("id", "?")), CFDesign.describe_issue(issue)]
				match String(issue.get("severity", "")):
					CFDesign.SEV_ERROR: errors.append(text)
					CFDesign.SEV_WARNING: warnings.append(text)
					_: infos.append(text)

	if String(db.mod_id).strip_edges().is_empty():
		errors.append("Mod ID 不能为空：它决定 manifest 的 id、目录名与 <id>.dll / <id>.pck 文件名。")
	elif not CFIds.is_valid_cs_identifier(db.mod_id):
		errors.append("Mod ID “%s” 不是合法的 C# 标识符（同时用作程序集名）。" % db.mod_id)

	if db.cards.is_empty() and db.relics.is_empty() and db.custom_characters.is_empty():
		warnings.append("没有任何卡牌或遗物，导出的 Mod 不会添加内容。")
	var character_issues := CFCharacters.validate(schema, db)
	errors.append_array(character_issues["errors"])
	warnings.append_array(character_issues["warnings"])

	# Localization key collisions across both kinds.
	var seen: Dictionary = {}
	for item in db.all_items():
		var kind := String(item.get("kind", ""))
		var entry := String(item.get("entry", ""))
		for field in CFSchema.LOC_FIELDS[kind]:
			var key := "%s/%s" % [CFSchema.LOC_TABLE[kind], CFIds.loc_key(entry, field)]
			if seen.has(key):
				errors.append("本地化键冲突：%s 同时被 %s 与 %s 使用。"
						% [key, seen[key], item.get("id", "?")])
			else:
				seen[key] = String(item.get("id", "?"))

	# Effect bindings that could not be resolved against the scanned API.
	var binding_info := CFEffects.resolve_bindings(schema)
	for m in binding_info.get("missing", []):
		warnings.append("效果类型 “%s” 在扫描到的命令 API 中找不到对应方法。" % m)

	# Two items cannot both be injected into the same character's starting deck
	# with conflicting intent; report duplicates so the author notices.
	var deck_claims: Dictionary = {}
	for item in db.all_items():
		var deck: Dictionary = item.get("deck", {})
		if not bool(deck.get("enabled", false)):
			continue
		var key := "%s/%s" % [item.get("kind", ""), deck.get("character", "")]
		if deck_claims.has(key):
			infos.append("%s “%s” 与 “%s” 都会加入同一个角色的开局内容，请确认这是有意的。"
					% ["遗物" if String(item.get("kind", "")) == CFDesign.KIND_RELIC else "卡牌",
					deck_claims[key], item.get("id", "?")])
		else:
			deck_claims[key] = String(item.get("id", "?"))

	# Content whose pool does not belong to the character it is injected into.
	for item in db.all_items():
		var deck: Dictionary = item.get("deck", {})
		if not bool(deck.get("enabled", false)):
			continue
		var pool := schema.pool_by_class(String(item.get("pool", "")),
				String(item.get("kind", "")) == CFDesign.KIND_RELIC)
		var owner := String(pool.get("character", ""))
		if not owner.is_empty() and owner != String(deck.get("character", "")):
			warnings.append("%s “%s” 所属的池属于 %s，却要加入 %s 的开局内容。"
					% ["遗物" if String(item.get("kind", "")) == CFDesign.KIND_RELIC else "卡牌",
					item.get("id", "?"), owner, deck.get("character", "")])

	return {
		"blocking": not errors.is_empty(),
		"errors": errors, "warnings": warnings, "infos": infos,
		"per_item": per_item, "counts": summary,
	}


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

## options:
##   out_dir        destination root (a `<ModId>/` folder is created inside)
##   force          export even when pre-flight found errors
##   game_assembly  path to sts2.dll for the generated csproj HintPath
##   godotsharp_dir folder containing GodotSharp.dll
##   compat_target  value written to lib/<v>/compat-target.txt
##   include_pck    build the .pck (default true)
##   dry_run        run pre-flight and report only
static func export(schema: CFSchema, db: CFDesignDb, options: Dictionary = {}) -> Dictionary:
	# The exporter reads derived fields everywhere (`entry`, `value_prop`, effect
	# ids, var `kind`), and the quiet typing path deliberately defers those. Flush
	# any pending normalisation before preflight so we never emit from a
	# half-normalised card.
	db.ensure_all_normalized(schema)
	# Re-derive the art paths from the current rules instead of trusting what is
	# stored: a design saved by an earlier version still carries the old card
	# paths (`images/card_portraits/...` — no `packed/`, no pool segment), which
	# no code in the game reads. The report exists precisely to name the file the
	# game will actually look for.
	for item in db.all_items():
		item["art"] = CFDesign.resolve_art(schema, item)
	var report := preflight(schema, db)
	var settings := CFPaths.load_settings()
	var ritsu_root := String(options.get("ritsulib_dir", settings.get("ritsulib_dir", "")))
	var ritsu_target := String(options.get("compat_target", settings.get("compat_target", "0.107.1")))
	if not db.custom_characters.is_empty():
		var dependency_error := CFCharacters.reference_error(ritsu_root, ritsu_target)
		if not dependency_error.is_empty():
			report["blocking"] = true
			report["errors"].append(dependency_error)
	if not bool(options.get("include_pck", true)) and db.custom_characters.any(func(c): return CFCharacterVisuals.normalized(c.get("visuals", {}))["mode"] == "custom"):
		report["ok"] = false
		report["error"] = "自定义角色模型需要 PCK 资源包，请启用资源包导出。"
		return report
	var out_root := String(options.get("out_dir", CFPaths.EXPORT_DIR))
	if out_root.begins_with("res://") or out_root.begins_with("user://"):
		out_root = ProjectSettings.globalize_path(out_root)
	var mod_id := String(db.mod_id).strip_edges()
	var dry := bool(options.get("dry_run", false))

	report["out_dir"] = out_root
	report["mod_id"] = mod_id
	report["written"] = []
	report["pck"] = {}

	if bool(report["blocking"]) and not bool(options.get("force", false)):
		report["ok"] = false
		report["error"] = "预检发现 %d 个错误，已中止导出（可勾选“忽略错误强制导出”）。" % (report["errors"] as Array).size()
		return report
	if dry:
		report["ok"] = true
		report["error"] = ""
		return report
	if mod_id.is_empty():
		report["ok"] = false
		report["error"] = "Mod ID 为空。"
		return report

	# These encounter invariants also apply to force-export, before writing files.
	for character in db.custom_characters:
		var dialogue_errors := CFAncientDialogues.validate(character.get("ancient_dialogues", {}))
		if (CFCharacters.is_independent(character) or not String(character.get("ancient_tome_card", "")).is_empty()) and CFAncientDialogues.tome_card(character, db).is_empty():
			dialogue_errors.append("角色 %s 缺少有效的尘封魔典候选卡牌。" % character["id"])
		if not dialogue_errors.is_empty():
			report["ok"] = false
			report["error"] = "\n".join(dialogue_errors)
			return report
	# Keep generated Ancient card editions out of the author's saved design.
	db = CFAncientDialogues.prepare_export(db, schema)
	var mod_dir := out_root.path_join(mod_id)
	for d in [mod_dir, mod_dir.path_join("src"), mod_dir.path_join("src").path_join("Cards"),
			mod_dir.path_join("src").path_join("Relics"), mod_dir.path_join("src").path_join("CardPools"),
			mod_dir.path_join("src").path_join("RelicPools"), mod_dir.path_join("assets")]:
		DirAccess.make_dir_recursive_absolute(d)

	var written: Array = report["written"]

	# --- manifest -----------------------------------------------------------
	var manifest := {
		"id": mod_id,
		"name": db.mod_name,
		"author": db.mod_author,
		"description": db.mod_description,
		"version": db.mod_version,
		"has_pck": bool(options.get("include_pck", true)),
		"has_dll": true,
		"affects_gameplay": true,
	}
	if not db.min_game_version.strip_edges().is_empty():
		manifest["min_game_version"] = db.min_game_version
	if not db.custom_characters.is_empty():
		manifest["dependencies"] = [{"id": "STS2-RitsuLib", "min_version": CFCharacters.RITSU_VERSION}]
	_write_json(mod_dir.path_join("%s.json" % mod_id), manifest, written)

	# --- localization -------------------------------------------------------
	var loc_tables := CFDesign.build_localization(db.all_items())
	CFCharacters.add_localization(loc_tables, db, schema)
	CFAncientDialogues.add_localization(loc_tables, db)
	var pck := CFPckWriter.new()
	for locale in loc_tables.keys():
		var by_table: Dictionary = loc_tables[locale]
		for table in by_table.keys():
			var rel := "%s/localization/%s/%s.json" % [mod_id, locale, table]
			var json_text := JSON.stringify(by_table[table], "  ")
			# Readable copy next to the sources (useful for manual edits).
			_write_text(mod_dir.path_join("assets").path_join(rel), json_text, written)
			pck.add_text(rel, json_text)

	# --- art ----------------------------------------------------------------
	var art_notes: Array = []
	for item in db.all_items():
		var entry := String(item.get("entry", ""))
		if entry.is_empty():
			continue
		var is_relic := String(item.get("kind", "")) == CFDesign.KIND_RELIC
		var rel_path := String((item.get("art", {}) as Dictionary).get(
				"icon" if is_relic else "portrait", ""))
		if rel_path.is_empty():
			art_notes.append("%s 没有推导出素材路径（缺少卡池或 ID）。" % entry)
			continue
		# The exact path matters: it is the only place the game looks. A wrong path
		# does not error — the sprite silently falls back to the placeholder, and the
		# game log only names the *game's* own path, which is why this mirror of
		# `CardModel.PortraitPngPath` / `RelicModel.BigIconPath` is spelled out.
		art_notes.append("%s 的图必须放在 %s —— 游戏只在这个路径找图，缺图会静默退回占位图。本工具不打包图片，请自行导入后随 pck 打包。"
				% [entry, rel_path])

	# --- C# sources ---------------------------------------------------------
	var card_classes: Array = []
	var relic_classes: Array = []
	# This mod's own cards, by localization entry: a `generate_card` effect that
	# points at one of them must name the class the design gave it (`wudi`), not
	# the un-slugged entry (`Wudi`, which does not exist -> CS0246).
	var mod_cards: Dictionary = {}
	for card in db.cards:
		var centry := String(card.get("entry", ""))
		var cid := String(card.get("id", ""))
		if not centry.is_empty() and not cid.is_empty():
			mod_cards[centry] = cid
	for card in db.cards:
		var cls := String(card.get("id", ""))
		if cls.is_empty():
			continue
		_write_text(mod_dir.path_join("src").path_join("Cards").path_join("%s.cs" % cls),
				emit_card(schema, card, mod_id, mod_cards), written)
		card_classes.append(cls)
	for relic in db.relics:
		var rcls := String(relic.get("id", ""))
		if rcls.is_empty():
			continue
		_write_text(mod_dir.path_join("src").path_join("Relics").path_join("%s.cs" % rcls),
				emit_relic(schema, relic, mod_id, mod_cards), written)
		relic_classes.append(rcls)
	for character in db.custom_characters:
		character = CFCharacters.normalized(character)
		var assets := CFCharacterVisuals.pack(character, mod_id, mod_dir, pck, written)
		if not assets["ok"]:
			report["ok"] = false
			report["error"] = assets["error"]
			return report
		_write_text(mod_dir.path_join("src/Characters/%s.cs" % CFCharacters.code_name(String(character["id"]))),
				CFCharacters.emit(character, db, schema), written)
		if CFCharacters.is_independent(character):
			var potion_pool := CFCharacters.code_name(String(character["id"])) + "PotionPool"
			_write_text(mod_dir.path_join("src/PotionPools/%s.cs" % potion_pool), emit_independent_potion_pool(mod_id, potion_pool), written)
		var card_pool := String(character.get("card_pool", ""))
		if not card_pool.is_empty():
			_write_text(mod_dir.path_join("src").path_join("CardPools").path_join("%s.cs" % card_pool),
					emit_custom_pool(db, character, card_pool, false, mod_id), written)
		var relic_pool := String(character.get("relic_pool", ""))
		if not relic_pool.is_empty():
			_write_text(mod_dir.path_join("src").path_join("RelicPools").path_join("%s.cs" % relic_pool),
					emit_custom_pool(db, character, relic_pool, true, mod_id), written)

	var patches := collect_patches(schema, db)
	var entry_code := emit_mod_entry(schema, db, mod_id, card_classes, relic_classes, patches, true)
	_write_text(mod_dir.path_join("src").path_join("ModEntry.cs"), entry_code, written)
	if not patches.is_empty():
		_write_text(mod_dir.path_join("src").path_join("Patches").path_join("StartingContentPatches.cs"),
				emit_patches(patches, mod_id), written)

	# Set before the report/README are rendered so those files can carry the
	# warning. The DLL does not exist yet: it is produced by build.cmd, which a
	# user may never run. Copying the raw export into mods/ produces
	# "[ERROR] ... declares that it should load an assembly, but no assembly ...
	# was found!" and a mod that adds nothing.
	var needs_build := not card_classes.is_empty() or not relic_classes.is_empty() or not db.custom_characters.is_empty()
	report["needs_build"] = needs_build

	var game_assembly := String(options.get("game_assembly", ""))
	if game_assembly.is_empty():
		game_assembly = CFPaths.default_settings()["game_assembly"]
	var godotsharp := String(options.get("godotsharp_dir", ""))
	if godotsharp.is_empty():
		godotsharp = CFPaths.detect_godotsharp_dir()
	var project := emit_csproj(mod_id, game_assembly, godotsharp, not patches.is_empty(),
			ritsu_root if not db.custom_characters.is_empty() else "", ritsu_target)
	# Re-exporting after a rename/deletion must not compile obsolete generated
	# classes. Keep old files on disk, and include only this export's sources.
	var sources: Array[String] = []
	for path in written:
		if String(path).ends_with(".cs"):
			sources.append('    <Compile Include="%s" />' % String(path).trim_prefix(mod_dir.path_join("src") + "/").xml_escape())
	project = project.replace("</Project>", "  <PropertyGroup><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup>\n  <ItemGroup>\n%s\n  </ItemGroup>\n</Project>" % "\n".join(sources))
	_write_text(mod_dir.path_join("src").path_join("%s.csproj" % mod_id), project, written)

	# --- pck ----------------------------------------------------------------
	if bool(options.get("include_pck", true)):
		var pck_path := mod_dir.path_join("%s.pck" % mod_id)
		var res := pck.write_pck(pck_path, "4.5.1")
		report["pck"] = res
		if bool(res.get("ok", false)):
			written.append(pck_path)
		else:
			report["ok"] = false
			report["error"] = "PCK 生成失败：%s" % res.get("error", "unknown")
			return report
		if db.custom_characters.any(func(c): return CFCharacterVisuals.normalized(c.get("visuals", {}))["mode"] == "custom"):
			if not ProjectSettings.load_resource_pack(pck_path):
				report["ok"] = false
				report["error"] = "导出的角色资源包无法回读。"
				return report
			var model_errors: Array = []
			for character in db.custom_characters:
				model_errors.append_array(CFCharacterVisuals.scene_errors(character, mod_id))
			if not model_errors.is_empty():
				report["ok"] = false
				report["error"] = "\n".join(model_errors)
				return report

	# --- sample-mod-compatible tooling layout -------------------------------
	var compat_target := String(options.get("compat_target", db.min_game_version))
	if compat_target.strip_edges().is_empty():
		compat_target = "0.107.1"
	var lib_dir := mod_dir.path_join("lib").path_join(compat_target)
	DirAccess.make_dir_recursive_absolute(lib_dir)
	_write_text(lib_dir.path_join("compat-target.txt"), compat_target, written)
	_write_json(mod_dir.path_join(variants_manifest_name(mod_id)), {
		"schema": 1,
		"variants": [{
			"compatTarget": compat_target,
			"directory": "lib/%s" % compat_target,
			"assembly": "%s.dll" % mod_id,
			"sha256": "",
		}],
		"_note": "此文件复刻样例 Mod 的分版本布局；游戏本体不读取它，build.ps1 会在编译后回填 sha256。",
	}, written)

	# --- build scripts + readme --------------------------------------------
	var game_dir := String(options.get("game_dir", ""))
	if game_dir.is_empty():
		game_dir = CFPaths.detect_game_dir()
	_write_text(mod_dir.path_join("build.ps1"),
			emit_build_script(mod_id, compat_target, game_assembly, godotsharp, patches.size()), written)
	_write_text(mod_dir.path_join("forge-paths.txt"),
			emit_paths_file(game_assembly, godotsharp, game_dir), written)
	_write_text(mod_dir.path_join("build.cmd"), emit_build_cmd(), written)
	_write_text(mod_dir.path_join("README.md"),
			(emit_character_readme(db, ritsu_target) + "\n\n" if not db.custom_characters.is_empty() else "")
			+ emit_readme(schema, db, mod_id, compat_target, art_notes, patches), written)
	if not db.custom_characters.is_empty():
		_write_text(mod_dir.path_join("CHARACTERS.md"), emit_character_readme(db, ritsu_target), written)
	_write_text(mod_dir.path_join("EXPORT_REPORT.md"),
			emit_report_md(schema, db, report, mod_id, written, art_notes), written)

	# --- "you must still build" sentinel ------------------------------------
	# The manifest above already declares has_dll=true, because that is what the
	# finished mod looks like. But the DLL only exists after build.ps1 runs, and
	# a user who drops the raw export into `mods/` gets a mod that reports
	# "[ERROR] declares that it should load an assembly, but no assembly ... was
	# found!" at startup and adds nothing to the game. Leave an unmissable note
	# in the folder (and a report flag for the UI) so that cannot happen quietly.
	if needs_build:
		var sentinel := mod_dir.path_join("!!! 先编译再安装 !!!.txt")
		_write_text(sentinel, emit_install_warning(mod_id, compat_target), written)
		report["warnings"].append(
				"导出的 Mod 尚未编译：必须运行一次 build.cmd 生成 %s.dll 后，再整体拷贝到 mods/。" % mod_id)

	report["ok"] = true
	report["error"] = ""
	report["mod_dir"] = mod_dir
	report["files_written"] = written.size()
	return report


## Plain-text note dropped into every export that still needs compiling.
##
## Uses `str.format()` with a dictionary rather than `%` tuple substitution:
## a `"""...""" % [..]` expression on a raw multiline literal is easy to get
## wrong (and silently returns the literal unformatted), and the placeholder
## count here is high enough that positional args are unreadable anyway.
static func emit_character_readme(db: CFDesignDb, target: String) -> String:
	var lines: Array = ["# 可选角色", "",
		"本工程针对游戏 API %s、RitsuLib %s 生成。先安装完整的 RitsuLib，再安装编译后的本 Mod。" % [target, CFCharacters.RITSU_VERSION],
		"RitsuLib 必须保留 compat/、shared/、assets.zip 与自身 manifest；不要只复制入口 DLL。",
		"在游戏主菜单开始新游戏后选择新角色。角色默认直接解锁。自定义模型角色完全独立：基础充能球栏位为 0，不默认显示星星，不借用原版角色的专属内容。选填素材使用制作器自带的默认资源。",
		"若角色列表较长，使用 RitsuLib 的角色选择翻页/滚动。", "",
		"卡牌和遗物在自制器中选择对应角色池，并通过「开局注入」指定初始内容。",
		"独立角色需配置自己的初始牌组和奖励池；通用遗物、药水仍由游戏正常提供。旧版原版外观记录保留兼容入口。",
		"已包含全部 9 位先古之民（含建筑师）的首次与重复台词。在制作器的「能力/角色库 → 先古之民对话」中编辑并保存，修改后重新导出编译。",
		"达弗的尘封魔典使用角色专属候选卡；选择普通卡时，导出器生成保留效果与升级的先古副本，原卡与初始牌组保持不变。",
		"更新后请开新的一局验证。旧对局存档会保留创建时的基础球位；本模组不会改写已有对局。", ""]
	for original in db.custom_characters:
		var c := CFCharacters.normalized(original)
		lines.append("- %s (%s)：生命 %d，能量 %d，金币 %d；%s；卡池 %s；遗物池 %s。" % [c["name"], c["id"], c["starting_hp"], c["max_energy"], c["starting_gold"], "独立角色" if c["independent"] else "旧版外观 " + c["template"], c["card_pool"], c["relic_pool"]])
		if not String(c.get("ancient_tome_card", "")).is_empty():
			lines.append("  尘封魔典奖励：%s。" % c["ancient_tome_card"])
		if c["visuals"]["mode"] == "custom":
			lines.append("  自定义战斗模型：%s。修改模型请回到自制器导入修改后的文件夹，再导出并编译。" % c["visuals"]["battle_scene"])
	lines.append("")
	lines.append("编译引用位置由 src/*.csproj 的 RitsuLibDir 指定，可用 dotnet build -p:RitsuLibDir=完整路径 覆盖。运行时从已安装的 RitsuLib 加载，依赖 DLL 不会复制进本 Mod。")
	return "\n".join(lines) + "\n"


static func emit_install_warning(mod_id: String, compat_target: String) -> String:
	var tpl := """这个 Mod 还不能直接用！
============================

现在文件夹里只有 {id}.json 与 {id}.pck，**没有 {id}.dll**。
游戏启动时会报：

    [ERROR] Mod manifest for mod {id} declares that it should load an assembly,
            but no assembly at path ...\\mods\\{id}\\{id}.dll was found!

然后这个 Mod 会被标记为已加载，但不会向游戏注册任何卡牌/遗物 —— 也就是说进游戏什么都不会发生。

原因
----
.pck 只能装本地化文本和素材，**不能定义卡牌或遗物**。
卡牌/遗物是 C# 类，必须编译进 {id}.dll，并且这个 dll 必须和
{id}.json、{id}.pck 放在同一层目录里。

怎么做
------
1. 双击运行本文件夹里的  build.cmd
   （它会在 src/ 下调用 dotnet 编译，然后把生成的 {id}.dll
     自动拷到本文件夹根目录，也就是 manifest 旁边）
2. 确认根目录出现 {id}.dll 之后，把**整个 {id} 文件夹**
   拷贝到：

       <游戏目录>\\mods\\{id}\\

   注意拷的是编译后的文件夹，不是只拷 json 和 pck。
3. 启动游戏，检查日志里出现：

       [INFO] Loading assembly DLL ...\\mods\\{id}\\{id}.dll
       [INFO] Finished mod initialization for '...' ({id}).

若编译报错，先看 build.cmd 的输出；也可以在 CardRelicForge 界面右栏
点「编译验证」直接跑一次。

目标游戏版本：{compat}
"""
	return tpl.format({"id": mod_id, "compat": compat_target})


# ---------------------------------------------------------------------------
# Starting-deck / starting-relic patches
# ---------------------------------------------------------------------------

## Describe every Harmony patch the export needs.
##
## `CharacterModel.StartingDeck` / `StartingRelics` are plain virtual members
## with no mod extension point, so injection must be a postfix on the concrete
## character's getter — the same approach the hand-built mod used.
static func collect_patches(schema: CFSchema, db: CFDesignDb) -> Array:
	var out: Array = []
	for item in db.cards:
		var deck: Dictionary = item.get("deck", {})
		if not bool(deck.get("enabled", false)):
			continue
		var character := String(deck.get("character", ""))
		if character.is_empty() or CFCharacters.contains(db, character):
			continue
		var rec := _patch_for(out, character)
		rec["cards"].append({
			"class_name": String(item.get("id", "")),
			"copies": maxi(1, int(deck.get("copies", 1))),
		})
	for item in db.relics:
		var deck: Dictionary = item.get("deck", {})
		if not bool(deck.get("enabled", false)):
			continue
		var character := String(deck.get("character", ""))
		if character.is_empty() or CFCharacters.contains(db, character):
			continue
		var rec := _patch_for(out, character)
		rec["relics"].append({"class_name": String(item.get("id", "")), "copies": 1})
	# The generated `typeof(<Character>)` needs the character's namespace, and
	# the character classes are not all in the ModelDb namespace.
	resolve_patch_namespaces(schema, out, db.custom_characters)
	return out


static func _patch_for(list: Array, character: String) -> Dictionary:
	for r in list:
		if String(r["character"]) == character:
			return r
	var rec := {"character": character, "namespace": "", "cards": [], "relics": []}
	list.append(rec)
	return rec


## Resolve each patched character's namespace from the schema, so the generated
## Postfix gets the right parameter type.
static func resolve_patch_namespaces(schema: CFSchema, patches: Array,
		custom_characters: Array = []) -> void:
	for p in patches:
		var cls := String(p["character"])
		for c in schema.characters:
			if String(c.get("class_name", "")) == cls:
				p["namespace"] = String(c.get("namespace", ""))
				break
		if not String(p.get("namespace", "")).is_empty():
			continue
		for c in custom_characters:
			if String(c.get("id", c.get("class_name", ""))) == cls:
				p["namespace"] = String(c.get("namespace", ""))
				break


static func emit_patches(patches: Array, mod_id: String) -> String:
	var lines: Array = []
	lines.append("using System;")
	lines.append("using System.Collections.Generic;")
	lines.append("using System.Linq;")
	lines.append("using HarmonyLib;")
	lines.append("using Godot;")
	lines.append("using MegaCrit.Sts2.Core.Entities.Cards;")
	lines.append("using MegaCrit.Sts2.Core.Entities.Relics;")
	lines.append("using MegaCrit.Sts2.Core.Models;")
	lines.append("")
	lines.append("namespace %s.Patches;" % mod_id)
	lines.append("")
	lines.append("/// <summary>")
	lines.append("/// 把自制内容加入角色的开局牌组 / 初始遗物。")
	lines.append("///")
	lines.append("/// 运行时按角色类名查找 getter，避免把用户输入的角色名当作 C# 类型名编译。")
	lines.append("/// </summary>")
	lines.append("internal static class StartingContentPatches")
	lines.append("{")
	lines.append("\tinternal static void ApplyAll()")
	lines.append("\t{")
	lines.append("\t\tvar harmony = new Harmony(\"%s.starting\");" % mod_id)
	for i in patches.size():
		var p: Dictionary = patches[i]
		if not (p["cards"] as Array).is_empty():
			lines.append("\t\tPatchGetter(harmony, %s, \"get_StartingDeck\", nameof(DeckPostfix_%d));" % [JSON.stringify(String(p["character"])), i])
		if not (p["relics"] as Array).is_empty():
			lines.append("\t\tPatchGetter(harmony, %s, \"get_StartingRelics\", nameof(RelicsPostfix_%d));" % [JSON.stringify(String(p["character"])), i])
	lines.append("\t}")
	lines.append("")
	lines.append("\tprivate static void PatchGetter(Harmony harmony, string characterName, string getterName, string postfixName)")
	lines.append("\t{")
	lines.append("\t\tvar characterType = AccessTools.TypeByName(characterName);")
	lines.append("\t\tif (characterType == null)")
	lines.append("\t\t{")
	lines.append("\t\t\tGD.PrintErr($\"[CardRelicForge] Starting content target '{characterName}' was not found. Ensure its character mod is installed and loaded.\");")
	lines.append("\t\t\treturn;")
	lines.append("\t\t}")
	lines.append("\t\tvar getter = AccessTools.Method(characterType, getterName);")
	lines.append("\t\tvar postfix = AccessTools.Method(typeof(StartingContentPatches), postfixName);")
	lines.append("\t\tif (getter == null || postfix == null)")
	lines.append("\t\t{")
	lines.append("\t\t\tGD.PrintErr($\"[CardRelicForge] Could not patch {characterName}.{getterName}.\");")
	lines.append("\t\t\treturn;")
	lines.append("\t\t}")
	lines.append("\t\tharmony.Patch(getter, postfix: new HarmonyMethod(postfix));")
	lines.append("\t}")
	for i in patches.size():
		lines.append(_emit_patch_methods(patches[i], i))
	lines.append("}")
	lines.append("")
	return "\n".join(lines)


static func _emit_patch_methods(p: Dictionary, index: int) -> String:
	var lines: Array = []
	if not (p["cards"] as Array).is_empty():
		lines.append("\tprivate static void DeckPostfix_%d(ref IEnumerable<CardModel> __result)" % index)
		lines.append("\t{")
		lines.append("\t\tvar added = new List<CardModel>();")
	for c in p["cards"]:
		var cname := String(c["class_name"])
		var copies := int(c["copies"])
		lines.append("\t\tfor (int i = 0; i < %d; i++)" % copies)
		lines.append("\t\t{")
		lines.append("\t\t\tadded.Add(ModelDb.Card<%s>());" % cname)
		lines.append("\t\t}")
	if not (p["cards"] as Array).is_empty():
		lines.append("\t\t__result = __result.Concat(added);")
		lines.append("\t}")
	if not (p["relics"] as Array).is_empty():
		lines.append("\tprivate static void RelicsPostfix_%d(ref IReadOnlyList<RelicModel> __result)" % index)
		lines.append("\t{")
		lines.append("\t\tvar added = new List<RelicModel>();")
		for r in p["relics"]:
			lines.append("\t\tadded.Add(ModelDb.Relic<%s>());" % String(r["class_name"]))
		lines.append("\t\t__result = __result.Concat(added).ToList();")
		lines.append("\t}")
	lines.append("")
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# C# emission — cards
# ---------------------------------------------------------------------------

## `mod_cards` maps this mod's own localization entries to their C# class names,
## which is what a `generate_card` effect needs in order to name the class it
## creates. Game cards are resolved from the schema instead.
static func emit_card(schema: CFSchema, card: Dictionary, mod_id: String,
		mod_cards: Dictionary = {}) -> String:
	var cls := String(card.get("id", "Card"))
	var keywords: Array = card.get("keywords", [])
	var tags: Array = card.get("tags", [])
	var vars: Array = card.get("vars", [])
	var effects: Array = card.get("effects", [])
	var up: Dictionary = card.get("upgrade", {})
	var flags: Dictionary = card.get("flags", {})
	var cost := int(card.get("cost", 1))
	var card_target_type := String(card.get("target", "AnyEnemy"))
	var needs_target := _targets_card_target(effects, card_target_type)

	var lines: Array = []
	for u in _merge_usings(CFEffects.usings_for(effects, false),
			_decl_usings(schema, effects, vars, mod_cards, "card")):
		lines.append("using %s;" % u)
	lines.append("")
	lines.append("namespace %s;" % mod_id)
	lines.append("")
	lines.append("/// <summary>")
	lines.append("/// %s — 由 CardRelicForge 生成。" % CFDesign.render_title(card, "zhs"))
	lines.append("/// ID：%s ｜ 本地化键：%s" % [cls, CFIds.loc_key(String(card.get("entry", "")), "title")])
	lines.append("/// </summary>")
	lines.append("public sealed class %s : CardModel" % cls)
	lines.append("{")
	if not keywords.is_empty():
		lines.append("\tpublic override IEnumerable<CardKeyword> CanonicalKeywords => new[]")
		lines.append("\t{")
		lines.append("\t\t%s," % ", ".join(keywords.map(func(k): return "CardKeyword.%s" % k)))
		lines.append("\t};")
		lines.append("")
	if not tags.is_empty():
		lines.append("\tprotected override HashSet<CardTag> CanonicalTags => new HashSet<CardTag>")
		lines.append("\t{")
		lines.append("\t\t%s," % ", ".join(tags.map(func(t): return "CardTag.%s" % t)))
		lines.append("\t};")
		lines.append("")
	if not vars.is_empty():
		lines.append("\tprotected override IEnumerable<DynamicVar> CanonicalVars => new DynamicVar[]")
		lines.append("\t{")
		for v in vars:
			lines.append("\t\t%s," % emit_var(schema, v))
		lines.append("\t};")
		lines.append("")
	if bool(card.get("has_x_cost", false)):
		lines.append("\tprotected override bool HasEnergyCostX => true;")
		lines.append("")
	var star_cost := int(card.get("star_cost", -1))
	if star_cost >= 0:
		lines.append("\tpublic override int CanonicalStarCost => %d;" % star_cost)
		lines.append("")
	var max_up := int(card.get("max_upgrade_level", 1))
	if max_up > 1:
		lines.append("\tpublic override int MaxUpgradeLevel => %d;" % max_up)
		lines.append("")
	if not bool(flags.get("show_in_card_library", true)):
		lines.append("\tpublic override bool ShouldShowInCardLibrary => false;")
		lines.append("")
	if bool(flags.get("gains_block", false)):
		lines.append("\tpublic override bool GainsBlock => true;")
		lines.append("")

	lines.append("\tpublic %s() : base(%d, CardType.%s, CardRarity.%s, TargetType.%s)"
			% [cls, cost, card.get("type", "Attack"), card.get("rarity", "Common"), card.get("target", "AnyEnemy")])
	lines.append("\t{")
	lines.append("\t}")
	lines.append("")

	lines.append("\tprotected override async Task OnPlay(PlayerChoiceContext choiceContext, CardPlay cardPlay)")
	lines.append("\t{")
	if needs_target:
		lines.append("\t\tArgumentNullException.ThrowIfNull(cardPlay.Target, \"cardPlay.Target\");")
	var body := CFEffects.emit_effects(effects, {
		"ind": "\t\t", "choice_ctx": "choiceContext", "scope": "card",
		"params": {}, "card_play": "cardPlay", "schema": schema,
		"card_target_type": card_target_type,
		"mod_cards": mod_cards,
	})
	if body.is_empty():
		lines.append("\t\t// TODO: 这张牌还没有配置效果。")
		lines.append("\t\tawait Task.CompletedTask;")
	else:
		for l in body:
			lines.append(l)
	lines.append("\t}")
	lines.append("")

	var up_lines := _emit_upgrade_lines(schema, vars, up)
	if not up_lines.is_empty():
		lines.append("\tprotected override void OnUpgrade()")
		lines.append("\t{")
		for l in up_lines:
			lines.append(l)
		lines.append("\t}")
		lines.append("")

	lines.append("}")
	lines.append("")
	return "\n".join(lines)


static func _emit_upgrade_lines(schema: CFSchema, vars: Array, up: Dictionary) -> Array:
	var out: Array = []
	for v in vars:
		var delta := float(v.get("upgrade_delta", 0.0))
		if absf(delta) > 0.0001:
			# The var's *name* is not a `DynamicVarSet` property — only a handful
			# of those exist. `dynvar_expr` picks the property when one exists and
			# the string indexer otherwise, which is what the game does too.
			out.append("\t\t%s.UpgradeValueBy(%sm);" % [schema.dynvar_expr(String(v.get("name", "Damage"))), _dec(delta)])
	var cost_delta := int(up.get("cost_delta", 0))
	if cost_delta != 0:
		out.append("\t\tbase.EnergyCost.UpgradeBy(%d);" % cost_delta)
	for k in up.get("keywords_add", []):
		out.append("\t\tAddKeyword(CardKeyword.%s);" % k)
	for k in up.get("keywords_remove", []):
		out.append("\t\tRemoveKeyword(CardKeyword.%s);" % k)
	return out


## True when at least one enabled effect resolves to the card's own target.
static func _targets_card_target(effects: Array, card_target_type: String = "AnyEnemy") -> bool:
	# All-target constructors resolve through CombatState and do not populate a
	# single CardPlay.Target. Only add the null guard for cards that genuinely
	# require the player to pick one creature/card target.
	if card_target_type in ["AllEnemies", "RandomEnemy", "AllAllies", "Self"]:
		return false
	for e in effects:
		if not bool(e.get("enabled", true)):
			continue
		var spec := CFEffects.kind_by_id(String(e.get("kind", "")))
		var t := String(e.get("target", ""))
		if t.is_empty():
			t = String(spec.get("default_target", "self"))
		if t == "card_target":
			return true
	return false


# ---------------------------------------------------------------------------
# C# emission — relics
# ---------------------------------------------------------------------------

static func emit_relic(schema: CFSchema, relic: Dictionary, mod_id: String,
		mod_cards: Dictionary = {}) -> String:
	var cls := String(relic.get("id", "Relic"))
	var triggers: Array = relic.get("triggers", [])
	var vars: Array = relic.get("vars", [])

	var all_effects: Array = []
	for t in triggers:
		for e in t.get("effects", []):
			all_effects.append(e)

	var lines: Array = []
	var usings: Array = CFEffects.usings_for(all_effects, true)
	var extra: Array = _hook_usings(schema, triggers)
	extra.append_array(_decl_usings(schema, all_effects, vars, mod_cards, "relic"))
	for u in _merge_usings(usings, extra):
		lines.append("using %s;" % u)
	lines.append("")
	lines.append("namespace %s;" % mod_id)
	lines.append("")
	lines.append("/// <summary>")
	lines.append("/// %s — 由 CardRelicForge 生成。" % CFDesign.render_title(relic, "zhs"))
	lines.append("/// ID：%s ｜ 本地化键：%s" % [cls, CFIds.loc_key(String(relic.get("entry", "")), "title")])
	lines.append("/// </summary>")
	lines.append("public sealed class %s : RelicModel" % cls)
	lines.append("{")
	lines.append("\tpublic override RelicRarity Rarity => RelicRarity.%s;" % relic.get("rarity", "Common"))
	lines.append("")
	if not vars.is_empty():
		lines.append("\tprotected override IEnumerable<DynamicVar> CanonicalVars => new DynamicVar[]")
		lines.append("\t{")
		for v in vars:
			lines.append("\t\t%s," % emit_var(schema, v))
		lines.append("\t};")
		lines.append("")
	lines.append("\tpublic override bool ShouldReceiveCombatHooks => true;")
	lines.append("")
	if bool(relic.get("stackable", false)):
		lines.append("\tpublic override bool IsStackable => true;")
		lines.append("")
	if bool(relic.get("show_counter", false)):
		var period := maxi(1, int(relic.get("counter_period", 3)))
		lines.append("\tprivate int _triggerCount;")
		lines.append("")
		lines.append("\tpublic override bool ShowCounter => true;")
		lines.append("")
		lines.append("\tpublic override int DisplayAmount => _triggerCount %% %d;" % period)
		lines.append("")

	for t in triggers:
		for line in _emit_trigger(schema, t, mod_cards):
			lines.append(line)

	lines.append("}")
	lines.append("")
	return "\n".join(lines)


## Add a `using` namespace to a list of them, ignoring empties and duplicates.
static func _add_ns(out: Array, ns: String) -> void:
	var s := ns.strip_edges()
	if not s.is_empty() and not out.has(s):
		out.append(s)


## `usings_for` plus `extra`, de-duplicated and sorted.
static func _merge_usings(base: Array, extra: Array) -> Array:
	var out: Array = base.duplicate()
	for u in extra:
		_add_ns(out, String(u))
	out.sort()
	return out


## Namespaces that the *body* of a generated file needs on top of the fixed list
## `CFEffects.usings_for` returns. Both of these are only knowable from the
## schema, which the fixed list has no access to:
##
##   * a `PowerVar<T>` or `PowerCmd.Apply<T>` names a power class, and the game's
##     test doubles live in a `.Mocks` sub-namespace — a bare
##     `using ...Models.Powers;` leaves those unresolved (CS0246) and the whole
##     mod fails to compile;
##   * `generate_card` names a card model class, and the game's cards live in
##     `...Core.Models.Cards`.
static func _decl_usings(schema: CFSchema, effects: Array, vars: Array,
		mod_cards: Dictionary, scope: String) -> Array:
	var out: Array = []
	for v in vars:
		if String(v.get("type", "")) != "PowerVar":
			continue
		var generic := String(v.get("generic", "")).strip_edges()
		if not generic.is_empty():
			_add_ns(out, schema.power_namespace(generic))
	for e in effects:
		if not bool(e.get("enabled", true)):
			continue
		match String(e.get("kind", "")):
			"apply_power":
				var power := String(e.get("power", "")).strip_edges()
				if not power.is_empty():
					_add_ns(out, schema.power_namespace(power))
			"generate_card":
				var ctx := {"scope": scope, "mod_cards": mod_cards, "schema": schema}
				_add_ns(out, schema.type_namespace(
						CFEffects.resolve_card_class(String(e.get("card_entry", "")), ctx)))
	return out


## `_emit_trigger` repeats each hook's parameter and return types verbatim, so the
## relic file needs a `using` for every namespace those types live in. The fixed
## list in `CFEffects.usings_for` cannot cover them all — `AfterAttack` alone
## mentions `AttackCommand`, which lives in `...Core.Commands.Builders` (CS0246).
static func _hook_usings(schema: CFSchema, triggers: Array) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for t in triggers:
		var h := schema.hook(String(t.get("hook", "")))
		if h.is_empty():
			continue
		var names: Array = _type_tokens(String(h.get("return_type", "")))
		for p in h.get("params", []):
			names.append_array(_type_tokens(_param_type(String(p))))
		for n in names:
			var name := String(n)
			if seen.has(name):
				continue
			seen[name] = true
			var ns := schema.type_namespace(name)
			if not ns.is_empty() and not out.has(ns):
				out.append(ns)
	return out


## The leading type expression of a C# parameter declaration, e.g.
## `IReadOnlyList<CardModel> cards = null` -> `IReadOnlyList<CardModel>`.
static func _param_type(param: String) -> String:
	var s := param.strip_edges()
	var eq := s.find("=")
	if eq >= 0:
		s = s.substr(0, eq).strip_edges()
	var sp := s.rfind(" ")
	if sp <= 0:
		return s
	return s.substr(0, sp).strip_edges()


## Every bare identifier in a C# type expression.
static func _type_tokens(type_expr: String) -> Array:
	var out: Array = []
	var cur := ""
	for i in type_expr.length():
		var c := type_expr[i]
		if c == "_" or (c >= "0" and c <= "9") \
				or (c >= "A" and c <= "Z") or (c >= "a" and c <= "z"):
			cur += c
		elif not cur.is_empty():
			out.append(cur)
			cur = ""
	if not cur.is_empty():
		out.append(cur)
	return out


static func _emit_trigger(schema: CFSchema, t: Dictionary, mod_cards: Dictionary = {}) -> Array:
	var lines: Array = []
	var hook_name := String(t.get("hook", ""))
	if hook_name.is_empty():
		return lines
	var h := schema.hook(hook_name)
	if h.is_empty():
		lines.append("")
		lines.append("\t// TODO: 触发时机 %s 在当前 schema 中不存在，已跳过。" % hook_name)
		return lines

	var ret := String(h.get("return_type", "Task"))
	var params: Array = h.get("params", [])
	var is_async := ret.contains("Task")
	var needs_void_return := ret == "void"
	var params_src := ", ".join(params)

	lines.append("")
	lines.append("\t// 触发时机：%s" % schema.hook_label(hook_name))
	var charge: Dictionary = t.get("charge", {})
	var charge_mode := String(charge.get("mode", "always"))
	var n := maxi(1, int(charge.get("n", 1)))
	if charge_mode != "always":
		lines.append("\t// 触发次数限制：%s（N=%d）" % [charge_mode, n])

	# C# requires the override to repeat the base member's accessibility: the
	# game's hooks are `public virtual`, so `protected override` is CS0507.
	var access := String(h.get("access", "public"))
	if access.is_empty():
		access = "public"
	lines.append("\t%s override %s%s %s(%s)"
			% [access, "async " if is_async else "", ret, hook_name, params_src])
	lines.append("\t{")
	var ind := "\t\t"
	if charge_mode == "every_n":
		lines.append("%s_triggerCount++;" % ind)
		lines.append("%sif (_triggerCount %% %d != 0)" % [ind, n])
		lines.append("%s{" % ind)
		lines.append("%s\treturn%s;" % [ind, "" if needs_void_return else " default"])
		lines.append("%s}" % ind)
	elif charge_mode == "first_n":
		lines.append("%s_triggerCount++;" % ind)
		lines.append("%sif (_triggerCount > %d)" % [ind, n])
		lines.append("%s{" % ind)
		lines.append("%s\treturn%s;" % [ind, "" if needs_void_return else " default"])
		lines.append("%s}" % ind)
	elif charge_mode == "once":
		lines.append("%sif (_triggerCount > 0)" % ind)
		lines.append("%s{" % ind)
		lines.append("%s\treturn%s;" % [ind, "" if needs_void_return else " default"])
		lines.append("%s}" % ind)
		lines.append("%s_triggerCount++;" % ind)

	# Parameter bindings: what each hook parameter is called in the effects.
	var bindings: Dictionary = t.get("params", {})
	# A parameter literally named `choiceContext` shadows nothing, but a binding
	# must still be a legal expression; keep only identifiers we declared.
	var available: Dictionary = {}
	for p in params:
		var raw := String(p)
		var sp := raw.find(" ")
		if sp <= 0:
			continue
		var var_name := raw.substr(sp + 1).strip_edges().trim_prefix("?")
		var eq := var_name.find("=")
		if eq >= 0:
			var_name = var_name.substr(0, eq).strip_edges()
		available[var_name] = true
	var chosen: Dictionary = {}
	for k in bindings.keys():
		var v := String(bindings[k])
		# A binding is either "" (unbound) or an identifier we can name.
		if v.is_empty():
			continue
		var ident := v.trim_prefix("_")
		if not available.has(ident) and not available.has(v):
			continue
		chosen[v] = v

	var choice_var := "choiceContext"
	if available.has("choiceContext"):
		choice_var = "choiceContext"
	elif available.has("ctx"):
		choice_var = "ctx"
	# Some hooks have no PlayerChoiceContext parameter at all; the effects still
	# need one, so fall back to the player's own context factory.
	var has_choice := false
	for p in params:
		if String(p).contains("PlayerChoiceContext"):
			has_choice = true
			break
	if not has_choice:
		if _effects_need_choice(t.get("effects", [])):
			# Lifecycle hooks such as AfterObtained have no context parameter, but
			# the command APIs still require one. The game uses a blocking context
			# for AfterObtained (it may run outside combat) and a throwing context
			# for other hooks where a choice must never suspend the hook forever.
			choice_var = "new BlockingPlayerChoiceContext()" \
				if hook_name == "AfterObtained" else "new ThrowingPlayerChoiceContext()"
		else:
			choice_var = "null!"

	var body := CFEffects.emit_effects(t.get("effects", []), {
		"ind": ind, "choice_ctx": choice_var, "scope": "relic",
		"params": chosen, "card_play": "cardPlay" if available.has("cardPlay") else "",
		"schema": schema, "mod_cards": mod_cards,
	})
	if body.is_empty():
		lines.append("%s// TODO: 这个触发时机还没有配置效果。" % ind)
		if is_async:
			lines.append("%sawait Task.CompletedTask;" % ind)
	else:
		for l in body:
			lines.append(l)
	lines.append("\t}")
	return lines


## True when any effect needs a PlayerChoiceContext argument.
static func _effects_need_choice(effects: Array) -> bool:
	for e in effects:
		if not bool(e.get("enabled", true)):
			continue
		if String(e.get("kind", "")) not in ["add_keyword"]:
			return true
	return false


# ---------------------------------------------------------------------------
# C# emission — entry point
# ---------------------------------------------------------------------------

static func _custom_pool_is_used(db: CFDesignDb, pool: String, relic: bool) -> bool:
	if pool.is_empty():
		return false
	for item in (db.relics if relic else db.cards):
		if String(item.get("pool", "")) == pool:
			return true
	return false


static func _pool_class(schema: CFSchema, db: CFDesignDb, pool: String, relic: bool) -> String:
	var scanned := String(schema.pool_by_class(pool, relic).get("class_name", ""))
	if not scanned.is_empty():
		return scanned
	for character in db.custom_characters:
		var field := "relic_pool" if relic else "card_pool"
		if String(character.get(field, "")) == pool and _custom_pool_is_used(db, pool, relic):
			return pool
	return ""


static func emit_custom_pool(db: CFDesignDb, character: Dictionary, pool: String,
		relic: bool, mod_id: String) -> String:
	character = CFCharacters.normalized(character)
	var template := String(character["template"])
	var independent := CFCharacters.is_independent(character)
	var kind := "Relics" if relic else "Cards"
	var base := "RelicPoolModel" if relic else "CardPoolModel"
	var model := "RelicModel" if relic else "CardModel"
	var method := "GenerateAllRelics" if relic else "GenerateAllCards"
	var pool_namespace := "%s.Models.%sPools" % [mod_id, "Relic" if relic else "Card"]
	var lines: Array = ["using System.Collections.Generic;", "using System.Linq;", "using MegaCrit.Sts2.Core.Models;",
		"using MegaCrit.Sts2.Core.Models.Characters;"]
	if not relic:
		lines.append("using Godot;")
		lines.append("using MegaCrit.Sts2.Core.Entities.Cards;")
	else:
		lines.append("using MegaCrit.Sts2.Core.Entities.Relics;")
	lines.append("using %s;" % mod_id)
	lines.append("")
	lines.append("namespace %s;" % pool_namespace)
	lines.append("")
	lines.append("public sealed class %s : %s" % [pool, base])
	lines.append("{")
	if not independent:
		lines.append("\tprivate static %s Template => ModelDb.Character<%s>().%sPool;" % [base, template, "Relic" if relic else "Card"])
	if relic:
		lines.append("\tpublic override string EnergyColorName => %s;" % ('"colorless"' if independent else "Template.EnergyColorName"))
	else:
		lines.append("\tpublic override string Title => \"%s\";" % pool.trim_suffix("CardPool").to_snake_case().to_lower())
		lines.append("\tpublic override string EnergyColorName => %s;" % ('"colorless"' if independent else "Template.EnergyColorName"))
		lines.append("\tpublic override string CardFrameMaterialPath => %s;" % ('"card_frame_colorless"' if independent else "Template.CardFrameMaterialPath"))
		lines.append("\tpublic override Color DeckEntryCardColor => %s;" % ('new Color("75CFC5")' if independent else "Template.DeckEntryCardColor"))
		lines.append("\tpublic override Color EnergyOutlineColor => %s;" % ('new Color("183C40")' if independent else "Template.EnergyOutlineColor"))
		lines.append("\tpublic override bool IsColorless => false;")
	lines.append("")
	lines.append("\tprotected override %s %s()" % ["IEnumerable<%s>" % model if relic else "%s[]" % model, method])
	lines.append("\t{")
	lines.append("\t\treturn new %s[]" % model)
	lines.append("\t\t{")
	var items := db.relics if relic else db.cards
	var models: Array[String] = []
	for item in items:
		if String(item.get("pool", "")) == pool and not String(item.get("id", "")).is_empty():
			models.append("\t\t\tModelDb.%s<%s>()" % ["Relic" if relic else "Card", item.get("id", "")])
	lines.append(",\n".join(models))
	if bool(character["include_base_relics" if relic else "include_base_cards"]):
		lines.append("\t\t}.Concat(Template.%s).Distinct().ToArray();" % ("AllRelics" if relic else "AllCards"))
	else:
		lines.append("\t\t};")
	lines.append("\t}")
	lines.append("}")
	return "\n".join(lines) + "\n"

static func emit_independent_potion_pool(mod_id: String, pool: String) -> String:
	# The game's shared potion pool is added by its reward system. This pool is
	# only for character-specific potions, so it must not inherit Defect etc.
	return "\n".join([
		"using System;", "using System.Collections.Generic;", "using MegaCrit.Sts2.Core.Models;",
		"namespace %s.Models.PotionPools;" % mod_id,
		"public sealed class %s : PotionPoolModel" % pool, "{",
		'\tpublic override string EnergyColorName => "colorless";',
		"\tprotected override IEnumerable<PotionModel> GenerateAllPotions() => Array.Empty<PotionModel>();", "}", ""])

static func emit_mod_entry(schema: CFSchema, db: CFDesignDb, mod_id: String,
		card_classes: Array, relic_classes: Array, patches: Array, with_harmony: bool) -> String:
	var pool_usings: Dictionary = {}
	for c in db.cards:
		var ns := String(schema.pool_by_class(String(c.get("pool", "")), false).get("namespace", ""))
		if not ns.is_empty():
			pool_usings[ns] = true
	for r in db.relics:
		var ns := String(schema.pool_by_class(String(r.get("pool", "")), true).get("namespace", ""))
		if not ns.is_empty():
			pool_usings[ns] = true
	for character in db.custom_characters:
		var card_pool := String(character.get("card_pool", ""))
		var relic_pool := String(character.get("relic_pool", ""))
		if _custom_pool_is_used(db, card_pool, false):
			pool_usings["%s.Models.CardPools" % mod_id] = true
		if _custom_pool_is_used(db, relic_pool, true):
			pool_usings["%s.Models.RelicPools" % mod_id] = true
	var keys := pool_usings.keys()
	keys.sort()

	var lines: Array = []
	lines.append("using MegaCrit.Sts2.Core.Modding;")
	if not db.custom_characters.is_empty():
		lines.append("using STS2RitsuLib;")
	for k in keys:
		lines.append("using %s;" % k)
	lines.append("")
	lines.append("namespace %s;" % mod_id)
	lines.append("")
	lines.append("/// <summary>")
	lines.append("/// Mod 入口。")
	lines.append("///")
	lines.append("/// 重要：ModInitializerAttribute 的 AttributeUsage 是 AttributeTargets.Class，")
	lines.append("/// 它标在**类**上，把要调用的方法名作为参数传入 —— 标在方法上会编译不过（CS0592）。")
	lines.append("/// </summary>")
	lines.append("[ModInitializer(nameof(Initialize))]")
	lines.append("public static class ModEntry")
	lines.append("{")
	lines.append("\tpublic static void Initialize()")
	lines.append("\t{")
	if not db.custom_characters.is_empty():
		lines.append("\t\tvar content = RitsuLibFramework.GetContentRegistry(%s);" % JSON.stringify(mod_id))
	for character in db.custom_characters:
		lines.append("\t\tcontent.RegisterCharacter<global::%s.Models.Characters.%s>();" % [mod_id, CFCharacters.code_name(String(character["id"]))])
		var tome := CFAncientDialogues.tome_card(character, db)
		if not tome.is_empty() and (CFCharacters.is_independent(character) or not String(character.get("ancient_tome_card", "")).is_empty()):
			lines.append("\t\tRitsuLibFramework.RegisterDustyTomeCard<global::%s.Models.Characters.%s, global::%s.%s>(%s);" % [mod_id, CFCharacters.code_name(String(character["id"])), mod_id, tome, JSON.stringify(mod_id)])
	if db.cards.is_empty() and db.relics.is_empty():
		lines.append("\t\t// 没有任何内容。")
	else:
		for c in db.cards:
			# Custom pools enumerate their members themselves. Registering twice
			# would duplicate rewards in CardPoolModel.AllCards.
			if CFCharacters.owns_pool(db, String(c.get("pool", "")), false):
				continue
			var cls := String(c.get("id", ""))
			if cls.is_empty():
				continue
			var pool := _pool_class(schema, db, String(c.get("pool", "")), false)
			if pool.is_empty():
				lines.append("\t\t// 警告：%s 没有有效卡池，请在工具里重新选择。" % cls)
				continue
			lines.append("\t\tModHelper.AddModelToPool<%s, %s>();" % [pool, cls])
		if not db.cards.is_empty() and not db.relics.is_empty():
			lines.append("")
		for r in db.relics:
			if CFCharacters.owns_pool(db, String(r.get("pool", "")), true):
				continue
			var rcls := String(r.get("id", ""))
			if rcls.is_empty():
				continue
			var rpool := _pool_class(schema, db, String(r.get("pool", "")), true)
			if rpool.is_empty():
				lines.append("\t\t// 警告：%s 没有有效遗物池，请在工具里重新选择。" % rcls)
				continue
			lines.append("\t\tModHelper.AddModelToPool<%s, %s>();" % [rpool, rcls])
	if not patches.is_empty():
		lines.append("")
		lines.append("\t\t// 带 [ModInitializer] 的程序集不会自动应用 Harmony 补丁，必须主动安装。")
		lines.append("\t\tPatches.StartingContentPatches.ApplyAll();")
	lines.append("\t}")
	lines.append("}")
	lines.append("")
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# Project file & scripts
# ---------------------------------------------------------------------------

static func emit_csproj(mod_id: String, game_assembly: String, godotsharp_dir: String,
		with_harmony: bool, ritsulib_dir: String = "", ritsu_target: String = "0.107.1") -> String:
	var sts2 := game_assembly.replace("\\", "/")
	var gs := godotsharp_dir.replace("\\", "/")
	var harmony_ref := ""
	if not with_harmony:
		# Previous exports may have this generated file. Keep it on disk for
		# review, but don't compile a retired patch after starters move into a
		# RitsuLib character's LocalStartingDeck/LocalStartingRelics.
		harmony_ref = "\n  <ItemGroup><Compile Remove=\"Patches/StartingContentPatches.cs\" /></ItemGroup>\n"
	var ritsu_ref := ""
	if not ritsulib_dir.is_empty():
		ritsu_ref = """
  <PropertyGroup>
    <RitsuLibDir Condition="'$(RitsuLibDir)' == ''">%s</RitsuLibDir>
    <RitsuLibReferenceTarget>%s</RitsuLibReferenceTarget>
  </PropertyGroup>
  <Import Project="$(RitsuLibDir)/RitsuLib.References.props" />
""" % [ritsulib_dir.replace("\\", "/").xml_escape(), ritsu_target.xml_escape()]
	if with_harmony:
		# 0Harmony.dll ships next to sts2.dll (in data_sts2_windows_x86_64/),
		# not in the game root. Deriving it from the assembly path is the only
		# location that is right for both a Steam install and a portable copy.
		harmony_ref = """
  <ItemGroup>
    <!-- 0Harmony 由游戏本体提供，绝不能复制到输出目录。
         它和 sts2.dll 同级（data_sts2_windows_x86_64/），不在游戏根目录。 -->
    <Reference Include="0Harmony">
      <HintPath>$(GameAssemblyDir)/0Harmony.dll</HintPath>
      <Private>false</Private>
    </Reference>
  </ItemGroup>
"""
	return """<Project Sdk="Godot.NET.Sdk/4.5.1">
  <!-- Generated by CardRelicForge.
       This is a plain class library: it is NOT the Godot project, it only
       produces <ModId>.dll which the game loads from the mods folder. -->
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <AssemblyName>%s</AssemblyName>
    <RootNamespace>%s</RootNamespace>
    <Nullable>enable</Nullable>
    <LangVersion>13.0</LangVersion>
    <EnableDynamicLoading>True</EnableDynamicLoading>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
    <GenerateAssemblyInfo>true</GenerateAssemblyInfo>
    <GameAssembly Condition="'$(GameAssembly)' == ''">%s</GameAssembly>
    <GodotSharpDir Condition="'$(GodotSharpDir)' == ''">%s</GodotSharpDir>
    <GameDir Condition="'$(GameDir)' == ''">$(GodotSharpDir)</GameDir>
    <!-- 0Harmony 与 sts2.dll 同级；从 sts2.dll 反推目录最稳。 -->
    <GameAssemblyDir Condition="'$(GameAssemblyDir)' == ''">$([System.IO.Path]::GetDirectoryName($(GameAssembly)))</GameAssemblyDir>
  </PropertyGroup>
  <ItemGroup>
    <Reference Include="sts2">
      <HintPath>$(GameAssembly)</HintPath>
      <Private>false</Private>
    </Reference>
    <Reference Include="GodotSharp">
      <HintPath>$(GodotSharpDir)/GodotSharp.dll</HintPath>
      <Private>false</Private>
    </Reference>
  </ItemGroup>%s</Project>
""" % [mod_id, mod_id, sts2.xml_escape(), gs.xml_escape(), harmony_ref + ritsu_ref]


static func emit_build_script(mod_id: String, compat_target: String, game_assembly: String,
		godotsharp_dir: String, patch_count: int) -> String:
	var tpl := PS1_HEADER + """#
#   powershell -File build.ps1
#   powershell -File build.ps1 -GameDir "E:\\steam\\steamapps\\common\\Slay the Spire 2"
#
# Steps: dotnet build -> <ModId>.dll, copy it next to the manifest, then copy
# the whole folder into <GameDir>\\mods\\.
#
# NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 reads a
# BOM-less .ps1 as ANSI, so non-ASCII comments would corrupt the script.
param(
    [string]$GameDir = "",
    [string]$GameAssembly = "",
    [string]$GodotSharpDir = ""
)

$ErrorActionPreference = "Stop"
$modId = "%MOD_ID%"
$compatTarget = "%COMPAT_TARGET%"
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }

# Absolute fallbacks are read from a side-car file rather than embedded here,
# because a workspace path may contain non-ASCII characters and this script
# must stay pure ASCII (PowerShell 5.1 reads BOM-less .ps1 as ANSI).
if ($GameDir -eq "") {
    $cfg = $here + "\\forge-paths.txt"
    if (Test-Path -LiteralPath $cfg) {
        foreach ($line in Get-Content -LiteralPath $cfg) {
            if ($line.StartsWith("game_dir=")) { $GameDir = $line.Substring(9) }
            elseif ($line.StartsWith("game_assembly=")) { $GameAssembly = $line.Substring(14) }
            elseif ($line.StartsWith("godotsharp_dir=")) { $GodotSharpDir = $line.Substring(16) }
        }
    }
}

if ($GameDir -ne "") {
    if ($GameAssembly -eq "") {
        $GameAssembly = $GameDir + "\\data_sts2_windows_x86_64\\sts2.dll"
    }
    if ($GodotSharpDir -eq "") {
        $GodotSharpDir = $GameDir + "\\data_sts2_windows_x86_64"
    }
}
if ($GodotSharpDir -eq "") {
    Write-Host "WARNING: GodotSharpDir is empty; pass -GodotSharpDir or add forge-paths.txt"
}

Write-Host "==> dotnet build"
dotnet build ($here + "\\src\\" + $modId + ".csproj") -c Release -p:GameAssembly=$GameAssembly -p:GodotSharpDir=$GodotSharpDir
$buildExitCode = $LASTEXITCODE
if ($buildExitCode -ne 0) {
    throw "dotnet build failed with exit code $buildExitCode; the old DLL was not copied or installed."
}

$built = $here + "\\src\\.godot\\mono\\temp\\bin\\Release\\" + $modId + ".dll"
if (-not (Test-Path -LiteralPath $built)) {
    $built = $here + "\\src\\bin\\Release\\" + $modId + ".dll"
}
if (-not (Test-Path -LiteralPath $built)) { throw "build did not produce " + $modId + ".dll" }

Copy-Item -LiteralPath $built -Destination ($here + "\\" + $modId + ".dll") -Force
Write-Host ("==> " + $modId + ".dll")

# Refresh the variants manifest with a real hash and stage the per-version copy.
$kebab = ($modId -creplace '([a-z0-9])([A-Z])', '$1-$2').ToLowerInvariant()
$variantManifest = $here + "\\" + $kebab + "-variants.manifest"
$libDir = $here + "\\lib\\" + $compatTarget
New-Item -ItemType Directory -Force -Path $libDir | Out-Null
Copy-Item -LiteralPath $built -Destination ($libDir + "\\" + $modId + ".dll") -Force
$sha = (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash.ToLower()
$variants = [ordered]@{
    schema   = 1
    variants = @([ordered]@{
        compatTarget = $compatTarget
        directory    = "lib/" + $compatTarget
        assembly     = $modId + ".dll"
        sha256       = $sha
    })
}
$variants | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $variantManifest -Encoding UTF8
Write-Host ("==> sha256 " + $sha)

if ($GameDir -ne "") {
    $dest = $GameDir + "\\mods\\" + $modId
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item ($here + "\\*") $dest -Recurse -Force -Exclude @("src", "assets", "obj", "bin", "lib")
    Write-Host ("==> installed to " + $dest)
    Write-Host "    the game loads mods from <game exe dir>\\mods\\ (not user://mods)."
} else {
    Write-Host "==> skipped install (no -GameDir given)"
}
"""
	# The script is deliberately ASCII-only: Windows PowerShell 5.1 reads a
	# BOM-less .ps1 as ANSI, so any non-ASCII byte would corrupt it.
	var out := tpl.replace("%MOD_ID%", mod_id)
	out = out.replace("%COMPAT_TARGET%", compat_target)
	return out


## Paths the generated build script falls back to. Written as a side-car so the
## `.ps1` itself can stay ASCII-only, which Windows PowerShell 5.1 requires.
static func emit_paths_file(game_assembly: String, godotsharp_dir: String, game_dir: String) -> String:
	return "game_dir=%s\ngame_assembly=%s\ngodotsharp_dir=%s\n" % [
		game_dir, game_assembly, godotsharp_dir]


static func emit_build_cmd() -> String:
	return "@echo off\nrem Convenience wrapper: forwards to build.ps1.\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0build.ps1\" %*\n"


# ---------------------------------------------------------------------------
# Documentation
# ---------------------------------------------------------------------------

static func emit_readme(schema: CFSchema, db: CFDesignDb, mod_id: String,
		compat_target: String, art_notes: Array, patches: Array) -> String:
	var card_list: Array = []
	for c in db.cards:
		card_list.append("- `%s` → %s（%s / %s / %s）" % [
			c.get("id", "?"), CFDesign.render_title(c, "zhs"),
			c.get("type", "?"), c.get("rarity", "?"), c.get("pool", "?")])
	var relic_list: Array = []
	for r in db.relics:
		relic_list.append("- `%s` → %s（%s / %s）" % [
			r.get("id", "?"), CFDesign.render_title(r, "zhs"),
			r.get("rarity", "?"), r.get("pool", "?")])

	var deck_lines: Array = []
	for p in patches:
		var parts: Array = []
		for c in p["cards"]:
			parts.append("%s ×%d" % [c["class_name"], c["copies"]])
		for r in p["relics"]:
			parts.append("%s（遗物）" % r["class_name"])
		deck_lines.append("- %s：%s" % [p["character"], ", ".join(parts)])

	var md := "# %s\n\n由 **CardRelicForge** 导出。\n\n" % db.mod_name
	md += "- Mod ID：`%s`\n- 版本：`%s`\n- 兼容目标：`%s`\n- Schema 来源：`%s`\n- 扫描时间：`%s`\n\n" % [
		mod_id, db.mod_version, compat_target, schema.source_root, schema.scanned_at]
	md += "## 内容\n\n### 卡牌（%d）\n%s\n\n### 遗物（%d）\n%s\n" % [
		db.cards.size(), "\n".join(card_list) if not card_list.is_empty() else "- （无）",
		db.relics.size(), "\n".join(relic_list) if not relic_list.is_empty() else "- （无）"]
	if not deck_lines.is_empty():
		md += "\n## 开局注入（Harmony 补丁）\n\n" + "\n".join(deck_lines) + "\n"
	# Substituted with replace() rather than `%` formatting: the prose contains
	# literal `%` characters (progress notes) that would break a format string.
	md += README_TAIL.replace("{id}", mod_id) \
			.replace("{art}", "\n".join(ArtNotesHelper.to_lines(art_notes)))
	return md


## Kept out of the function body so the braces and percent signs inside it are
## never treated as a format string.
const README_TAIL := """
## 文件说明

| 文件 | 谁读取它 | 说明 |
| --- | --- | --- |
| `{id}.json` | 游戏 | manifest，字段与 `ModManifest.cs` 对应；只有 `id` 是强制的 |
| `{id}.dll` | 游戏 | 由 `build.ps1` 编译生成，包含 CardModel / RelicModel 子类 |
| `{id}.pck` | 游戏 | 资源包，内含本地化（`res://{id}/localization/<lang>/<table>.json`） |
| `<kebab>-variants.manifest` | Mod 自带工具链 | 复刻样例 Mod 的分版本布局，**游戏本体不读取** |
| `src/` | 开发者 | 生成的 C# 源码与 csproj |
| `assets/` | — | pck 内容的可读副本，便于比对 |
| `build.ps1` / `build.cmd` | 开发者 | 编译并安装到 `mods/` |

## 构建

```powershell
powershell -File build.ps1 -GameDir "E:\\steam\\steamapps\\common\\Slay the Spire 2"
```

游戏从 **`<游戏 exe 目录>\\mods\\`** 加载 Mod（不是 `user://mods`）。manifest 可以是该目录下
任意深度的 `*.json`，但 `<id>.dll` 与 `<id>.pck` 必须与它同级。

## 本地化与素材落点

- 本地化：`res://{id}/localization/<lang>/cards.json`、`relics.json`
  （只能合并进**已存在**的表名，新增表名不会被自动加载）
- 卡面：`res://images/packed/card_portraits/<卡池 Title>/<entry 小写>.png`
  （`CardModel.PortraitPngPath`；卡池 Title 见 ① 标识里的卡池，例如 `ironclad`）
- 遗物图标：`res://images/relics/<entry 小写>.png`
- 图片必须**经过 Godot 导入**（生成 `.png.import` 与 `.ctex`）后随 pck 打包；
  裸 PNG 直接塞进 pck，游戏 `ResourceLoader` 读不到，卡面会退回占位图。

## 素材

{art}

## 注意

生成的 C# 是脚手架：效果语句按扫描到的真实命令 API 生成，但目标选择器与部分重载请对照
你自己的游戏版本核对一次。`EXPORT_REPORT.md` 列出了本次引用到的全部 API 与预检问题。
"""


## Small helper so the README tail can stay a constant.
class ArtNotesHelper:
	static func to_lines(notes: Array) -> Array:
		var out: Array = []
		for n in notes:
			out.append("- " + String(n))
		return out


static func emit_report_md(schema: CFSchema, db: CFDesignDb, report: Dictionary,
		mod_id: String, written: Array, art_notes: Array) -> String:
	var md: Array = []
	md.append("# 导出报告 — %s" % mod_id)
	md.append("")
	if bool(report.get("needs_build", false)):
		md.append("> ## ⚠ 这个文件夹还不能直接拷进 mods/")
		md.append(">")
		md.append("> 目前只有 `%s.json` 与 `%s.pck`，**没有 `%s.dll`**。" % [mod_id, mod_id, mod_id])
		md.append("> `.pck` 只能放本地化与素材，卡牌/遗物必须编进 `%s.dll`。" % mod_id)
		md.append("> 直接拷进去游戏会报 “declares that it should load an assembly, but no assembly … was found”，")
		md.append("> 且卡牌不会出现。**请先运行本文件夹的 `build.cmd`，再把整个文件夹拷到 `mods/%s/`。**" % mod_id)
		md.append("")
	md.append("- 卡牌：%d，遗物：%d" % [db.cards.size(), db.relics.size()])
	md.append("- 预检：%d 个错误 / %d 个警告 / %d 条提示" % [
			(report["errors"] as Array).size(), (report["warnings"] as Array).size(),
			(report["infos"] as Array).size()])
	md.append("")
	md.append("## 预检问题")
	md.append("")
	for severity in ["errors", "warnings", "infos"]:
		var list: Array = report[severity]
		if list.is_empty():
			continue
		md.append("### %s（%d）" % [severity, list.size()])
		md.append("")
		for line in list:
			md.append("- %s" % line)
		md.append("")
	if (report["errors"] as Array).is_empty() and (report["warnings"] as Array).is_empty():
		md.append("没有发现问题。")
		md.append("")

	md.append("## 引用的游戏 API（请对照你的游戏版本核对）")
	md.append("")
	md.append("| 效果类型 | 绑定方法 | 签名 |")
	md.append("| --- | --- | --- |")
	var bindings := CFEffects.resolve_bindings(schema)
	for k in CFEffects.KINDS:
		var kind_id := String(k["id"])
		var b: Dictionary = (bindings["bindings"] as Dictionary).get(kind_id, {})
		md.append("| %s | `%s.%s` | %s |" % [
			kind_id, k["receiver"], k["method"],
			("`%s`" % b.get("signature", "")) if bool(b.get("found", false)) else "**未在扫描结果中找到**"])
	md.append("")
	md.append("触发时机签名来自 `AbstractModel` 的虚方法（共扫描到 %d 个，其中可安全覆写 %d 个）。"
			% [schema.hooks.size(), schema.usable_hooks().size()])
	md.append("")

	md.append("## 素材")
	md.append("")
	for note in art_notes:
		md.append("- %s" % note)
	md.append("")

	md.append("## 写入的文件（%d）" % written.size())
	md.append("")
	for w in written:
		md.append("- `%s`" % String(w).replace("\\", "/"))
	md.append("")
	md.append("## PCK")
	md.append("")
	var pck: Dictionary = report.get("pck", {})
	if bool(pck.get("ok", false)):
		md.append("- 文件数：%s" % pck.get("files", "?"))
		md.append("- 大小：%s 字节" % pck.get("size", "?"))
		md.append("- 目录偏移：%s" % pck.get("dir_offset", "?"))
	else:
		md.append("- 未生成：%s" % pck.get("error", "已禁用"))
	md.append("")
	return "\n".join(md)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Vars whose constructor takes an `int` rather than a `decimal` — `RepeatVar(int
## times)` is the common one. `PROP_VARS` likewise take a `ValueProp`.
##
## Both are **fallbacks only**: the scanner reads every DynamicVar subclass's real
## constructors out of the game source (`schema.var_ctor_info`), and these tables
## stand in when that data is absent (a schema cached by an older build, or a
## partial context in a unit test).
const INT_VARS := ["RepeatVar", "CardCountVar", "IntVar"]
const PROP_VARS := ["DamageVar", "CalculatedDamageVar", "BlockVar", "CalculatedBlockVar",
		"HpLossVar", "OstyDamageVar"]


## One entry of `CanonicalVars`, e.g. `new PowerVar<VulnerablePower>("power", 2m)`.
##
## Getting the constructor right matters twice over:
##
##   * it has to exist.  The old hardcoded `new IntVar(0)` did not: `IntVar` only
##     declares `IntVar(string name, decimal amount)`, so the file could not even
##     be compiled (CS1729). That is the type the 「＋ 添加变量」 button creates.
##   * it has to register the var under the **user's** name, because every read is
##     `base.DynamicVars["<name>"]` and every `{<name>:diff()}` in the text
##     resolves against the same key.
##
## `new BlockVar(20m, ValueProp.Move)` satisfied the first and broke the second: it
## compiles, names the var "Block", and the card then throws
## `KeyNotFoundException: The given key 'Value4' was not present in the dictionary`
## as soon as it is played or upgraded — no block, and nothing in the tool to see.
## `CFSchemaScanner._var_ctor_facts` supplies the real overloads; the tables above
## are the fallback.
static func emit_var(schema: CFSchema, v: Dictionary) -> String:
	var type_name := String(v.get("type", "IntVar"))
	var generic := String(v.get("generic", ""))
	var raw := float(v.get("base", 0.0))
	var vname := String(v.get("name", "")).strip_edges()
	if type_name == "PowerVar" and generic.is_empty():
		# A PowerVar without its power type cannot be constructed at all. Validation
		# reports it as an error before export; this keeps the emitted file compilable
		# in the meantime.
		return "/* TODO: PowerVar 需要泛型参数（例如 VulnerablePower） */ new IntVar(\"%s\", 0)" % vname
	var info: Dictionary = schema.var_ctor_info(type_name, generic) if schema != null else {}
	var ctor := _pick_var_ctor(info.get("ctors", []), type_name)
	var args: Array = []
	var params: Array = ctor.get("params", [])
	for pi in params.size():
		var ptype := String(params[pi])
		match ptype:
			"string":
				# The first string parameter is the DynamicVar dictionary key. A
				# later string (StringVar's optional value) is a real text value,
				# which the design model does not currently store, so use empty text.
				args.append("\"%s\"" % vname if pi == 0 else "\"\"")
			"decimal":
				args.append(_var_literal("decimal", raw))
			"int":
				args.append(_var_literal("int", raw))
			"bool":
				args.append(_var_literal("bool", raw))
			"ValueProp":
				var vp := String(v.get("value_prop", ""))
				args.append("ValueProp.%s" % (vp if not vp.is_empty() else "Move"))
			"UpgradeDisplay":
				# Use a fully-qualified name so this special constructor does not
				# depend on a variable-specific using clause.
				args.append("MegaCrit.Sts2.Core.Localization.UpgradeDisplay.Normal")
			_:
				# Unknown optional parameters are left as a compile-time-visible
				# placeholder instead of silently producing a wrong overload.
				args.append("default(%s)" % ptype)
	if args.is_empty():
		# A constructor with no parameters is not expected for DynamicVar, but
		# keep the generated source syntactically useful for old schema caches.
		args.append(_var_literal("decimal", raw))
	var head := "%s<%s>" % [type_name, generic] if not generic.is_empty() else type_name
	return "new %s(%s)" % [head, ", ".join(args)]


## The overload to emit: a named one when the type has it (the only way to register
## the var under the user's key), else the value-only one.
##
## `ctors` is a list of parameter-type lists, e.g.
## `[["decimal", "ValueProp"], ["string", "decimal", "ValueProp"]]`.
static func _pick_var_ctor(ctors: Array, type_name: String) -> Dictionary:
	# Prefer an overload that accepts the user's name. This is what makes
	# `base.DynamicVars["<name>"]` resolve to the same key used by localization.
	# Among named overloads prefer one whose remaining parameters are all values
	# the design model can represent (numeric, ValueProp, UpgradeDisplay, string).
	for c in ctors:
		var params: Array = c
		if not params.is_empty() and String(params[0]) == "string" and _ctor_supported(params):
			return {"params": params}
	for c in ctors:
		var params: Array = c
		if not params.is_empty() and _ctor_supported(params):
			return {"params": params}
	# Unknown type (no scanned constructors): keep the pre-facts behaviour, so the
	# fallback itself cannot be the thing that regresses.
	if INT_VARS.has(type_name):
		return {"params": ["int"]}
	if PROP_VARS.has(type_name):
		return {"params": ["decimal", "ValueProp"]}
	return {"params": ["string", "decimal"]}


static func _ctor_supported(params: Array) -> bool:
	for p in params:
		if String(p) not in ["string", "decimal", "int", "bool", "ValueProp", "UpgradeDisplay"]:
			return false
	return true


## A base value as the literal the constructor's parameter type expects.
static func _var_literal(value_type: String, raw: float) -> String:
	match value_type:
		"int": return "%d" % int(round(raw))
		"bool": return "true" if raw != 0.0 else "false"
		"string": return "\"%s\"" % _dec(raw)
		_: return "%sm" % _dec(raw)


static func variants_manifest_name(mod_id: String) -> String:
	return "%s-variants.manifest" % CFIds.kebab(mod_id)


# ---------------------------------------------------------------------------
# Build verification
# ---------------------------------------------------------------------------

## Run `dotnet build` on an exported mod and report whether it produced the dll.
##
## This is the only way to catch the class of bug that a purely data-driven
## export cannot see: wrong assembly paths, missing namespaces, bad overrides.
## Blocking, so callers should run it after the export finishes, not during.
##
## Godot.NET.Sdk pins the compiler output to `src/.godot/mono/temp/bin/<Config>/`
## and ignores `BaseOutputPath` (verified against SDK 4.5.1 + MSBuild 9.0.303),
## so the dll cannot be redirected to the mod root by project properties alone.
## We therefore copy it ourselves right after a successful build — that is what
## makes "where the dll is built" and "where the mod lives" the same folder.
static func verify_build(mod_dir: String) -> Dictionary:
	mod_dir = ProjectSettings.globalize_path(mod_dir).replace("\\", "/").trim_suffix("/")
	var mod_id := mod_dir.get_file()
	var csproj := mod_dir.path_join("src/%s.csproj" % mod_id)
	if not FileAccess.file_exists(csproj):
		return {"ok": false, "error": "找不到工程：" + csproj, "log": ""}

	var dotnet := CFPaths.detect_dotnet()
	var args := [
		"build", csproj, "-c", "Release",
		"--nologo", "-v", "quiet",
	]
	var out: Array = []
	var code := OS.execute(dotnet, args, out, true, false)
	var log := "\n".join(out).strip_edges()
	var log_path := mod_dir.path_join("build.log")
	CFPaths.write_text(log_path, log)
	if code != 0:
		return {"ok": false, "error": "编译失败（退出码 %d）" % code, "log": log, "log_path": log_path}

	# Require the assembly from this Release build, never a dependency DLL or
	# an old Debug output whose presence could disguise a failed build.
	var found := mod_dir.path_join("src/.godot/mono/temp/bin/Release/%s.dll" % mod_id)
	if not FileAccess.file_exists(found):
		return {"ok": false, "error": "编译成功但没找到输出：" + found, "log": log, "log_path": log_path}
	var copied := _stage_dll(mod_dir, found)
	if copied.is_empty():
		return {"ok": false, "error": "编译成功，但无法将 DLL 放到 Mod 根目录。请检查文件占用或目录权限。", "log": log, "log_path": log_path}
	return {"ok": true, "error": "", "log": log, "log_path": log_path, "dll": found, "staged": copied}


## Copy a freshly built dll to the mod root as `<ModId>.dll`.
##
## Returns the destination path, or "" when the copy could not be made (the
## caller reports staging failure separately from compiler failure).
static func _stage_dll(mod_dir: String, built: String) -> String:
	if built.is_empty() or not FileAccess.file_exists(built):
		return ""
	var mod_id := mod_dir.get_file()
	var dest := mod_dir.path_join("%s.dll" % mod_id)
	var bytes := FileAccess.get_file_as_bytes(built)
	if bytes.is_empty():
		return ""
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		push_error("CFExporter: cannot stage dll to %s (err %d)" % [dest, FileAccess.get_open_error()])
		return ""
	f.store_buffer(bytes)
	f.close()
	# The folder is now complete (json + pck + dll), so the "build first" note
	# exported earlier no longer applies and would only mislead.
	var sentinel := mod_dir.path_join("!!! 先编译再安装 !!!.txt")
	if FileAccess.file_exists(sentinel):
		DirAccess.remove_absolute(sentinel)
	return dest


static func _dec(v: float) -> String:
	return str(int(v)) if v == floor(v) else String.num(v, 2)


static func _write_json(path: String, data: Variant, written: Array) -> void:
	_write_text(path, JSON.stringify(data, "  "), written)


static func _write_text(path: String, text: String, written: Array) -> void:
	path = ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("CFExporter: cannot write %s (err %d)" % [path, FileAccess.get_open_error()])
		return
	f.store_string(text)
	f.close()
	written.append(path)
