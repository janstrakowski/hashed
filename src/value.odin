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
  // Builtins only: the operation's name, which is what one hashes as
  // (hash_function.odin). Empty for a closure, whose identity is its body's
  // shape and its captures instead.
  name:          string,
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

  // Directory only: §3's directory hash, read off the disk the first time
  // anything asks for it and kept thereafter (hash.odin). A Regular file's
  // content is already in `content`, so it needs no such field - this is the
  // one kind whose digest is not a function of what the value already holds.
  //
  // Memoised rather than recomputed because §3 calls a File an *immutable*
  // handle: a value whose digest changed under a program because someone
  // touched the tree would not be one. The first read is therefore the read,
  // and a later `sha256` of the same value answers the same thing forever.
  // (A fresh `loadfile` of the same path is a new value, and sees the tree as
  // it is then - which is how a build observes a change.)
  dir_digest:         Value_Digest,
  dir_digest_known:   bool,
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

// SPEC.md §9's ctx.dir: a handle to the directory a program was started in -
// the running source file's own directory, or the process's cwd. Its own type
// rather than a directory File, for one specific reason: §15 puts the whole
// `ctx` into every `cached` key, and a directory File hashes over its contents
// (§3), so a File here would make every cache entry depend on every byte of
// the project tree - touching any file would invalidate all of them. Like
// ctx.cache it therefore hashes as a bare tag (hash.odin). Reading *through*
// it yields ordinary Files that hash by content as usual, so nothing about
// incremental correctness is given up; what is discarded is only the identity
// of the directory itself, which is the same thing ctx.cache discards.
Workdir_Value :: struct {
  dir_path: string, // absolute - display-only, same as File_Value's
  dir_fd:   Fs_Fd,
}

// SPEC.md §10's forward reference: a stand-in for a `let rec` Table entry that
// is still being evaluated. Demand-driven evaluation reorders away every
// dependency that has a topological order (see eval.odin's Rec_Build); one of
// these is created only for the residual *true* cycle - an entry projecting an
// entry already in progress, which no ordering can fix.
//
// It may be **stored**: dropped into a Table, a Variant, a closure's captured
// environment. The moment anything **inspects** it before it is filled - a
// field access, a call, arithmetic, a comparison - that is a genuinely
// circular definition and fails (see eval.odin's concrete_value). By the time
// the enclosing `let rec` returns, every reference it made is filled, so a
// program can never receive a value containing an unresolved one. That is why
// this is not one of §3's types: it exists only during construction, and is
// transparent to everything afterwards.
Forward_Ref_Value :: struct {
  target:   Value,  // valid only once `resolved`
  resolved: bool,
  name:     string, // the `let rec` binding this points into, for the message
  key:      Value,  // ...and which of its entries
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
  ^Workdir_Value,
  ^Async_Handle, // SPEC.md §2 - a fired-but-not-yet-awaited `async` expression; see eval_async.odin
  ^Forward_Ref_Value, // SPEC.md §10 - a `let rec` cycle's back-edge, only ever unresolved mid-construction
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

// Follows a chain of forward references (§10) to the value one finally stands
// for. `ok` is false if the chain ends at one that is not filled in yet, which
// only happens while its own `let rec` is still building - see
// Forward_Ref_Value and eval.odin's concrete_value, which turns that into the
// user-facing "circular definition" failure.
resolve_forward :: proc(v: Value) -> (Value, bool) {
  cur := v
  for {
    fr, is_fwd := cur.(^Forward_Ref_Value)
    if !is_fwd do return cur, true
    if !fr.resolved do return cur, false
    cur = fr.target
  }
}

// Each candidate is compared with its own assumption state (values_equal makes
// a fresh one), which matters and is not just tidiness: this loop is the one
// place in the comparison machinery that *keeps going* after a comparison
// returns false. The optimistic algorithm below records "assume these two are
// equal" as it descends, and those assumptions are only sound if the descent
// succeeds - a failed one leaves claims that were never justified. Sharing
// state across candidates would let a later candidate short-circuit to `true`
// on the wreckage of an earlier failure. Asking whether two keys match is a
// self-contained question about their own two subgraphs, so answering it in
// isolation is both sound and enough.
table_find :: proc(t: ^Table_Value, key: Value) -> (Value, bool) {
  for entry in t.entries {
    if values_equal(entry.key, key) do return entry.value, true
  }
  return nil, false
}

// ---- equality over possibly-cyclic values (SPEC.md §6/§10) -------------------

// `let rec` can build a Table that reaches itself (§10), so the structural walk
// below has to terminate on a graph rather than a tree. The algorithm is the
// standard optimistic one (Downey-Sethi-Tarjan congruence closure): on first
// meeting a pair of Tables, *assume* they are equal, record that assumption,
// and compare their entries under it. A back-edge then arrives at a pair
// already assumed equal and stops, instead of recursing forever. If any
// entry actually mismatches, the whole comparison returns false, and it does so
// all the way out: every caller down the value spine propagates a false rather
// than trying something else, so the discredited assumptions die with the walk
// that made them and nothing has to be rolled back. That argument holds only
// because of it - table_find, the one loop that does try something else, is
// therefore kept out of this state entirely (see its comment).
//
// What that computes is bisimulation: two separately built cycles of the same
// shape are equal, which is what §6's "equality is about content" requires -
// a pointer comparison would call them different for no reason a program can
// see. Assumptions live in a union-find with path compression, so the cost is
// near-linear (O(n·α(n))) rather than the O(n²) a visited-pair set would give.
//
// The map is created only when two *distinct* Tables are first assumed equal,
// so every acyclic comparison - and every scalar key lookup through
// table_find, which is on the hot path of field access - allocates nothing.
@(private = "file")
Bisim :: struct {
  parent: map[rawptr]rawptr,
}

@(private = "file")
bisim_destroy :: proc(bs: ^Bisim) {
  if bs.parent != nil do delete(bs.parent)
}

@(private = "file")
bisim_find :: proc(bs: ^Bisim, x: rawptr) -> rawptr {
  // A nil map reads as "every node is its own root", which is exactly the
  // state before any assumption has been made - so this is safe to call
  // before `parent` exists.
  root := x
  for {
    p, ok := bs.parent[root]
    if !ok || p == root do break
    root = p
  }
  cur := x
  for cur != root {
    p := bs.parent[cur]
    bs.parent[cur] = root
    cur = p
  }
  return root
}

@(private = "file")
bisim_assume_equal :: proc(bs: ^Bisim, a: rawptr, b: rawptr) {
  if bs.parent == nil do bs.parent = make(map[rawptr]rawptr)
  ra := bisim_find(bs, a)
  rb := bisim_find(bs, b)
  if ra == rb do return
  bs.parent[ra] = rb
  bs.parent[rb] = rb
}

// No implicit coercion between kinds (Integer 5 and Float 5.0 are not equal) -
// not addressed by the spec, kept simple and predictable for this pass.
values_equal :: proc(a: Value, b: Value) -> bool {
  bs: Bisim
  defer bisim_destroy(&bs)
  return values_equal_bisim(a, b, &bs)
}

@(private = "file")
values_equal_bisim :: proc(a: Value, b: Value, bs: ^Bisim) -> bool {
  // Comparing a value is inspecting it, so an unresolved forward reference
  // cannot be compared - but it also cannot be *reached* by a program, since
  // the only code running while one exists is the `let rec` building it, and
  // that fails at the inspection itself (concrete_value). Returning false
  // keeps this total rather than relying on that argument.
  av, aok := resolve_forward(a)
  bv, bok := resolve_forward(b)
  if !aok || !bok do return false

  switch x in av {
  case Nothing_Value:
    _, ok := bv.(Nothing_Value)
    return ok
  case i64:
    y, ok := bv.(i64)
    return ok && x == y
  case f64:
    y, ok := bv.(f64)
    return ok && x == y
  case string:
    y, ok := bv.(string)
    return ok && x == y
  case bool:
    y, ok := bv.(bool)
    return ok && x == y
  case []u8:
    y, ok := bv.([]u8)
    return ok && slice.equal(x, y)
  case ^Table_Value:
    y, ok := bv.(^Table_Value)
    if !ok || len(x.entries) != len(y.entries) do return false
    if x == y do return true // the same node - bisimilar to itself, no walk needed
    if bisim_find(bs, x) == bisim_find(bs, y) do return true // already assumed
    bisim_assume_equal(bs, x, y)
    for entry in x.entries {
      other_val, found := table_find(y, entry.key)
      if !found || !values_equal_bisim(entry.value, other_val, bs) do return false
    }
    return true
  case ^Function_Value:
    y, ok := bv.(^Function_Value)
    return ok && x == y // reference equality - functions aren't otherwise comparable
  case ^File_Value:
    y, ok := bv.(^File_Value)
    if !ok do return false
    // SPEC.md §3: a File's identity is pure content, independent of path -
    // two Files built from different paths are equal whenever their content
    // matches. A Regular file compares by its content digest, a Directory by
    // §3's entry-wise directory digest (hash.odin).
    //
    // A directory's digest is read off the disk on first demand, and reading
    // is an I/O operation - so it needs the `io` permission and an
    // interpreter to ask, neither of which exists down here (this is reached
    // from table_find, on the hot path of every field access). The evaluator
    // therefore warms both operands before comparing them (eval.odin's
    // hash_materialize), and what is left here is a pure question about
    // memoised digests. The `x == y` shortcut is what makes a directory still
    // compare equal to itself if that warming was skipped or refused.
    if x.kind != y.kind do return false
    if x == y do return true
    return values_hash_equal(x, y)
  case ^Cache_Value:
    y, ok := bv.(^Cache_Value)
    return ok && x == y // reference equality - there's only ever one per context anyway
  case ^Workdir_Value:
    y, ok := bv.(^Workdir_Value)
    return ok && x == y // as ctx.cache: one per context, and no content to compare
  case ^Async_Handle:
    // Every real call site awaits an operand before comparing it (see
    // eval_async.odin) - an un-awaited handle reaching here would be a bug
    // elsewhere, not a case real programs should hit. Reference equality
    // just keeps this switch exhaustive without pretending to be meaningful.
    y, ok := bv.(^Async_Handle)
    return ok && x == y
  case ^Forward_Ref_Value:
    // Unreachable: resolve_forward above returns either a non-forward value
    // or ok == false. Present so the switch stays exhaustive.
    return false
  }
  return false
}
