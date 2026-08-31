package hashedbuild

import "core:strconv"
import "core:strings"

// The part of a cached expression's identity that a *closure* digest cannot
// carry, and the reason §15's cache key is not simply `sha256 <the closure>`.
//
// hash_function.odin encodes a closure as its body's shape plus the values it
// captures, which is exactly right for a Function value. But `#arg`/`#argN`,
// `#self`/`#selfN` and a bare Hole are not captures: they are dynamic lookups
// into the interpreter's own stacks (§9), which is precisely what lets them
// reach through a hard boundary the way a lexical name cannot. Nothing about
// them is in the closure, so nothing about them is in its digest.
//
// Left there, `let f func (cached (#arg + 1))` would have one entry for every
// argument, and `f 10` would answer 2. `cached` therefore mixes the reachable
// stack entries in on top of the closure digest (see eval.odin's eval_cached).
//
// **How far an expression can reach is decided statically**, by the largest N
// written anywhere in it - a bare `#arg`, `#self` or Hole counting as 1. That
// bound holds even for a `#argN` written inside a function the expression
// itself calls: entering that function pushes a frame, so an N there reaches
// N-1 of the frames that were already on the stack when `cached` ran. Whatever
// the expression pushes for itself follows from its code and its captured
// environment, and the closure digest already covers both.
//
// An expression that mentions none of them is left alone entirely - its key is
// the closure digest unchanged, so this costs nothing in the ordinary case.

// `base`, plus the stack entries the expression can reach, innermost first.
// Tagged separately from everything in hash.odin because it is not a value's
// digest: it is a cache key, and only `cached` ever computes one.
implicit_reach_digest :: proc(
  base: Value_Digest, args: []Value, selves: []Value, interp: ^Interpreter,
) -> (Value_Digest, Hash_Fail) {
  s: Digest_Stream
  digest_stream_begin(&s, TAG_IMPLICIT_REACH)
  digest_stream_digest(&s, base)

  for group in ([][]Value{args, selves}) {
    count: [8]u8
    n := u64(len(group))
    for i in 0 ..< 8 do count[i] = u8((n >> (8 * uint(i))) & 0xff)
    digest_stream_bytes(&s, count[:])
    for v in group {
      d, f := value_digest(v, interp)
      if f.kind != .None do return {}, f
      digest_stream_digest(&s, d)
    }
  }
  return digest_stream_end(&s), HASH_OK
}

// How deep into each stack the expression can reach. Zero for both means it
// reads neither.
implicit_reach :: proc(interp: ^Interpreter, idx: Node_Idx, max_arg: ^int, max_self: ^int) {
  n := interp.ast.nodes[idx]

  #partial switch n.kind {
  case .Hole:
    // An evaluated Hole is `#arg` by another spelling (eval.odin).
    if max_arg^ < 1 do max_arg^ = 1
  case .Implicit_Name:
    note_implicit(node_text(interp, idx), max_arg, max_self)
  }

  for i in 0 ..< int(n.children_count) {
    implicit_reach(interp, interp.ast.extra_children[int(n.children_start) + i], max_arg, max_self)
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
