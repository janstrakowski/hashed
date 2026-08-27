// Tests run natively, never in a WASI build: core:testing pulls in
// core:log and core:terminal, neither of which compiles for wasm32.
#+build linux
package hashedbuild

import "core:testing"

@(private = "file")
source_from_string :: proc(s: string) -> source_t {
  return source_t{name = "test", n_bytes = u64(len(s)), data = raw_data(s)}
}

@(private = "file")
parse_string :: proc(s: string) -> ast_t {
  return parse(source_from_string(s), ast_t{})
}

// root -> [expr]; returns the expr node's index.
@(private = "file")
root_expr :: proc(ast: ^ast_t) -> Node_Idx {
  root := ast.nodes[ast.root]
  return ast.extra_children[root.children_start]
}

@(private = "file")
child :: proc(ast: ^ast_t, n: Node_Idx, i: int) -> Node_Idx {
  node := ast.nodes[n]
  return ast.extra_children[int(node.children_start) + i]
}

@(private = "file")
kind_of :: proc(ast: ^ast_t, n: Node_Idx) -> Node_Kind { return ast.nodes[n].kind }

@(private = "file")
text_of :: proc(ast: ^ast_t, src: string, n: Node_Idx) -> string {
  span := ast.nodes[n].span
  return src[span.start:span.end]
}

@(private = "file")
child_count :: proc(ast: ^ast_t, n: Node_Idx) -> int { return int(ast.nodes[n].children_count) }

@(test)
test_number_literal :: proc(t: ^testing.T) {
  ast := parse_string("42")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Number_Literal)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_arithmetic_precedence :: proc(t: ^testing.T) {
  // 1 + 2 * 3  ==  1 + (2 * 3)
  ast := parse_string("1 + 2 * 3")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  op := child(&ast, e, 1)
  testing.expect_value(t, kind_of(&ast, op), Node_Kind.Op_Plus)
  rhs := child(&ast, e, 2)
  testing.expect_value(t, kind_of(&ast, rhs), Node_Kind.Binary_Expr)
  rhs_op := child(&ast, rhs, 1)
  testing.expect_value(t, kind_of(&ast, rhs_op), Node_Kind.Op_Star)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_unary_minus_reads_as_math :: proc(t: ^testing.T) {
  // -2-1 == (-2) - 1, per SPEC.md §4
  ast := parse_string("-2-1")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr) // outer: subtraction
  op := child(&ast, e, 1)
  testing.expect_value(t, kind_of(&ast, op), Node_Kind.Op_Minus)
  lhs := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, lhs), Node_Kind.Unary_Expr) // -2
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_application_binds_tighter_than_unary_minus :: proc(t: ^testing.T) {
  // -f x == -(f x)
  src := "-f x"
  ast := parse_string(src)
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Unary_Expr)
  operand := child(&ast, e, 1)
  testing.expect_value(t, kind_of(&ast, operand), Node_Kind.Binary_Expr) // f x
  call_op := child(&ast, operand, 1)
  testing.expect_value(t, kind_of(&ast, call_op), Node_Kind.Op_Call)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_application_left_associative_chain :: proc(t: ^testing.T) {
  // f x y == (f x) y
  ast := parse_string("f x y")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Op_Call)
  inner := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, inner), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, inner, 1)), Node_Kind.Op_Call)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_minus_after_expr_is_always_binary :: proc(t: ^testing.T) {
  // f -x == f - x, not f (-x) - the deliberate disambiguation rule
  ast := parse_string("f -x")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Op_Minus)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_dot_and_bracket_postfix_chain :: proc(t: ^testing.T) {
  // t.field[0] - dot binds first, then bracket, both tighter than application
  ast := parse_string("t.field[0]")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr) // outer: bracket
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Op_Bracket)
  inner := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, inner), Node_Kind.Binary_Expr) // t.field
  testing.expect_value(t, kind_of(&ast, child(&ast, inner, 1)), Node_Kind.Op_Dot)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_table_sequence_literal :: proc(t: ^testing.T) {
  src := "{ 1, 2, 3 }"
  ast := parse_string(src)
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Table_Construct)
  testing.expect_value(t, ast.nodes[e].children_count, u16(3))
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_table_map_literal :: proc(t: ^testing.T) {
  src := `{ .a = 1, [b] = 2 }`
  ast := parse_string(src)
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Table_Construct)
  testing.expect_value(t, ast.nodes[e].children_count, u16(2))
  entry0 := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, entry0), Node_Kind.Table_Entry)
  testing.expect_value(t, kind_of(&ast, child(&ast, entry0, 0)), Node_Kind.Identifier)
  entry1 := child(&ast, e, 1)
  testing.expect_value(t, kind_of(&ast, child(&ast, entry1, 0)), Node_Kind.Identifier) // `b` as a key expr
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_table_mixed_forms_is_an_error :: proc(t: ^testing.T) {
  ast := parse_string("{ .a = 1, 2 }")
  defer ast_destroy(&ast)
  testing.expect(t, len(ast.errors) > 0, "expected mixing map/sequence entries to be flagged")
}

@(test)
test_and_or_concat_precedence :: proc(t: ^testing.T) {
  // a or b and c concat d  ==  a or (b and (c concat d))
  ast := parse_string("a or b and c concat d")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Op_Or)
  rhs := child(&ast, e, 2)
  testing.expect_value(t, kind_of(&ast, child(&ast, rhs, 1)), Node_Kind.Op_And)
  rhs2 := child(&ast, rhs, 2)
  testing.expect_value(t, kind_of(&ast, child(&ast, rhs2, 1)), Node_Kind.Op_Concat)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_parenthesized_overrides_precedence :: proc(t: ^testing.T) {
  ast := parse_string("(1 + 2) * 3")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Op_Star)
  lhs := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, lhs), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, lhs, 1)), Node_Kind.Op_Plus)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_string_and_comment_lexing :: proc(t: ^testing.T) {
  src := "\"hi\" // trailing comment\n"
  ast := parse_string(src)
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.String_Literal)
  testing.expect_value(t, text_of(&ast, src, e), `"hi"`)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_numeric_literal_forms :: proc(t: ^testing.T) {
  for src in ([]string{"0x2A", "0o52", "0b101010", "0.5", "1.5e10", "1_000_000"}) {
    ast := parse_string(src)
    defer ast_destroy(&ast)
    e := root_expr(&ast)
    testing.expect_value(t, kind_of(&ast, e), Node_Kind.Number_Literal)
    testing.expect_value(t, len(ast.errors), 0)
  }
}

@(test)
test_trailing_operand_is_a_hole_not_an_error :: proc(t: ^testing.T) {
  // `1 +` is `1 + <omitted>` per §7 - a legitimate function, not a parse error.
  ast := parse_string("1 +")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  rhs := child(&ast, e, 2)
  testing.expect_value(t, kind_of(&ast, rhs), Node_Kind.Hole)
}

@(test)
test_error_recovery_genuine_syntax_error :: proc(t: ^testing.T) {
  ast := parse_string("1 + )")
  defer ast_destroy(&ast)
  testing.expect(t, len(ast.errors) > 0, "expected an error for the stray ')'")
}

// ---- omission holes (§7) ----------------------------------------------------

@(test)
test_hole_leading_operand :: proc(t: ^testing.T) {
  // (*3+4) - leading hole, section-style
  ast := parse_string("(*3+4)")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr) // outer: +
  lhs := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, lhs), Node_Kind.Binary_Expr) // *
  testing.expect_value(t, kind_of(&ast, child(&ast, lhs, 0)), Node_Kind.Hole)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_hole_both_sides_duplicate_argument :: proc(t: ^testing.T) {
  // (* ) - hole on each side of *, squaring per §7
  ast := parse_string("(* )")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.Hole)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 2)), Node_Kind.Hole)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_hole_bubbles_across_or_not_stopped_by_and :: proc(t: ^testing.T) {
  // (*1-2) or b - the hole bubbles across the whole `or` expr per §7's example
  ast := parse_string("(*1-2) or b")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Op_Or)
}

@(test)
test_hole_as_dot_accessor_section :: proc(t: ^testing.T) {
  // .field - hole then dot access, a field-projector section
  ast := parse_string(".field")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.Hole)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Op_Dot)
}

// ---- as-bind, func, asfunc (§7) --------------------------------------------

@(test)
test_as_bind_named_function :: proc(t: ^testing.T) {
  // as my_arg my_arg + 1
  ast := parse_string("as my_arg my_arg + 1")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.As_Bind)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.Hole) // bound expr omitted
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Identifier) // my_arg
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 2)), Node_Kind.Binary_Expr) // my_arg + 1
}

@(test)
test_as_bind_with_explicit_value :: proc(t: ^testing.T) {
  ast := parse_string("compute() as result result * 2")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.As_Bind)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.Binary_Expr) // compute()
}

@(test)
test_func_and_omission_combine :: proc(t: ^testing.T) {
  // func *2+1 - resolved: valid, same as bare (*2+1)
  ast := parse_string("func *2+1")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Func_Expr)
  body := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, body), Node_Kind.Binary_Expr)
}

@(test)
test_asfunc_and_asfuncstatic :: proc(t: ^testing.T) {
  ast1 := parse_string("asfunc predicate")
  defer ast_destroy(&ast1)
  testing.expect_value(t, kind_of(&ast1, root_expr(&ast1)), Node_Kind.AsFunc_Expr)

  ast2 := parse_string("asfuncstatic predicate")
  defer ast_destroy(&ast2)
  testing.expect_value(t, kind_of(&ast2, root_expr(&ast2)), Node_Kind.AsFuncStatic_Expr)
}

// ---- then/else, |> (§8) -----------------------------------------------------

@(test)
test_then_without_else_can_fail :: proc(t: ^testing.T) {
  ast := parse_string("cond then happy")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Then_Expr)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_then_else :: proc(t: ^testing.T) {
  ast := parse_string("cond then happy else bad")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Else_Expr)
  then_node := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, then_node), Node_Kind.Then_Expr)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_pipe_basic_and_chaining :: proc(t: ^testing.T) {
  // x |> f |> g == g(f(x)), left-associative
  ast := parse_string("x |> f |> g")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Op_Pipe)
  inner := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, inner), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, inner, 1)), Node_Kind.Op_Pipe)
}

@(test)
test_pipe_omitted_left_makes_a_function :: proc(t: ^testing.T) {
  // |> f - the whole thing is a function of the omitted piped-in value
  ast := parse_string("|> f")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.Hole)
}

@(test)
test_canonical_guard_chain_example :: proc(t: ^testing.T) {
  // object |> (c1 and is p1 and c2) then happy else bad - SPEC.md §8's own example
  src := "object |> (c1 and is p1 and c2) then happy else bad"
  ast := parse_string(src)
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)

  e := root_expr(&ast) // Else_Expr
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Else_Expr)
  then_node := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, then_node), Node_Kind.Then_Expr)

  cond := child(&ast, then_node, 0) // object |> (...)
  testing.expect_value(t, kind_of(&ast, cond), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, cond, 1)), Node_Kind.Op_Pipe)

  guard_chain := child(&ast, cond, 2) // c1 and is p1 and c2
  testing.expect_value(t, kind_of(&ast, guard_chain), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, guard_chain, 1)), Node_Kind.Op_And)

  is_p1 := child(&ast, guard_chain, 0)
  testing.expect_value(t, kind_of(&ast, is_p1), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, is_p1, 1)), Node_Kind.Op_And)
  is_expr := child(&ast, is_p1, 2)
  testing.expect_value(t, kind_of(&ast, child(&ast, is_expr, 1)), Node_Kind.Op_Is)
}

@(test)
test_pipe_needs_parens_for_and_chain :: proc(t: ^testing.T) {
  // WITHOUT parens, |> binds tighter than `and`, so this reads as
  // (object |> c1) and is p1 and c2 - a deliberate parser choice (documented).
  ast := parse_string("object |> c1 and is p1 and c2")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Op_And)
  lhs := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, lhs), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, lhs, 1)), Node_Kind.Op_And)
  llhs := child(&ast, lhs, 0)
  testing.expect_value(t, kind_of(&ast, llhs), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, llhs, 1)), Node_Kind.Op_Pipe)
}

// ---- Variants and Optionals (§5) -------------------------------------------

@(test)
test_variant_construct_static_tag :: proc(t: ^testing.T) {
  ast := parse_string(":.pending 42")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Variant_Construct)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.Tag_Name)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Number_Literal)
}

@(test)
test_variant_construct_dynamic_key :: proc(t: ^testing.T) {
  ast := parse_string(":: tag_var 42")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Variant_Construct)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.Identifier) // NOT Tag_Name - a real reference
}

@(test)
test_present_sugar_desugars_to_variant_construct :: proc(t: ^testing.T) {
  ast := parse_string("present 42")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Variant_Construct)
  tag := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, tag), Node_Kind.Tag_Name)
  testing.expect_value(t, text_of(&ast, "present 42", tag), "present")
}

@(test)
test_empty_desugars_to_zero_entry_table :: proc(t: ^testing.T) {
  ast := parse_string("empty")
  defer ast_destroy(&ast)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Table_Construct)
  testing.expect_value(t, child_count(&ast, e), 0)
  testing.expect_value(t, len(ast.errors), 0)
}

@(test)
test_check_or_throw_static_and_dynamic :: proc(t: ^testing.T) {
  ast1 := parse_string("x !.pending")
  defer ast_destroy(&ast1)
  e1 := root_expr(&ast1)
  testing.expect_value(t, kind_of(&ast1, e1), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast1, child(&ast1, e1, 1)), Node_Kind.Op_CheckDot)
  testing.expect_value(t, kind_of(&ast1, child(&ast1, e1, 2)), Node_Kind.Tag_Name)

  ast2 := parse_string("x !: key_expr")
  defer ast_destroy(&ast2)
  e2 := root_expr(&ast2)
  testing.expect_value(t, kind_of(&ast2, child(&ast2, e2, 1)), Node_Kind.Op_CheckColon)
}

// ---- check/static_check/error (§11) ----------------------------------------

@(test)
test_check_with_and_without_message :: proc(t: ^testing.T) {
  ast1 := parse_string("check(x > 0) x")
  defer ast_destroy(&ast1)
  e1 := root_expr(&ast1)
  testing.expect_value(t, kind_of(&ast1, e1), Node_Kind.Check_Expr)
  testing.expect_value(t, child_count(&ast1, e1), 2) // [condition, body]

  ast2 := parse_string(`static_check(x > 0, "must be positive") x`)
  defer ast_destroy(&ast2)
  e2 := root_expr(&ast2)
  testing.expect_value(t, kind_of(&ast2, e2), Node_Kind.StaticCheck_Expr)
  testing.expect_value(t, child_count(&ast2, e2), 3) // [condition, msg, body]
}

@(test)
test_error_with_and_without_message :: proc(t: ^testing.T) {
  ast1 := parse_string("error")
  defer ast_destroy(&ast1)
  e1 := root_expr(&ast1)
  testing.expect_value(t, kind_of(&ast1, e1), Node_Kind.Error_Expr)
  testing.expect_value(t, child_count(&ast1, e1), 0)

  ast2 := parse_string(`error "boom"`)
  defer ast_destroy(&ast2)
  e2 := root_expr(&ast2)
  testing.expect_value(t, kind_of(&ast2, e2), Node_Kind.Error_Expr)
  testing.expect_value(t, child_count(&ast2, e2), 1)
}

// ---- import/serialize/serialize_file/sha256/cached/async (§13/§15) --------

@(test)
test_keyword_prefix_family :: proc(t: ^testing.T) {
  cases := []struct{ src: string, kind: Node_Kind }{
    {"import \"foo\"", .Import_Expr},
    {"serialize x", .Serialize_Expr},
    {"serialize_file x", .SerializeFile_Expr},
    {"sha256 x", .Sha256_Expr},
    {"cached x", .Cached_Expr},
    {"async x", .Async_Expr},
  }
  for c in cases {
    ast := parse_string(c.src)
    defer ast_destroy(&ast)
    testing.expect_value(t, kind_of(&ast, root_expr(&ast)), c.kind)
    testing.expect_value(t, len(ast.errors), 0)
  }
}

@(test)
test_async_cached_both_orders :: proc(t: ^testing.T) {
  ast1 := parse_string("async cached x")
  defer ast_destroy(&ast1)
  e1 := root_expr(&ast1)
  testing.expect_value(t, kind_of(&ast1, e1), Node_Kind.Async_Expr)
  testing.expect_value(t, kind_of(&ast1, child(&ast1, e1, 0)), Node_Kind.Cached_Expr)

  ast2 := parse_string("cached async x")
  defer ast_destroy(&ast2)
  e2 := root_expr(&ast2)
  testing.expect_value(t, kind_of(&ast2, e2), Node_Kind.Cached_Expr)
  testing.expect_value(t, kind_of(&ast2, child(&ast2, e2, 0)), Node_Kind.Async_Expr)
}

// ---- implicit names, nothing (§9/§3) ---------------------------------------

@(test)
test_implicit_names_and_nothing :: proc(t: ^testing.T) {
  ast := parse_string("#arg + #arg2 == nothing")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Binary_Expr) // ==
  lhs := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, lhs), Node_Kind.Binary_Expr) // +
  testing.expect_value(t, kind_of(&ast, child(&ast, lhs, 0)), Node_Kind.Implicit_Name)
  testing.expect_value(t, kind_of(&ast, child(&ast, lhs, 2)), Node_Kind.Implicit_Name)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 2)), Node_Kind.Nothing_Literal)
}

// ---- pattern grammar for `is` (§8) ------------------------------------------

@(test)
test_pattern_literal_and_binding :: proc(t: ^testing.T) {
  ast := parse_string("x is 5")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 2)), Node_Kind.Number_Literal)

  ast2 := parse_string("x is y as z")
  defer ast_destroy(&ast2)
  e2 := root_expr(&ast2)
  pat := child(&ast2, e2, 2)
  testing.expect_value(t, kind_of(&ast2, pat), Node_Kind.Pattern_Bind)
  testing.expect_value(t, kind_of(&ast2, child(&ast2, pat, 0)), Node_Kind.Identifier)
  testing.expect_value(t, kind_of(&ast2, child(&ast2, pat, 1)), Node_Kind.Identifier)
}

@(test)
test_pattern_table_destructure :: proc(t: ^testing.T) {
  ast := parse_string("x is { .field, .field2 as f, [expr] }")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  pat := child(&ast, e, 2)
  testing.expect_value(t, kind_of(&ast, pat), Node_Kind.Table_Pattern)
  testing.expect_value(t, child_count(&ast, pat), 3)
  testing.expect_value(t, kind_of(&ast, child(&ast, pat, 0)), Node_Kind.Table_Pattern_Field)
  bound := child(&ast, pat, 1)
  testing.expect_value(t, kind_of(&ast, bound), Node_Kind.Pattern_Bind)
  testing.expect_value(t, kind_of(&ast, child(&ast, pat, 2)), Node_Kind.Table_Pattern_Index)
}

@(test)
test_pattern_bare_sequence :: proc(t: ^testing.T) {
  ast := parse_string("x is {{4}}")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  pat := child(&ast, e, 2)
  testing.expect_value(t, kind_of(&ast, pat), Node_Kind.Table_Pattern_Sequence)
  testing.expect_value(t, child_count(&ast, pat), 1) // just N
  testing.expect_value(t, kind_of(&ast, child(&ast, pat, 0)), Node_Kind.Number_Literal)
}

@(test)
test_pattern_sequence_with_elementwise_selectors :: proc(t: ^testing.T) {
  // { {2}: .1 as first, [2] as second } - the exact §8 example
  ast := parse_string("x is { {2}: .1 as first, [2] as second }")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  pat := child(&ast, e, 2)
  testing.expect_value(t, kind_of(&ast, pat), Node_Kind.Table_Pattern_Sequence)
  testing.expect_value(t, child_count(&ast, pat), 3) // N, sel1, sel2
  testing.expect_value(t, kind_of(&ast, child(&ast, pat, 0)), Node_Kind.Number_Literal)
  sel1 := child(&ast, pat, 1)
  testing.expect_value(t, kind_of(&ast, sel1), Node_Kind.Pattern_Bind)
  testing.expect_value(t, kind_of(&ast, child(&ast, sel1, 0)), Node_Kind.Table_Pattern_Field)
  sel2 := child(&ast, pat, 2)
  testing.expect_value(t, kind_of(&ast, sel2), Node_Kind.Pattern_Bind)
  testing.expect_value(t, kind_of(&ast, child(&ast, sel2, 0)), Node_Kind.Table_Pattern_Index)
}

@(test)
test_pattern_variant_and_optional :: proc(t: ^testing.T) {
  ast1 := parse_string("x is :.pending v")
  defer ast_destroy(&ast1)
  testing.expect_value(t, len(ast1.errors), 0)
  pat1 := child(&ast1, root_expr(&ast1), 2)
  testing.expect_value(t, kind_of(&ast1, pat1), Node_Kind.Variant_Construct)
  testing.expect_value(t, child_count(&ast1, pat1), 2)

  ast2 := parse_string("x is present as v")
  defer ast_destroy(&ast2)
  testing.expect_value(t, len(ast2.errors), 0)
  pat2 := child(&ast2, root_expr(&ast2), 2)
  testing.expect_value(t, kind_of(&ast2, pat2), Node_Kind.Pattern_Bind)
  variant := child(&ast2, pat2, 0)
  testing.expect_value(t, kind_of(&ast2, variant), Node_Kind.Variant_Construct)
  testing.expect_value(t, child_count(&ast2, variant), 1) // tag only, no payload subpattern

  ast3 := parse_string("x is empty")
  defer ast_destroy(&ast3)
  testing.expect_value(t, len(ast3.errors), 0)
  pat3 := child(&ast3, root_expr(&ast3), 2)
  testing.expect_value(t, kind_of(&ast3, pat3), Node_Kind.Table_Construct)
}

@(test)
test_guard_chain_and_scope_threading_shape :: proc(t: ^testing.T) {
  // if c1 andif is p1 andif c2 then happy - old example, now spelled with `and`
  ast := parse_string("c1 and is p1 and c2 then happy else bad")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.Else_Expr)
}

// ---- ctx / withctx (§9) ------------------------------------------------------

@(test)
test_ctx_is_its_own_leaf_node :: proc(t: ^testing.T) {
  ast := parse_string("ctx")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  testing.expect_value(t, kind_of(&ast, root_expr(&ast)), Node_Kind.Ctx_Expr)
}

@(test)
test_withctx_basic_and_omitted_left :: proc(t: ^testing.T) {
  ast := parse_string("1 + 2 withctx ctx")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.With_Ctx_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.Binary_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Ctx_Expr)

  // withctx ctx - omitted left is a function of the omitted value, same rule
  // as |>'s and as-bind's omitted slots (§7).
  ast2 := parse_string("withctx ctx")
  defer ast_destroy(&ast2)
  testing.expect_value(t, len(ast2.errors), 0)
  e2 := root_expr(&ast2)
  testing.expect_value(t, kind_of(&ast2, e2), Node_Kind.With_Ctx_Expr)
  testing.expect_value(t, kind_of(&ast2, child(&ast2, e2, 0)), Node_Kind.Hole)
}

@(test)
test_withctx_absorbed_into_as_bind_body_without_parens :: proc(t: ^testing.T) {
  // x as a a withctx c - even though withctx is the LOOSEST operator, an
  // as-bind's body (§10) recurses through the full grammar (same greedy-tail
  // shape as present/:./:: 's payload), so a trailing withctx gets absorbed
  // into the body rather than reaching back to wrap the whole as-bind:
  // x as a (a withctx c), NOT (x as a a) withctx c.
  ast := parse_string("x as a a withctx c")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.As_Bind)
  body := child(&ast, e, 2)
  testing.expect_value(t, kind_of(&ast, body), Node_Kind.With_Ctx_Expr)
}

@(test)
test_withctx_wraps_as_bind_with_explicit_parens :: proc(t: ^testing.T) {
  // (x as a a) withctx c - parenthesizing the as-bind gets the "wraps a whole
  // computation" grouping the loosest-operator precedence otherwise suggests.
  ast := parse_string("(x as a a) withctx c")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.With_Ctx_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.As_Bind)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Identifier)
}

@(test)
test_chctx_basic_and_omitted_left :: proc(t: ^testing.T) {
  ast := parse_string("x chctx f")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.ChCtx_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 0)), Node_Kind.Identifier)
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Identifier)

  // chctx f - omitted left is a function of the omitted value, same rule as
  // withctx's and |>'s (§7).
  ast2 := parse_string("chctx f")
  defer ast_destroy(&ast2)
  testing.expect_value(t, len(ast2.errors), 0)
  e2 := root_expr(&ast2)
  testing.expect_value(t, kind_of(&ast2, e2), Node_Kind.ChCtx_Expr)
  testing.expect_value(t, kind_of(&ast2, child(&ast2, e2, 0)), Node_Kind.Hole)
}

@(test)
test_withctx_and_chctx_chain_left_associatively :: proc(t: ^testing.T) {
  // x withctx c1 chctx c2 == (x withctx c1) chctx c2 - each's own right side
  // parses one level tighter, so it doesn't swallow the sibling suffix.
  ast := parse_string("x withctx c1 chctx c2")
  defer ast_destroy(&ast)
  testing.expect_value(t, len(ast.errors), 0)
  e := root_expr(&ast)
  testing.expect_value(t, kind_of(&ast, e), Node_Kind.ChCtx_Expr)
  inner := child(&ast, e, 0)
  testing.expect_value(t, kind_of(&ast, inner), Node_Kind.With_Ctx_Expr)
  testing.expect_value(t, kind_of(&ast, child(&ast, inner, 0)), Node_Kind.Identifier) // x
  testing.expect_value(t, kind_of(&ast, child(&ast, inner, 1)), Node_Kind.Identifier) // c1
  testing.expect_value(t, kind_of(&ast, child(&ast, e, 1)), Node_Kind.Identifier) // c2

  // the reverse order chains the same way
  ast2 := parse_string("x chctx c1 withctx c2")
  defer ast_destroy(&ast2)
  e2 := root_expr(&ast2)
  testing.expect_value(t, kind_of(&ast2, e2), Node_Kind.With_Ctx_Expr)
  testing.expect_value(t, kind_of(&ast2, child(&ast2, e2, 0)), Node_Kind.ChCtx_Expr)
}

@(test)
test_ctx_and_withctx_are_context_sensitive_keywords :: proc(t: ^testing.T) {
  // :.ctx 1 - a tag literally named "ctx", not the context-read expression.
  ast1 := parse_string(":.ctx 1")
  defer ast_destroy(&ast1)
  testing.expect_value(t, len(ast1.errors), 0)
  e1 := root_expr(&ast1)
  testing.expect_value(t, kind_of(&ast1, e1), Node_Kind.Variant_Construct)
  tag := child(&ast1, e1, 0)
  testing.expect_value(t, kind_of(&ast1, tag), Node_Kind.Tag_Name)
  testing.expect_value(t, text_of(&ast1, ":.ctx 1", tag), "ctx")

  // x as ctx ctx - "ctx" as an as-bind target is just a name; the *body's*
  // bare "ctx" is still the reserved context-read leaf, not a reference to it.
  ast2 := parse_string("x as ctx ctx")
  defer ast_destroy(&ast2)
  testing.expect_value(t, len(ast2.errors), 0)
  e2 := root_expr(&ast2)
  testing.expect_value(t, kind_of(&ast2, e2), Node_Kind.As_Bind)
  name := child(&ast2, e2, 1)
  testing.expect_value(t, kind_of(&ast2, name), Node_Kind.Identifier)
  testing.expect_value(t, text_of(&ast2, "x as ctx ctx", name), "ctx")
  body := child(&ast2, e2, 2)
  testing.expect_value(t, kind_of(&ast2, body), Node_Kind.Ctx_Expr)
}

// ---- context-sensitive keywords ---------------------------------------------

@(test)
test_keywords_are_context_sensitive_as_names :: proc(t: ^testing.T) {
  // `present`/`and`/`then`/etc. are only special where the grammar looks for
  // them - anywhere a bare name is expected, they're valid names too.
  ast1 := parse_string(":.present 1") // tag name after `:.`
  defer ast_destroy(&ast1)
  testing.expect_value(t, len(ast1.errors), 0)
  e1 := root_expr(&ast1)
  testing.expect_value(t, kind_of(&ast1, e1), Node_Kind.Variant_Construct)
  tag1 := child(&ast1, e1, 0)
  testing.expect_value(t, kind_of(&ast1, tag1), Node_Kind.Tag_Name)
  testing.expect_value(t, text_of(&ast1, ":.present 1", tag1), "present")

  ast2 := parse_string("t.and") // field name
  defer ast_destroy(&ast2)
  testing.expect_value(t, len(ast2.errors), 0)
  e2 := root_expr(&ast2)
  testing.expect_value(t, kind_of(&ast2, e2), Node_Kind.Binary_Expr)
  field := child(&ast2, e2, 2)
  testing.expect_value(t, kind_of(&ast2, field), Node_Kind.Identifier)
  testing.expect_value(t, text_of(&ast2, "t.and", field), "and")

  // `then` as the *bound name* itself - note this only extends to name-expected
  // positions (.field/:.tag/as-target), not to standalone value references: `then`
  // still can't be used as a bare primary, since that's a genuinely different
  // (unnamed) grammar slot that parse_primary doesn't special-case for keywords.
  ast3 := parse_string("x as then 42")
  defer ast_destroy(&ast3)
  testing.expect_value(t, len(ast3.errors), 0)
  e3 := root_expr(&ast3)
  testing.expect_value(t, kind_of(&ast3, e3), Node_Kind.As_Bind)
  name3 := child(&ast3, e3, 1)
  testing.expect_value(t, kind_of(&ast3, name3), Node_Kind.Identifier)
  testing.expect_value(t, text_of(&ast3, "x as then 42", name3), "then")
}
