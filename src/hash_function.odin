package hashedbuild

import "core:slice"
import "core:strconv"
import "core:strings"

// The Function half of SPEC.md §6's "every value is hashable", which §15 needs
// before `cached` can exist at all: the cache key is the hash of the cached
// expression *treated as a function*, so a closure has to have a digest.
//
// A closure is three things, and the digest mixes exactly those three:
//
//   1. **its code** - the AST subtree of its body, encoded structurally, so
//      that reformatting an expression or writing a comment inside it does
//      not change the key;
//   2. **its captured `ctx`** (§9), whole - which is why ctx.cache had to
//      become hashable (hash.odin's TAG_CACHE) rather than staying the
//      "no identity" case it was;
//   3. **the free names its code actually uses**, each paired with the value
//      it resolves to in the closure's environment.
//
// (3) is the part that has to be right for `cached` to be *correct* rather
// than merely deterministic. Hashing the code alone would give `cached x + 1`
// one key for every value of `x`, so the second call would happily hand back
// the first call's answer. Hashing the whole environment instead would be
// correct but useless - the global scope is in there, and so is every
// unrelated binding in every enclosing `let`.
//
// **The collection is deliberately conservative.** free_names below gathers
// every Identifier that sits in a value position anywhere in the subtree,
// without tracking which of them an inner `let` or pattern binder has already
// bound. So a name the expression shadows locally is still included, if a
// binding of that name also exists outside. That direction is safe: an extra
// name can only split one cache entry into two, never merge two into one.
// Under-collecting is the direction that would return a wrong value, and it
// cannot happen here - every name a lookup could resolve is offered to the
// lookup.
//
// Names that don't resolve are skipped rather than hashed as "absent": an
// unresolvable name is either locally bound (so not part of the closure's
// captured state) or genuinely unbound (so the expression fails when it runs,
// and never gets as far as storing anything).

// A closure being hashed right now, so a recursive one terminates. `let rec f`
// puts `f` in its own environment, so f's free-name digest reaches f again;
// the second visit hashes as a back-reference to the enclosing occurrence
// instead of recursing. The distance is counted from the top of the stack, so
// two structurally identical recursive closures still hash alike.
Seen_Stack :: [dynamic]^Function_Value

function_digest :: proc(f: ^Function_Value, seen: ^Seen_Stack = nil) -> (Value_Digest, Hash_Error) {
  if f.native != nil {
    // A proc address is not stable from one run to the next, so a native
    // hashes as the name it is bound under plus whatever it captured -
    // see Function_Value.native_name.
    closure_d, err := value_digest(f.native_closure, seen)
    if err != .None do return {}, err
    return mix_digests(TAG_NATIVE, sha256_tagged(TAG_UTF8, transmute([]u8)f.native_name), closure_d, nil), .None
  }

  if f.ast == nil do return {}, .Function_Ast

  stack: Seen_Stack
  s := seen
  if s == nil {
    stack = make(Seen_Stack, 0, 8, context.temp_allocator)
    s = &stack
  }
  for entry, i in s^ {
    if entry == f {
      depth := len(s^) - i // 1 = the closure immediately enclosing this point
      back: [2]u8 = {u8(depth), u8(depth >> 8)}
      return sha256_tagged(TAG_FUNCTION, back[:]), .None
    }
  }
  append(s, f)
  defer pop(s)

  code_d := ast_digest(f.ast, f.src, f.body)
  ctx_d, ctx_err := value_digest(f.ctx, s)
  if ctx_err != .None do return {}, ctx_err
  free_d, free_err := free_names_digest(f, s)
  if free_err != .None do return {}, free_err

  return mix_digests(TAG_FUNCTION, code_d, ctx_d, free_d[:]), .None
}

// ---- the code ---------------------------------------------------------------

// A node hashes as its kind, its flags, the digest of its own source text, and
// the digests of its children in order. Fixed-width throughout (2 + 1 + 32,
// then a whole number of digests), so the encoding stays unambiguous under
// hash.odin's Merkle rule.
//
// Source text is mixed in for leaves only - a leaf is where the text carries
// meaning the kind does not (which Identifier, which literal). An inner node's
// span is just whatever its children cover, so leaving it out is what makes
// the digest insensitive to whitespace, line breaks and comments.
//
// It is *not* insensitive to how a literal is spelled: `1_000` and `1000` are
// different text, so they get different keys for the same value. Conservative
// in the harmless direction again - a split entry, never a wrong hit.
@(private = "file")
ast_digest :: proc(ast: ^ast_t, src: string, node: Node_Idx) -> Value_Digest {
  n := ast.nodes[node]

  head: [3]u8 = {u8(u16(n.kind)), u8(u16(n.kind) >> 8), u8(transmute(u8)n.flags)}
  text_d: Value_Digest
  if n.children_count == 0 {
    start := int(n.span.start)
    end := int(n.span.end)
    if start <= end && end <= len(src) {
      text_d = sha256_tagged(TAG_UTF8, transmute([]u8)src[start:end])
    } else {
      text_d = sha256_tagged(TAG_UTF8, nil) // a synthesized node has no text
    }
  } else {
    text_d = sha256_tagged(TAG_UTF8, nil)
  }

  buf := make([]u8, len(head) + DIGEST_SIZE + int(n.children_count) * DIGEST_SIZE, context.temp_allocator)
  copy(buf[:], head[:])
  copy(buf[len(head):], text_d[:])
  for i in 0 ..< int(n.children_count) {
    child_d := ast_digest(ast, src, ast.extra_children[int(n.children_start) + i])
    copy(buf[len(head) + DIGEST_SIZE + i * DIGEST_SIZE:], child_d[:])
  }
  return sha256_tagged(TAG_AST_NODE, buf)
}

// ---- the free names ---------------------------------------------------------

@(private = "file")
free_names_digest :: proc(f: ^Function_Value, seen: ^Seen_Stack) -> (Value_Digest, Hash_Error) {
  names := make([dynamic]string, 0, 8, context.temp_allocator)
  collect_names(f.ast, f.src, f.body, &names)
  slice.sort(names[:])

  pairs := make([dynamic][2]Value_Digest, 0, len(names), context.temp_allocator)
  last := ""
  for name in names {
    if name == last do continue // an identifier used twice contributes once
    last = name
    val, found := env_lookup(f.env, name)
    if !found do continue // locally bound, or unbound and about to fail anyway
    vd, err := value_digest(val, seen)
    if err != .None do return {}, err
    append(&pairs, [2]Value_Digest{sha256_tagged(TAG_UTF8, transmute([]u8)name), vd})
  }

  buf := make([]u8, len(pairs) * 2 * DIGEST_SIZE, context.temp_allocator)
  for i in 0 ..< len(pairs) {
    copy(buf[i * 2 * DIGEST_SIZE:], pairs[i][0][:])
    copy(buf[(i * 2 + 1) * DIGEST_SIZE:], pairs[i][1][:])
  }
  return sha256_tagged(TAG_FREE_NAMES, buf), .None
}

// Every Identifier in the subtree that stands for a *variable*, as opposed to
// a literal name the grammar happens to spell the same way. The exclusions
// below are the whole list of the latter; see this file's header for why
// over-collecting beyond them is deliberate and safe.
@(private = "file")
collect_names :: proc(ast: ^ast_t, src: string, node: Node_Idx, out: ^[dynamic]string) {
  n := ast.nodes[node]

  if n.kind == .Identifier {
    start := int(n.span.start)
    end := int(n.span.end)
    if start <= end && end <= len(src) do append(out, src[start:end])
    return
  }

  skip := -1 // index of the one child to walk past, if any
  #partial switch n.kind {
  case .Binary_Expr:
    // `.field`, and `!.name` - the right operand names a Table key literally,
    // it is not a variable reference. (`[expr]` and `!: expr` are the dynamic
    // forms and do read variables, so they are not excluded.)
    if n.children_count >= 3 {
      op := ast.nodes[ast.extra_children[int(n.children_start) + 1]].kind
      if op == .Op_Dot || op == .Op_CheckDot do skip = 2
    }
  case .Table_Entry:
    // `.name = v` writes the literal key `name`; `[name] = v` (Computed_Key)
    // reads the variable.
    if .Computed_Key not_in n.flags do skip = 0
  case .Let_Bind:
    skip = 1 // the name being introduced
  case .Pattern_Bind:
    skip = 1 // `<pattern> as <name>`
  case .Table_Pattern_Field:
    skip = 0 // a bare `.field` selector
  }

  for i in 0 ..< int(n.children_count) {
    if i == skip do continue
    collect_names(ast, src, ast.extra_children[int(n.children_start) + i], out)
  }
}

// ---- what a closure does *not* capture --------------------------------------

// `#arg`/`#argN`, `#self`/`#selfN` and a bare Hole are dynamic lookups into the
// interpreter's own stacks (§9), deliberately so - that is what lets them reach
// through a hard boundary the way a lexical name cannot. They are therefore
// *not* in the closure's environment, and function_digest above cannot see
// them. Left at that, `let f func (cached (#arg + 1)); f 1` and `f 10` would
// share one entry, and the second call would answer 2.
//
// So `cached` mixes them in separately, and this is that mix: the stack entries
// the expression could possibly reach, in order, deepest reach last.
//
// **How far it can reach is decided statically**, by the largest N written
// anywhere in the expression (a bare `#arg` or Hole counting as 1). That bound
// holds even for a `#argN` nested inside a function the expression itself
// calls: entering that function pushes a frame, so an N there reaches N-1 of
// the frames that were already on the stack. Anything the expression pushes for
// itself follows from its code and its captured environment, both of which the
// closure digest already covers.
//
// A level that isn't on the stack hashes as Nothing - the expression will fail
// when it runs, and it has not got as far as storing anything.
implicit_reach_digest :: proc(base: Value_Digest, args: []Value, selves: []Value) -> (Value_Digest, Hash_Error) {
  buf := make([]u8, (len(args) + len(selves)) * DIGEST_SIZE, context.temp_allocator)
  i := 0
  for group in ([][]Value{args, selves}) {
    for v in group {
      d, err := value_digest(v)
      if err != .None do return {}, err
      copy(buf[i * DIGEST_SIZE:], d[:])
      i += 1
    }
  }
  return mix_digests(TAG_IMPLICIT_REACH, base, sha256_tagged(TAG_FREE_NAMES, buf), nil), .None
}

// How deep into each stack the expression can reach - see above. Zero for both
// means it reads neither, and `cached` skips the mix entirely, so an ordinary
// expression's key is unchanged by any of this.
implicit_reach :: proc(ast: ^ast_t, src: string, node: Node_Idx, max_arg: ^int, max_self: ^int) {
  n := ast.nodes[node]

  #partial switch n.kind {
  case .Hole:
    // An evaluated Hole is `#arg` by another spelling (eval.odin).
    if max_arg^ < 1 do max_arg^ = 1
  case .Implicit_Name:
    start, end := int(n.span.start), int(n.span.end)
    if start <= end && end <= len(src) do note_implicit(src[start:end], max_arg, max_self)
  }

  for i in 0 ..< int(n.children_count) {
    implicit_reach(ast, src, ast.extra_children[int(n.children_start) + i], max_arg, max_self)
  }
}

// "#arg" / "#arg3" / "#self" / "#self2". Anything else - `#context`, or a
// malformed name - is left alone: it has no stack to reach into, and it fails
// when the expression runs.
@(private = "file")
note_implicit :: proc(text: string, max_arg: ^int, max_self: ^int) {
  rest := text[1:] if len(text) > 0 else text

  target: ^int
  prefix: string
  switch {
  case strings.has_prefix(rest, "arg"):  target, prefix = max_arg, "arg"
  case strings.has_prefix(rest, "self"): target, prefix = max_self, "self"
  case: return
  }

  level := 1
  if digits := rest[len(prefix):]; len(digits) > 0 {
    v, ok := strconv.parse_int(digits)
    if !ok do return
    level = v
  }
  if level > target^ do target^ = level
}
