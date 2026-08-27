package hashedbuild

import "core:strings"
import "core:sync"
import "core:thread"

// SPEC.md §2's `async`. The two-pass description there ("pass 1 starts every
// async immediately without waiting; pass 2 walks the same route again,
// awaiting each one in order") is implemented here as an ordinary fire/join
// pair rather than as two literal tree walks:
//
//   - `async <expr>` (see eval's dispatcher) spawns `<expr>`'s evaluation on
//     a real OS thread right away and returns a `^Async_Handle` immediately,
//     never blocking - that alone *is* "pass 1: start it, don't wait".
//   - `await_value` resolves a handle (joining its thread) into its real
//     result, or propagates its failure - and passes any other Value through
//     completely untouched. Inserted at the small set of places that
//     genuinely need a *concrete* value (arithmetic/comparison/concat
//     operands, a call target, a ctx swap, ...; see their call sites in
//     eval.odin), this reproduces "pass 2 awaits on the way back" for free,
//     in left-to-right/nesting order, without a second tree walk - and costs
//     nothing when no `async` exists anywhere, since nothing ever produces a
//     handle for it to resolve (matching "if pass 1 finds no async anywhere,
//     pass 2 is skipped entirely").
//   - Firing several sibling `async`s before awaiting any of them (see
//     eval_table_construct) is what makes them actually run concurrently
//     with each other, not just with surrounding sync code.
Async_Handle :: struct {
  th:     ^thread.Thread,
  interp: Interpreter, // this async's own independent sub-evaluation (own arg_stack snapshot, own ctx)
  body:   Node_Idx,
  env:    ^Env,

  mu:            sync.Mutex, // guards the join/result transition below, in case the same handle is awaited from more than one goroutine
  awaited:       bool,
  result_value:  Value,
  result_ok:     bool,
  error_message: string, // owned; only set when !result_ok
}

@(private = "file")
async_thread_proc :: proc(t: ^thread.Thread) {
  h := cast(^Async_Handle)t.data
  h.result_value, h.result_ok = eval(&h.interp, h.body, h.env)
  if !h.result_ok do h.error_message = strings.clone(h.interp.error_message)
}

// Starts `body` (evaluated under `env`) running on a new thread right now,
// returning a handle to it without waiting. The new thread gets its own
// Interpreter - sharing the read-only `ast`/`src`, a snapshot of the current
// `arg_stack` (so `#arg`/a Hole inside the async body resolves exactly as it
// would have synchronously), the current `ctx` (captured by value, same as a
// closure would), and the current `discard_depth` (a discarded then/else or
// and/or side that itself spawns an async is still discarded). Its own
// trace state (Steps panel) is never propagated - that mechanism's full,
// synchronous-only trace doesn't have a meaningful cross-thread story. Its
// *debugger* is propagated, though: this is what lets a paused, stepping
// debug run see into `async` at all, as one more task in the same shared,
// single-tree log (see debugger.odin) rather than a black box that just
// silently finishes in the background.
spawn_async :: proc(interp: ^Interpreter, body: Node_Idx, env: ^Env) -> ^Async_Handle {
  h := new(Async_Handle)
  h.body = body
  h.env = env
  h.interp = Interpreter{
    ast           = interp.ast,
    src           = interp.src,
    current_ctx   = interp.current_ctx,
    base_dir_fd   = interp.base_dir_fd,
    has_base_dir  = interp.has_base_dir,
    debugger      = interp.debugger,
    discard_depth = interp.discard_depth,
  }
  h.interp.arg_stack = make([dynamic]Value, len(interp.arg_stack))
  copy(h.interp.arg_stack[:], interp.arg_stack[:])

  h.th = thread.create(async_thread_proc)
  h.th.data = h
  thread.start(h.th)
  if interp.debugger != nil do register_debugger_task(interp.debugger, h)
  return h
}

// Resolves `v` into a concrete value: joins and unpacks an `^Async_Handle`
// (propagating its failure as an ordinary evaluation failure - this is what
// makes an async failure "poison the whole well" the moment anything actually
// needs its value), or passes any other Value through unchanged. Safe to
// call unconditionally at any point a concrete value is needed - it's a
// no-op whenever `async` isn't involved, which is the overwhelmingly common
// case.
await_value :: proc(interp: ^Interpreter, v: Value) -> (Value, bool) {
  h, is_async := v.(^Async_Handle)
  if !is_async do return v, true

  sync.mutex_lock(&h.mu)
  if !h.awaited {
    // Marked (and later unmarked) *while still holding h.mu* - a second
    // concurrent await_value call on the same handle blocks on this same
    // mutex rather than double-joining the thread, so the marker's lifetime
    // exactly matches the one real join underneath it.
    if interp.debugger != nil do mark_awaiting(interp.debugger, h.body, true)
    thread.join(h.th)
    if interp.debugger != nil do mark_awaiting(interp.debugger, h.body, false)
    h.awaited = true
  }
  sync.mutex_unlock(&h.mu)

  if !h.result_ok do return fail(interp, h.error_message)
  return h.result_value, true
}

// A blunt, purely structural scan for whether `node`'s subtree contains an
// `async` anywhere - deliberately ignoring the hole-boundary rules used
// elsewhere (§7's contains_hole_shallow stops at call/pipe/and/or operands;
// this does not), matching §2's "found without special-casing... regardless
// of depth". Used only to decide whether a `then`/`else` or `and`/`or`
// branch that *wouldn't* ordinarily be evaluated must still be walked (for
// its async side effects) even though its value ends up discarded - see
// eval_then_or_else and eval_guard_chain. A syntactic over-approximation
// (e.g. a `func async ...` value that's merely referenced, never called,
// still counts) is harmless here: it can only cause a harmless extra
// evaluation of an otherwise-skipped branch, never a wrong result.
contains_async_anywhere :: proc(ast: ^ast_t, node: Node_Idx) -> bool {
  n := ast.nodes[node]
  if n.kind == .Async_Expr do return true
  start := int(n.children_start)
  for i in 0 ..< int(n.children_count) {
    if contains_async_anywhere(ast, ast.extra_children[start + i]) do return true
  }
  return false
}
