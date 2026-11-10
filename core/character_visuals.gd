@tool
class_name CFCharacterVisuals
extends RefCounted

## Self-contained, script-free Godot model bundles. Source assets remain editable;
## textures are converted to native resources so the game needs no import cache.
const IMAGES := ["png", "webp", "jpg", "jpeg", "svg"]
const TEXT := ["tscn", "tres", "gdshader", "gdshaderinc"]
const SCENES := ["battle_scene", "merchant_scene", "rest_scene"]
const PICTURES := ["icon", "select_icon", "select_background"]
const ANIMATIONS := ["idle", "attack", "cast", "hit", "dead"]
const EXAMPLE := "res://resources/character_models/ForgePuppet"


static func normalized(value: Variant) -> Dictionary:
	var v: Dictionary = value.duplicate(true) if value is Dictionary else {}
	var defaults := {"mode": "template", "asset_root": "", "battle_scene": "battle.tscn",
		"merchant_scene": "", "rest_scene": "", "icon": "", "select_icon": "", "select_background": "",
		"animated": true, "idle": "idle", "attack": "attack", "cast": "cast", "hit": "hit", "dead": "dead",
		"attack_delay": 0.15, "cast_delay": 0.15}
	for key in defaults:
		if not v.has(key):
			v[key] = defaults[key]
	return v


static func example() -> Dictionary:
	return normalized({"mode": "custom", "asset_root": EXAMPLE, "merchant_scene": "world.tscn",
		"rest_scene": "world.tscn", "icon": "icon.svg", "select_icon": "select.svg", "select_background": "background.svg"})


static func safe_relative(path: String) -> bool:
	return not path.is_empty() and not path.is_absolute_path() and not path.contains(":") \
		and not path.contains("\\") and not ".." in path.split("/") and not path.begins_with(".")


static func files_in(root: String, sub: String = "") -> Array[String]:
	root = ProjectSettings.globalize_path(root)
	var result: Array[String] = []
	var dir := DirAccess.open(root.path_join(sub))
	if dir == null:
		return result
	for folder in dir.get_directories():
		if not folder.begins_with("."):
			result.append_array(files_in(root, sub.path_join(folder)))
	for file in dir.get_files():
		if file.get_extension().to_lower() in IMAGES + TEXT:
			result.append(sub.path_join(file))
	result.sort()
	return result


static func references(text: String) -> Array:
	# Godot text resources declare every external dependency as an ext_resource.
	var refs: Array = []
	for match in RegEx.create_from_string('path="([^"]+)"').search_all(text):
		refs.append(match.get_string(1))
	for match in RegEx.create_from_string('#include\\s+"([^"]+)"').search_all(text):
		refs.append(match.get_string(1))
	return refs


static func resolve_reference(file: String, ref: String) -> String:
	if ref.begins_with("res://"):
		return ref.trim_prefix("res://")
	if ref.is_absolute_path() or ref.contains(":"):
		return ""
	return file.get_base_dir().path_join(ref).simplify_path()


static func validate(v0: Variant) -> Array:
	var v := normalized(v0)
	if v["mode"] == "template":
		return []
	if v["mode"] != "custom":
		return ["模型模式无效，请选择原版模板或自定义模型。"]
	var errors: Array = []
	var root := ProjectSettings.globalize_path(String(v["asset_root"]))
	if String(v["asset_root"]).is_empty() or not DirAccess.dir_exists_absolute(root):
		return ["自定义模型文件夹不存在，请重新导入模型。"]
	var files := files_in(root)
	for field in SCENES + PICTURES:
		var path := String(v[field])
		if path.is_empty() and field != "battle_scene":
			continue
		if not safe_relative(path) or not path in files:
			errors.append("模型 %s 找不到文件或路径越界：%s" % [field, path])
		elif field in SCENES and path.get_extension() != "tscn":
			errors.append("模型 %s 必须为 .tscn 场景。" % field)
		elif field in PICTURES and not path.get_extension().to_lower() in IMAGES:
			errors.append("模型 %s 必须为 PNG、WebP、JPG 或 SVG 图片。" % field)
	for file in files:
		if not file.get_extension().to_lower() in TEXT:
			continue
		var text := CFPaths.read_text(root.path_join(file))
		for ref in references(text):
			var resolved := resolve_reference(file, ref)
			if not safe_relative(resolved) or not resolved in files:
				errors.append("模型 %s 的依赖不可打包：%s。资源必须在模型文件夹内；支持 tscn/tres、图片和着色器，不支持脚本或导入缓存。" % [file, ref])
		if RegEx.create_from_string('(?m)^\\s*script\\s*=').search(text) != null:
			errors.append("模型 %s 含脚本；请使用无脚本的场景和 AnimationPlayer / AnimatedSprite2D。" % file)
	if bool(v["animated"]) and String(v["idle"]).strip_edges().is_empty():
		errors.append("启用动画时必须填写待机动画名。")
	for key in ["attack_delay", "cast_delay"]:
		if not (v[key] is float or v[key] is int) or not is_finite(float(v[key])) or float(v[key]) < 0 or float(v[key]) > 10:
			errors.append("动作延迟必须是 0～10 秒的数值。")
	return errors


static func import_bundle(v0: Dictionary) -> Dictionary:
	var errors := validate(v0)
	if not errors.is_empty():
		return {"ok": false, "error": "\n".join(errors)}
	var v := normalized(v0)
	if v["mode"] == "template":
		return {"ok": true, "visuals": v}
	var root := ProjectSettings.globalize_path(String(v["asset_root"]))
	var files := files_in(root)
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	for file in files:
		hash.update(file.to_utf8_buffer())
		hash.update(FileAccess.get_file_as_bytes(root.path_join(file)))
	var target := "res://designs/character_assets/" + hash.finish().hex_encode()
	for file in files:
		var dest := ProjectSettings.globalize_path(target.path_join(file))
		if ProjectSettings.globalize_path(root.path_join(file)) == ProjectSettings.globalize_path(dest):
			continue
		if DirAccess.make_dir_recursive_absolute(dest.get_base_dir()) != OK or DirAccess.copy_absolute(root.path_join(file), dest) != OK:
			return {"ok": false, "error": "无法保存模型素材：" + dest}
	CFPaths.write_text(ProjectSettings.globalize_path(target.path_join(".gdignore")), "")
	v["asset_root"] = target
	return {"ok": true, "visuals": v}


static func resource_path(mod_id: String, character_id: String, path: String) -> String:
	if path.is_empty():
		return ""
	return "res://%s/characters/%s/%s%s" % [mod_id, CFCharacters.code_name(character_id), path,
		".ctex" if path.get_extension().to_lower() in IMAGES else ""]


static func save_compressed_texture(img: Image, path: String) -> Error:
	# Godot 4.5 CompressedTexture2D v1, lossless PNG payload, no mipmaps.
	# Layout: scene/resources/compressed_texture.cpp (_load_data/load_image_from_file)
	# and editor/import/resource_importer_texture.cpp (_save_ctex). Keep this a
	# CompressedTexture2D: the game's selection icons and map markers cast to it.
	if img.is_empty() or img.get_width() > 65535 or img.get_height() > 65535:
		return ERR_INVALID_DATA
	img.convert(Image.FORMAT_RGBA8)
	img.clear_mipmaps()
	var png := img.save_png_to_buffer()
	if png.is_empty():
		return ERR_INVALID_DATA
	var f := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer("GST2".to_ascii_buffer())
	f.store_32(1) # FORMAT_VERSION
	f.store_32(img.get_width())
	f.store_32(img.get_height())
	f.store_32(0) # No streaming or detection flags.
	f.store_32(0) # Mipmap limit (unused without mipmaps).
	for i in 3:
		f.store_32(0) # Reserved.
	f.store_32(1) # DATA_FORMAT_PNG
	f.store_16(img.get_width())
	f.store_16(img.get_height())
	f.store_32(0) # Mipmap count.
	f.store_32(Image.FORMAT_RGBA8)
	# Image::png_packer_func adds a four-byte tag before the ordinary PNG stream.
	f.store_32(png.size() + 4)
	f.store_buffer("PNG ".to_ascii_buffer())
	f.store_buffer(png)
	f.flush()
	var err := f.get_error()
	f.close()
	return err


static func pack(c: Dictionary, mod_id: String, mod_dir: String, pck: CFPckWriter, written: Array) -> Dictionary:
	var v := normalized(c.get("visuals", {}))
	var errors := validate(v)
	if not errors.is_empty():
		return {"ok": false, "error": "\n".join(errors)}
	if v["mode"] == "template":
		return {"ok": true}
	var root := ProjectSettings.globalize_path(String(v["asset_root"]))
	var result := _pack_files(c, root, "", mod_id, mod_dir, pck, written)
	if not result["ok"]:
		return result
	# Supply independent UI/world defaults for optional fields, never a vanilla
	# character's asset profile. The namespace is reserved inside this character.
	return _pack_files(c, ProjectSettings.globalize_path(EXAMPLE), "_forge_defaults", mod_id, mod_dir, pck, written)


static func _pack_files(c: Dictionary, root: String, prefix: String, mod_id: String, mod_dir: String, pck: CFPckWriter, written: Array) -> Dictionary:
	for file in files_in(root):
		if prefix.is_empty() and file.begins_with("_forge_defaults/"):
			return {"ok": false, "error": "模型文件夹中的 _forge_defaults 为保留目录，请重命名。"}
		var res := resource_path(mod_id, String(c["id"]), prefix.path_join(file))
		var dest := mod_dir.path_join("assets").path_join(res.trim_prefix("res://"))
		if DirAccess.make_dir_recursive_absolute(dest.get_base_dir()) != OK:
			return {"ok": false, "error": "无法创建模型导出目录：" + dest}
		if file.get_extension().to_lower() in IMAGES:
			var img := Image.new()
			if img.load(root.path_join(file)) != OK:
				return {"ok": false, "error": "无法读取模型图片：" + file}
			if save_compressed_texture(img, dest) != OK:
				return {"ok": false, "error": "无法导出模型图片：" + file}
		else:
			var text := CFPaths.read_text(root.path_join(file))
			for ref in references(text):
				text = text.replace('"' + ref + '"', '"' + resource_path(mod_id, String(c["id"]), prefix.path_join(resolve_reference(file, ref))) + '"')
			# The ctex loader requires the concrete type when an ext_resource
			# supplies a type hint (ordinary imported images use Texture2D).
			for declaration in RegEx.create_from_string('\\[ext_resource[^\\]\\n]*path="[^"]+\\.ctex"[^\\]\\n]*\\]').search_all(text):
				var original := declaration.get_string()
				text = text.replace(original, original.replace('type="Texture2D"', 'type="CompressedTexture2D"'))
			# Source-project UIDs must not redirect resources into another project.
			text = RegEx.create_from_string(' uid="[^"]+"').sub(text, "", true)
			var saved := CFPaths.write_text(dest, text)
			if not saved:
				return {"ok": false, "error": "无法导出模型资源：" + file}
		if not pck.add_file(res, dest):
			return {"ok": false, "error": "无法打包模型资源：" + file}
		written.append(dest)
	return {"ok": true}


static func scene_errors(c: Dictionary, mod_id: String) -> Array:
	var v := normalized(c.get("visuals", {}))
	if v["mode"] != "custom":
		return []
	var errors: Array = []
	for field in PICTURES:
		if String(v[field]).is_empty():
			continue
		var path := resource_path(mod_id, String(c["id"]), String(v[field]))
		var texture := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		if not texture is CompressedTexture2D:
			errors.append("角色图片必须为游戏兼容的 CompressedTexture2D：" + path)
	for field in SCENES:
		if String(v[field]).is_empty():
			continue
		var path := resource_path(mod_id, String(c["id"]), String(v[field]))
		var scene := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
		if scene == null:
			errors.append("模型场景无法加载：" + path)
			continue
		var node := scene.instantiate()
		if not node is Node2D:
			errors.append("模型场景根节点必须为 Node2D：" + path)
		if field == "rest_scene":
			if not node.get_node_or_null("ControlRoot") is Control:
				errors.append("休息处模型缺少 ControlRoot（Control）。")
			if not node.get_node_or_null("%Hitbox") is Control:
				errors.append("休息处模型缺少场景唯一名称 Hitbox（Control）。")
		if field == "battle_scene":
			for slot in ["Visuals", "Bounds", "CenterPos", "IntentPos"]:
				var child := node.get_node_or_null(NodePath(slot))
				var valid := child is Control if slot == "Bounds" else (child is Marker2D if slot.ends_with("Pos") else child is Node2D)
				if not valid:
					errors.append("战斗模型缺少直接子节点或类型不正确：" + slot)
			if bool(v["animated"]):
				var player := node.find_child("AnimationPlayer", true, false) as AnimationPlayer
				var sprite := node.find_child("AnimatedSprite2D", true, false) as AnimatedSprite2D
				for key in ANIMATIONS:
					var anim := String(v[key])
					if anim.is_empty():
						continue
					if not (player != null and player.has_animation(anim)) and not (sprite != null and sprite.sprite_frames != null and sprite.sprite_frames.has_animation(anim)):
						errors.append("战斗模型缺少动画：%s（%s）" % [anim, key])
		# Animation method tracks can invoke code even in otherwise script-free scenes.
		for player in node.find_children("*", "AnimationPlayer", true, false):
			for name in player.get_animation_list():
				var animation: Animation = player.get_animation(name)
				for track in animation.get_track_count():
					if animation.track_get_type(track) == Animation.TYPE_METHOD:
						errors.append("模型动画不支持方法调用轨道：%s / %s" % [path, name])
		node.free()
	return errors


static func emit(c: Dictionary, mod_id: String) -> Array:
	var v := normalized(c.get("visuals", {}))
	if v["mode"] != "custom":
		return ["\tpublic override CreatureAnimator GenerateAnimator(MegaSprite controller) => Template.GenerateAnimator(controller);"]
	var lines: Array = []
	var properties := {"battle_scene": "CustomVisualsPath", "merchant_scene": "CustomMerchantAnimPath",
		"rest_scene": "CustomRestSiteAnimPath", "icon": "CustomIconTexturePath",
		"select_icon": "CustomCharacterSelectIconPath", "select_background": "CustomCharacterSelectBgPath"}
	for field in properties:
		var file := String(v[field])
		if file.is_empty():
			file = "_forge_defaults/" + String(example()[field])
		lines.append("\tpublic override string %s => %s;" % [properties[field], JSON.stringify(resource_path(mod_id, String(c["id"]), file))])
	lines.append("\tpublic override string CustomIconOutlineTexturePath => CustomIconTexturePath;")
	lines.append("\tpublic override string CustomIconPath => CustomIconTexturePath;")
	lines.append("\tpublic override string CustomMapMarkerPath => CustomIconTexturePath;")
	lines.append("\tpublic override string CustomCharacterSelectLockedIconPath => CustomCharacterSelectIconPath;")
	for property in ["CustomArmPointingTexturePath", "CustomArmRockTexturePath", "CustomArmPaperTexturePath", "CustomArmScissorsTexturePath"]:
		lines.append("\tpublic override string %s => CustomIconTexturePath;" % property)
	for pair in [["CustomEnergyCounterPath", "energy.tscn"], ["CustomTrailPath", "trail.tscn"], ["CustomCharacterSelectTransitionPath", "transition.tres"]]:
		lines.append("\tpublic override string %s => %s;" % [pair[0], JSON.stringify(resource_path(mod_id, String(c["id"]), "_forge_defaults/" + pair[1]))])
	for property in ["CustomCharacterSelectSfx", "CustomCharacterTransitionSfx"]:
		lines.append('\tpublic override string %s => "event:/sfx/ui/clicks/ui_click";' % property)
	for property in ["CustomAttackSfx", "CustomCastSfx", "CustomDeathSfx"]:
		lines.append('\tpublic override string %s => "event:/sfx/ui/cards/card_movement_B_into_discard";' % property)
	lines.append("\tprotected override NCreatureVisuals? TryCreateCreatureVisuals() => RitsuGodotNodeFactories.CreateFromScenePath<NCreatureVisuals>(CustomVisualsPath);")
	lines.append("\tpublic override float AttackAnimDelay => %sf;" % str(float(v["attack_delay"])))
	lines.append("\tpublic override float CastAnimDelay => %sf;" % str(float(v["cast_delay"])))
	if bool(v["animated"]):
		var args: Array[String] = []
		for pair in [["idle", "idleName"], ["dead", "deadName"], ["hit", "hitName"], ["attack", "attackName"], ["cast", "castName"]]:
			args.append("%s: %s" % [pair[1], "null" if String(v[pair[0]]).is_empty() else JSON.stringify(String(v[pair[0]]))])
		lines.append("\tprotected override ModAnimStateMachine? SetupCustomCombatAnimationStateMachine(Node visualsRoot, CharacterModel character)")
		lines.append("\t{")
		lines.append("\t\tvar machine = ModAnimStateMachines.StandardCue(visualsRoot, character, %s);" % ", ".join(args))
		lines.append("\t\tif (machine.Current != null) machine.AddAnyState(\"Revive\", machine.Current);")
		lines.append("\t\treturn machine;")
		lines.append("\t}")
	return lines
