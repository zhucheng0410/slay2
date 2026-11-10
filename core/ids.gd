@tool
class_name CFIds
extends RefCounted

## Reproduces the host game's identifier rules exactly, so generated class
## names, localization keys and asset filenames line up with what the game
## expects.
##
## Mirrors `MegaCrit.Sts2.Core.Helpers.StringHelper`:
##
##   CamelCaseRegex   = ([A-Za-z0-9]|\G(?!^))([A-Z])  -> "$1_$2"
##   WhitespaceRegex  = \s+                            -> "_"
##   SpecialCharRegex = [^A-Z0-9_]                     -> ""
##
##   SnakeCase(t) = CamelCaseReplace(t).ToLowerInvariant()
##   Slugify(t)   = SpecialCharReplace(WhitespaceReplace(CamelCaseReplace(t).ToUpper(), "_"), "")
##
## `ModelId.Entry` is `Slugify(ClassName)`. Localization keys are
## `<Entry>.<field>`; asset filenames use `Entry.to_lower()`.


static func camel_split(text: String) -> String:
	var s := text.strip_edges()
	var n := s.length()
	var out := ""
	var i := 0
	var scan_start := 0
	while i < n:
		if i + 1 < n and _is_alnum(s[i]) and _is_upper(s[i + 1]):
			out += s[i] + "_" + s[i + 1]
			i += 2
			scan_start = i
			continue
		if i == scan_start and i > 0 and _is_upper(s[i]):
			out += "_" + s[i]
			i += 1
			scan_start = i
			continue
		out += s[i]
		i += 1
	return out


## "AllForOne" -> "all_for_one"
static func snake_case(text: String) -> String:
	return camel_split(text).to_lower()


## "AllForOne" -> "ALL_FOR_ONE"
static func slugify(text: String) -> String:
	var t := camel_split(text).to_upper()
	t = RegEx.create_from_string("\\s+").sub(t, "_", true)
	t = RegEx.create_from_string("[^A-Z0-9_]").sub(t, "", true)
	return t


## "ALL_FOR_ONE" -> "AllForOne"
static func unslugify(text: String) -> String:
	var t := text.strip_edges().to_lower()
	var out := ""
	var upper_next := false
	for i in t.length():
		var c := t[i]
		if c == "_":
			upper_next = true
			continue
		out += c.to_upper() if upper_next else c
		upper_next = false
	if out.is_empty():
		return out
	return out[0].to_upper() + out.substr(1)


static func is_valid_cs_identifier(text: String) -> bool:
	if text.is_empty() or text.length() > 64:
		return false
	if RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$").search(text) == null:
		return false
	if _CS_KEYWORDS.has(text):
		return false
	return true


const _CS_KEYWORDS := {
	"abstract": true, "as": true, "base": true, "bool": true, "break": true,
	"byte": true, "case": true, "catch": true, "char": true, "checked": true,
	"class": true, "const": true, "continue": true, "decimal": true,
	"default": true, "delegate": true, "do": true, "double": true, "else": true,
	"enum": true, "event": true, "explicit": true, "extern": true, "false": true,
	"finally": true, "fixed": true, "float": true, "for": true, "foreach": true,
	"goto": true, "if": true, "implicit": true, "in": true, "int": true,
	"interface": true, "internal": true, "is": true, "lock": true, "long": true,
	"namespace": true, "new": true, "null": true, "object": true,
	"operator": true, "out": true, "override": true, "params": true,
	"private": true, "protected": true, "public": true, "readonly": true,
	"ref": true, "return": true, "sbyte": true, "sealed": true, "short": true,
	"sizeof": true, "stackalloc": true, "static": true, "string": true,
	"struct": true, "switch": true, "this": true, "throw": true, "true": true,
	"try": true, "typeof": true, "uint": true, "ulong": true, "unchecked": true,
	"unsafe": true, "ushort": true, "using": true, "virtual": true, "void": true,
	"volatile": true, "while": true,
}


## Localization key for a model entry, e.g. ("ALL_FOR_ONE", "title").
static func loc_key(entry: String, field: String) -> String:
	return "%s.%s" % [entry, field]


## Slug of a C# type name, with the game's `_MODEL` suffix rule applied.
static func category_slug(type_name: String) -> String:
	var t := slugify(type_name)
	if t.ends_with("_MODEL"):
		t = t.substr(0, t.length() - 6)
	return t


## "my_card" / "MyCard" / "my card" -> "my-card" (matches the sample mod style).
static func kebab(text: String) -> String:
	return snake_case(text).replace("_", "-")


static func _is_alnum(c: String) -> bool:
	if c.is_empty():
		return false
	var u := c.unicode_at(0)
	return (u >= 48 and u <= 57) or (u >= 65 and u <= 90) or (u >= 97 and u <= 122)


static func _is_upper(c: String) -> bool:
	if c.is_empty():
		return false
	var u := c.unicode_at(0)
	return u >= 65 and u <= 90
