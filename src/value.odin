package hashedbuild

import "core:slice"

// Runtime values (SPEC.md §3/§5/§6). `Bytes` has no literal syntax yet - the
// only way to produce one today would be a builtin that hands one back, and
// none currently does - so the Value case exists (§16's createfile accepts
// one) but is presently unreachable from actual HashedBuild source.

Nothing_Value :: struct {}

Table_Entry_Value :: struct {
  key:   Value,
  value: Value,
}

Table_Value :: struct {
  entries: [dynamic]Table_Entry_Value, // order preserved; sequence-shaped tables
                                        // are just tables with 1..N Integer keys
}

// A native (Odin-implemented) function, as opposed to a user-defined closure
// with an AST body - see eval.odin's call_function for how the two differ in
// how they treat `ctx`. `closure` is extra data a native carries with it
// (Odin `proc` values can't capture locals) - e.g. chperm's returned
// ctx-changing function captures its {name, enabled} argument this way. Most
// natives (loadfile & friends) ignore it.
Native_Fn :: proc(interp: ^Interpreter, closure: Value, arg: Value) -> (Value, bool)

Function_Value :: struct {
  body:          Node_Idx, // the deferred expression - evaluated once an argument is pushed; unused if native != nil
  env:           ^Env,      // captured lexical environment at the point the closure was made; unused if native != nil
  ctx:           Value,     // captured `ctx` (SPEC.md §9) at the point the closure was made - see eval.odin's call_function
  native:        Native_Fn, // non-nil for a builtin (§16) - call_function invokes this instead of evaluating body/env
  native_closure: Value,    // passed as `closure` to `native`, if any
}

// SPEC.md §3's File: a handle to a filesystem entity, file or directory only
// (never a symlink - those are directory metadata, §3/§16). A Regular file's
// content is read fully up front; a Directory keeps an open fd so it can be
// used as the `.dir` handle in further loadfile/createfile/symlink/readlink
// calls (§16), each independently contained to it.
File_Kind :: enum { Regular, Directory }

File_Value :: struct {
  kind:               File_Kind,
  content:            []u8,     // Regular only
  dir_fd:             Fs_Fd,   // Directory only
  // Where this File was actually read from or written to, resolved through
  // /proc/self/fd so it's absolute regardless of how the call named it (§3's
  // display rule). format_value shows it; nothing else does. There's no
  // builtin that lets HashedBuild source read this field back out, by design
  // - a program holds the handle without ever learning where its data lives.
  // Empty only if that resolution failed (see builtins_fs.odin's path_of_fd).
  display_path:       string,
}

// SPEC.md §9's ctx.cache: a write-only, content-addressed blob store rooted
// at some directory (XDG-resolved by default, §16) - "accepted as a
// directory" wherever createfile's `.dir` is, but not a File/directory in
// its own right, since it can't be read from or traversed, only written to.
// The underlying directory is created lazily, on the first actual write.
Cache_Value :: struct {
  dir_path: string,  // absolute path - display-only, same as File_Value's
  dir_fd:   Fs_Fd,
  opened:   bool,
}

Value :: union {
  Nothing_Value,
  i64,      // Integer
  f64,      // Float
  string,   // Utf8
  bool,     // Boolean
  []u8,     // Bytes
  ^Table_Value,
  ^Function_Value,
  ^File_Value,
  ^Cache_Value,
  ^Async_Handle, // SPEC.md §2 - a fired-but-not-yet-awaited `async` expression; see eval_async.odin
}

Env :: struct {
  parent: ^Env,
  names:  map[string]Value,
}

env_make_child :: proc(parent: ^Env) -> ^Env {
  e := new(Env)
  e.parent = parent
  e.names = make(map[string]Value)
  return e
}

env_lookup :: proc(env: ^Env, name: string) -> (Value, bool) {
  e := env
  for e != nil {
    if v, ok := e.names[name]; ok do return v, true
    e = e.parent
  }
  return nil, false
}

env_bind :: proc(env: ^Env, name: string, val: Value) {
  env.names[name] = val
}

table_find :: proc(t: ^Table_Value, key: Value) -> (Value, bool) {
  for entry in t.entries {
    if values_equal(entry.key, key) do return entry.value, true
  }
  return nil, false
}

// No implicit coercion between kinds (Integer 5 and Float 5.0 are not equal) -
// not addressed by the spec, kept simple and predictable for this pass.
values_equal :: proc(a: Value, b: Value) -> bool {
  switch av in a {
  case Nothing_Value:
    _, ok := b.(Nothing_Value)
    return ok
  case i64:
    bv, ok := b.(i64)
    return ok && av == bv
  case f64:
    bv, ok := b.(f64)
    return ok && av == bv
  case string:
    bv, ok := b.(string)
    return ok && av == bv
  case bool:
    bv, ok := b.(bool)
    return ok && av == bv
  case []u8:
    bv, ok := b.([]u8)
    return ok && slice.equal(av, bv)
  case ^Table_Value:
    bv, ok := b.(^Table_Value)
    if !ok || len(av.entries) != len(bv.entries) do return false
    for entry in av.entries {
      other_val, found := table_find(bv, entry.key)
      if !found || !values_equal(entry.value, other_val) do return false
    }
    return true
  case ^Function_Value:
    bv, ok := b.(^Function_Value)
    return ok && av == bv // reference equality - functions aren't otherwise comparable
  case ^File_Value:
    bv, ok := b.(^File_Value)
    // Reference equality for now - SPEC.md §3's real content-hash-based File
    // identity (content bytes for a Regular file, a recursive entry-hash for
    // a Directory) isn't implemented yet, same gap as serialize/sha256 (§15).
    return ok && av == bv
  case ^Cache_Value:
    bv, ok := b.(^Cache_Value)
    return ok && av == bv // reference equality - there's only ever one per context anyway
  case ^Async_Handle:
    // Every real call site awaits an operand before comparing it (see
    // eval_async.odin) - an un-awaited handle reaching here would be a bug
    // elsewhere, not a case real programs should hit. Reference equality
    // just keeps this switch exhaustive without pretending to be meaningful.
    bv, ok := b.(^Async_Handle)
    return ok && av == bv
  }
  return false
}
