@tool
extends SceneTree

## Headless self-test: scans the game, builds the example design, exports a mod
## and verifies the pack it wrote. Run with:
##
##   Godot_..._console.exe --headless --path <CardRelicForge> --script res://tools/selftest.gd
##
## Exits with code 0 on success, 1 on failure. Everything it prints goes to
## stdout so the caller can grep for "FAIL".

var _failures := 0
## Total number of assertions run, so the summary line can report it (the UI test
## does the same — a count is how a silently-skipped test gets noticed).
var _checks := 0


func _init() -> void:
	print("===== CardRelicForge selftest =====")
	_test_ids()
	_test_pck_roundtrip()
	var schema := _test_scan()
	if schema != null and not schema.source_root.is_empty():
		_test_schema_contents(schema)
		var db := _test_example_design(schema)
		_test_authoring_library(schema)
		_test_export(schema, db)
		_test_loop_var_guard(schema)
		_test_var_roundtrip(schema)
		_test_dynvar_accessor(schema)
		_test_block_grant(schema)
		_test_card_target_mapping(schema)
		_test_var_constructor_safety(schema)
		_test_effect_matrix(schema)
		_test_relic_effect_matrix(schema)
		_test_relic_lifecycle_context(schema)
		_test_power_matrix(schema)
		_test_usings_and_locals(schema)
	if _failures > 0:
		print("===== FAILED (%d/%d) =====" % [_failures, _checks])
	else:
		print("===== PASSED =====  %d 项检查" % _checks)
	quit(1 if _failures > 0 else 0)


func _ok(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  [ok]   %s%s" % [label, ("  " + detail) if not detail.is_empty() else ""])
	else:
		_failures += 1
		print("  [FAIL] %s  %s" % [label, detail])


# ---------------------------------------------------------------------------

func _test_ids() -> void:
	print("\n-- CFIds --")
	_ok("slugify(NinefoldStrike) == NINEFOLD_STRIKE",
			CFIds.slugify("NinefoldStrike") == "NINEFOLD_STRIKE", CFIds.slugify("NinefoldStrike"))
	_ok("slugify(AllForOne) == ALL_FOR_ONE",
			CFIds.slugify("AllForOne") == "ALL_FOR_ONE", CFIds.slugify("AllForOne"))
	_ok("unslugify round-trips",
			CFIds.unslugify("ALL_FOR_ONE") == "AllForOne", CFIds.unslugify("ALL_FOR_ONE"))
	_ok("kebab(HexDesignerSample) == hex-designer-sample",
			CFIds.kebab("HexDesignerSample") == "hex-designer-sample", CFIds.kebab("HexDesignerSample"))
	_ok("rejects C# keyword", not CFIds.is_valid_cs_identifier("class"))
	_ok("accepts identifier", CFIds.is_valid_cs_identifier("IronWard"))


func _test_pck_roundtrip() -> void:
	print("\n-- CFPckWriter --")
	var w := CFPckWriter.new()
	w.add_text("MyMod/localization/zhs/cards.json", '{"A":{"title":"b"}}')
	w.add_text("MyMod/localization/eng/cards.json", '{"A":{"title":"b"}}')
	var tmp := "user://selftest.pck"
	var res := w.write_pck(ProjectSettings.globalize_path(tmp), "4.5.1")
	_ok("write_pck ok", bool(res.get("ok", false)), str(res.get("error", "")))
	var read := CFPckWriter.read_pck(ProjectSettings.globalize_path(tmp))
	_ok("read_pck ok", bool(read.get("ok", false)), str(read.get("error", "")))
	_ok("pack has 2 entries", (read.get("files", []) as Array).size() == 2,
			str((read.get("files", []) as Array).size()))
	_ok("engine version 4.5.1", String(read.get("engine", "")) == "4.5.1", String(read.get("engine", "")))
	var first := (read.get("files", []) as Array)[0] as Dictionary
	_ok("entry path preserved", String(first.get("path", "")).ends_with("cards.json"),
			String(first.get("path", "")))
	# The real proof: Godot itself must be able to load it.
	var loaded := ProjectSettings.load_resource_pack(ProjectSettings.globalize_path(tmp), true)
	_ok("Godot load_resource_pack() accepts the pack", loaded)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


# ---------------------------------------------------------------------------

func _test_scan() -> CFSchema:
	print("\n-- CFSchemaScanner --")
	var root := CFPaths.detect_source_root()
	if root.is_empty():
		_failures += 1
		print("  [FAIL] 找不到解包数据目录")
		return null
	print("  source_root = %s" % root)
	var s := CFSchema.new()
	CFSchemaScanner.scan(root, s)
	print("  %s" % s.summary())
	_ok("扫描到枚举", s.enums.size() > 5, "%d" % s.enums.size())
	_ok("扫描到卡池", s.card_pools.size() > 0, "%d" % s.card_pools.size())
	_ok("扫描到遗物池", s.relic_pools.size() > 0, "%d" % s.relic_pools.size())
	_ok("扫描到角色", s.characters.size() > 0, "%d" % s.characters.size())
	_ok("扫描到触发时机", s.hooks.size() > 20, "%d" % s.hooks.size())
	_ok("扫描到命令", s.commands.size() > 50, "%d" % s.commands.size())
	_ok("扫描到 Power", s.powers.size() > 20, "%d" % s.powers.size())
	_ok("扫描到游戏自带卡牌", s.existing_cards.size() > 100, "%d" % s.existing_cards.size())
	_ok("扫描到游戏自带遗物", s.existing_relics.size() > 50, "%d" % s.existing_relics.size())
	_ok("无扫描错误", s.errors.is_empty(), str(s.errors))
	return s


func _test_schema_contents(s: CFSchema) -> void:
	print("\n-- schema 内容 --")
	var ct := s.members_for_role("card_type")
	_ok("CardType 含 Attack", ct.has("Attack"), str(ct))
	var kw := s.members_for_role("card_keyword")
	_ok("CardKeyword 含 Exhaust", kw.has("Exhaust"), str(kw))
	var rr := s.members_for_role("relic_rarity")
	_ok("RelicRarity 含 Common", rr.has("Common"), str(rr))
	_ok("存在 Ironclad 卡池",
			not s.pool_by_class("IroncladCardPool", false).is_empty())
	# 卡池归属只能从角色那一侧读：池文件里只有它自己的类名，所以「这个池属于谁」
	# 曾经一律答成池自己的名字 —— 下拉框显示 `IroncladCardPool  (IroncladCardPool)`，
	# 导出预检还会给每个开局注入都加一条无意义的警告。
	var ic_pool := s.pool_by_class("IroncladCardPool", false)
	_ok("IroncladCardPool 的归属角色是 Ironclad",
			String(ic_pool.get("character", "")) == "Ironclad",
			String(ic_pool.get("character", "")))
	var cl_pool := s.pool_by_class("ColorlessCardPool", false)
	_ok("没有角色认领的卡池不编造归属（ColorlessCardPool）",
			String(cl_pool.get("character", "")) == "",
			String(cl_pool.get("character", "")))
	_ok("存在一个可用的 BeforeCombatStart 钩子",
			not s.hook("BeforeCombatStart").is_empty(),
			String(s.hook("BeforeCombatStart").get("signature", "")))
	var bindings := CFEffects.resolve_bindings(s)
	_ok("所有效果类型都能绑定到真实 API",
			(bindings["missing"] as Array).is_empty(), str(bindings["missing"]))
	_ok("本地化索引非空", s.localization_keys.size() > 0,
			str(s.localization_keys.keys()))
	_ok("未发现 localization 冲突误报",
			not s.base_loc_has("zhs", "cards", "NINEFOLD_STRIKE.title"))


# ---------------------------------------------------------------------------

func _test_example_design(s: CFSchema) -> CFDesignDb:
	print("\n-- 示例设计 --")
	var db := CFDesignDb.new()
	db.seed_example(s)
	_ok("生成 1 张卡牌", db.cards.size() == 1)
	_ok("生成 1 件遗物", db.relics.size() == 1)
	var card: Dictionary = db.cards[0]
	_ok("卡牌 entry == NINEFOLD_STRIKE", String(card["entry"]) == "NINEFOLD_STRIKE", String(card["entry"]))
	var issues := CFDesign.validate(s, card, db.all_items())
	var counts := CFDesign.issue_counts(issues)
	_ok("示例卡牌无错误", int(counts["errors"]) == 0,
			str(issues.filter(func(i): return i["severity"] == "error")))
	var relic: Dictionary = db.relics[0]
	var rissues := CFDesign.validate(s, relic, db.all_items())
	var rcounts := CFDesign.issue_counts(rissues)
	_ok("示例遗物无错误", int(rcounts["errors"]) == 0,
			str(rissues.filter(func(i): return i["severity"] == "error")))
	# Description rendering with the {Var:diff()} placeholder.
	var rendered := CFDesign.render_description(card, "zhs", false)
	_ok("描述模板已渲染（无残留占位符）",
			not String(rendered["plain"]).contains("{"), String(rendered["plain"]))
	return db


func _test_authoring_library(s: CFSchema) -> void:
	print("\n-- 能力配方 / 自定义角色持久化 --")
	var db := CFDesignDb.new()
	var card := CFDesign.new_card(s)
	card["id"] = "LibraryProbe"
	card["vars"] = [CFDesign.new_var("Draw", "Draw", "CardsVar", 2.0)]
	var effect := CFDesign.new_effect("draw")
	effect["amount"] = 2.0
	card["effects"] = [effect]
	CFDesign.normalize(s, card)
	db.cards = [card]
	db.save_ability_from_item(card, "DrawRecipe", "抽牌组合")
	_ok("保存组合能力及其变量/效果", db.abilities.size() == 1
			and db.abilities[0]["vars"].size() == 1
			and db.abilities[0]["effects"].size() == 1)
	_ok("组合能力可应用到卡牌", db.apply_ability_to_card(0, 0)
			and db.cards[0]["effects"].size() == 2
			and db.cards[0]["vars"].size() == 1)
	db.add_custom_character({"id": "LibraryHero", "name": "库测试角色",
		"namespace": "LibraryMod.Models.Characters",
		"card_pool": "LibraryHeroCardPool", "relic_pool": "LibraryHeroRelicPool"})
	var targets := s.deck_targets(db.custom_characters)
	var custom_target_found := false
	for target in targets:
		if String(target.get("class_name", "")) == "LibraryHero":
			custom_target_found = true
	_ok("自定义角色同步进入开局注入目标", custom_target_found)
	var injected_card: Dictionary = db.cards[0].duplicate(true)
	injected_card["pool"] = "LibraryHeroCardPool"
	injected_card["deck"] = {"enabled": true, "character": "LibraryHero", "copies": 1}
	var injection_issues := CFDesign.validate(s, injected_card, [], db.custom_characters)
	var injection_errors: Array = injection_issues.filter(func(issue):
		return String(issue.get("field", "")) in ["deck", "pool"] and String(issue.get("severity", "")) == CFDesign.SEV_ERROR)
	_ok("自定义角色专属卡池通过卡池与开局注入校验", injection_errors.is_empty(), str(injection_errors))
	db.cards[0] = injected_card
	var generated_pool := CFExporter.emit_custom_pool(db, db.custom_characters[0], "LibraryHeroCardPool", false, db.mod_id)
	_ok("自定义角色卡池会生成并包含自制卡", generated_pool.contains("class LibraryHeroCardPool")
			and generated_pool.contains("ModelDb.Card<%s>()" % db.cards[0].get("id", "")))
	var entry_code := CFExporter.emit_mod_entry(s, db, db.mod_id, [], [], [], true)
	_ok("Mod入口注册可选角色且自定义池不会重复注册", entry_code.contains("RegisterCharacter<global::%s.Models.Characters.LibraryHero>" % db.mod_id)
			and not entry_code.contains("AddModelToPool<LibraryHeroCardPool"))
	var patches := CFExporter.collect_patches(s, db)
	_ok("自定义角色不再用 Harmony 修改继承的开局属性", patches.is_empty())
	var character_code := CFCharacters.emit(db.custom_characters[0], db)
	_ok("自定义角色有独立开局声明与模板素材回退", character_code.contains("LocalStartingDeck")
			and character_code.contains("ModelDb.Card<global::%s.LibraryProbe>()" % db.mod_id)
			and character_code.contains("PlaceholderCharacterId => \"ironclad\""))
	var reopened := CFDesignDb.new()
	var load_result := reopened.load_from_json(db.to_json())
	_ok("自定义角色和池写入 JSON", reopened.custom_characters.size() == 1
			and reopened.custom_characters[0]["card_pool"] == "LibraryHeroCardPool")
	_ok("能力配方与角色重开后仍存在", bool(load_result["ok"])
			and reopened.abilities.size() == 1
			and reopened.custom_characters.size() == 1)


# ---------------------------------------------------------------------------

func _test_export(s: CFSchema, db: CFDesignDb) -> void:
	print("\n-- 导出 --")
	var out := ProjectSettings.globalize_path("res://exports")
	var report := CFExporter.export(s, db, {
		"out_dir": out,
		"force": false,
		"include_pck": true,
	})
	_ok("导出成功", bool(report.get("ok", false)), String(report.get("error", "")))
	if not bool(report.get("ok", false)):
		return
	var mod_dir := String(report["mod_dir"])
	print("  mod_dir = %s" % mod_dir)
	print("  写入 %s 个文件" % report.get("files_written", 0))

	for rel in ["MyCardMod.json", "MyCardMod.pck", "build.ps1", "build.cmd",
			"README.md", "EXPORT_REPORT.md", "src/ModEntry.cs",
			"src/MyCardMod.csproj", "src/Cards/NinefoldStrike.cs",
			"src/Relics/IronWard.cs", "my-card-mod-variants.manifest",
			"lib/0.107.1/compat-target.txt",
			"assets/MyCardMod/localization/zhs/cards.json"]:
		_ok("存在 %s" % rel, FileAccess.file_exists(mod_dir.path_join(rel)))

	var pck := CFPckWriter.read_pck(mod_dir.path_join("MyCardMod.pck"))
	_ok("导出的 pck 可解析", bool(pck.get("ok", false)), String(pck.get("error", "")))
	# One file per (locale, table): 2 locales x (cards + relics) == 4.
	_ok("pck 含 4 个本地化文件", (pck.get("files", []) as Array).size() == 4,
			str((pck.get("files", []) as Array).size()))

	# Regression: an export ships <id>.json declaring has_dll=true, but the DLL
	# only exists after build.cmd runs. A user who copies the raw export into
	# mods/ gets "[ERROR] declares that it should load an assembly, but no
	# assembly ... was found!" and zero cards. The export must say so loudly.
	_ok("导出标记了 needs_build", bool(report.get("needs_build", false)))
	_ok("根目录没有 dll（正因如此需要编译）",
			not FileAccess.file_exists(mod_dir.path_join("MyCardMod.dll")))
	var sentinel_path := mod_dir.path_join("!!! 先编译再安装 !!!.txt")
	_ok("导出留下“先编译再安装”提示文件", FileAccess.file_exists(sentinel_path))
	var sentinel := CFPaths.read_text(sentinel_path)
	_ok("提示文件点名缺失的 dll", sentinel.contains("MyCardMod.dll"),
			"%d 字符" % sentinel.length())
	_ok("提示文件给出 build.cmd 指引", sentinel.contains("build.cmd"))
	_ok("提示文件说明 pck 不能定义卡牌", sentinel.contains(".pck"))
	var report_md := CFPaths.read_text(mod_dir.path_join("EXPORT_REPORT.md"))
	_ok("EXPORT_REPORT.md 顶部给出编译警告",
			report_md.contains("还不能直接拷进 mods"), )

	# The entry point must use the CLASS-level attribute, which was the bug in
	# the previous designer's generator.
	var entry_src := CFPaths.read_text(mod_dir.path_join("src/ModEntry.cs"))
	_ok("ModEntry 使用类级 [ModInitializer]",
			entry_src.contains("[ModInitializer(nameof(Initialize))]") and
			entry_src.contains("public static class ModEntry"), )
	_ok("ModEntry 不含方法级 [ModInitializer]",
			not entry_src.contains("[ModInitializer(\"Initialize\")]"))

	# The pck must contain the localization at the path the game reads.
	var pck_paths: Array = CFPckWriter.read_pck(mod_dir.path_join("MyCardMod.pck"))["files"]
	var found_loc := false
	for f in pck_paths:
		if String(f["path"]) == "MyCardMod/localization/zhs/cards.json":
			found_loc = true
	_ok("pck 内本地化路径正确", found_loc,
			str(pck_paths.map(func(f): return f["path"])))

	# ps1 must stay ASCII so PowerShell 5.1 can read it.
	var ps1 := FileAccess.open(mod_dir.path_join("build.ps1"), FileAccess.READ)
	var non_ascii := 0
	if ps1 != null:
		var bytes := ps1.get_buffer(ps1.get_length())
		ps1.close()
		for b in bytes:
			if b > 127:
				non_ascii += 1
	_ok("build.ps1 为纯 ASCII（PowerShell 5.1 兼容）", non_ascii == 0, "%d 个非 ASCII 字节" % non_ascii)
	var build_script := CFPaths.read_text(mod_dir.path_join("build.ps1"))
	_ok("build.ps1 编译失败时停止安装且不复制旧 DLL",
			build_script.contains("$buildExitCode = $LASTEXITCODE")
			and build_script.contains("if ($buildExitCode -ne 0)")
			and build_script.contains("the old DLL was not copied or installed"))

	# Card source must Reflect the intent: 9 hits via a var loop + Exhaust.
	var card_src := CFPaths.read_text(mod_dir.path_join("src/Cards/NinefoldStrike.cs"))
	_ok("卡牌含 Exhaust 关键字", card_src.contains("CardKeyword.Exhaust"))
	_ok("升级移除 Exhaust", card_src.contains("RemoveKeyword(CardKeyword.Exhaust)"))
	_ok("卡牌含伤害循环", card_src.contains("for (int i = 0; i < base.DynamicVars[\"Repeat\"].IntValue"))

	var relic_src := CFPaths.read_text(mod_dir.path_join("src/Relics/IronWard.cs"))
	_ok("遗物覆写 BeforeCombatStart", relic_src.contains("BeforeCombatStart"))
	_ok("遗物给出格挡", relic_src.contains("CreatureCmd.GainBlock"))
	_ok("触发时机显示英文后接翻译文件中的中文", s.hook_label("BeforeCombatStart").contains("BeforeCombatStart（战斗开始前触发）"),
			s.hook_label("BeforeCombatStart"))
	_ok("翻译文件覆盖卡牌移动触发时机", s.hook_label("AfterCardChangedPiles").contains("卡牌在牌堆之间移动后触发"),
			s.hook_label("AfterCardChangedPiles"))
	_ok("翻译文件补充新的触发时机", s.hook_label("AfterCardDrawnEarly").contains("抽到卡牌后的前置触发时机"),
			s.hook_label("AfterCardDrawnEarly"))


## Regression for the reported CS0029 + CS0103 in a generated card:
##
##   for (int i = 0; i < base.DynamicVars..IntValue; i++)
##
## `loop.var` defaults to "" (not absent), so the old
## `loop.get("var", "Repeat")` fallback never fired and the emitter produced a
## member access with an empty name. Two things must now hold:
##   1. the emitter never writes `DynamicVars..` (last line of defence), and
##   2. validation reports the mistake as an error before export.
func _test_loop_var_guard(schema: CFSchema) -> void:
	print("\n-- 循环变量守卫（回归 CS0029/CS0103）--")

	# (a) loop mode "var" with an empty name, and no matching var declared.
	var card := CFDesign.new_card(schema)
	card["id"] = "hedaji"
	card["entry"] = "HEDAJI"
	card["text"]["zhs"]["title"] = "核打击"
	card["text"]["eng"]["title"] = "hedaji"
	card["text"]["zhs"]["description"] = "造成 {Damage:diff()} 点伤害1次。"
	card["text"]["eng"]["description"] = "Deal {Damage:diff()} damage {Repeat} times."
	card["vars"] = [CFDesign.new_var("Damage", "Damage", "DamageVar", 300.0, "Move")]
	var eff := CFDesign.new_effect("damage")
	eff["amount"] = 300.0
	eff["loop"] = {"mode": "var", "count": 1, "var": ""}
	card["effects"] = [eff]
	CFDesign.normalize(schema, card)

	var src := CFExporter.emit_card(schema, card, "MyCardMod")
	_ok("生成代码不含 `DynamicVars..`（空变量名）", not src.contains("DynamicVars.."))
	var loop_line := ""
	for l in src.split("\n"):
		if String(l).contains("for (int i = 0; i <"):
			loop_line = String(l).strip_edges()
			break
	_ok("仍生成可用的 for 循环头", not loop_line.is_empty(), loop_line)
	if not loop_line.is_empty():
		var cond := loop_line.split("i < ")[1].split(";")[0].strip_edges()
		_ok("循环上限是有效表达式", not cond.is_empty() and not cond.contains("..")
				and not cond.ends_with(".IntValue"), cond)

	var issues := CFDesign.validate(schema, card, [])
	var err_count := 0
	for it in issues:
		if String(it["severity"]) == CFDesign.SEV_ERROR:
			err_count += 1
	_ok("校验把「按变量循环但未选变量」判为错误", err_count >= 1, "%d 个错误" % err_count)

	# (b) loop names a var that is not declared -> must be an error.
	eff["loop"] = {"mode": "var", "count": 1, "var": "Repeat"}
	card["effects"] = [eff]
	CFDesign.normalize(schema, card)
	var caught := false
	for it in CFDesign.validate(schema, card, []):
		if String(it["severity"]) == CFDesign.SEV_ERROR and String(it["message"]).contains("Repeat"):
			caught = true
	_ok("校验能发现引用了未声明的变量", caught)

	# (c) declaring the var makes it valid and emits the right member access.
	card["vars"] = [
		CFDesign.new_var("Damage", "Damage", "DamageVar", 1.0, "Move"),
		CFDesign.new_var("Repeat", "Repeat", "RepeatVar", 9.0, ""),
	]
	card["effects"] = [eff]
	CFDesign.normalize(schema, card)
	var errs3 := 0
	for it in CFDesign.validate(schema, card, []):
		if String(it["severity"]) == CFDesign.SEV_ERROR:
			errs3 += 1
	_ok("声明 Repeat 后校验无错误", errs3 == 0, "%d 个错误" % errs3)
	var src3 := CFExporter.emit_card(schema, card, "MyCardMod")
	_ok("生成 `base.DynamicVars[\"Repeat\"].IntValue`",
			src3.contains("for (int i = 0; i < base.DynamicVars[\"Repeat\"].IntValue"))
	# 命名构造函数：`RepeatVar(int times)` 会把 Name 钉成 "Repeat"，而读值走的是
	# `DynamicVars["Repeat"]` —— 名字一旦不是默认名，就会 KeyNotFoundException。
	# 所以生成器一律用 `(name, value)` 重载。（变量名恰好等于默认名时两者等价。）
	_ok("CanonicalVars 含 new RepeatVar(\"Repeat\", 9)",
			src3.contains('new RepeatVar("Repeat", 9)'), src3)


## Regression for "变量名 / 类型填进去几秒后就没了".
##
## Two independent defects used to make a `vars` edit evaporate:
##   1. each keystroke rebuilt the editor column, freeing the very LineEdit the
##      user was typing into — so only the first character ever got through;
##   2. `type` was written on its own, and `CFDesign.normalize` derives `kind`
##      from `type` (and `value_prop` from `kind`), so a later write to a
##      neighbouring field silently reverted it.
## This pins the storage side: an atomic whole-entry write must survive a
## normalise pass, for every field the row exposes.
func _test_var_roundtrip(schema: CFSchema) -> void:
	print("\n-- 变量行原子写入（回归「改完几秒后丢失」）--")
	var card := CFDesign.new_card(schema)
	card["id"] = "VarRoundtrip"
	card["entry"] = "VAR_ROUNDTRIP"
	card["text"]["zhs"]["title"] = "变量往返"
	card["text"]["eng"]["title"] = "VarRoundtrip"
	card["vars"] = [CFDesign.new_var("Value1", "Int", "IntVar", 0.0)]
	var db := CFDesignDb.new()
	db.cards = [card]
	db.set_selection(CFDesign.KIND_CARD, 0)

	var v0: Dictionary = (card["vars"] as Array)[0]
	var path := db._var_field_path(card, 0, v0)
	_ok("变量行解析到 vars[0]", str(path) == str(["vars", 0]), str(path))

	# (a) name + type written as one atomic entry.
	db.set_field(schema, CFDesign.KIND_CARD, 0, path,
			CFDesignDb.var_payload(v0, {"name": "Hits", "type": "RepeatVar"}), "修改变量")
	var after: Dictionary = (db.cards[0]["vars"] as Array)[0]
	_ok("变量名称已保存", String(after.get("name", "")) == "Hits", String(after.get("name", "")))
	_ok("变量类型已保存（未被 normalize 回滚）",
			String(after.get("type", "")) == "RepeatVar", String(after.get("type", "")))
	# `kind` is the tool's own short label and is derived from `type`, not stored
	# independently: a stale kind made `{Damage:diff()}` stop resolving.
	_ok("kind 随 type 推导为 Repeat", String(after.get("kind", "")) == "Repeat",
			String(after.get("kind", "")))
	var rendered := CFDesign.render_description(db.cards[0], "zhs", false)
	_ok("描述里的 {Hits} 能解析出数值",
			not String(rendered["plain"]).contains("{"), String(rendered["plain"]))

	# (b) a *later* write to a neighbouring field must not revert the type.
	#     This is the exact sequence that used to lose the value.
	var v1: Dictionary = (db.cards[0]["vars"] as Array)[0]
	var p1 := db._var_field_path(db.cards[0], 0, v1)
	db.set_field(schema, CFDesign.KIND_CARD, 0, p1, CFDesignDb.var_payload(v1, {"base": 7.0}), "改基础值")
	var after2: Dictionary = (db.cards[0]["vars"] as Array)[0]
	_ok("改基础值后类型仍在", String(after2.get("type", "")) == "RepeatVar", String(after2.get("type", "")))
	_ok("改基础值后名称仍在", String(after2.get("name", "")) == "Hits", String(after2.get("name", "")))
	_ok("基础值已保存", absf(float(after2.get("base", 0.0)) - 7.0) < 0.0001,
			str(after2.get("base", 0.0)))

	# (c) the row lookup follows a rename instead of blindly using the index.
	var p2 := db._var_field_path(db.cards[0], 0, {"name": "Hits"})
	db.set_field(schema, CFDesign.KIND_CARD, 0, p2,
			CFDesignDb.var_payload(after2, {"upgrade_delta": 3.0}), "改升级增量")
	var after3: Dictionary = (db.cards[0]["vars"] as Array)[0]
	_ok("改升级增量后名称/类型仍在",
			String(after3.get("name", "")) == "Hits" and String(after3.get("type", "")) == "RepeatVar",
			"%s / %s" % [after3.get("name", ""), after3.get("type", "")])
	_ok("升级增量已保存", absf(float(after3.get("upgrade_delta", 0.0)) - 3.0) < 0.0001,
			str(after3.get("upgrade_delta", 0.0)))

	# (d) uncommitted typing still reaches undo once flushed.
	db.clear_history()
	var v2: Dictionary = (db.cards[0]["vars"] as Array)[0]
	var p3 := db._var_field_path(db.cards[0], 0, v2)
	db.set_field_quiet(schema, CFDesign.KIND_CARD, 0, p3,
			CFDesignDb.var_payload(v2, {"name": "Typed"}))
	_ok("quiet 写入立即可见",
			String((db.cards[0]["vars"] as Array)[0].get("name", "")) == "Typed")
	db.flush_edit(p3)
	_ok("flush 后进入撤销历史", db.can_undo())
	if db.can_undo():
		db.undo()
		_ok("撤销恢复旧变量名",
				String((db.cards[0]["vars"] as Array)[0].get("name", "")) == "Hits",
				String((db.cards[0]["vars"] as Array)[0].get("name", "")))

	# (e) a card whose vars are still the defaults must survive a re-read.
	var card2 := CFDesign.new_card(schema)
	card2["id"] = "Defaults"
	card2["entry"] = "DEFAULTS"
	CFDesign.normalize(schema, card2)
	db.cards.append(card2)
	db.set_selection(CFDesign.KIND_CARD, 1)
	var d0: Dictionary = (card2["vars"] as Array)[0]
	var pr := db._var_field_path(card2, 0, d0)
	db.set_field(schema, CFDesign.KIND_CARD, 1, pr,
			CFDesignDb.var_payload(d0, {"name": "Damage", "type": "DamageVar"}))
	var d1: Dictionary = (db.cards[1]["vars"] as Array)[0]
	_ok("默认变量改名后仍保留 DamageVar",
			String(d1.get("type", "")) == "DamageVar", String(d1.get("type", "")))

## Regression for the `NewCard.cs: 34, 91: CS1061` the user hit.
##
## Two independent generator defects produced C# that cannot compile:
##   1. the scanner offered the *declaring class's own type parameter* as a
##      generic argument, so `class PowerVar<T>` made the dropdown show
##      `PowerVar<T>`; picking it stored the literal `"T"` and the exporter
##      emitted `new PowerVar<T>(2m)` — `T` is not a type in the card's scope.
##   2. the exporter spliced the user's *variable name* into a member access
##      (`base.DynamicVars.power`), but `DynamicVarSet` is a closed set with no
##      `power` property — every var without a property must use the indexer.
func _test_dynvar_accessor(schema: CFSchema) -> void:
	print("\n-- 动态变量访问形式（回归 CS1061）--")

	# (a) the scanner must not offer placeholder type parameters.
	var placeholder_types: Array = []
	for d in schema.dynamic_var_types:
		var g := String(d.get("generic", ""))
		if g == "T":
			placeholder_types.append(String(d["type"]))
	_ok("不把类型参数 T 当作泛型候选", placeholder_types.is_empty(),
			str(placeholder_types))

	# (b) PowerVar must be offered with a *concrete* power, or not at all.
	var powervar_generics: Array = []
	for d in schema.dynamic_var_types:
		if String(d["type"]) == "PowerVar":
			powervar_generics.append(String(d.get("generic", "")))
	_ok("PowerVar 若出现则带具体 Power 类",
			powervar_generics.is_empty()
			or powervar_generics.all(func(g): return g.ends_with("Power")),
			"%d 个，前 3 个：%s" % [powervar_generics.size(), str(powervar_generics.slice(0, 3))])
	# The combo must still be *usable*: dropping PowerVar entirely would be a
	# regression in its own right (it is the only way to declare a power var).
	_ok("下拉框仍提供 PowerVar 选项（带具体 Power）",
			not powervar_generics.is_empty(), str(powervar_generics))
	_ok("包含 PowerVar<VulnerablePower>",
			powervar_generics.has("VulnerablePower"), str(powervar_generics.size()))
	# 覆盖**全部** Power，而不只是 DynamicVarSet 恰好命名的那 6 个访问器。
	# 只镜像访问器表也能编译，但会让下拉框里几乎看不到 buff —— 用户无从察觉
	# 少了东西，比给一个长列表更糟。
	_ok("PowerVar 选项覆盖全部已扫描 Power（而非仅访问器）",
			powervar_generics.size() >= 200,
			"%d 个（Power 共 %d 个）" % [powervar_generics.size(), schema.powers.size()])
	_ok("PowerVar 选项含 StrengthPower",
			powervar_generics.has("StrengthPower"))
	# 抽象基类不是合法的泛型实参（`where T : PowerModel` 允许它，但实例化无意义）。
	_ok("PowerVar 选项不含抽象基类 PowerModel",
			not powervar_generics.has("PowerModel"))

	# (c) the accessor set must have been scanned, and must NOT contain the
	#     invented name the user's design used.
	_ok("已扫描到 DynamicVarSet 访问器", schema.dynamic_var_accessors.size() > 0,
			"%d 个" % schema.dynamic_var_accessors.size())
	_ok("访问器里没有 `power` 这个属性",
			schema.dynvar_accessor_for("power").is_empty(),
			schema.dynvar_accessor_for("power"))

	# (d) the resolver form: **always the indexer**.
	#
	# The property form used to be preferred whenever the name matched a
	# `DynamicVarSet` property (directly, or as `<Prop>Power`). That compiles —
	# and then throws at play time, because a property reads a *fixed* key
	# (`Weak` -> `_vars["WeakPower"]`) while `CFExporter.emit_var` registers the
	# var under the user's own name. The game logged
	# `KeyNotFoundException: The given key 'WeakPower' was not present`, the card
	# play action failed, and the card did nothing at all in game.
	_ok("属性名也走索引器（属性读的是另一个 key）",
			schema.dynvar_expr("Vulnerable") == "base.DynamicVars[\"Vulnerable\"]",
			schema.dynvar_expr("Vulnerable"))
	_ok("Power 类名走索引器",
			schema.dynvar_expr("VulnerablePower") == "base.DynamicVars[\"VulnerablePower\"]",
			schema.dynvar_expr("VulnerablePower"))
	_ok("不在访问器表里的名字也走索引器",
			schema.dynvar_expr("power") == "base.DynamicVars[\"power\"]",
			schema.dynvar_expr("power"))
	_ok("空名不产生 `DynamicVars.`",
			not schema.dynvar_expr("").contains("DynamicVars."),
			schema.dynvar_expr(""))

	# (e) end-to-end: the user's exact design shape must not emit CS1061.
	var card := CFDesign.new_card(schema)
	card["id"] = "DynVar"
	card["entry"] = "DYN_VAR"
	card["text"]["zhs"]["title"] = "易伤测试"
	card["text"]["eng"]["title"] = "DynVar"
	# The variable is named `power` and holds the Vulnerable stacks; the effect
	# applies `VulnerablePower`. That mismatch is what the cache contained.
	card["vars"] = [{
		"base": 2.0, "generic": "VulnerablePower", "kind": "Power",
		"name": "power", "type": "PowerVar", "upgrade_delta": 3.0, "value_prop": "",
	}]
	card["effects"] = [{
		"amount": 0.0, "amount_is_var": true, "amount_var": "power",
		"condition": {"left": "", "mode": "none", "op": ">=", "right": 0.0},
		"enabled": true, "hits": 1, "kind": "apply_power",
		"loop": {"count": 1, "mode": "count", "var": ""},
		"power": "VulnerablePower", "target": "AllEnemies",
	}]
	CFDesign.normalize(schema, card)
	var src := CFExporter.emit_card(schema, card, "MyCardMod")
	_ok("不再生成 base.DynamicVars.power", not src.contains("DynamicVars.power"),
			"含" if src.contains("DynamicVars.power") else "不含")
	_ok("读值走索引器 base.DynamicVars[\"power\"]",
			src.contains('base.DynamicVars["power"]'))
	_ok("CanonicalVars 用具体 PowerVar<VulnerablePower>",
			src.contains("new PowerVar<VulnerablePower>("))
	_ok("升级增量也走索引器",
			src.contains('base.DynamicVars["power"].UpgradeValueBy(3m)'))
	# PowerVar 的 Name 默认是 typeof(T).Name（"VulnerablePower"），但用户自定义名
	# 可能是别的（如 "power"）。必须用第二个构造函数传自定义名，否则
	# DynamicVarSet 字典的 key 不对，描述里的 {power:diff()} 无法替换，
	# OnUpgrade() 也会抛 KeyNotFoundException。
	# 不要拿整个生成源码当 detail —— 会淹掉其它断言的可读性。
	# 只在失败时截取相关那一行。
	var pv_line := ""
	for l in src.split("\n"):
		if l.contains("new PowerVar<"):
			pv_line = l.strip_edges()
			break
	_ok("PowerVar 使用用户自定义名称作为字典 key",
			src.contains('new PowerVar<VulnerablePower>("power",'), pv_line)
	_ok("PowerVar 命名后变量名仍走索引器（名字与属性不是一回事）",
			src.contains('base.DynamicVars["power"]'), pv_line)

	# (e2) the nastiest naming: the variable is named *exactly* like one of the
	#      game's own `DynamicVarSet` properties. `base.DynamicVars.Weak` then
	#      compiles fine and still throws at play time — the property looks up
	#      the key `"WeakPower"` while the generated CanonicalVars registered
	#      `"Weak"`. This is the shape that shipped and broke a card in game.
	var weak_card := CFDesign.new_card(schema)
	weak_card["id"] = "WeakProbe"
	weak_card["text"]["zhs"]["title"] = "同名变量"
	weak_card["text"]["eng"]["title"] = "WeakProbe"
	weak_card["vars"] = [{
		"base": 2.0, "generic": "WeakPower", "kind": "Power",
		"name": "Weak", "type": "PowerVar", "upgrade_delta": 1.0, "value_prop": "",
	}]
	weak_card["effects"] = [{
		"amount": 0.0, "amount_is_var": true, "amount_var": "Weak",
		"condition": {"left": "", "mode": "none", "op": ">=", "right": 0.0},
		"enabled": true, "hits": 1, "kind": "apply_power",
		"loop": {"count": 1, "mode": "count", "var": ""},
		"power": "WeakPower", "target": "AllEnemies",
	}]
	CFDesign.normalize(schema, weak_card)
	var weak_src := CFExporter.emit_card(schema, weak_card, "MyCardMod")
	_ok("变量名与属性同名也不生成属性形式（游戏里会 KeyNotFoundException）",
			not weak_src.contains("base.DynamicVars.Weak"),
			"含" if weak_src.contains("base.DynamicVars.Weak") else "不含")
	_ok("同名变量读值走索引器",
			weak_src.contains('base.DynamicVars["Weak"].BaseValue'))
	_ok("同名变量的升级增量走索引器",
			weak_src.contains('base.DynamicVars["Weak"].UpgradeValueBy(1m)'))

	# (e3) localization placeholders. ONE unknown formatter makes the game fail to
	#      format the *whole* string, so the card shows no text at all:
	#        Localization formatting error! No formatter with name 'difff' found
	#      This is the other half of the "做出来的卡在游戏里没字/没效果" report, and
	#      the tool used to accept any spec (its preview even substituted a number).
	var bad := CFDesign.scan_placeholders("给予{Value3:difff()}层无实体.")
	_ok("查出游戏不认识的格式化器",
			bad.size() == 1 and String(bad[0]["reason"]) == "formatter", str(bad))
	_ok("冒号前是变量名、冒号后才是格式化器",
			bad.size() == 1 and String(bad[0]["name"]) == "Value3" \
				and String(bad[0]["formatter"]) == "difff", str(bad))
	var dotted := CFDesign.scan_placeholders("给予{Weak.diff()}层虚弱.")
	_ok("点号写法被判为语法错误（游戏解析不出这个占位符）",
			dotted.size() == 1 and String(dotted[0]["reason"]) == "syntax", str(dotted))
	var good := CFDesign.scan_placeholders(
			"造成{Damage:diff()}点伤害{Repeat}次。{IfUpgraded:show:升级|基础}。")
	_ok("正常占位符全部解析出来且不报错", good.size() == 3, str(good))
	_ok("正常占位符 reason 为空",
			good.all(func(p): return String(p["reason"]).is_empty()), str(good))
	_ok("带参数的格式化器也认识 {energyPrefix:energyIcons(1)}",
			CFDesign.describe_placeholders("{energyPrefix:energyIcons(1)}").is_empty(),
			CFDesign.describe_placeholders("{energyPrefix:energyIcons(1)}"))
	_ok("{{ 转义的花括号不算占位符",
			CFDesign.scan_placeholders("{{not a var}}").is_empty())
	for probe in ["获得{Energy:energyIcons()}。",
			"给予所有敌人[blue]{VulnerablePower}[/blue]层[gold]易伤[/gold]。"]:
		# Only the *reason* matters here: `Energy` / `VulnerablePower` are the
		# author's own vars to declare, so the undeclared-name check is skipped.
		var flagged: Array = []
		for p in CFDesign.scan_placeholders(probe):
			if not String(p["reason"]).is_empty():
				flagged.append(p)
		_ok("游戏自带写法不误报：%s" % probe,
				flagged.is_empty(), str(flagged))

	var loc_card := CFDesign.new_card(schema)
	loc_card["id"] = "LocProbe"
	loc_card["text"]["zhs"]["title"] = "文案测试"
	loc_card["text"]["eng"]["title"] = "LocProbe"
	loc_card["text"]["zhs"]["description"] = "给予{Value3:difff()}层无实体。"
	loc_card["vars"] = [CFDesign.new_var("Value3", "Value3", "PowerVar", 1.0)]
	loc_card["effects"] = []
	CFDesign.normalize(schema, loc_card)
	var loc_errors := 0
	var loc_messages := ""
	for it in CFDesign.validate(schema, loc_card, []):
		if String(it["severity"]) == CFDesign.SEV_ERROR:
			loc_errors += 1
			loc_messages += String(it["message"])
	_ok("校验把格式化器笔误报成错误", loc_errors >= 1 and loc_messages.contains("difff"),
			loc_messages)
	_ok("预览不替坏掉的 spec 编一个数字",
			CFDesign.render_description(loc_card, "zhs")["bbcode"].contains("difff"),
			String(CFDesign.render_description(loc_card, "zhs")["bbcode"]))
	_ok("未声明的变量会被点名",
			CFDesign.describe_placeholders("造成{Nope:diff()}点伤害", ["Damage"]).contains("Nope"),
			CFDesign.describe_placeholders("造成{Nope:diff()}点伤害", ["Damage"]))
	_ok("已声明的变量不点名",
			CFDesign.describe_placeholders("造成{Damage:diff()}点伤害", ["Damage"]).is_empty(),
			CFDesign.describe_placeholders("造成{Damage:diff()}点伤害", ["Damage"]))

	# (e4) art paths, mirroring the game's own accessors. The card paths used to
	#      be written without `packed/` and without the pool segment — a path no
	#      code in the game reads, so the portrait always fell back to the
	#      missing-art placeholder.
	var art_card := CFDesign.new_card(schema)
	art_card["id"] = "wudi"
	art_card["pool"] = "IroncladCardPool"
	art_card["vars"] = []
	art_card["effects"] = []
	CFDesign.normalize(schema, art_card)
	var art: Dictionary = art_card["art"]
	_ok("卡图路径与 CardModel.PortraitPngPath 一致",
			String(art["portrait"]) == "images/packed/card_portraits/ironclad/wudi.png",
			String(art["portrait"]))
	_ok("卡图图集路径与 CardModel.PortraitPath 一致",
			String(art["atlas"]) == "images/atlases/card_atlas.sprites/ironclad/wudi.tres",
			String(art["atlas"]))
	_ok("卡池 Title 用扫描值/后缀兜底得到 ironclad",
			CFDesign.pool_art_name(schema, "IroncladCardPool") == "ironclad",
			CFDesign.pool_art_name(schema, "IroncladCardPool"))
	_ok("ColorlessCardPool -> colorless",
			CFDesign.pool_art_name(schema, "ColorlessCardPool") == "colorless",
			CFDesign.pool_art_name(schema, "ColorlessCardPool"))
	var art_relic := CFDesign.new_relic(schema)
	art_relic["id"] = "Ward"
	CFDesign.normalize(schema, art_relic)
	_ok("遗物图标路径与 RelicModel.BigIconPath 一致",
			String(art_relic["art"]["icon"]) == "images/relics/ward.png",
			String(art_relic["art"]["icon"]))

	# (f) the label helpers used by the UI.
	_ok("power_title(VulnerablePower) 给出中文",
			schema.power_title("VulnerablePower", "zhs") == "易伤",
			schema.power_title("VulnerablePower", "zhs"))
	_ok("power_label 形如 中文（English）",
			schema.power_label("VulnerablePower") == "易伤（Vulnerable）",
			schema.power_label("VulnerablePower"))
	_ok("未本地化的 Power 退回类名去后缀",
			schema.power_title("NoSuchPowerXyz", "zhs") == "NoSuchPowerXyz".trim_suffix("Power"),
			schema.power_title("NoSuchPowerXyz", "zhs"))

# ---------------------------------------------------------------------------
# 效果 / Buff 全量覆盖
#
# 「把卡牌与遗物定义器里的所有 buff 和效果都过一遍」：每一种效果 × 每一种目标
# 都要走完「归一化 → 校验 → 生成 C#」三步，并断言生成的代码里出现的是游戏里
# **真实存在**的那个 API。
#
# 之前只有零散几个断言，于是 弃牌 / 消耗 / 升级 / 生成牌 / 直接伤害 / 获得金币
# 这些效果在被真正用到之前，没人知道它们生成的是不存在的重载 —— 卡牌编不过，
# 玩家看到的只有「做出来的卡在游戏里用不了」。
# ---------------------------------------------------------------------------

## kind -> 生成的 C# 里必须出现的那次调用（卡牌作用域、默认目标）。
const EFFECT_EXPECT := {
	"damage": "DamageCmd.Attack(",
	"damage_direct": "CreatureCmd.Damage(",
	"block": "CreatureCmd.GainBlock(",
	"heal": "CreatureCmd.Heal(",
	"gain_max_hp": "CreatureCmd.GainMaxHp(",
	"energy": "PlayerCmd.GainEnergy(",
	"star": "PlayerCmd.GainStars(",
	"draw": "CardPileCmd.Draw(",
	"discard": "CardCmd.Discard(",
	"exhaust": "CardCmd.Exhaust(",
	"upgrade_card": "CardCmd.Upgrade(",
	"generate_card": "AddGeneratedCardToCombat(",
	"apply_power": "PowerCmd.Apply<",
	"add_keyword": "AddKeyword(",
	"gain_gold": "PlayerCmd.GainGold(",
	"forge": "ForgeCmd.Forge(",
}

## 目标表达式是「一堆生物」（IEnumerable<Creature>）的那几个。
const LIST_TARGETS := ["all_enemies", "all_allies"]
## 这些命令只收单个 Creature，对上面那些目标必须用 foreach 逐个调用。
const SINGLE_CREATURE_KINDS := ["block", "heal", "gain_max_hp"]
## 每个单生物效果在 foreach 里用的循环变量名（与 emitter 里保持一致）。
const SINGLE_CREATURE_LOOP_VAR := {
	"block": "blockTarget",
	"heal": "healTarget",
	"gain_max_hp": "maxHpTarget",
}


## 第一条包含 `needle` 的源码行（去首尾空白）：断言失败时用来说明到底生成了什么。
func _line_with(src: String, needle: String) -> String:
	for l in src.split("\n"):
		if l.contains(needle):
			return l.strip_edges()
	return "（没有含 “%s” 的行）" % needle


## 该效果在某作用域 / 目标下应当出现的调用。
##
## `damage` 有两种形态：卡牌里是 DamageCmd.Attack 流式 API，一旦没有可用的
## AttackCommand 目标（遗物没有 FromCard、友方列表没有 Targeting*）就退回
## CreatureCmd.Damage。
func _expected_call(kind: String, target: String, is_relic: bool = false) -> String:
	if kind == "damage" and (is_relic or target == "all_allies"):
		return "CreatureCmd.Damage("
	return String(EFFECT_EXPECT.get(kind, ""))


func _sev_errors(issues: Array) -> Array:
	var out: Array = []
	for i in issues:
		if String(i.get("severity", "")) == CFDesign.SEV_ERROR:
			out.append(String(i.get("message", "")))
	return out


## 建一个带各种必需字段的效果（数量 3、目标由调用方指定）。
func _matrix_effect(schema: CFSchema, kind: String, target: String) -> Dictionary:
	var e := CFDesign.new_effect(kind)
	e["amount"] = 3.0
	e["target"] = target
	e["pile"] = "Hand"
	e["position"] = "Bottom"
	if not schema.powers.is_empty():
		e["power"] = String((schema.powers[0] as Dictionary).get("class_name", ""))
	var kws := schema.members_for_role("card_keyword")
	if not kws.is_empty():
		e["keyword"] = String(kws[0])
	if not schema.existing_cards.is_empty():
		e["card_entry"] = String((schema.existing_cards[0] as Dictionary).get("entry", ""))
	return e


## 一张只带一个效果、瞄准 `target` 的卡牌。
func _matrix_card(schema: CFSchema, kind: String, target: String) -> Dictionary:
	var card := CFDesign.new_card(schema)
	card["id"] = "MatrixCard"
	card["entry"] = "MATRIX_CARD"
	card["text"]["zhs"]["title"] = "全量检查"
	card["text"]["eng"]["title"] = "Matrix"
	card["vars"] = []
	card["flags"]["gains_block"] = true
	card["effects"] = [_matrix_effect(schema, kind, target)]
	CFDesign.normalize(schema, card)
	return card


## 一件带单个效果（挂在 `hook_name` 上、目标=自己）的遗物。
func _matrix_relic(schema: CFSchema, kind: String, hook_name: String) -> Dictionary:
	var relic := CFDesign.new_relic(schema)
	relic["id"] = "MatrixRelic"
	relic["entry"] = "MATRIX_RELIC"
	relic["text"]["zhs"]["title"] = "全量检查"
	relic["text"]["eng"]["title"] = "Matrix"
	relic["vars"] = []
	relic["triggers"] = [{
		"hook": hook_name,
		"params": CFDesign._default_param_bindings(schema, hook_name),
		"condition": CFDesign.new_condition(),
		"charge": {"mode": "always", "n": 1},
		"loop": {"mode": "none", "count": 1, "var": ""},
		"effects": [_matrix_effect(schema, kind, "self")],
		"note": "",
	}]
	CFDesign.normalize(schema, relic)
	return relic


## 用户实测的那张牌：BlockVar 叫 Value4，效果是「给自己格挡」。
##
## 它同时踩了两个坑：`new BlockVar(20m, …)` 用默认名 "Block" 注册，而读值走的
## 是 `base.DynamicVars["Value4"]` → 一打出就 KeyNotFoundException、格挡一点
## 也不加；而「给谁格挡」曾经写死成某个非目标表达式。
func _test_block_grant(schema: CFSchema) -> void:
	print("\n-- 格挡给谁 + BlockVar 命名（用户实测）--")
	var card := CFDesign.new_card(schema)
	card["id"] = "Wudi"
	card["entry"] = "WUDI"
	card["text"]["zhs"]["title"] = "我无敌了"
	card["text"]["eng"]["title"] = "Wudi"
	card["flags"]["gains_block"] = true
	card["vars"] = [CFDesign.new_var("Value4", "Block", "BlockVar", 20.0, "Move")]
	var e := CFDesign.new_effect("block")
	e["target"] = "self"
	e["amount_is_var"] = true
	e["amount_var"] = "Value4"
	card["effects"] = [e]
	CFDesign.normalize(schema, card)
	_ok("BlockVar + 格挡效果 校验无错误", _sev_errors(CFDesign.validate(schema, card, [])).is_empty(),
			str(_sev_errors(CFDesign.validate(schema, card, []))))
	var src := CFExporter.emit_card(schema, card, "WudiMod")
	_ok("BlockVar 用用户自己的名字注册（Value4，而不是默认 Block）",
			src.contains('new BlockVar("Value4", 20m, ValueProp.Move)'), _line_with(src, "new BlockVar"))
	_ok("读值用的是同一个 key（base.DynamicVars[\"Value4\"]）",
			src.contains('base.DynamicVars["Value4"].BaseValue'), _line_with(src, "DynamicVars"))
	_ok("格挡给「打出这张牌的玩家的生物」",
			src.contains("CreatureCmd.GainBlock(base.Owner.Creature, base.DynamicVars[\"Value4\"].BaseValue, ValueProp.Move, cardPlay)"),
			_line_with(src, "GainBlock"))


## Collection-target cards do not populate `CardPlay.Target`. A generated effect
## that refers to the shorthand "card target" must use the combat-state target
## and must not throw a null-target exception before OnPlay starts.
func _test_card_target_mapping(schema: CFSchema) -> void:
	print("\n-- 卡牌集合目标映射 --")
	var card := CFDesign.new_card(schema, "AllTargetProbe")
	card["target"] = "AllEnemies"
	var e := CFDesign.new_effect("damage")
	e["target"] = "card_target"
	e["amount"] = 2.0
	e["amount_is_var"] = false
	card["effects"] = [e]
	CFDesign.normalize(schema, card)
	var src := CFExporter.emit_card(schema, card, "TargetProbe")
	_ok("AllEnemies 卡牌不检查空的 cardPlay.Target", not src.contains("ThrowIfNull(cardPlay.Target"),
			_line_with(src, "ThrowIfNull"))
	_ok("卡牌目标效果映射为 TargetingAllOpponents",
			src.contains("TargetingAllOpponents(base.Owner.Creature.CombatState)"),
			_line_with(src, "TargetingAllOpponents"))


func _test_var_constructor_safety(schema: CFSchema) -> void:
	print("\n-- DynamicVar 构造函数安全性 --")
	var unnamed: Array = []
	for d in schema.dynamic_var_types:
		var type_name := String(d.get("type", ""))
		var generic := String(d.get("generic", ""))
		if type_name == "PowerVar" and generic.is_empty():
			continue
		var info := schema.var_ctor_info(type_name, generic)
		var ctors: Array = info.get("ctors", [])
		var has_named := false
		for ctor in ctors:
			if ctor is Array and not (ctor as Array).is_empty() and String((ctor as Array)[0]) == "string":
				has_named = true
				break
		if not has_named:
			unnamed.append("%s<%s>" % [type_name, generic])
	_ok("扫描结果保留了默认名构造函数类型的事实",
			unnamed.has("CalculatedBlockVar<>") or unnamed.has("CalculatedBlockVar<"),
			"仅默认名类型：%s" % str(unnamed.slice(0, 12)))
	# A custom name on a default-only type must be a blocking validation issue.
	var card := CFDesign.new_card(schema, "CtorProbe")
	card["vars"] = [CFDesign.new_var("CustomBlock", "Block", "CalculatedBlockVar", 2.0, "Move")]
	CFDesign.normalize(schema, card)
	var errors := _sev_errors(CFDesign.validate(schema, card, []))
	_ok("默认名构造函数不能伪装成自定义变量名", not errors.is_empty(), str(errors))



func _test_effect_matrix(schema: CFSchema) -> void:
	print("\n-- 效果全量覆盖（%d 种效果 × %d 种目标）--"
			% [CFEffects.KINDS.size(), CFEffects.TARGETS.size()])

	var uncovered: Array = []
	for k in CFEffects.KINDS:
		if not EFFECT_EXPECT.has(String(k["id"])):
			uncovered.append(String(k["id"]))
	_ok("每种效果都有「生成结果」断言表项", uncovered.is_empty(), str(uncovered))

	var validate_bad: Array = []
	var emit_bad: Array = []
	var scope_leak: Array = []
	var single_bad: Array = []
	var generated_bad: Array = []
	for k in CFEffects.KINDS:
		var kind := String(k["id"])
		for t in CFEffects.TARGETS:
			var target := String(t["id"])
			var card := _matrix_card(schema, kind, target)
			for m in _sev_errors(CFDesign.validate(schema, card, [])):
				validate_bad.append("%s/%s: %s" % [kind, target, m])
			var src := CFExporter.emit_card(schema, card, "MatrixMod")
			var expect := _expected_call(kind, target, false)
			if not src.contains(expect):
				emit_bad.append("%s/%s 缺少 %s" % [kind, target, expect])
			if src.contains("未知效果类型"):
				emit_bad.append("%s/%s 生成了 TODO" % [kind, target])
			# `RelicModel` 上没有 CombatState；卡牌作用域也必须走
			# base.Owner.Creature.CombatState，否则遗物那边会编不过。
			if src.contains("base.CombatState"):
				scope_leak.append("%s/%s 用了 base.CombatState" % [kind, target])
			# 单生物命令直接吃列表是 CS1503 —— 必须 foreach。
			if SINGLE_CREATURE_KINDS.has(kind) and LIST_TARGETS.has(target):
				if not src.contains("foreach (Creature"):
					single_bad.append("%s/%s 没有 foreach" % [kind, target])
				else:
					var loop_var := String(SINGLE_CREATURE_LOOP_VAR.get(kind, ""))
					if not src.contains("(%s" % loop_var):
						single_bad.append("%s/%s 循环体没有用循环变量" % [kind, target])
			# 生成的卡牌：先 CreateCard 再 AddGeneratedCardToCombat，且牌堆/位置不能为空。
			if kind == "generate_card":
				if not src.contains("CombatState.CreateCard<"):
					generated_bad.append("没有 CreateCard")
				if src.contains("PileType.;") or src.contains("CardPilePosition.;"):
					generated_bad.append("牌堆/位置为空：%s" % _line_with(src, "AddGeneratedCardToCombat"))

	_ok("每种效果 × 每种目标 都通过校验（无 error）", validate_bad.is_empty(),
			"%d 项：%s" % [validate_bad.size(), str(validate_bad.slice(0, 4))])
	_ok("每种效果 × 每种目标 都生成了预期 API", emit_bad.is_empty(),
			"%d 项：%s" % [emit_bad.size(), str(emit_bad.slice(0, 4))])
	_ok("生成代码不使用不存在的 base.CombatState", scope_leak.is_empty(),
			str(scope_leak.slice(0, 4)))
	_ok("单生物命令对「一堆生物」改用 foreach", single_bad.is_empty(), str(single_bad))
	_ok("生成牌效果先 CreateCard 且牌堆/位置有值", generated_bad.is_empty(), str(generated_bad))

	# 目标表达式本身：所有敌人 / 所有友方都要能从卡牌与遗物两个作用域访问。
	var enemy_src := CFExporter.emit_card(schema, _matrix_card(schema, "apply_power", "all_enemies"), "M")
	_ok("所有敌人 = base.Owner.Creature.CombatState.HittableEnemies",
			enemy_src.contains("base.Owner.Creature.CombatState.HittableEnemies"),
			_line_with(enemy_src, "Apply<"))
	var ally_src := CFExporter.emit_card(schema, _matrix_card(schema, "block", "all_allies"), "M")
	_ok("所有友方 = base.Owner.Creature.CombatState.Allies（不再是 Players）",
			ally_src.contains("base.Owner.Creature.CombatState.Allies")
			and not ally_src.contains("CombatState.Players"), _line_with(ally_src, "GainBlock"))
	var ally_dmg := CFExporter.emit_card(schema, _matrix_card(schema, "damage", "all_allies"), "M")
	_ok("友方目标没有 AttackCommand 形式时退回 CreatureCmd.Damage",
			ally_dmg.contains("CreatureCmd.Damage(") and not ally_dmg.contains("TargetingAllOpponents"),
			_line_with(ally_dmg, "Damage"))
	# 弃牌/消耗/升级收的是「牌」，不是一个数量：生成的必然是选牌 + 操作。
	var discard_src := CFExporter.emit_card(schema, _matrix_card(schema, "discard", "self"), "M")
	_ok("弃牌先选牌再弃（CardSelectCmd.FromHandForDiscard → CardCmd.Discard）",
			discard_src.contains("CardSelectCmd.FromHandForDiscard(")
			and discard_src.contains("CardSelectorPrefs.DiscardSelectionPrompt"),
			_line_with(discard_src, "Discard("))
	var upgrade_src := CFExporter.emit_card(schema, _matrix_card(schema, "upgrade_card", "self"), "M")
	_ok("升级是 CardCmd.Upgrade(牌)（不是 async、也没有数量参数）",
			upgrade_src.contains("CardCmd.Upgrade(upgradeTarget);")
			and not upgrade_src.contains("await CardCmd.Upgrade("),
			_line_with(upgrade_src, "Upgrade("))
	# 金币：第三个参数是 wasStolenBack，不是「播放动画」。
	var gold_src := CFExporter.emit_card(schema, _matrix_card(schema, "gain_gold", "self"), "M")
	_ok("获得金币不传 wasStolenBack=true",
			gold_src.contains("PlayerCmd.GainGold(3m, base.Owner);") and not gold_src.contains("GainGold(3m, base.Owner, true)"),
			_line_with(gold_src, "GainGold"))


## 遗物作用域：同一个效果在遗物里得生成**另一套**写法（没有 cardPlay、没有
## CombatState、没有 AddKeyword，CardModel? 参数要传 null）。
func _test_relic_effect_matrix(schema: CFSchema) -> void:
	print("\n-- 遗物全量覆盖（%d 种效果）--" % CFEffects.KINDS.size())
	var hook_name := ""
	for h in schema.usable_hooks():
		var has_ctx := false
		for p in (h.get("params", []) as Array):
			if String(p).contains("PlayerChoiceContext"):
				has_ctx = true
		if has_ctx:
			hook_name = String(h["name"])
			break
	_ok("找到一个带 PlayerChoiceContext 的触发时机", not hook_name.is_empty(), hook_name)
	if hook_name.is_empty():
		return

	var validate_bad: Array = []
	var emit_bad: Array = []
	var relic_leak: Array = []
	for k in CFEffects.KINDS:
		var kind := String(k["id"])
		var relic := _matrix_relic(schema, kind, hook_name)
		var errs := _sev_errors(CFDesign.validate(schema, relic, []))
		# 「给这张牌加关键字」在遗物上没有对应方法：必须**报错**而不是悄悄生成
		# 编不过的代码。
		if kind == "add_keyword":
			if errs.is_empty():
				validate_bad.append("add_keyword 没有报错")
		elif not errs.is_empty():
			validate_bad.append("%s: %s" % [kind, str(errs)])
		var src := CFExporter.emit_relic(schema, relic, "MatrixMod")
		if not (src.contains("override ") and src.contains("%s(" % hook_name)):
			emit_bad.append("%s 没有生成 %s 覆写" % [kind, hook_name])
		if kind == "add_keyword":
			if not src.contains("TODO"):
				emit_bad.append("add_keyword 没有生成 TODO 注释")
		elif not src.contains(_expected_call(kind, "self", true)):
			emit_bad.append("%s 缺少 %s" % [kind, _expected_call(kind, "self", true)])
		if src.contains("cardPlay") or src.contains("base.CombatState"):
			relic_leak.append("%s 用了卡牌专属表达式" % kind)
		if kind == "damage" and src.contains("FromCard(this)"):
			relic_leak.append("damage 用了 FromCard(this)（遗物没有 CardModel）")
		if kind == "apply_power" and not src.contains("base.Owner.Creature, null);"):
			relic_leak.append("apply_power 的 cardSource 不是 null")
		if kind == "damage_direct" and not src.contains("base.Owner.Creature, null);"):
			relic_leak.append("damage_direct 的 cardSource 不是 null")
	_ok("遗物：每种效果都通过校验（add_keyword 必须报错）", validate_bad.is_empty(),
			"%d 项：%s" % [validate_bad.size(), str(validate_bad.slice(0, 4))])
	_ok("遗物：每种效果都生成了对应 API", emit_bad.is_empty(),
			"%d 项：%s" % [emit_bad.size(), str(emit_bad.slice(0, 4))])
	_ok("遗物：不生成卡牌专属表达式（cardPlay / CombatState / FromCard）", relic_leak.is_empty(),
			str(relic_leak.slice(0, 4)))
	# 遗物里选「卡牌目标」是编不过的：必须在导出前就报出来。
	var bad := _matrix_relic(schema, "block", hook_name)
	bad["triggers"][0]["effects"][0]["target"] = "card_target"
	_ok("遗物 + 卡牌目标 被校验拦下",
			not _sev_errors(CFDesign.validate(schema, bad, [])).is_empty(), str(bad["triggers"][0]["effects"][0]))


## Lifecycle hooks such as AfterObtained do not receive PlayerChoiceContext.
## Generated relic effects still need a context for command APIs; use the same
## blocking context the game uses for pickup callbacks instead of emitting an
## undefined `choiceContext` local.
func _test_relic_lifecycle_context(schema: CFSchema) -> void:
	print("\n-- 遗物生命周期触发时机 --")
	var hook_name := "AfterObtained" if not schema.hook("AfterObtained").is_empty() else ""
	_ok("扫描到 AfterObtained 生命周期触发时机", not hook_name.is_empty(), hook_name)
	if hook_name.is_empty():
		return
	var relic := CFDesign.new_relic(schema)
	relic["id"] = "LifecycleRelic"
	relic["entry"] = "LIFECYCLE_RELIC"
	relic["text"]["zhs"]["title"] = "生命周期遗物"
	var e := CFDesign.new_effect("apply_power")
	e["power"] = "VulnerablePower"
	e["target"] = "self"
	e["amount"] = 1.0
	relic["triggers"] = [{
		"hook": hook_name,
		"params": CFDesign._default_param_bindings(schema, hook_name),
		"condition": CFDesign.new_condition(),
		"charge": {"mode": "always", "n": 1},
		"loop": {"mode": "none", "count": 1, "var": ""},
		"effects": [e],
		"note": "",
	}]
	CFDesign.normalize(schema, relic)
	var src := CFExporter.emit_relic(schema, relic, "LifecycleMod")
	_ok("AfterObtained 使用 BlockingPlayerChoiceContext",
			src.contains("new BlockingPlayerChoiceContext()"), _line_with(src, "BlockingPlayerChoiceContext"))
	_ok("AfterObtained 不引用不存在的 choiceContext",
		not src.contains("PowerCmd.Apply<VulnerablePower>(choiceContext,"), _line_with(src, "PowerCmd.Apply"))


## Buff 全量：256 个 Power 每一个都要能当效果目标，也都能当 PowerVar<T> 变量。
func _test_power_matrix(schema: CFSchema) -> void:
	print("\n-- Buff / Power 全量覆盖（%d 个 Power）--" % schema.powers.size())
	var count := 0
	var mock_count := 0
	var apply_bad: Array = []
	var var_bad: Array = []
	var ctor_bad: Array = []
	for p in schema.powers:
		var cls := String((p as Dictionary).get("class_name", "")).strip_edges()
		if cls.is_empty():
			continue
		count += 1
		var card := _matrix_card(schema, "apply_power", "self")
		card["effects"][0]["power"] = cls
		var src := CFExporter.emit_card(schema, card, "MatrixMod")
		if not src.contains("PowerCmd.Apply<%s>(" % cls):
			apply_bad.append(cls)
		# 测试替身（`...Models.Powers.Mocks`）只保证「当效果能编过」：它们是游戏
		# 自带的桩，选择器不提供，也不该出现在 PowerVar 变量类型列表里。
		if bool((p as Dictionary).get("is_mock", false)):
			mock_count += 1
			continue
		if bool((p as Dictionary).get("is_abstract", false)):
			continue
		if schema.var_ctor_info("PowerVar", cls).is_empty():
			ctor_bad.append(cls)
		var vcard := CFDesign.new_card(schema)
		vcard["id"] = "PowVar"
		vcard["entry"] = "POW_VAR"
		vcard["text"]["zhs"]["title"] = "全量检查"
		vcard["text"]["eng"]["title"] = "PowVar"
		vcard["effects"] = []
		vcard["vars"] = [CFDesign.new_var("P", "Power", "PowerVar", 1.0, "", cls)]
		vcard["flags"]["gains_block"] = true
		CFDesign.normalize(schema, vcard)
		var vsrc := CFExporter.emit_card(schema, vcard, "MatrixMod")
		if not vsrc.contains('new PowerVar<%s>("P", 1m)' % cls):
			var_bad.append(cls)
	_ok("扫描到全部 Power（>= 200）", count >= 200, str(count))
	_ok("测试替身 Power 只做效果验证，不算变量类型", mock_count > 0,
			"%d 个 Mock（共 %d 个 Power）" % [mock_count, count])
	_ok("每个 Power 都能生成 PowerCmd.Apply<T>", apply_bad.is_empty(),
			"%d 个失败：%s" % [apply_bad.size(), str(apply_bad.slice(0, 5))])
	_ok("每个正式 Power（不含测试替身）都能当 PowerVar<T> 变量（用户自定义名）", var_bad.is_empty(),
			"%d 个失败：%s" % [var_bad.size(), str(var_bad.slice(0, 5))])
	_ok("每个正式 Power 的 PowerVar 构造函数都被扫描到", ctor_bad.is_empty(),
			"%d 个缺失：%s" % [ctor_bad.size(), str(ctor_bad.slice(0, 5))])


## 生成的 C# 「能不能编过」，最终只有真编译器说了算（上一轮的满汉全席探针就是
## 直接 dotnet build 的）。这里把那轮只有编译器才抓得到的坑固化成断言：
##
##   * 一张牌里放两个「生成一张牌」时，`CardModel generated` 会在同一个声明空间
##     里声明两次 → CS0128，整个 mod 编不过，游戏里一张牌都用不上；
##   * `<T>` 里的类型要 import 对应命名空间，否则 CS0246：`PowerVar<T>` /
##     `PowerCmd.Apply<T>` 需要 Powers（游戏自带的测试替身在 `.Mocks`
##     子命名空间，必须单独 import，也不该出现在选择器里），`CreateCard<T>`
##     需要 Models.Cards，遗物覆写签名里的 `AttackCommand` 需要 Commands.Builders。
func _test_usings_and_locals(schema: CFSchema) -> void:
	print("\n-- 生成代码的 using 与局部变量唯一性 --")
	# (1) 两个「生成一张牌」：局部变量名必须唯一。
	var card := _matrix_card(schema, "generate_card", "self")
	card["effects"].append(_matrix_effect(schema, "generate_card", "self"))
	CFDesign.normalize(schema, card)
	var src := CFExporter.emit_card(schema, card, "UsingsMod")
	_ok("两个「生成一张牌」不会重复声明 generated（CS0128）",
			src.count("CardModel generated =") == 1
			and src.count("CardModel generated_2 =") == 1,
			_line_with(src, "generated_2 ="))
	# (2) 生成基础游戏的卡牌 → 要 import 卡牌模型的命名空间。
	_ok("生成基础游戏卡牌会 import MegaCrit.Sts2.Core.Models.Cards",
			src.contains("using MegaCrit.Sts2.Core.Models.Cards;"),
			_line_with(src, "CreateCard<"))

	var real_power := ""
	var mock_power := ""
	for p in schema.powers:
		var cls := String((p as Dictionary).get("class_name", ""))
		if cls.is_empty():
			continue
		if bool((p as Dictionary).get("is_mock", false)):
			if mock_power.is_empty():
				mock_power = cls
		elif real_power.is_empty():
			real_power = cls
	# (3) 只有 PowerVar<T> 变量（没有 apply_power）也要 import Powers。
	if not real_power.is_empty():
		var vcard := CFDesign.new_card(schema)
		vcard["id"] = "PowVarOnly"
		vcard["entry"] = "POW_VAR_ONLY"
		vcard["text"]["zhs"]["title"] = "只有变量"
		vcard["text"]["eng"]["title"] = "PowVarOnly"
		vcard["effects"] = []
		vcard["vars"] = [CFDesign.new_var("P", "Power", "PowerVar", 1.0, "", real_power)]
		CFDesign.normalize(schema, vcard)
		var vsrc := CFExporter.emit_card(schema, vcard, "UsingsMod")
		_ok("只有 PowerVar<T>（没有 apply_power）也会 import Power 的命名空间",
				vsrc.contains("using MegaCrit.Sts2.Core.Models.Powers;"),
				_line_with(vsrc, "new PowerVar<"))
	# (4) 测试替身 Power 在 `.Mocks`：必须单独 import，且选择器不提供。
	_ok("扫描到测试替身 Power（用于验证子命名空间）", not mock_power.is_empty(), mock_power)
	if not mock_power.is_empty():
		var mcard := _matrix_card(schema, "apply_power", "self")
		mcard["effects"][0]["power"] = mock_power
		CFDesign.normalize(schema, mcard)
		var msrc := CFExporter.emit_card(schema, mcard, "UsingsMod")
		_ok("测试替身 Power 会 import ...Models.Powers.Mocks",
				msrc.contains("using MegaCrit.Sts2.Core.Models.Powers.Mocks;"),
				_line_with(msrc, "Apply<"))
	var leaked: Array = []
	for o in CFEffects.power_options(schema):
		var v := String((o as Dictionary).get("value", ""))
		if v.begins_with("Mock"):
			leaked.append(v)
	_ok("Power 选择器不再列出测试替身（Mock*Power）", leaked.is_empty(),
			"%d 个：%s" % [leaked.size(), str(leaked.slice(0, 5))])
	var pv_leaked: Array = []
	for t in schema.dynamic_var_types:
		if String(t.get("type", "")) == "PowerVar" \
				and String(t.get("generic", "")).begins_with("Mock"):
			pv_leaked.append(String(t.get("generic", "")))
	_ok("PowerVar 变量类型选择器也不列出测试替身", pv_leaked.is_empty(),
			"%d 个：%s" % [pv_leaked.size(), str(pv_leaked.slice(0, 5))])

	# (5) 遗物覆写签名里的参数类型要 import：AfterAttack 的 AttackCommand 在
	#     ...Core.Commands.Builders。
	var hook_name := ""
	for h in schema.usable_hooks():
		var hit := false
		for prm in (h.get("params", []) as Array):
			hit = hit or String(prm).contains("AttackCommand")
		if hit:
			hook_name = String(h["name"])
			break
	if not hook_name.is_empty():
		var relic := _matrix_relic(schema, "draw", hook_name)
		var rsrc := CFExporter.emit_relic(schema, relic, "UsingsMod")
		_ok("遗物覆写提到的参数类型会 import 对应命名空间（AttackCommand）",
				rsrc.contains("using MegaCrit.Sts2.Core.Commands.Builders;"),
				_line_with(rsrc, "override "))
