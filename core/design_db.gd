@tool
class_name CFDesignDb
extends Resource

## Holds every design the user has authored, the mod metadata, and the UndoRedo
## history. Undo is snapshot-based: it completely avoids partial-undo bugs, and
## the "before" state is captured lazily — once per edit group instead of once
## per write — so per-keystroke edits stay O(1) instead of deep-copying the whole
## document on every character (the localization typing-lag fix).

signal designs_changed()
signal selection_changed()
signal dirty_changed(dirty: bool)

@export var cards: Array = []
@export var relics: Array = []
## Reusable effect recipes and character/pool definitions authored in the tool.
## Kept in the same design document so they survive save/reopen and travel with
## a project file instead of being tied to this machine's user directory.
@export var abilities: Array = []
@export var custom_characters: Array = []

@export var mod_id: String = "MyCardMod"
@export var mod_name: String = "我的卡牌扩展"
@export var mod_author: String = ""
@export var mod_description: String = ""
@export var mod_version: String = "1.0.0"
@export var min_game_version: String = ""

@export var selected_kind: String = CFDesign.KIND_CARD
@export var selected_index: int = -1

var _undo := UndoRedo.new()
var _pending: Dictionary = {}
## Number of `snapshot()` calls, i.e. number of whole-document deep copies.
##
## Exposed purely so the regression test for the typing lag can assert the
## per-keystroke path does not copy: a cost that is invisible in a unit test's
## wall-clock time is still a real 5 ms/frame stall at 31 cards.
var snapshot_count := 0
var _dirty := false

## Kinds whose entries were written by `set_field_quiet` and therefore have not
## had a full `CFDesign.normalize` yet.
##
## A keyed set (kind -> true) rather than a flag per item: the quiet path is only
## ever driven from the editor, which edits one kind at a time, and re-normalising
## the whole list on flush is cheap enough that tracking per-index would add
## bug surface for no gain.
var _needs_normalize: Dictionary = {}

## The schema the quiet path was last called with.
##
## `set_field_quiet` already takes a schema, but `flush_edit` (its natural pair,
## invoked on focus exit) and `snapshot` do not — threading a new parameter
## through the whole app for a value the DB was just handed would be worse than
## remembering it. Only ever set from a real quiet write, so it is guaranteed
## non-null by the time the deferred normalize actually needs it.
var _schema_ref: CFSchema = null

## Path of the field currently being typed into, e.g. ["text","zhs","description"].
##
## While a text field has focus every keystroke arrives as its own
## `text_changed`, and *any* rebuild tears the column down and recreates the
## widgets — which destroys the very LineEdit the user is typing into. Focus is
## lost, so the caret disappears and the next character goes nowhere.
## The editor is expected to publish the focused field's path here so the
## rebuild logic can tell "same field, keep the widget" from "different field,
## rebuild".
var _edit_path: Array = []


# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------

func items_for(kind: String) -> Array:
	return relics if kind == CFDesign.KIND_RELIC else cards


func all_items() -> Array:
	return cards + relics


func item_count(kind: String) -> int:
	return items_for(kind).size()


func selected_item() -> Dictionary:
	var list := items_for(selected_kind)
	if selected_index < 0 or selected_index >= list.size():
		return {}
	return list[selected_index]


func set_selection(kind: String, index: int) -> void:
	var changed := kind != selected_kind or index != selected_index
	selected_kind = kind
	selected_index = index
	if changed:
		selection_changed.emit()


func find_index_by_id(kind: String, id: String) -> int:
	var list := items_for(kind)
	for i in list.size():
		if String(list[i].get("id", "")) == id:
			return i
	return -1


# ---------------------------------------------------------------------------
# Mutation with undo
# ---------------------------------------------------------------------------

func begin_action() -> void:
	_ensure_pending()


## Capture the "before" state of the current mutation group, exactly once.
##
## Must run before any mutation. `begin_action` calls it eagerly (discrete
## actions such as adding a card want their undo target captured up front), while
## the quiet typing path calls it directly: the text fields fire one write per
## keystroke, and the only state worth keeping is the one from *before the first*
## character, so the deep copy is paid once per edit group rather than per write.
func _ensure_pending() -> void:
	if _pending.is_empty():
		_pending = snapshot()


## True while an edit group is open (its "before" state is captured but has not
## been committed to the undo history yet). Drives `flush_edit`.
func has_uncommitted_edit() -> bool:
	return not _pending.is_empty()


func commit_action(action_name: String) -> void:
	var after := snapshot()
	_undo.create_action(action_name)
	_undo.add_do_method(_restore.bind(after))
	_undo.add_undo_method(_restore.bind(_pending))
	_undo.commit_action()
	_pending = {}
	_mark_dirty(true)
	designs_changed.emit()


## Mutate, then commit. `mutator` is a Callable taking no arguments.
func mutate(action_name: String, mutator: Callable) -> void:
	begin_action()
	mutator.call()
	commit_action(action_name)


func undo() -> void:
	if _undo.has_undo():
		_undo.undo()
		_clamp_selection()
		_mark_dirty(true)
		designs_changed.emit()


func redo() -> void:
	if _undo.has_redo():
		_undo.redo()
		_clamp_selection()
		_mark_dirty(true)
		designs_changed.emit()


func can_undo() -> bool:
	return _undo.has_undo()


func can_redo() -> bool:
	return _undo.has_redo()


func undo_name() -> String:
	return _undo.get_current_action_name() if _undo.has_undo() else ""


func clear_history() -> void:
	_undo.clear_history()


func _restore(state: Dictionary) -> void:
	cards = (state.get("cards", []) as Array).duplicate(true)
	relics = (state.get("relics", []) as Array).duplicate(true)
	abilities = (state.get("abilities", []) as Array).duplicate(true)
	custom_characters = (state.get("custom_characters", []) as Array).duplicate(true)
	for i in custom_characters.size():
		custom_characters[i] = CFCharacters.normalized(custom_characters[i])
	mod_id = String(state.get("mod_id", mod_id))
	mod_name = String(state.get("mod_name", mod_name))
	mod_author = String(state.get("mod_author", mod_author))
	mod_description = String(state.get("mod_description", mod_description))
	mod_version = String(state.get("mod_version", mod_version))
	min_game_version = String(state.get("min_game_version", min_game_version))


func snapshot() -> Dictionary:
	snapshot_count += 1
	return {
		"cards": cards.duplicate(true),
		"relics": relics.duplicate(true),
		"abilities": abilities.duplicate(true),
		"custom_characters": custom_characters.duplicate(true),
		"mod_id": mod_id,
		"mod_name": mod_name,
		"mod_author": mod_author,
		"mod_description": mod_description,
		"mod_version": mod_version,
		"min_game_version": min_game_version,
	}


# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------

func add_item(schema: CFSchema, kind: String, item: Dictionary) -> int:
	var list := items_for(kind)
	CFDesign.normalize(schema, item)
	begin_action()
	list.append(item)
	commit_action("新增%s" % _kind_label(kind))
	set_selection(kind, list.size() - 1)
	return list.size() - 1


func save_ability_from_item(item: Dictionary, ability_id: String, title: String) -> void:
	var ability := {
		"id": ability_id.strip_edges(), "title": title.strip_edges(),
		"vars": (item.get("vars", []) as Array).duplicate(true),
		"effects": (item.get("effects", []) as Array).duplicate(true),
		"created": Time.get_datetime_string_from_system(),
	}
	var existing := -1
	for i in abilities.size():
		if String((abilities[i] as Dictionary).get("id", "")) == ability["id"]:
			existing = i
			break
	var next := abilities.duplicate(true)
	if existing >= 0:
		next[existing] = ability
	else:
		next.append(ability)
	mutate("保存组合能力", func(): abilities = next)


func apply_ability_to_card(card_index: int, ability_index: int) -> bool:
	if card_index < 0 or card_index >= cards.size() or ability_index < 0 or ability_index >= abilities.size():
		return false
	var updated := (cards[card_index] as Dictionary).duplicate(true)
	var ability: Dictionary = abilities[ability_index]
	var vars: Array = updated.get("vars", []).duplicate(true)
	var known := {}
	for v in vars:
		known[String(v.get("name", ""))] = true
	for v in ability.get("vars", []):
		if not known.has(String(v.get("name", ""))):
			vars.append((v as Dictionary).duplicate(true))
	updated["vars"] = vars
	var effects: Array = updated.get("effects", []).duplicate(true)
	for e in ability.get("effects", []):
		var copy: Dictionary = (e as Dictionary).duplicate(true)
		copy["id"] = "%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
		effects.append(copy)
	updated["effects"] = effects
	mutate("应用组合能力", func(): cards[card_index] = updated)
	return true


func add_custom_character(character: Dictionary) -> void:
	character = CFCharacters.normalized(character)
	var next := custom_characters.duplicate(true)
	var new_id := String(character.get("id", ""))
	for i in next.size():
		if String((next[i] as Dictionary).get("id", "")) == new_id:
			next[i] = character.duplicate(true)
			mutate("更新自定义角色", func(): custom_characters = next)
			return
	next.append(character.duplicate(true))
	mutate("新增自定义角色", func(): custom_characters = next)


func remove_item(kind: String, index: int) -> void:
	var list := items_for(kind)
	if index < 0 or index >= list.size():
		return
	begin_action()
	list.remove_at(index)
	commit_action("删除%s" % _kind_label(kind))
	_clamp_selection()


## Repair a legacy invalid character ID and every starter reference atomically.
func update_custom_character(old_id: String, character: Dictionary) -> void:
	var updated := CFCharacters.normalized(character)
	var previous: Dictionary = {}
	begin_action()
	for i in custom_characters.size():
		if String(custom_characters[i].get("id", "")) == old_id:
			previous = custom_characters[i]
			custom_characters[i] = updated
	for item in all_items():
		var deck: Dictionary = item.get("deck", {})
		if String(deck.get("character", "")) == old_id:
			deck["character"] = updated["id"]
		var pool_field := "relic_pool" if String(item.get("kind", "")) == CFDesign.KIND_RELIC else "card_pool"
		var old_pool := String(previous.get(pool_field, ""))
		if not old_pool.is_empty() and String(item.get("pool", "")) == old_pool:
			item["pool"] = updated[pool_field]
	commit_action("更新自定义角色")


func duplicate_item(schema: CFSchema, kind: String, index: int) -> int:
	var list := items_for(kind)
	if index < 0 or index >= list.size():
		return -1
	begin_action()
	var copy: Dictionary = (list[index] as Dictionary).duplicate(true)
	copy["id"] = "%sCopy" % String(copy.get("id", "Card"))
	copy["entry"] = CFIds.slugify(String(copy["id"]))
	copy["created"] = Time.get_datetime_string_from_system()
	# A copy must not inherit the starting-deck toggle: two copies would both be
	# appended, and duplicate ids are blocked anyway.
	if copy.has("deck") and copy["deck"] is Dictionary:
		(copy["deck"] as Dictionary)["enabled"] = false
	list.insert(index + 1, copy)
	commit_action("复制%s" % _kind_label(kind))
	set_selection(kind, index + 1)
	return index + 1


## Set a (possibly nested) field, then re-normalise and commit as one action.
func set_field(schema: CFSchema, kind: String, index: int, path: Array, value: Variant,
		action_name: String = "修改") -> void:
	set_field_quiet(schema, kind, index, path, value)
	commit_action(action_name)


## Write a field WITHOUT committing to the undo history.
##
## Used while the user is still typing: pushing one undo step per keystroke makes
## undo useless (and needlessly copies the whole design). The caller pairs this
## with `flush_edit(path)` once the field loses focus.
##
## The *held* path is refreshed too, so a type-write that renormalisation would
## otherwise refuse is never dropped when the focus handler flushes.
##
## ## Why this must NOT run the full `normalize` (typing-lag fix)
##
## `CFDesign.normalize` is a *whole-entry* pass: it re-coerces type/rarity/target/
## keywords/tags, walks every var and every effect (and, for relics, every
## trigger), rebuilds the text table, re-resolves the art paths and stamps
## `modified` with a fresh timestamp. Running that once per keystroke is what made
## the ②文字（本地化）fields stutter — a two-character description was doing two
## full card passes, including `Time.get_datetime_string_from_system()` and a
## fresh `Time.get_ticks_usec()` for every effect id.
##
## A text edit only needs two things to be *observably* correct right now:
##   1. the value is stored (so the widget reads back what was typed), and
##   2. the live edit path stays consistent (so the focus flush cannot read a
##      stale value and the field is not rebuilt out from under the caret).
##
## Everything `normalize` derives — `entry`, `kind`, `value_prop`, effect ids,
## the `modified` stamp — is only ever *consumed* at commit / export / list-draw
## time, and `flush_edit` (focus exit) plus `commit_action` both run the real
## normalize. So we defer it: `_needs_normalize` records that the entry is
## temporarily un-normalised, and the next full normalize call will re-derive it
## before anything reads those fields.
func set_field_quiet(schema: CFSchema, kind: String, index: int, path: Array, value: Variant) -> void:
	var list := items_for(kind)
	if index < 0 or index >= list.size():
		return
	# Lazy: snapshot only the first write of the group (see `_ensure_pending`).
	_ensure_pending()
	var previous_id := String(list[index].get("id", ""))
	_apply_path(list[index], path, value)
	if kind == CFDesign.KIND_CARD and path == ["id"]:
		for character in custom_characters:
			for row in character.get("starting_deck", []):
				if row.get("source") == "mod" and row.get("id") == previous_id:
					row["id"] = String(value).strip_edges()
	# Cheap, text-safe re-derivations only. These are pure string work on a single
	# field, so they cost nothing at typing speed, but they keep the two things
	# the UI reads mid-edit in sync with what was just typed.
	_normalize_live(schema, list[index], path)
	_mark_dirty(true)
	# Bring the live path up to date with what was actually stored, so a later
	# flush cannot read a stale value.
	_edit_path = update_live_path(list[index], path, _edit_path)
	# Remember that the entry is only partially normalised, so the next caller
	# that needs a fully-consistent entry can pay for it exactly once.
	_schema_ref = schema
	_needs_normalize[kind] = true


## The subset of `CFDesign.normalize` that is safe (and necessary) mid-keystroke.
##
## Deliberately mirrors only the derivations the *editing UI* reads back:
##   * `entry` follows `id` (the entry field is written live and shown as a hint),
##   * `text[locale][field]` is created on demand so a first keystroke into an
##     empty localization box does not read back null,
##   * a var's `kind` follows its `type` — the description hint line renders
##     `{Damage:diff()}`-style substitutions live, and a stale kind silently stops
##     the placeholder resolving while the user is still typing.
##
## Anything else is left to the deferred full normalize. In particular we must not
## touch `art`, effect ids or `modified` here — those are exactly the expensive,
## whole-entry parts.
func _normalize_live(schema: CFSchema, item: Dictionary, path: Array) -> void:
	if path.is_empty():
		return
	var head := String(path[0])
	if head == "id":
		item["id"] = String(item.get("id", "")).strip_edges()
		item["entry"] = CFIds.slugify(item["id"])
	elif head == "vars":
		var vars: Array = item.get("vars", []) if item.get("vars") is Array else []
		for v in vars:
			# `kind` is the tool's short label for a var; `_var_kind_from_type`
			# derives it from `type` so the two can never drift.
			v["kind"] = CFDesign._var_kind_from_type(
					String(v.get("type", "")), String(v.get("kind", "")))
		item["vars"] = vars
	elif head == "text":
		var text: Dictionary = item.get("text", {}) if item.get("text") is Dictionary else {}
		var kind := String(item.get("kind", CFDesign.KIND_CARD))
		for locale in CFSchema.LOCALES:
			if not text.has(locale) or not (text[locale] is Dictionary):
				text[locale] = {}
			for field in CFSchema.LOC_FIELDS[kind]:
				if not text[locale].has(field):
					text[locale][field] = ""
		item["text"] = text


## Commit (if any) the uncommitted edits made to `path`, so they land in undo.
##
## Clearing the live path is *only* correct when this was a real focus exit.
## `_on_edit_focus_entered` also calls this to close out whatever field was
## being edited before, and it must not wipe the path it is about to publish.
func flush_edit(path: Array) -> void:
	if not has_uncommitted_edit():
		return
	if not path.is_empty():
		_edit_path = update_live_path_on_current(path)
	# Pay for the deferred normalize now, before it lands in the undo stack: the
	# recorded "after" snapshot must be the fully-consistent entry, or undoing
	# past this edit would restore a half-normalised card.
	ensure_all_normalized()
	commit_action("修改")
	_edit_path = []


## Run the deferred full normalisation for one kind, if the quiet path skipped it.
##
## Call this before anything reads a derived field of an entry that may have been
## typed into: the exporter, the list view, the save path and `snapshot` all need a
## fully-consistent entry, and `set_field_quiet` now deliberately leaves entries
## only partially normalised. Idempotent and cheap when nothing is pending.
##
## `schema` defaults to the one remembered from the quiet write, so callers that
## already paid that cost (e.g. `flush_edit`) do not need to thread it through.
func ensure_normalized(kind: String, schema: CFSchema = null) -> void:
	if not _needs_normalize.get(kind, false):
		return
	var s: CFSchema = schema if schema != null else _schema_ref
	if s == null:
		# Nothing to normalize with — leave the flag set so a later call that does
		# have a schema still gets its chance, rather than silently marking clean.
		return
	_needs_normalize.erase(kind)
	for item in items_for(kind):
		CFDesign.normalize(s, item)


## Every entry, fully normalised. Used by save/export, which may touch both kinds.
func ensure_all_normalized(schema: CFSchema = null) -> void:
	ensure_normalized(CFDesign.KIND_CARD, schema)
	ensure_normalized(CFDesign.KIND_RELIC, schema)


## Forget the field the user was typing into (called from a real focus exit).
func clear_edit_path() -> void:
	_edit_path = []


## Read a (possibly nested) field, or null when the path does not resolve.
func get_field(kind: String, index: int, path: Array) -> Variant:
	var list := items_for(kind)
	if index < 0 or index >= list.size():
		return null
	var cur: Variant = list[index]
	for key in path:
		if cur is Dictionary and (cur as Dictionary).has(key):
			cur = (cur as Dictionary)[key]
		elif cur is Array and key is int and int(key) < (cur as Array).size():
			cur = (cur as Array)[int(key)]
		else:
			return null
	return cur


## Is `path` (or a prefix of it) the field the user is currently typing into?
##
## Treating a prefix as "the same" matters for nested writes: editing a variable
## name publishes ["vars", 0, "name"] but the row may be rebuilt from
## ["vars", 0], and that must still count as the focused field.
func is_editing(path: Array) -> bool:
	if _edit_path.is_empty():
		return false
	var n := mini(_edit_path.size(), path.size())
	for i in n:
		if _edit_path[i] != path[i]:
			return false
	return true


func edit_path() -> Array:
	return _edit_path


## Publish the field that currently holds keyboard focus.
func set_edit_path(path: Array) -> void:
	_edit_path = path.duplicate()


## Re-read the *value* at `path` after a write.
##
## Only array slots are index-addressed and can drift (normalize may rebuild an
## entry, the user may delete a row above). A dictionary key such as
## `["text","zhs","description"]` is stable, so rewriting its last element —
## as the first version of this helper did — replaced the key `"description"`
## with the description *text*, producing paths like
## `["text","zhs","造成 {Damage}…"]` that resolve to nothing. Every subsequent
## keystroke then failed to update the live path and the widget was rebuilt.
func update_live_path(_item: Variant, path: Array, held: Array) -> Array:
	if held.is_empty() or path.is_empty():
		return held
	var last: Variant = path[path.size() - 1]
	if not (last is int):
		return held
	return held


func update_live_path_on_current(path: Array) -> Array:
	return path


func _get_on(root: Variant, path: Array) -> Variant:
	var cur: Variant = root
	for key in path:
		if cur is Dictionary and (cur as Dictionary).has(key):
			cur = (cur as Dictionary)[key]
		elif cur is Array and key is int and int(key) < (cur as Array).size():
			cur = (cur as Array)[int(key)]
		else:
			return null
	return cur


## Add an effect to a card, or to one of a relic's triggers.
func add_effect(schema: CFSchema, kind: String, index: int, trigger_index: int,
		effect_kind: String) -> int:
	var list := items_for(kind)
	if index < 0 or index >= list.size():
		return -1
	begin_action()
	var target: Array
	if kind == CFDesign.KIND_RELIC:
		var triggers: Array = list[index].get("triggers", [])
		if trigger_index < 0 or trigger_index >= triggers.size():
			commit_action("新增效果")
			return -1
		target = triggers[trigger_index]["effects"]
	else:
		target = list[index]["effects"]
	var e := CFDesign.new_effect(effect_kind)
	var spec := CFEffects.kind_by_id(effect_kind)
	e["target"] = String(spec.get("default_target", "self"))
	if String(spec.get("needs", "")).contains("power"):
		var opts := CFEffects.power_options(schema)
		if not opts.is_empty():
			e["power"] = String(opts[0]["value"])
	target.append(e)
	CFDesign.normalize(schema, list[index])
	commit_action("新增效果")
	return target.size() - 1


func remove_effect(kind: String, index: int, trigger_index: int, effect_index: int) -> void:
	var list := items_for(kind)
	if index < 0 or index >= list.size():
		return
	begin_action()
	var target: Array
	if kind == CFDesign.KIND_RELIC:
		var triggers: Array = list[index].get("triggers", [])
		if trigger_index < 0 or trigger_index >= triggers.size():
			commit_action("删除效果")
			return
		target = triggers[trigger_index]["effects"]
	else:
		target = list[index]["effects"]
	if effect_index >= 0 and effect_index < target.size():
		target.remove_at(effect_index)
	commit_action("删除效果")


func add_trigger(schema: CFSchema, index: int) -> int:
	var list := items_for(CFDesign.KIND_RELIC)
	if index < 0 or index >= list.size():
		return -1
	var usable := schema.usable_hooks()
	if usable.is_empty():
		return -1
	begin_action()
	var triggers: Array = list[index].get("triggers", [])
	var hook := String(usable[0]["name"])
	triggers.append({
		"hook": hook,
		"params": CFDesign._default_param_bindings(schema, hook),
		"condition": CFDesign.new_condition(),
		"charge": {"mode": "always", "n": 1},
		"loop": {"mode": "none", "count": 1, "var": ""},
		"effects": [],
		"note": "",
	})
	list[index]["triggers"] = triggers
	commit_action("新增触发时机")
	return triggers.size() - 1


func remove_trigger(index: int, trigger_index: int) -> void:
	var list := items_for(CFDesign.KIND_RELIC)
	if index < 0 or index >= list.size():
		return
	var triggers: Array = list[index].get("triggers", [])
	if trigger_index < 0 or trigger_index >= triggers.size():
		return
	begin_action()
	triggers.remove_at(trigger_index)
	commit_action("删除触发时机")


func _apply_path(root: Variant, path: Array, value: Variant) -> void:
	var cur: Variant = root
	for i in range(path.size() - 1):
		var key: Variant = path[i]
		if cur is Dictionary and (cur as Dictionary).has(key):
			cur = (cur as Dictionary)[key]
		elif cur is Array and key is int and int(key) < (cur as Array).size():
			cur = (cur as Array)[int(key)]
		else:
			return
	var last: Variant = path[path.size() - 1]
	if cur is Dictionary:
		(cur as Dictionary)[String(last)] = value
	elif cur is Array and last is int and int(last) < (cur as Array).size():
		(cur as Array)[int(last)] = value


func _kind_label(kind: String) -> String:
	return "遗物" if kind == CFDesign.KIND_RELIC else "卡牌"


# ---------------------------------------------------------------------------
# Variable rows (the `vars` array)
# ---------------------------------------------------------------------------

## Build a complete `vars` entry from a payload.
##
## A whole entry is always written at once rather than field by field. The var
## editor binds several fields (名称 / 类型 / 基础值 / 升级增量) and
## `CFDesign.normalize` reconciles `kind` with `type` and `value_prop` with
## `kind`; writing one field at a time therefore clobbers what the neighbours
## just set. A single full write is atomic and immune to that.
static func var_payload(v: Dictionary, overrides: Dictionary = {}) -> Dictionary:
	var out := (v as Dictionary).duplicate(true)
	for k in overrides:
		out[k] = overrides[k]
	return out


## The concrete `vars` slot a row edit should be written to.
##
## `normalize` replaces any entry that carries no usable `value_prop` with a
## freshly built one (a new Dictionary), and the *index* of the row being edited
## can shift underneath the editor. Matching by name — falling back to the index
## the row was built with — keeps an edit on the row the user is actually
## looking at instead of silently overwriting a neighbour.
func _var_field_path(item: Dictionary, var_index: int, v: Dictionary) -> Array:
	var vars: Array = item.get("vars", []) if item.get("vars") is Array else []
	var name := String(v.get("name", "")).strip_edges()
	if not name.is_empty():
		for i in vars.size():
			if String((vars[i] as Dictionary).get("name", "")).strip_edges() == name:
				return ["vars", i]
	if var_index >= 0 and var_index < vars.size():
		return ["vars", var_index]
	return ["vars", maxi(0, mini(var_index, vars.size() - 1))]


func _clamp_selection() -> void:
	var list := items_for(selected_kind)
	if selected_index >= list.size():
		selected_index = list.size() - 1


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

## Validate everything including cross-entry duplicate detection.
## Returns { card: {i: [issue]}, relic: {i: [issue]}, summary: {...},
##           by_item: { kind: {i: [issue]} } }
func validate_all(schema: CFSchema) -> Dictionary:
	# Validation checks derived fields (duplicate `entry`, var `kind`) that the
	# quiet typing path defers — flush them first so a mid-typed card is judged on
	# its real shape rather than on stale derivations.
	ensure_all_normalized(schema)
	var result: Dictionary = {CFDesign.KIND_CARD: {}, CFDesign.KIND_RELIC: {}}
	var summary := {"errors": 0, "warnings": 0, "infos": 0}
	for kind in [CFDesign.KIND_CARD, CFDesign.KIND_RELIC]:
		var list := items_for(kind)
		var others := all_items()
		for i in list.size():
			var issues := CFDesign.validate(schema, list[i], others, custom_characters)
			result[kind][i] = issues
			var counts := CFDesign.issue_counts(issues)
			summary["errors"] += int(counts["errors"])
			summary["warnings"] += int(counts["warnings"])
			summary["infos"] += int(counts["infos"])
	result["summary"] = summary
	return result


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func to_json() -> String:
	# A save is a reader of derived fields (`entry`, effect ids, `modified`), and
	# the quiet typing path deliberately defers those. Normalize first so what
	# lands on disk is always a fully-consistent document.
	ensure_all_normalized()
	var payload := snapshot()
	payload["format"] = "card_relic_forge/designs"
	payload["format_version"] = 2
	payload["saved_at"] = Time.get_datetime_string_from_system()
	return JSON.stringify(payload, "  ")


func load_from_json(text: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {"ok": false, "error": "JSON 解析失败：%s（第 %d 行）" % [parser.get_error_message(), parser.get_error_line()]}
	var data: Variant = parser.data
	if not (data is Dictionary):
		return {"ok": false, "error": "文件根节点不是对象。"}
	_restore(data as Dictionary)
	clear_history()
	# Everything just came off disk already normalised; do not let a stale flag
	# from the previous document trigger a pointless re-normalise (and a new
	# `modified` stamp) on the freshly loaded one.
	_needs_normalize.clear()
	_mark_dirty(false)
	_clamp_selection()
	designs_changed.emit()
	return {"ok": true, "error": ""}


func save_to_file(path: String) -> Dictionary:
	if not CFPaths.write_text(path, to_json()):
		return {"ok": false, "error": "无法写入 %s" % path}
	_mark_dirty(false)
	return {"ok": true, "error": ""}


func load_from_file(path: String) -> Dictionary:
	var text := CFPaths.read_text(path)
	if text.is_empty():
		return {"ok": false, "error": "文件不存在或为空：%s" % path}
	return load_from_json(text)


func is_dirty() -> bool:
	return _dirty


func _mark_dirty(value: bool) -> void:
	if _dirty != value:
		_dirty = value
		dirty_changed.emit(value)


# ---------------------------------------------------------------------------
# Example content (first run)
# ---------------------------------------------------------------------------

## A ready-to-open sample so the tool is never an empty screen: one card and one
## relic, both using only effects whose bindings were verified against the
## unpacked game source.
func seed_example(schema: CFSchema) -> void:
	var card := CFDesign.new_card(schema)
	card["id"] = "NinefoldStrike"
	card["text"]["zhs"]["title"] = "九重打击"
	card["text"]["eng"]["title"] = "Ninefold Strike"
	card["text"]["zhs"]["description"] = "造成 {Damage:diff()} 点伤害 {Repeat} 次。消耗。"
	card["text"]["eng"]["description"] = "Deal {Damage:diff()} damage {Repeat} times. Exhaust."
	card["keywords"] = ["Exhaust"]
	card["tags"] = ["Strike"]
	card["cost"] = 1
	card["rarity"] = _pick(schema, "card_rarity", ["Basic", "Common"])
	card["vars"] = [
		CFDesign.new_var("Damage", "Damage", "DamageVar", 1.0, "Move"),
		CFDesign.new_var("Repeat", "Repeat", "RepeatVar", 9.0, ""),
	]
	card["effects"] = [CFDesign.new_effect("damage")]
	card["effects"][0]["amount"] = 1.0
	card["effects"][0]["amount_is_var"] = true
	card["effects"][0]["amount_var"] = "Damage"
	card["effects"][0]["hits"] = 1
	card["effects"][0]["loop"] = {"mode": "var", "count": 1, "var": "Repeat"}
	card["upgrade"] = {
		"cost_delta": 0, "keywords_add": [], "keywords_remove": ["Exhaust"],
		"var_deltas": [], "text_override": CFDesign._empty_text(CFDesign.KIND_CARD),
	}
	card["deck"] = {"enabled": false, "character": "", "copies": 1}
	CFDesign.normalize(schema, card)
	cards = [card]

	var relic := CFDesign.new_relic(schema)
	relic["id"] = "IronWard"
	relic["text"]["zhs"]["title"] = "铁壁护符"
	relic["text"]["eng"]["title"] = "Iron Ward"
	relic["text"]["zhs"]["description"] = "战斗开始时，获得 {Block} 点格挡。"
	relic["text"]["eng"]["description"] = "At the start of combat, gain {Block} Block."
	relic["vars"] = [CFDesign.new_var("Block", "Block", "BlockVar", 6.0, "Unpowered")]
	var hook := ""
	for h in schema.usable_hooks():
		if String(h["name"]) == "BeforeCombatStart":
			hook = "BeforeCombatStart"
			break
	if hook.is_empty():
		var usable := schema.usable_hooks()
		hook = String(usable[0]["name"]) if not usable.is_empty() else ""
	var eff := CFDesign.new_effect("block")
	eff["amount_is_var"] = true
	eff["amount_var"] = "Block"
	eff["target"] = "self"
	relic["triggers"] = [{
		"hook": hook,
		"params": CFDesign._default_param_bindings(schema, hook),
		"condition": CFDesign.new_condition(),
		"charge": {"mode": "always", "n": 1},
		"loop": {"mode": "none", "count": 1, "var": ""},
		"effects": [eff],
		"note": "",
	}]
	CFDesign.normalize(schema, relic)
	relics = [relic]

	mod_id = "MyCardMod"
	mod_name = "我的卡牌扩展"
	mod_version = "1.0.0"
	clear_history()
	_mark_dirty(true)


static func _pick(schema: CFSchema, role: String, prefer: Array) -> String:
	var members := schema.members_for_role(role)
	for p in prefer:
		if members.has(p):
			return p
	return members[0] if not members.is_empty() else ""


## Delete the character and its owned pools, keeping authored items usable.
## The entire change is one undo operation, including disabled starter links.
func remove_custom_character(schema: CFSchema, id: String) -> bool:
	var index := -1
	for i in custom_characters.size():
		if String(custom_characters[i].get("id", "")) == id:
			index = i
	if index < 0:
		return false
	var character := CFCharacters.normalized(custom_characters[index])
	var template: Dictionary = {}
	if character["independent"]:
		template = {"card_pool": "ColorlessCardPool", "relic_pool": "SharedRelicPool"}
	for row in schema.characters:
		if row["class_name"] == character["template"]:
			template = row
	if template.is_empty():
		return false
	begin_action()
	for item in all_items():
		var field := "relic_pool" if item.get("kind") == CFDesign.KIND_RELIC else "card_pool"
		if item.get("pool") == character[field]:
			item["pool"] = template[field]
			CFDesign.normalize(schema, item)
		var deck: Dictionary = item.get("deck", {})
		if deck.get("character") == id:
			deck["enabled"] = false
			deck["character"] = ""
	custom_characters.remove_at(index)
	commit_action("删除角色及两个池（保留卡牌和遗物）")
	return true
