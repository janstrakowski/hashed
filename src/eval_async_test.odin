// Tests run natively, never in a WASI build: core:testing pulls in
// core:log and core:terminal, neither of which compiles for wasm32.
#+build linux, windows
package hashedbuild

import "core:testing"
import "core:time"

// ---- async (SPEC.md §2) ---------------------------------------------------
// Local copies of eval_test.odin's small helpers (those are file-private, so
// not reachable from here) - kept minimal, just what these tests need.

@(private = "file")
async_parse :: proc(s: string) -> ast_t {
  return parse(source_t{name = "test", n_bytes = u64(len(s)), data = raw_data(s)}, ast_t{})
}

@(private = "file")
async_eval_top :: proc(ast: ^ast_t, src: string) -> (val: Value, ok: bool, err: string) {
  interp := Interpreter{ast = ast, src = src}
  env := env_make_child(nil)
  val, ok = eval(&interp, ast.root, env)
  return val, ok, interp.error_message
}

@(private = "file")
async_expect_int :: proc(t: ^testing.T, val: Value, ok: bool, err: string, want: i64) {
  testing.expect(t, ok, err)
  n, is_int := val.(i64)
  testing.expect(t, is_int, "expected an Integer result")
  testing.expect_value(t, n, want)
}

@(private = "file")
async_expect_bool :: proc(t: ^testing.T, val: Value, ok: bool, err: string, want: bool) {
  testing.expect(t, ok, err)
  b, is_bool := val.(bool)
  testing.expect(t, is_bool, "expected a Boolean result")
  testing.expect_value(t, b, want)
}

@(test)
test_async_bare_top_level_is_not_auto_awaited :: proc(t: ^testing.T) {
  // Evaluating `async <expr>` produces a handle immediately, without
  // blocking - "pass 1: start it, don't wait" (eval_async.odin). Nothing
  // automatically forces it unless something actually consumes it.
  src := "async (1 + 2)"
  ast := async_parse(src)
  defer ast_destroy(&ast)
  val, ok, err := async_eval_top(&ast, src)
  testing.expect(t, ok, err)
  h, is_handle := val.(^Async_Handle)
  testing.expect(t, is_handle, "expected an un-awaited Async_Handle")

  interp := Interpreter{ast = &ast, src = src}
  resolved, rok := await_value(&interp, h)
  testing.expect(t, rok, interp.error_message)
  n, is_int := resolved.(i64)
  testing.expect(t, is_int, "expected an Integer once awaited")
  testing.expect_value(t, n, i64(3))
}

@(test)
test_async_used_in_arithmetic_is_awaited_automatically :: proc(t: ^testing.T) {
  // Arithmetic is one of the "needs a concrete value" choke points - both
  // operands get awaited without the source needing to do anything special.
  src := "(async 2) * (async 3)"
  ast := async_parse(src)
  defer ast_destroy(&ast)
  val, ok, err := async_eval_top(&ast, src)
  async_expect_int(t, val, ok, err, 6)
}

@(test)
test_async_failure_propagates_through_arithmetic :: proc(t: ^testing.T) {
  src := `1 + (async (error "boom"))`
  ast := async_parse(src)
  defer ast_destroy(&ast)
  _, ok, err := async_eval_top(&ast, src)
  testing.expect(t, !ok, "an async failure should fail the whole expression")
  testing.expect_value(t, err, "boom")
}

@(test)
test_async_table_entries_all_resolve :: proc(t: ^testing.T) {
  src := "{async 1, async 2, async 3}"
  ast := async_parse(src)
  defer ast_destroy(&ast)
  val, ok, err := async_eval_top(&ast, src)
  testing.expect(t, ok, err)
  tbl, is_table := val.(^Table_Value)
  testing.expect(t, is_table, "expected a Table")
  if is_table {
    testing.expect_value(t, len(tbl.entries), 3)
    for entry, i in tbl.entries {
      n, is_int := entry.value.(i64)
      testing.expect(t, is_int, "table entry should already be awaited, not a raw handle")
      testing.expect_value(t, n, i64(i + 1))
    }
  }
}

@(test)
test_async_then_else_discarded_branch_still_poisons :: proc(t: ^testing.T) {
  // §2: the untaken branch's async work still has to be started and awaited
  // to completion - if it fails, that poisons the whole evaluation even
  // though its value was never going to be used.
  src := `1 > 0 then 1 else (async (error "boom"))`
  ast := async_parse(src)
  defer ast_destroy(&ast)
  _, ok, err := async_eval_top(&ast, src)
  testing.expect(t, !ok, "a failing async in the untaken else-branch should still fail the expression")
  testing.expect_value(t, err, "boom")
}

@(test)
test_async_then_else_ordinary_case_unaffected :: proc(t: ^testing.T) {
  // Same shape as above, but the discarded branch's async now succeeds - the
  // overall result should still just be the taken branch's value.
  src := `1 > 0 then 1 else (async 999)`
  ast := async_parse(src)
  defer ast_destroy(&ast)
  val, ok, err := async_eval_top(&ast, src)
  async_expect_int(t, val, ok, err, 1)
}

@(test)
test_async_and_discarded_side_still_poisons :: proc(t: ^testing.T) {
  // `and` ordinarily short-circuits on a false left side - but §2's async
  // exception says the right side still has to run (and be awaited) if it
  // contains async, even though its Boolean result gets discarded.
  src := `1 < 0 and (async (error "boom"))`
  ast := async_parse(src)
  defer ast_destroy(&ast)
  _, ok, err := async_eval_top(&ast, src)
  testing.expect(t, !ok, "a failing async on and's short-circuited side should still fail")
  testing.expect_value(t, err, "boom")
}

@(test)
test_async_or_discarded_side_still_poisons :: proc(t: ^testing.T) {
  src := `1 > 0 or (async (error "boom"))`
  ast := async_parse(src)
  defer ast_destroy(&ast)
  _, ok, err := async_eval_top(&ast, src)
  testing.expect(t, !ok, "a failing async on or's short-circuited side should still fail")
  testing.expect_value(t, err, "boom")
}

@(test)
test_async_and_or_without_async_still_short_circuit :: proc(t: ^testing.T) {
  // No async anywhere - ordinary short-circuiting must be completely
  // unaffected (the contains_async_anywhere check should cost nothing here
  // beyond a cheap structural scan, and never force extra evaluation).
  src := `1 < 0 and (error "should never run")`
  ast := async_parse(src)
  defer ast_destroy(&ast)
  val, ok, err := async_eval_top(&ast, src)
  async_expect_bool(t, val, ok, err, false)
}

@(private = "file")
slow_echo_native :: proc(interp: ^Interpreter, closure: Value, arg: Value) -> (Value, bool) {
  time.sleep(40 * time.Millisecond)
  return arg, true
}

@(test)
test_async_actually_runs_concurrently :: proc(t: ^testing.T) {
  // Two independently-async'd 40ms operations should overlap, not serialize -
  // proof that `async` fires real background work rather than just being a
  // no-op wrapper. Generous threshold (well under the 80ms two serial calls
  // would take, comfortably above the ~40ms true concurrency would take) to
  // stay robust against scheduler jitter.
  src := "(async (slow 1)) + (async (slow 2))"
  ast := async_parse(src)
  defer ast_destroy(&ast)
  env := env_make_child(nil)
  slow_fn := new(Function_Value)
  slow_fn.native = slow_echo_native
  env_bind(env, "slow", slow_fn)
  interp := Interpreter{ast = &ast, src = src}

  start := time.now()
  val, ok := eval(&interp, ast.root, env)
  elapsed := time.since(start)

  testing.expect(t, ok, interp.error_message)
  n, is_int := val.(i64)
  testing.expect(t, is_int, "expected an Integer result")
  testing.expect_value(t, n, i64(3))
  testing.expect(t, elapsed < 65 * time.Millisecond, "two async ops should run concurrently, not serially")
}
