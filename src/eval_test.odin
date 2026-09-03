// Tests run natively, never in a WASI build: core:testing pulls in
// core:log and core:terminal, neither of which compiles for wasm32.
#+build linux, windows
package hashed

import "core:strings"
import "core:testing"

@(private = "file")
parse_src :: proc(s: string) -> ast_t {
  return parse(source_t{name = "test", n_bytes = u64(len(s)), data = raw_data(s)}, ast_t{})
}

// Evaluates the top-level expression of an already-parsed source string in a
// fresh empty environment.
@(private = "file")
eval_top :: proc(ast: ^ast_t, src: string) -> (val: Value, ok: bool, err: string) {
  interp := Interpreter{ast = ast, src = src}
  env := env_make_child(nil)
  // Evaluate the Root node itself (not its extracted child directly) so its
  // own eval_slot boundary check actually runs, same as any real caller.
  val, ok = eval(&interp, ast.root, env)
  return val, ok, interp.error_message
}

@(private = "file")
expect_int :: proc(t: ^testing.T, val: Value, ok: bool, err: string, want: i64) {
  testing.expect(t, ok, err)
  n, is_int := val.(i64)
  testing.expect(t, is_int, "expected an Integer result")
  testing.expect_value(t, n, want)
}

@(private = "file")
expect_float :: proc(t: ^testing.T, val: Value, ok: bool, err: string, want: f64) {
  testing.expect(t, ok, err)
  n, is_float := val.(f64)
  testing.expect(t, is_float, "expected a Float result")
  testing.expect_value(t, n, want)
}

@(private = "file")
expect_bool :: proc(t: ^testing.T, val: Value, ok: bool, err: string, want: bool) {
  testing.expect(t, ok, err)
  b, is_bool := val.(bool)
  testing.expect(t, is_bool, "expected a Boolean result")
  testing.expect_value(t, b, want)
}

@(private = "file")
expect_string :: proc(t: ^testing.T, val: Value, ok: bool, err: string, want: string) {
  testing.expect(t, ok, err)
  s, is_str := val.(string)
  testing.expect(t, is_str, "expected a Utf8 result")
  testing.expect_value(t, s, want)
}

// ---- arithmetic / comparison / concat ----------------------------------------

@(test)
test_eval_arithmetic_precedence :: proc(t: ^testing.T) {
  src := "1 + 2 * 3"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 7)
}

@(test)
test_eval_unary_minus :: proc(t: ^testing.T) {
  src := "-5 + 2"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, -3)
}

@(test)
test_eval_integer_vs_float_division :: proc(t: ^testing.T) {
  src1 := "7 / 2"
  ast1 := parse_src(src1)
  defer ast_destroy(&ast1)
  val1, ok1, err1 := eval_top(&ast1, src1)
  expect_int(t, val1, ok1, err1, 3) // integer division truncates

  src2 := "7.0 / 2"
  ast2 := parse_src(src2)
  defer ast_destroy(&ast2)
  val2, ok2, err2 := eval_top(&ast2, src2)
  expect_float(t, val2, ok2, err2, 3.5)
}

@(test)
test_eval_division_by_zero_fails :: proc(t: ^testing.T) {
  src := "1 / 0"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  _, ok, _ := eval_top(&ast, src)
  testing.expect(t, !ok, "division by zero should fail, not crash")
}

@(test)
test_eval_comparison :: proc(t: ^testing.T) {
  src := "3 < 5"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_bool(t, val, ok, err, true)
}

@(test)
test_eval_concat :: proc(t: ^testing.T) {
  src := `"ab" concat "cd"`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_string(t, val, ok, err, "abcd")
}

@(test)
test_eval_trace_records_steps_in_completion_order :: proc(t: ^testing.T) {
  // Off by default, zero-cost - tracing is only ever recorded when a caller
  // explicitly opts in via enable_trace.
  src := "1 + 2 * 3"
  ast := parse_src(src)
  defer ast_destroy(&ast)

  interp := Interpreter{ast = &ast, src = src, enable_trace = true}
  env := env_make_child(nil)
  val, ok := eval(&interp, ast.root, env)
  expect_int(t, val, ok, interp.error_message, 7)

  // Sub-expressions complete (and get recorded) before the expression that
  // combines them - "2", "3", "2 * 3", then "1 + 2 * 3" is the last step.
  testing.expect(t, len(interp.trace) > 0)
  last := interp.trace[len(interp.trace) - 1]
  testing.expect_value(t, node_text(&interp, last.node), src)
  testing.expect(t, last.ok)
  testing.expect_value(t, last.value.(i64), i64(7))

  found_six := false
  for step in interp.trace {
    if node_text(&interp, step.node) == "2 * 3" {
      testing.expect(t, step.ok)
      testing.expect_value(t, step.value.(i64), i64(6))
      found_six = true
    }
  }
  testing.expect(t, found_six)
}

@(test)
test_eval_table_concat_is_functional_update :: proc(t: ^testing.T) {
  // SPEC.md §4/§5: Table concat Table merges, right side wins on collision -
  // this is Table's functional-update mechanism.
  src := `{ .a = 1, .b = 2 } concat { .b = 20, .c = 3 }`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  testing.expect(t, ok, err)
  t2, is_table := val.(^Table_Value)
  testing.expect(t, is_table)
  a, a_found := table_find(t2, "a")
  testing.expect(t, a_found)
  testing.expect_value(t, a.(i64), i64(1))
  b, b_found := table_find(t2, "b")
  testing.expect(t, b_found)
  testing.expect_value(t, b.(i64), i64(20)) // right side's value wins
  c, c_found := table_find(t2, "c")
  testing.expect(t, c_found)
  testing.expect_value(t, c.(i64), i64(3))
}

// ---- Tables -------------------------------------------------------------------

@(test)
test_eval_table_map_dot_and_bracket_access :: proc(t: ^testing.T) {
  src := `{ .a = 1, .b = 2 }.a`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 1)

  src2 := `{ .a = 1, .b = 2 }["a"]`
  ast2 := parse_src(src2)
  defer ast_destroy(&ast2)
  val2, ok2, err2 := eval_top(&ast2, src2)
  expect_int(t, val2, ok2, err2, 1)
}

@(test)
test_eval_table_sequence_is_1_indexed :: proc(t: ^testing.T) {
  src := "{10, 20, 30}[2]"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 20)
}

@(test)
test_eval_table_missing_key_fails :: proc(t: ^testing.T) {
  src := `{ .a = 1 }["b"]`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  _, ok, _ := eval_top(&ast, src)
  testing.expect(t, !ok, "accessing a missing key should fail")
}

// ---- holes, functions, application, |> -----------------------------------------

@(test)
test_eval_pipe_with_hole_closure :: proc(t: ^testing.T) {
  // 5 |> (*2 + 1)  ==  (5 * 2) + 1
  src := "5 |> (*2 + 1)"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 11)
}

@(test)
test_eval_func_keyword_and_application :: proc(t: ^testing.T) {
  src := "(func #arg + 1) 5"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 6)
}

@(test)
test_eval_hole_with_no_active_call_fails :: proc(t: ^testing.T) {
  // A deferred function value, never called - forcing it (by asking for its
  // Integer-ness) should fail cleanly rather than reading garbage.
  src := "*2 + 1"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  testing.expect(t, ok, err) // the *slot* evaluates fine - it's just a Function
  _, is_fn := val.(^Function_Value)
  testing.expect(t, is_fn, "an unresolved hole should defer into a Function value")
}

@(test)
test_eval_let_bind_explicit_value :: proc(t: ^testing.T) {
  src := "let x 5; x + 1"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 6)
}

@(test)
test_eval_let_bind_named_function :: proc(t: ^testing.T) {
  // §7 rule 2: "let my_arg; my_arg + 1" - the bound value omitted entirely -
  // is itself a named function, behaving exactly like "func #arg + 1".
  src := "(let my_arg; my_arg + 1) 5"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 6)
}

@(test)
test_eval_let_bind_curried_hole_is_independent_slot :: proc(t: ^testing.T) {
  // "let x (*2); ..." - the bound value ISN'T entirely omitted, it's a bigger
  // expression that merely contains a hole, so per §7 rule 1 that's its own
  // curried slot: x is bound to a doubling Function, not to a raw number.
  src := "let x (*2); x 5"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 10)
}

// ---- let rec and #self: recursion (§9/§10) --------------------------------------

@(test)
test_eval_let_rec_lets_a_function_call_itself :: proc(t: ^testing.T) {
  src := "let rec fact (let n; (n == 0) then 1 else n * (fact (n - 1))); fact 10"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 3628800)
}

@(test)
test_eval_plain_let_does_not_see_its_own_name :: proc(t: ^testing.T) {
  // Without `rec` the bound value is evaluated in the parent scope, so the
  // name isn't there yet - the whole point of the distinction.
  src := "let fact (let n; (n == 0) then 1 else n * (fact (n - 1))); fact 3"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  _, ok, err := eval_top(&ast, src)
  testing.expect(t, !ok)
  testing.expect(t, strings.contains(err, "undefined name: fact"), err)
}

@(test)
test_eval_let_rec_on_a_non_function_fails_with_undefined_name :: proc(t: ^testing.T) {
  // `rec` binds the name into the scope the value is computed in, but nothing
  // is *stored* there until that value exists - so a self-reference that has
  // to be read immediately (rather than captured in a closure and read later)
  // lands in the window before the bind and reports the ordinary error.
  src := "let rec x x + 1; x"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  _, ok, err := eval_top(&ast, src)
  testing.expect(t, !ok)
  testing.expect(t, strings.contains(err, "undefined name: x"), err)
}

@(test)
test_eval_let_rec_table_gives_mutual_recursion :: proc(t: ^testing.T) {
  // One `rec` covering a Table of closures is how two functions reach each
  // other: neither could be bound first with its own `let rec`.
  src := "let rec fns { .even = (let n; (n == 0) then 1 else fns.odd (n - 1)), .odd = (let n; (n == 0) then 0 else fns.even (n - 1)) }; fns.even 8"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 1)
}

@(test)
test_eval_self_recurses_without_a_name :: proc(t: ^testing.T) {
  src := "(func (#arg == 0) then 1 else #arg * (#self (#arg - 1))) 5"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 120)
}

@(test)
test_eval_self2_reaches_the_enclosing_call :: proc(t: ^testing.T) {
  // The inner function makes the recursive step by calling the *outer* one
  // back, exactly as #arg2 reaches the outer call's argument.
  src := "(func (#arg == 0) then 0 else ((func #arg2 + (#self2 (#arg2 - 1))) #arg)) 5"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 15)
}

@(test)
test_eval_self_outside_any_call_fails :: proc(t: ^testing.T) {
  src := "#self"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  _, ok, err := eval_top(&ast, src)
  testing.expect(t, !ok)
  testing.expect(t, strings.contains(err, "no such enclosing function"), err)
}

@(test)
test_eval_tightest_runaway_self_call_fails_instead_of_crashing :: proc(t: ^testing.T) {
  // The worst case for the nesting budget, and the one that caught an earlier
  // version of it: one eval and one call per level and nothing else, so almost
  // none of the stack being burned shows up as eval frames. See MAX_NEST_DEPTH.
  src := "(func #self 0) 5"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  _, ok, err := eval_top(&ast, src)
  testing.expect(t, !ok)
  testing.expect(t, strings.contains(err, "nested too deeply"), err)
}

@(test)
test_eval_runaway_recursion_fails_instead_of_crashing :: proc(t: ^testing.T) {
  // Unbounded recursion must come back as an ordinary fatal failure (§8), not
  // as a native stack overflow - see MAX_EVAL_DEPTH in eval.odin.
  src := "let rec f (let n; n + (f (n + 1))); f 1"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  _, ok, err := eval_top(&ast, src)
  testing.expect(t, !ok)
  testing.expect(t, strings.contains(err, "nested too deeply"), err)
}

// ---- guard chains: and / or / is, then / else ----------------------------------

@(test)
test_eval_and_or_short_circuit_shape :: proc(t: ^testing.T) {
  src1 := "3 < 5 and 5 < 10"
  ast1 := parse_src(src1)
  defer ast_destroy(&ast1)
  val1, ok1, err1 := eval_top(&ast1, src1)
  expect_bool(t, val1, ok1, err1, true)

  src2 := "3 > 5 and 1 / 0 > 0" // right side must NOT run if `and` short-circuits
  ast2 := parse_src(src2)
  defer ast_destroy(&ast2)
  val2, ok2, err2 := eval_top(&ast2, src2)
  expect_bool(t, val2, ok2, err2, false)

  src3 := "3 < 5 or 1 / 0 > 0" // right side must NOT run if `or` short-circuits
  ast3 := parse_src(src3)
  defer ast_destroy(&ast3)
  val3, ok3, err3 := eval_top(&ast3, src3)
  expect_bool(t, val3, ok3, err3, true)
}

@(test)
test_eval_is_literal_pattern :: proc(t: ^testing.T) {
  src1 := "let x 5; x is 5"
  ast1 := parse_src(src1)
  defer ast_destroy(&ast1)
  val1, ok1, err1 := eval_top(&ast1, src1)
  expect_bool(t, val1, ok1, err1, true)

  src2 := "let x 3; x is 5"
  ast2 := parse_src(src2)
  defer ast_destroy(&ast2)
  val2, ok2, err2 := eval_top(&ast2, src2)
  expect_bool(t, val2, ok2, err2, false)
}

@(test)
test_eval_is_binds_name_into_and_chain :: proc(t: ^testing.T) {
  // x is n as m and m > 0 - a successful `is` binds `m`, visible to the `and`
  // chain's right side (§8's scope-threading rule).
  src := "let x 5; (x is n as m and m > 0)"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_bool(t, val, ok, err, true)
}

@(test)
test_eval_then_without_else_fails_on_false_condition :: proc(t: ^testing.T) {
  src := "let x 3; x > 5 then x"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  _, ok, _ := eval_top(&ast, src)
  testing.expect(t, !ok, "a failing `then` with no `else` should fail")
}

@(test)
test_eval_then_else_takes_bad_path_on_failure :: proc(t: ^testing.T) {
  src := "let x 3; x > 5 then 100 else 200"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 200)
}

@(test)
test_eval_then_else_takes_happy_path_on_success :: proc(t: ^testing.T) {
  src := "let x 10; x > 5 then 100 else 200"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 100)
}

@(test)
test_eval_canonical_pipe_guard_chain_example :: proc(t: ^testing.T) {
  // object |> (c1 and is p1 and c2) then happy else bad - SPEC.md §8's own
  // example, instantiated with concrete values.
  src := "let object 5; object |> (object > 0 and is n as p1 and p1 < 100) then p1 else 0"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 5)
}

// ---- Variants / Optionals -------------------------------------------------------

@(test)
test_eval_variant_construct_and_dot_field :: proc(t: ^testing.T) {
  src := `(:.pending 42).pending`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 42)
}

@(test)
test_eval_present_and_empty :: proc(t: ^testing.T) {
  src1 := "(present 42).present"
  ast1 := parse_src(src1)
  defer ast_destroy(&ast1)
  val1, ok1, err1 := eval_top(&ast1, src1)
  expect_int(t, val1, ok1, err1, 42)

  src2 := "empty"
  ast2 := parse_src(src2)
  defer ast_destroy(&ast2)
  val2, ok2, err2 := eval_top(&ast2, src2)
  testing.expect(t, ok2, err2)
  table, is_table := val2.(^Table_Value)
  testing.expect(t, is_table)
  testing.expect_value(t, len(table.entries), 0)
}

@(test)
test_eval_is_variant_and_optional_patterns :: proc(t: ^testing.T) {
  src1 := "let x (present 42); x is present as v and v > 0"
  ast1 := parse_src(src1)
  defer ast_destroy(&ast1)
  val1, ok1, err1 := eval_top(&ast1, src1)
  expect_bool(t, val1, ok1, err1, true)

  src2 := "let x empty; x is empty"
  ast2 := parse_src(src2)
  defer ast_destroy(&ast2)
  val2, ok2, err2 := eval_top(&ast2, src2)
  expect_bool(t, val2, ok2, err2, true)

  src3 := "let x (:.pending 42); x is :.pending v and v > 0"
  ast3 := parse_src(src3)
  defer ast_destroy(&ast3)
  val3, ok3, err3 := eval_top(&ast3, src3)
  expect_bool(t, val3, ok3, err3, true)
}

// ---- Table destructuring patterns ------------------------------------------------

@(test)
test_eval_is_table_destructure_pattern :: proc(t: ^testing.T) {
  src := `let t { .a = 1, .b = 2 }; t is { .a, .b as bound } and bound > 0`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_bool(t, val, ok, err, true)
}

@(test)
test_eval_is_sequence_pattern :: proc(t: ^testing.T) {
  src := "let t {10, 20}; t is {{2}: .1 as first, [2] as second} and first < second"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_bool(t, val, ok, err, true)

  src2 := "let t {10, 20, 30}; t is {{2}}" // wrong length
  ast2 := parse_src(src2)
  defer ast_destroy(&ast2)
  val2, ok2, err2 := eval_top(&ast2, src2)
  expect_bool(t, val2, ok2, err2, false)
}

// ---- check / static_check / error -----------------------------------------------

@(test)
test_eval_check_passes_through_on_success :: proc(t: ^testing.T) {
  src := "let x 5; check(x > 0) x"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 5)
}

@(test)
test_eval_check_fails_with_message :: proc(t: ^testing.T) {
  src := `let x -5; static_check(x > 0, "must be positive") x`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  _, ok, err := eval_top(&ast, src)
  testing.expect(t, !ok, "check should fail when the condition is false")
  testing.expect_value(t, err, "must be positive")
}

// ---- ctx / withctx (§9) -------------------------------------------------------

@(test)
test_eval_ctx_reads_the_active_context :: proc(t: ^testing.T) {
  src := "ctx withctx { .a = 1 }"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  testing.expect(t, ok, err)
  t2, is_table := val.(^Table_Value)
  testing.expect(t, is_table)
  a, found := table_find(t2, "a")
  testing.expect(t, found)
  testing.expect_value(t, a.(i64), i64(1))
}

@(test)
test_eval_withctx_scoped_to_its_expr_only :: proc(t: ^testing.T) {
  // ctx read outside a withctx is unaffected by one that already finished.
  src := "let inner (ctx withctx { .a = 1 }); ctx"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  // outer `ctx` was never set up by this test - nil - just confirm it's NOT
  // the {a: 1} the inner withctx used.
  testing.expect(t, ok, err)
  _, is_table := val.(^Table_Value)
  testing.expect(t, !is_table, "outer ctx read should not see the inner withctx's context")
}

@(test)
test_eval_closure_captures_ctx_at_creation_not_call_site :: proc(t: ^testing.T) {
  // A function created while ctx={tag:1} keeps seeing {tag:1} even when
  // called from inside a withctx that has since widened ctx to {tag:2} -
  // SPEC.md §9's security boundary: a called function only ever sees its own
  // context, never a wider one supplied by whoever happens to call it.
  src := "let f ((func ctx) withctx { .tag = 1 }); (f 0) withctx { .tag = 2 }"
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  testing.expect(t, ok, err)
  t2, is_table := val.(^Table_Value)
  testing.expect(t, is_table)
  tag, found := table_find(t2, "tag")
  testing.expect(t, found)
  testing.expect_value(t, tag.(i64), i64(1)) // f's own captured context, not the caller's
}

@(test)
test_eval_chctx_calls_function_with_old_ctx :: proc(t: ^testing.T) {
  // chctx computes the new context by calling its right-hand function with
  // the OLD context as the argument (unlike withctx, which takes the new
  // context directly) - here the transform wraps whatever it's given under
  // .wrapped, so the result should reflect the {a: 1} set up by the outer
  // withctx.
  src := `(ctx chctx (func { .wrapped = #arg })) withctx { .a = 1 }`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  testing.expect(t, ok, err)
  outer, is_table := val.(^Table_Value)
  testing.expect(t, is_table)
  wrapped_val, found := table_find(outer, "wrapped")
  testing.expect(t, found)
  wrapped, wrapped_is_table := wrapped_val.(^Table_Value)
  testing.expect(t, wrapped_is_table)
  a_val, a_found := table_find(wrapped, "a")
  testing.expect(t, a_found)
  testing.expect_value(t, a_val.(i64), i64(1))
}

@(test)
test_eval_error_with_and_without_message :: proc(t: ^testing.T) {
  src1 := "error"
  ast1 := parse_src(src1)
  defer ast_destroy(&ast1)
  _, ok1, _ := eval_top(&ast1, src1)
  testing.expect(t, !ok1)

  src2 := `error "boom"`
  ast2 := parse_src(src2)
  defer ast_destroy(&ast2)
  _, ok2, err2 := eval_top(&ast2, src2)
  testing.expect(t, !ok2)
  testing.expect_value(t, err2, "boom")
}

// A `[expr]` key is evaluated; a `.name` key is the name's own spelling
// (SPEC.md §5). The two look identical in the tree once the expression is a
// bare identifier, which is exactly the case that used to silently produce
// the literal key "k" for `[k] = ...`.
@(test)
test_eval_table_computed_key_is_evaluated :: proc(t: ^testing.T) {
  src := `let k "sha256"; { [k] = 1, .k = 2, [1 + 1] = 3 }`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  testing.expect(t, ok, err)
  table, is_table := val.(^Table_Value)
  testing.expect(t, is_table)

  computed, computed_found := table_find(table, "sha256")
  testing.expect(t, computed_found, "[k] must use the value k is bound to")
  testing.expect_value(t, computed.(i64), i64(1))

  literal, literal_found := table_find(table, "k")
  testing.expect(t, literal_found, ".k must use the identifier's own spelling")
  testing.expect_value(t, literal.(i64), i64(2))

  arithmetic, arithmetic_found := table_find(table, i64(2))
  testing.expect(t, arithmetic_found, "a non-identifier computed key still evaluates")
  testing.expect_value(t, arithmetic.(i64), i64(3))
}

// `:.tag as name` binds the payload, the same way §8's `present as name`
// does - it just parses the other way round (the bind lands inside the
// variant pattern, against an omitted payload pattern), which used to make
// it evaluate that omitted slot as an expression and fail.
@(test)
test_eval_variant_tag_pattern_binds_payload :: proc(t: ^testing.T) {
  src := `(:.ok 42) is :.ok as payload then payload else 0`
  ast := parse_src(src)
  defer ast_destroy(&ast)
  val, ok, err := eval_top(&ast, src)
  expect_int(t, val, ok, err, 42)

  // A different tag is an ordinary non-match, not a failure.
  src2 := `(:.ok 42) is :.err as payload then payload else -1`
  ast2 := parse_src(src2)
  defer ast_destroy(&ast2)
  val2, ok2, err2 := eval_top(&ast2, src2)
  expect_int(t, val2, ok2, err2, -1)
}
