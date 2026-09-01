package hashedbuild

// The builtins a build description needs, beyond §16's filesystem set:
// traversing a Table (`fold`), measuring and cutting text (`textlen`,
// `textslice`), listing a directory (`listdir`, SPEC.md §16) and running a
// program (`exec`). Like §16's, none of these are syntax - they are ordinary
// Function values pre-bound in the global scope, so adding one never touches
// the grammar.

import "core:fmt"
import "core:os"
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

// ---- exec ---------------------------------------------------------------------

// exec { .cmd, .args, .inputs, .outputs, .stdin }
//   -> { .status, .stdout, .stderr, .outputs = { name -> File } }
//
// Runs a program, and is the first builtin here that is designed *around* the
// cache rather than beside it. The shape is the whole point: the command runs
// in a fresh scratch directory that holds nothing but the `.inputs` it was
// given, and what comes back out are the `.outputs` **as values**, never
// paths. That is what makes `cached exec { … }` correct - §15's key excludes
// anything an expression reads at run time, so a thinner exec that wrote into
// a directory and let the caller `loadfile` the result afterwards would cache
// the first run's answer forever. Here every input is a File, a File is its
// content (§3), so the inputs are *in* the key and a changed source
// invalidates exactly the steps that consumed it.
//
//   .cmd     Utf8, looked up on PATH.
//   .args    a sequence of Utf8; default none.
//   .inputs  either a directory File (its contents become the scratch root) or
//            a Table of relative-name -> File. Default: an empty scratch.
//   .outputs a sequence of Utf8 relative paths to collect afterwards.
//   .stdin   optional Utf8 fed to the program.
//
// **A non-zero exit is not a failure here.** It comes back as `.status`, so a
// build can `check(r.status == 0, …)` and show `.stderr` - which is the useful
// thing to do with a compiler that rejected its input. Everything else is
// fatal like any other builtin (§16): a command that could not be started, an
// input that could not be written, a declared output that is not there.
//
// Gated by `ctx.permissions.exec`, checked live at the call site. Running an
// arbitrary program is strictly more authority than reading a file, so it does
// not ride on `io`.
//
// Worth being plain about in the docs: this contains what is *handed to* a
// build step, not what that step then does. A compiler started here is an
// ordinary process and can read whatever the user running it can.
@(private = "file")
builtin_exec :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  if !ctx_has_permission(interp, "exec") {
    return fail(interp, "exec: exec permission not granted in the current context")
  }
  if !ctx_allows_io(interp) {
    return fail(interp, "exec: io permission not granted in the current context")
  }

  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "exec expects a { .cmd, .args, .inputs, .outputs } Table")

  cmd_val, has_cmd := table_find(t, "cmd")
  cmd, cmd_ok := cmd_val.(string)
  if !has_cmd || !cmd_ok do return fail(interp, "exec needs a Utf8 .cmd")

  // argv[0] is the command itself, as every exec-family call expects.
  command := make([dynamic]string, 0, 8, context.temp_allocator)
  append(&command, cmd)
  if args_val, has_args := table_find(t, "args"); has_args {
    args_t, args_is_table := args_val.(^Table_Value)
    if !args_is_table do return fail(interp, "exec's .args must be a Table of Utf8")
    for idx in fold_order(args_t) {
      a, a_ok := args_t.entries[idx].value.(string)
      if !a_ok do return fail(interp, "exec's .args must all be Utf8")
      append(&command, a)
    }
  }

  scratch_path, scratch_fd, made := exec_make_scratch(interp)
  if !made do return fail(interp, "exec: could not create a scratch directory to run in")
  defer fs_close(scratch_fd)
  defer exec_remove_scratch(interp, scratch_path)

  if inputs_val, has_inputs := table_find(t, "inputs"); has_inputs {
    if msg := exec_materialize(scratch_fd, inputs_val); msg != "" {
      return fail(interp, fmt.tprintf("exec: %s", msg))
    }
  }

  // A .cmd naming a path ("./cjson-demo") means "in the directory this run
  // happens in" - which is the only directory the program can see anyway. It
  // has to be made absolute here: the exec-family lookup checks the name
  // against the *parent's* working directory, before the child ever changes
  // into the scratch, so a relative one would be looked for in the wrong
  // place. A bare name ("clang") is left alone and found on PATH as usual.
  if strings.index_byte(cmd, '/') >= 0 && !is_absolute_path(cmd) {
    trimmed := cmd
    if strings.has_prefix(trimmed, "./") do trimmed = trimmed[2:]
    command[0] = strings.concatenate({scratch_path, "/", trimmed}, context.temp_allocator)
  }

  desc := os.Process_Desc{working_dir = scratch_path, command = command[:]}

  // .stdin is handed over as a real file inside the scratch rather than a
  // pipe: the program is waited on to completion anyway, so there is nothing
  // a pipe would buy beyond a second failure mode to get wrong.
  stdin_file: ^os.File
  if stdin_val, has_stdin := table_find(t, "stdin"); has_stdin {
    text, text_ok := stdin_val.(string)
    if !text_ok do return fail(interp, "exec's .stdin must be a Utf8")
    if msg := write_bytes(scratch_fd, EXEC_STDIN_NAME, transmute([]u8)text, false); msg != "" {
      return fail(interp, fmt.tprintf("exec: %s", msg))
    }
    f, ferr := os.open(strings.concatenate({scratch_path, "/", EXEC_STDIN_NAME}, context.temp_allocator))
    if ferr != nil do return fail(interp, "exec: could not open .stdin for the program to read")
    stdin_file = f
    desc.stdin = f
  }
  defer if stdin_file != nil do os.close(stdin_file)

  state, stdout_bytes, stderr_bytes, run_err := os.process_exec(desc, context.allocator)
  if run_err != nil {
    // WASI has no way to start a process at all - core:os's backend answers
    // .Unsupported - so this is also where a wasm build lands, and it says so
    // rather than reporting a missing program.
    if run_err == .Unsupported {
      return fail(interp, "exec: running a program is not available on this target")
    }
    return fail(interp, fmt.tprintf("exec: could not run %s (%v)", cmd, run_err))
  }

  outputs := new(Table_Value)
  if outs_val, has_outs := table_find(t, "outputs"); has_outs {
    outs_t, outs_is_table := outs_val.(^Table_Value)
    if !outs_is_table do return fail(interp, "exec's .outputs must be a Table of Utf8")
    for idx in fold_order(outs_t) {
      name, name_ok := outs_t.entries[idx].value.(string)
      if !name_ok do return fail(interp, "exec's .outputs must all be Utf8")
      is_dir, stat_err := fs_stat_is_dir_at(scratch_fd, name, true)
      if stat_err != .None {
        return fail(interp, fmt.tprintf("exec: %s declared no output named %s", cmd, name))
      }
      if is_dir {
        return fail(interp, fmt.tprintf("exec: .outputs names %s, which is a directory - only regular files can be collected today", name))
      }
      fv, msg := open_as_file_value(scratch_fd, name, false, display_join(scratch_path, name))
      if msg != "" do return fail(interp, fmt.tprintf("exec: %s", msg))
      append(&outputs.entries, Table_Entry_Value{key = strings.clone(name), value = fv})
    }
  }

  result := new(Table_Value)
  append(&result.entries, Table_Entry_Value{key = "status", value = i64(state.exit_code)})
  append(&result.entries, Table_Entry_Value{key = "stdout", value = exec_text(stdout_bytes)})
  append(&result.entries, Table_Entry_Value{key = "stderr", value = exec_text(stderr_bytes)})
  append(&result.entries, Table_Entry_Value{key = "outputs", value = outputs})
  return result, true
}

EXEC_STDIN_NAME :: ".hb-exec-stdin"


// A program's output is whatever bytes it chose to write, which need not be
// text at all. Utf8 is the only shape the language has for it, so invalid
// bytes are replaced rather than failing the build - a compiler that emitted
// one stray byte on stderr should not take the whole run down, and the
// diagnostic is still what the user needs to read.
@(private = "file")
exec_text :: proc(raw: []u8) -> Value {
  if utf8.valid_string(string(raw)) do return strings.clone(string(raw))
  b := strings.builder_make()
  for r in string(raw) do strings.write_rune(&b, r == utf8.RUNE_ERROR ? '?' : r)
  return strings.to_string(b)
}

// The scratch lives under the cache directory: it is already the place this
// language keeps working files, `--cache-dir` already points it somewhere
// writable, and putting it there keeps build droppings out of the project.
@(private = "file")
exec_make_scratch :: proc(interp: ^Interpreter) -> (path: string, fd: Fs_Fd, ok: bool) {
  cache, has_cache := cache_of_ctx(interp.current_ctx)
  if !has_cache do return "", FS_INVALID_FD, false
  if ensure_cache_dir_open(cache) != .None do return "", FS_INVALID_FD, false

  name, made := make_temp_dir(cache.dir_fd, "exec")
  if !made do return "", FS_INVALID_FD, false
  dir_fd, err := fs_open_dir_at(cache.dir_fd, name, true)
  if err != .None do return "", FS_INVALID_FD, false
  return strings.concatenate({cache.dir_path, "/", name}), dir_fd, true
}

@(private = "file")
exec_remove_scratch :: proc(interp: ^Interpreter, scratch_path: string) {
  cache, has_cache := cache_of_ctx(interp.current_ctx)
  if !has_cache do return
  idx := strings.last_index_byte(scratch_path, '/')
  if idx < 0 do return
  remove_tree_at(cache.dir_fd, scratch_path[idx + 1:])
}

// `.inputs` is either one directory File - whose contents become the scratch
// root, which is what lets `listdir` names be used as arguments verbatim - or
// a Table placing each File at its own key.
@(private = "file")
exec_materialize :: proc(scratch_fd: Fs_Fd, inputs: Value) -> string {
  #partial switch v in inputs {
  case ^File_Value:
    if v.kind != .Directory do return ".inputs given as a single File must be a directory"
    return copy_tree(v.dir_fd, scratch_fd)
  case ^Table_Value:
    for entry in v.entries {
      name, name_ok := entry.key.(string)
      if !name_ok do return ".inputs keys must be Utf8 names"
      fv, is_file := entry.value.(^File_Value)
      if !is_file do return fmt.tprintf(".inputs entry %s is not a File", name)
      if msg := write_file_value(scratch_fd, name, fv); msg != "" do return msg
    }
    return ""
  }
  return ".inputs must be a directory File or a Table of name -> File"
}

// ---- registration -------------------------------------------------------------

// Called by make_global_env (builtins_fs.odin) alongside §16's six. Kept here
// rather than there so the two sets stay separately readable; the names are
// what each hashes as (hash_function.odin), so they are as load-bearing as
// the procs and must not be renamed casually.
bind_build_builtins :: proc(env: ^Env) {
  env_bind(env, "fold", new_build_native("fold", builtin_fold))
  env_bind(env, "listdir", new_build_native("listdir", builtin_listdir))
  env_bind(env, "exec", new_build_native("exec", builtin_exec))
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

