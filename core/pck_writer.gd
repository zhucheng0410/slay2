@tool
class_name CFPckWriter
extends RefCounted

## Writes Godot 4 `.pck` resource packs from GDScript, with no editor involved.
##
## This is the same on-disk layout the game itself produces, verified by
## reloading a produced pack with `ProjectSettings.load_resource_pack()` in a
## headless Godot run (see `tools/pck_test.gd`).
##
## Header (128 bytes):
##   u32  magic          = 0x43504447 ("GDPC")
##   u32  version        = 3
##   u32  ver_major / ver_minor / ver_patch   (engine version, e.g. 4 / 5 / 1)
##   u32  pack_flags     = 2   (PACK_REL_FILEBASE: entry offsets are relative
##                              to `file_base`)
##   u64  file_base      = 128
##   u64  dir_offset     = byte offset of the directory
##   ...  zero padding up to 128 bytes
##
## Directory at `dir_offset`:
##   u32  file_count
##   per file:
##     u32   path_len  (byte length of the path INCLUDING its 4-byte padding)
##     u8[]  path      (UTF-8, NUL padded)
##     u64   offset    (relative to file_base)
##     u64   size
##     u8[16] md5
##     u32   flags     (0 for unencrypted entries)
##   u32  0            (trailer)

const MAGIC := 0x43504447  # "GDPC"
const PACK_FORMAT_VERSION := 3
const PACK_FLAGS_REL_FILEBASE := 2
const HEADER_SIZE := 128

var _entries: Array = []
var _res_paths: Dictionary = {}


## Queue a file that lives on disk. `res_path` is relative to the pack root and
## uses forward slashes, e.g. "MyMod/localization/zhs/cards.json".
func add_file(res_path: String, disk_path: String) -> bool:
	if not FileAccess.file_exists(disk_path):
		return false
	var f := FileAccess.open(disk_path, FileAccess.READ)
	if f == null:
		return false
	var data := f.get_buffer(f.get_length())
	f.close()
	add_bytes(res_path, data)
	return true


func add_text(res_path: String, text: String) -> void:
	add_bytes(res_path, text.to_utf8_buffer())


func add_bytes(res_path: String, data: PackedByteArray) -> void:
	var clean := _normalise(res_path)
	if clean.is_empty() or _res_paths.has(clean):
		return
	_res_paths[clean] = true
	_entries.append({"path": clean, "data": data})


func clear() -> void:
	_entries.clear()
	_res_paths.clear()


func file_count() -> int:
	return _entries.size()


func paths() -> Array:
	var out: Array = []
	for e in _entries:
		out.append(String(e["path"]))
	return out


## Serialise the pack. Returns { ok, path, size, files, dir_offset, error }.
func write_pck(out_path: String, engine_version: String = "4.5.1") -> Dictionary:
	if _entries.is_empty():
		return {"ok": false, "error": "没有要写入的文件"}

	# Deterministic ordering keeps exports byte-reproducible.
	_entries.sort_custom(func(a, b): return String(a["path"]) < String(b["path"]))

	var versions := _parse_version(engine_version)

	var offsets: Array = []
	var cursor := 0
	for e in _entries:
		offsets.append(cursor)
		cursor += (e["data"] as PackedByteArray).size()
	var payload_size := cursor
	var dir_offset := HEADER_SIZE + payload_size
	var file_base := HEADER_SIZE

	var dir := _build_directory(offsets)

	var out := FileAccess.open(out_path, FileAccess.WRITE)
	if out == null:
		return {"ok": false, "error": "无法写入 %s（错误码 %d）" % [out_path, FileAccess.get_open_error()]}

	out.store_32(MAGIC)
	out.store_32(PACK_FORMAT_VERSION)
	out.store_32(versions[0])
	out.store_32(versions[1])
	out.store_32(versions[2])
	out.store_32(PACK_FLAGS_REL_FILEBASE)
	out.store_64(file_base)
	out.store_64(dir_offset)
	# 6 * u32 + 2 * u64 == 40 bytes written; pad the rest of the header.
	var written := 6 * 4 + 8 + 8
	for i in range(HEADER_SIZE - written):
		out.store_8(0)

	for e in _entries:
		out.store_buffer(e["data"])

	out.store_buffer(dir)

	var total := out.get_length()
	out.close()
	return {
		"ok": true,
		"path": out_path,
		"size": total,
		"files": _entries.size(),
		"dir_offset": dir_offset,
		"payload_size": payload_size,
		"error": "",
	}


func _build_directory(offsets: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_u32(_entries.size())
	for i in _entries.size():
		var e: Dictionary = _entries[i]
		var path_bytes := String(e["path"]).to_utf8_buffer()
		var pad := (4 - (path_bytes.size() % 4)) % 4
		buf.put_u32(path_bytes.size() + pad)
		buf.put_data(path_bytes)
		for p in pad:
			buf.put_u8(0)
		buf.put_u64(offsets[i])
		var data: PackedByteArray = e["data"]
		buf.put_u64(data.size())
		buf.put_data(_md5(data))
		buf.put_u32(0)
	buf.put_u32(0)  # trailer
	return buf.data_array


static func _md5(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(data)
	return ctx.finish()


static func _parse_version(version: String) -> Array:
	var parts := version.split(".", false)
	var out := [0, 0, 0]
	for i in mini(3, parts.size()):
		out[i] = int(parts[i])
	return out


static func _normalise(res_path: String) -> String:
	var p := res_path.replace("\\", "/").strip_edges()
	p = p.trim_prefix("res://").trim_prefix("/")
	while p.contains("//"):
		p = p.replace("//", "/")
	if p.contains("..") or p.is_empty():
		return ""
	return p


# ---------------------------------------------------------------------------
# Reader (used by the self-test to verify what we wrote)
# ---------------------------------------------------------------------------

## Parse a pack written by [method write_pck].
## Returns { ok, error, files: [{path, offset, size, md5}], dir_offset }.
static func read_pck(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "文件不存在", "files": []}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "无法读取", "files": []}
	if f.get_length() < HEADER_SIZE:
		f.close()
		return {"ok": false, "error": "文件小于头部长度", "files": []}
	var magic := f.get_32()
	if magic != MAGIC:
		f.close()
		return {"ok": false, "error": "magic 不匹配：0x%08X" % magic, "files": []}
	var fmt := f.get_32()
	var major := f.get_32()
	var minor := f.get_32()
	var patch := f.get_32()
	var flags := f.get_32()
	var file_base := f.get_64()
	var dir_offset := f.get_64()
	f.seek(dir_offset)
	var count := f.get_32()
	var files: Array = []
	for i in count:
		var path_len := f.get_32()
		var raw := f.get_buffer(path_len)
		var name := ""
		for b in raw:
			if b == 0:
				break
			name += char(b)
		var offset := f.get_64()
		var size := f.get_64()
		var md5 := f.get_buffer(16)
		var entry_flags := f.get_32()
		files.append({
			"path": name, "offset": offset, "size": size,
			"md5": md5.hex_encode(), "flags": entry_flags,
		})
	f.close()
	return {
		"ok": true,
		"error": "",
		"format": fmt,
		"engine": "%d.%d.%d" % [major, minor, patch],
		"flags": flags,
		"file_base": file_base,
		"dir_offset": dir_offset,
		"files": files,
	}
