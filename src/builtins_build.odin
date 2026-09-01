package hashedbuild

// The builtins a build description needs, beyond §16's filesystem set:
// traversing a Table (`fold`), measuring and cutting text (`textlen`,
// `textslice`), listing a directory (`listdir`, SPEC.md §16) and running a
// program (`exec`). Like §16's, none of these are syntax - they are ordinary
// Function values pre-bound in the global scope, so adding one never touches
// the grammar.

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// ---- fold ---------------------------------------------------------------------

// fold { .table, .init, .step } -> Value
//
// The language has no loops (§8), and recursion cannot get at a Table's
// entries without a way to enumerate them - so this is the one general
// traversal primitive, and `map`/`filter`/`append` are written in HashedBuild
// on top of it rather than each being a builtin of its own.
//
// `.step` is called with { .acc, .key, .value } and returns the next
// accumulator. Not gated: it reads nothing outside the value it was handed.
//
// **Visiting order is ascending key order**, which is a deliberate choice and
// not the order the entries happen to sit in. Two consequences are the reason:
// a sequence (§5 - keys 1..N) folds in index order, which is what makes
// folding a list of filenames mean anything; and two Tables that compare
// equal (§6, which ignores entry order) fold to the same answer, which they
// would not if this walked `entries` as written. The order is numbers first
// by value, then Utf8 keys byte-wise; any other key kind sorts after those,
// keeping its relative position (see fold_key_less).
@(private = "file")
builtin_fold :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "fold expects a { .table, .init, .step } Table")

  table_val, has_table := table_find(t, "table")
  init_val, has_init := table_find(t, "init")
  step_val, has_step := table_find(t, "step")
  if !has_table do return fail(interp, "fold needs a .table")
  if !has_init do return fail(interp, "fold needs an .init")
  if !has_step do return fail(interp, "fold needs a .step")

  target, target_is_table := table_val.(^Table_Value)
  if !target_is_table do return fail(interp, "fold's .table must be a Table")
  step, step_is_fn := step_val.(^Function_Value)
  if !step_is_fn do return fail(interp, "fold's .step must be a Function")

  order := fold_order(target)
  defer delete(order)

  acc := init_val
  for idx in order {
    entry := target.entries[idx]
    frame := new(Table_Value)
    append(&frame.entries, Table_Entry_Value{key = "acc", value = acc})
    append(&frame.entries, Table_Entry_Value{key = "key", value = entry.key})
    append(&frame.entries, Table_Entry_Value{key = "value", value = entry.value})
    next, ok := call_function(interp, step, frame)
    if !ok do return nil, false
    next, ok = concrete_value(interp, next)
    if !ok do return nil, false
    acc = next
  }
  return acc, true
}

// Indices into `t.entries`, ascending by key. A hand-rolled insertion sort
// rather than slice.sort_by because it has to be *stable*: keys the ordering
// below does not distinguish (a Table used as a key, say) must still come out
// in a fixed order rather than whatever an unstable sort happens to do, or a
// fold over such a Table would not be reproducible run to run.
@(private = "file")
fold_order :: proc(t: ^Table_Value) -> []int {
  order := make([]int, len(t.entries))
  for i in 0 ..< len(t.entries) do order[i] = i
  for i in 1 ..< len(order) {
    j := i
    for j > 0 && fold_key_less(t.entries[order[j]].key, t.entries[order[j - 1]].key) {
      order[j], order[j - 1] = order[j - 1], order[j]
      j -= 1
    }
  }
  return order
}

// Numbers before text before everything else; within numbers by value, within
// text byte-wise. Anything else compares equal to anything else, which the
// stable sort above turns into "keeps the order it was written in" - the
// honest answer, since §6 defines no ordering over those kinds and inventing
// one here would be a language decision this builtin has no business making.
@(private = "file")
fold_key_less :: proc(a: Value, b: Value) -> bool {
  ra, rb := fold_key_rank(a), fold_key_rank(b)
  if ra != rb do return ra < rb
  switch ra {
  case 0:
    return fold_key_number(a) < fold_key_number(b)
  case 1:
    return a.(string) < b.(string)
  }
  return false
}

@(private = "file")
fold_key_rank :: proc(v: Value) -> int {
  #partial switch _ in v {
  case i64, f64: return 0
  case string:   return 1
  }
  return 2
}

@(private = "file")
fold_key_number :: proc(v: Value) -> f64 {
  #partial switch x in v {
  case i64: return f64(x)
  case f64: return x
  }
  return 0
}

// ---- textlen / textslice ------------------------------------------------------

// Both count in *codepoints*, not bytes: the type is Utf8 (§3), and an index
// that could land inside a multi-byte character would make `textslice` able to
// produce something that is not Utf8 at all. Neither is gated by `io` - they
// only look at text already in hand, the same reasoning that leaves `filetext`
// ungated (§16).

// textlen <Utf8> -> Integer
@(private = "file")
builtin_textlen :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  s, is_text := arg.(string)
  if !is_text do return fail(interp, "textlen expects a Utf8")
  return i64(utf8.rune_count_in_string(s)), true
}

// textslice { .text, .start, .count } -> Utf8
//
// `.start` is 1-based, matching `[i]`'s element access (§5). Asking for
// anything outside the text is fatal rather than clamped: a silently short
// answer is how an off-by-one becomes a wrong build instead of a stopped one.
@(private = "file")
builtin_textslice :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "textslice expects a { .text, .start, .count } Table")

  text_val, has_text := table_find(t, "text")
  start_val, has_start := table_find(t, "start")
  count_val, has_count := table_find(t, "count")

  s, text_ok := text_val.(string)
  start, start_ok := start_val.(i64)
  count, count_ok := count_val.(i64)
  if !has_text || !text_ok do return fail(interp, "textslice needs a Utf8 .text")
  if !has_start || !start_ok do return fail(interp, "textslice needs an Integer .start")
  if !has_count || !count_ok do return fail(interp, "textslice needs an Integer .count")

  n := i64(utf8.rune_count_in_string(s))
  if start < 1 do return fail(interp, "textslice's .start is 1-based, so it must be at least 1")
  if count < 0 do return fail(interp, "textslice's .count cannot be negative")
  if start - 1 + count > n {
    return fail(interp, "textslice: .start + .count reaches past the end of the text")
  }
  return strings.clone(strings.cut(s, int(start - 1), int(count))), true
}

// ---- listdir ------------------------------------------------------------------

// listdir <dirFile> -> a sequence of names (Utf8), sorted
//
// SPEC.md §16 left this open ("what a directory File's listing looks like as a
// value, so you can enumerate its entries, not just address a name you already
// know"); this is that half resolved. The plumbing was already here - the
// directory hasher walks a tree with the same call - it simply was not exposed.
//
// **Names only, not kinds.** What an entry *is* can already be asked by opening
// it (`loadfile { .dir, .path }`), and a bare sequence is the shape `fold`
// traverses and `[i]` indexes; a Table of name -> tag would need unwrapping at
// every use for something most callers do not consult. Adding kinds later is a
// widening, which is the direction that stays compatible.
//
// Sorted by name, byte-wise, for the same reason the directory *hash* sorts
// (§3): readdir order is a filesystem's private business, and a build whose
// argument order changed between machines would hash - and therefore cache -
// differently on each. Gated by `io` like every other read (§16).
@(private = "file")
builtin_listdir :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  if !ctx_allows_io(interp) do return fail(interp, "listdir: io permission not granted in the current context")

  fv, is_file := arg.(^File_Value)
  if !is_file do return fail(interp, "listdir expects a File")
  if fv.kind != .Directory do return fail(interp, "listdir expects a directory, not a regular file")

  entries, err := fs_list_entries_at(fv.dir_fd, context.temp_allocator)
  if err != .None do return fail(interp, "listdir: could not read the directory")
  slice.sort_by(entries, proc(a, b: Fs_Dir_Entry) -> bool { return a.name < b.name })

  out := new(Table_Value)
  for entry, i in entries {
    append(&out.entries, Table_Entry_Value{key = i64(i + 1), value = strings.clone(entry.name)})
  }
  return out, true
}

// ---- registration -------------------------------------------------------------

// Called by make_global_env (builtins_fs.odin) alongside §16's six. Kept here
// rather than there so the two sets stay separately readable; the names are
// what each hashes as (hash_function.odin), so they are as load-bearing as
// the procs and must not be renamed casually.
bind_build_builtins :: proc(env: ^Env) {
  env_bind(env, "fold", new_build_native("fold", builtin_fold))
  env_bind(env, "listdir", new_build_native("listdir", builtin_listdir))
  env_bind(env, "textlen", new_build_native("textlen", builtin_textlen))
  env_bind(env, "textslice", new_build_native("textslice", builtin_textslice))
}

@(private = "file")
new_build_native :: proc(name: string, fn: Native_Fn, closure: Value = nil) -> Value {
  f := new(Function_Value)
  f.name = name
  f.native = fn
  f.native_closure = closure
  return f
}

