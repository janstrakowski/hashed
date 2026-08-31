package hashedbuild

import "core:slice"

// A Function's digest (SPEC.md §15), which the rest of hash.odin's Merkle fold
// treats as just another composite.
//
// §15 says `cached` hashes the cached expression "as a function", and asks for
// the cache key to be the hash of that function representation - but it never
// says what a closure's representation *is*, which is the decision this file
// makes. A closure is two things and nothing else:
//
//   * **the shape of its body** - the AST, node kind by node kind, with each
//     leaf's own spelling folded in; and
//   * **the values it captures** - the free names of that body, looked up in
//     the environment the closure was made in, each hashed as an ordinary
//     value and mixed in under its name.
//
// So two closures hash alike exactly when they would compute the same thing:
// the same expression, reading the same values. Where they were written, and
// what else happened to be in scope there, does not enter into it - which is
// the property `cached` actually needs, since a cache keyed on irrelevant
// surroundings misses every time the surroundings change.
//
// Three things follow, and are worth being plain about:
//
//   * **Bound names count.** `func (let x 1; x)` and `func (let y 1; y)` are
//     the same function and hash differently, because the shape includes every
//     leaf's spelling. Alpha-equivalence would need the binders renumbered,
//     which is a bigger analysis than this buys back - a closure's digest
//     surviving a rename is not something §15 asks for.
//   * **Literals hash as written.** `"a"` and `"\x61"` are the same Utf8 value
//     and hash differently as *shapes*, for the same reason. The digest is of
//     the program, not of what the program would evaluate to.
//   * **The free-name set is an over-approximation.** free_names below collects
//     every identifier in a reference position, including ones an inner `let`
//     goes on to bind. A name bound inside the body simply is not in the
//     closure's environment, so it contributes nothing; one that is *also* a
//     name outside contributes a value the body never reads. That costs
//     precision - two closures that differ only in such a shadow hash apart -
//     and never correctness, which is the direction that matters: every name
//     the body can actually read is in the set.
//
// A builtin (§16) has no body to take a shape from, so it hashes as its name
// plus whatever it carries in `native_closure` - `chperm { .name = "io" }`
// returns a function, and two of those are the same function when they were
// built from the same permission.

// One captured name and the value it stood for. Exposed because two other
// places walk a closure's children: hash.odin warms directory digests before a
// comparison, and hash_cyclic.odin treats a closure as a graph node whose
// out-edges are exactly these.
Function_Capture :: struct {
  name:  string,
  value: Value,
}

function_digest :: proc(fv: ^Function_Value, w: ^Hash_Walk) -> (Value_Digest, Hash_Fail) {
  if fv.native != nil {
    closure_digest, f := value_digest_walk(fv.native_closure, w)
    if f.kind != .None do return {}, f
    payload: [2 * DIGEST_SIZE]u8
    nd := sha256_text(fv.name)
    copy(payload[0:], nd[:])
    copy(payload[DIGEST_SIZE:], closure_digest[:])
    return sha256_tagged(TAG_NATIVE, payload[:]), HASH_OK
  }

  if w.interp == nil do return {}, Hash_Fail{kind = .No_Program}

  // A closure that captures itself - `let rec f func (f #arg)`, the ordinary
  // way to write a recursive function - is a cycle like any other, and goes
  // to hash_cyclic.odin by the same route a cyclic Table does.
  for open in w.open {
    if open == rawptr(fv) do return {}, Hash_Fail{kind = .Cyclic}
  }
  append(&w.open, rawptr(fv))
  defer pop(&w.open)

  shape := function_shape_digest(w.interp, fv)
  captures := function_captures(w.interp, fv)

  buf := make([]u8, DIGEST_SIZE + len(captures) * 2 * DIGEST_SIZE, context.temp_allocator)
  copy(buf[0:], shape[:])
  for capture, i in captures {
    vd, f := value_digest_walk(capture.value, w)
    if f.kind != .None do return {}, f
    nd := sha256_text(capture.name)
    at := DIGEST_SIZE + i * 2 * DIGEST_SIZE
    copy(buf[at:], nd[:])
    copy(buf[at + DIGEST_SIZE:], vd[:])
  }
  return sha256_tagged(TAG_FUNCTION, buf), HASH_OK
}

// The body's shape, plus the captured `ctx` when - and only when - the body
// can see it. A closure carries the context it was made in (§9), and two
// closures with different authority genuinely are different functions; but
// folding `ctx` in unconditionally would make every closure's digest depend on
// the whole permission table, so a body that never writes `ctx` does not pay
// for it.
function_shape_digest :: proc(interp: ^Interpreter, fv: ^Function_Value) -> Value_Digest {
  body := node_shape_digest(interp, fv.body)
  _, uses_ctx := free_names(interp, fv.body)
  if !uses_ctx do return body

  ctx_walk := Hash_Walk{interp = interp, open = make([dynamic]rawptr, 0, 4, context.temp_allocator)}
  ctx_digest, f := value_digest_walk(fv.ctx, &ctx_walk)
  // A context that cannot be hashed - it holds a directory nobody has read, say
  // - folds in as a bare tag rather than failing the whole function: `ctx` is
  // ambient authority, not an argument, and refusing to hash a closure because
  // of what its caller could do is not a distinction §15 wants.
  if f.kind != .None do ctx_digest = sha256_tagged(TAG_CACHE, nil)

  payload: [2 * DIGEST_SIZE]u8
  copy(payload[0:], body[:])
  copy(payload[DIGEST_SIZE:], ctx_digest[:])
  return sha256_tagged(TAG_FUNCTION, payload[:])
}

// The free names of the closure's body, paired with what they stood for where
// it was written. Sorted by name, so the digest does not depend on the order
// the walk happened to meet them in. A name the environment does not hold is
// dropped: it is bound inside the body (see the over-approximation note above),
// or it is an undefined name the program will fail on anyway.
//
// **That order is part of the encoding**, not an internal detail: a closure
// caught in a cycle is encoded by hash_cyclic.odin instead, and it mirrors this
// order exactly rather than imposing its own. The two must agree, or the same
// closure would have two digests depending on how it was reached.
function_captures :: proc(interp: ^Interpreter, fv: ^Function_Value) -> []Function_Capture {
  if fv.native != nil do return nil

  names, _ := free_names(interp, fv.body)
  captures := make([dynamic]Function_Capture, 0, len(names), context.temp_allocator)
  for name in names {
    if v, found := env_lookup(fv.env, name); found {
      append(&captures, Function_Capture{name = name, value = v})
    }
  }
  slice.sort_by(captures[:], proc(a, b: Function_Capture) -> bool { return a.name < b.name })
  return captures[:]
}

// ---- the body's shape ---------------------------------------------------------

// One node as a fixed-width record - kind, the flags that change meaning,
// child count, then either the leaf's own text or the children's digests. The
// count is what makes concatenating the children unambiguous without any
// separator, the same argument the Merkle encoding rests on in hash.odin.
@(private = "file")
node_shape_digest :: proc(interp: ^Interpreter, idx: Node_Idx) -> Value_Digest {
  n := interp.ast.nodes[idx]

  // Only the two flags that mean something semantically. Has_Error and
  // Is_Missing describe a program that isn't going to run.
  flags: u8
  if .Computed_Key in n.flags do flags |= 1
  if .Is_Rec in n.flags do flags |= 2

  header: [5]u8
  header[0] = u8(u16(n.kind) & 0xff)
  header[1] = u8(u16(n.kind) >> 8)
  header[2] = flags
  header[3] = u8(n.children_count & 0xff)
  header[4] = u8(n.children_count >> 8)

  if n.children_count == 0 {
    text := sha256_text(node_text(interp, idx))
    payload: [5 + DIGEST_SIZE]u8
    copy(payload[0:], header[:])
    copy(payload[5:], text[:])
    return sha256_tagged(TAG_AST, payload[:])
  }

  buf := make([]u8, 5 + int(n.children_count) * DIGEST_SIZE, context.temp_allocator)
  copy(buf[0:], header[:])
  for i in 0 ..< int(n.children_count) {
    child := node_shape_digest(interp, interp.ast.extra_children[int(n.children_start) + i])
    copy(buf[5 + i * DIGEST_SIZE:], child[:])
  }
  return sha256_tagged(TAG_AST, buf)
}

// A leaf's own spelling. Operators and punctuation have a kind and nothing
// else worth hashing, but taking the span uniformly costs nothing and means a
// new leaf kind that *does* carry text needs no change here.
@(private = "file")
node_text :: proc(interp: ^Interpreter, idx: Node_Idx) -> string {
  n := interp.ast.nodes[idx]
  if int(n.span.end) > len(interp.src) || n.span.start > n.span.end do return ""
  return interp.src[n.span.start:n.span.end]
}

// ---- free names ----------------------------------------------------------------

// Every identifier in the subtree that is a *reference* to a name, plus
// whether the subtree mentions `ctx`. The work is in telling a reference from
// the several places an Identifier leaf means something else entirely - a
// field's spelling, a binder, a pattern's selector - none of which reads
// anything from the enclosing scope.
@(private = "file")
free_names :: proc(interp: ^Interpreter, idx: Node_Idx) -> (names: []string, uses_ctx: bool) {
  found := make([dynamic]string, 0, 8, context.temp_allocator)
  ctx_seen := false
  collect_names(interp, idx, &found, &ctx_seen)

  slice.sort(found[:])
  unique := make([dynamic]string, 0, len(found), context.temp_allocator)
  for name, i in found {
    if i > 0 && found[i - 1] == name do continue
    append(&unique, name)
  }
  return unique[:], ctx_seen
}

@(private = "file")
collect_names :: proc(interp: ^Interpreter, idx: Node_Idx, out: ^[dynamic]string, uses_ctx: ^bool) {
  n := interp.ast.nodes[idx]

  #partial switch n.kind {
  case .Identifier:
    append(out, node_text(interp, idx))
    return
  case .Ctx_Expr:
    uses_ctx^ = true
    return
  }

  for i in 0 ..< int(n.children_count) {
    if child_is_a_spelling(interp, n, i) do continue
    collect_names(interp, interp.ast.extra_children[int(n.children_start) + i], out, uses_ctx)
  }
}

// Whether child `i` of `n` is an Identifier used as a literal spelling rather
// than as a variable. Each of these is a place the parser reuses the
// Identifier leaf for a name that is written down rather than looked up, and
// descending into one would invent a capture out of a field name.
@(private = "file")
child_is_a_spelling :: proc(interp: ^Interpreter, n: Node, i: int) -> bool {
  #partial switch n.kind {
  case .Binary_Expr:
    // [left, op_leaf, right]. `a.b` and `a !.b` name a field on the left
    // operand; the right leaf is that field's spelling, not a variable.
    if i != 2 do return false
    op := interp.ast.nodes[interp.ast.extra_children[int(n.children_start) + 1]].kind
    return op == .Op_Dot || op == .Op_CheckDot
  case .Table_Entry:
    // [key, value]. A `.name = v` key is the literal text; a `[expr] = v` key
    // is an expression, and Computed_Key is the only thing telling them apart.
    return i == 0 && .Computed_Key not_in n.flags
  case .Let_Bind:
    return i == 1 // [bound_expr, name_leaf, body]
  case .Pattern_Bind:
    return i == 1 // [pattern, name_leaf]
  case .Table_Pattern_Field:
    return i == 0 // [name_leaf]
  }
  return false
}
