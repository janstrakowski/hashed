// Tests run natively, never in a WASI build: core:testing pulls in
// core:log and core:terminal, neither of which compiles for wasm32.
#+build linux, windows
package hashedbuild

import "core:testing"

// SPEC.md §10's cyclic `let rec` (rec_build.odin): demand-driven entry
// evaluation, the forward reference that closes a true cycle, and the two
// things that then have to cope with a graph rather than a tree - equality
// (value.odin) and printing (print_value.odin).

@(private = "file")
run :: proc(src: string) -> (val: Value, ok: bool, err: string) {
  ast := parse(source_t{name = "test", n_bytes = u64(len(src)), data = raw_data(src)}, ast_t{})
  interp := Interpreter{ast = &ast, src = src}
  env := env_make_child(nil)
  val, ok = eval(&interp, ast.root, env)
  return val, ok, interp.error_message
}

// Like `run`, but the AST and the interpreter are heap-allocated and kept: a
// Function's digest is the shape of its body, which is a subtree of the
// program it was written in, so hashing one after the run needs both alive.
@(private = "file")
run_keeping_the_program :: proc(src: string) -> (val: Value, interp: ^Interpreter, ok: bool) {
  ast := new(ast_t)
  ast^ = parse(source_t{name = "test", n_bytes = u64(len(src)), data = raw_data(src)}, ast_t{})
  interp = new(Interpreter)
  interp.ast = ast
  interp.src = src
  val, ok = eval(interp, ast.root, env_make_child(nil))
  return
}

@(private = "file")
expect_prints :: proc(t: ^testing.T, src: string, want: string) {
  val, ok, err := run(src)
  testing.expect(t, ok, err)
  if !ok do return
  testing.expect_value(t, format_value(val), want)
}

@(private = "file")
expect_fails_with :: proc(t: ^testing.T, src: string, want_err: string) {
  _, ok, err := run(src)
  testing.expect(t, !ok, "expected this to fail")
  if ok do return
  testing.expect_value(t, err, want_err)
}

// ---- the cycle itself --------------------------------------------------------

@(test)
test_rec_table_reaches_itself :: proc(t: ^testing.T) {
  // The simplest cycle: one entry whose value is the Table it belongs to.
  // Walking `.self` any number of times has to arrive back at the same Table.
  expect_prints(t, "let rec p { .n = 1, .self = p }; p.self.self.self.n", "1")
}

@(test)
test_rec_sequence_reaches_itself :: proc(t: ^testing.T) {
  expect_prints(t, "let rec ones {1, ones}; ones[2][2][2][1]", "1")
}

@(test)
test_rec_mutual_entries_close_the_cycle :: proc(t: ^testing.T) {
  // Alice's friends hold Bob and Bob's hold Alice, so following the edge twice
  // must land on the very Table we started from. Evaluating `.alice` demands
  // `.bob` out of order; `.bob` then reaches back into `.alice`, which is still
  // in progress - the one place a forward reference is created.
  src := `let rec people {
    .alice = { .name = "Alice", .friends = { people.bob } },
    .bob   = { .name = "Bob",   .friends = { people.alice } },
  }; people.alice.friends[1].friends[1].name`
  expect_prints(t, src, `"Alice"`)
}

@(test)
test_rec_demand_reorders_without_any_cycle :: proc(t: ^testing.T) {
  // `.a` needs `.b`, which is written after it. No cycle is involved at all -
  // this is purely the reordering, and it is what removes the need for a
  // placeholder in every case that has a topological order.
  expect_prints(t, "let rec p { .a = p.b + 1, .b = 2 }; p.a", "3")
}

@(test)
test_rec_entries_keep_source_order :: proc(t: ^testing.T) {
  // `.b` is evaluated first (demanded by `.a`) but must still be printed
  // second: §5 preserves the order entries were written in, whatever order
  // they ended up running in.
  expect_prints(t, "let rec p { .a = p.b, .b = 2 }; p", "{a: 2, b: 2}")
}

@(test)
test_rec_over_a_function_is_unchanged :: proc(t: ^testing.T) {
  // The pre-existing `let rec` path: a closure captures the scope, so this
  // never goes near rec_build.odin. Guards against the new Table path
  // changing how ordinary recursion behaves.
  expect_prints(t, "let rec fact (let n; (n == 0) then 1 else n * (fact (n - 1))); fact 5", "120")
}

// ---- what is still circular --------------------------------------------------

@(test)
test_rec_entry_defined_as_itself_fails :: proc(t: ^testing.T) {
  // `.a` is `.b` and `.b` is `.a`: no ordering and no forward reference can
  // produce a value, because there is no value.
  expect_fails_with(t, "let rec p { .a = p.b, .b = p.a }; p.a",
    "circular definition: p.b is defined as itself, through p.a")
}

@(test)
test_rec_inspecting_an_entry_in_progress_fails :: proc(t: ^testing.T) {
  // A forward reference may be stored, never inspected - `+` inspects.
  expect_fails_with(t, "let rec p { .a = p.b + 1, .b = p.a + 1 }; p.a",
    "circular definition: p.a is needed before it has a value")
}

@(test)
test_rec_non_table_still_fails_as_before :: proc(t: ^testing.T) {
  // Nothing but a Table literal gets the new path, so a scalar reading its own
  // name still hits the window before the bind, exactly as it did.
  expect_fails_with(t, "let rec x x + 1; x", "undefined name: x")
}

@(test)
test_rec_missing_key_still_fails :: proc(t: ^testing.T) {
  expect_fails_with(t, "let rec p { .a = 1 }; p.zz", "no such key in Table")
}

// ---- equality over a graph ---------------------------------------------------

@(test)
test_cyclic_equality_is_bisimulation :: proc(t: ^testing.T) {
  // Two 2-cycles of the same shape, built by separate bindings that share no
  // node at all. §6 makes equality a question about content, so these are the
  // same value - and answering it at all needs the assumption-based walk,
  // since a naive structural compare would never terminate.
  src := `let rec g { .a = { .tag = "a", .next = g.b }, .b = { .tag = "b", .next = g.a } };
          let rec h { .a = { .tag = "a", .next = h.b }, .b = { .tag = "b", .next = h.a } };
          g.a == h.a`
  expect_prints(t, src, "true")
}

@(test)
test_cyclic_equality_still_sees_a_difference :: proc(t: ^testing.T) {
  // Same shape, one differing payload deep inside the cycle. The optimistic
  // assumption must not swallow a real mismatch.
  src := `let rec g { .a = { .tag = "a", .next = g.b }, .b = { .tag = "b", .next = g.a } };
          let rec h { .a = { .tag = "a", .next = h.b }, .b = { .tag = "ZZ", .next = h.a } };
          g.a == h.a`
  expect_prints(t, src, "false")
}

@(test)
test_cyclic_equality_of_different_period :: proc(t: ^testing.T) {
  // A 1-cycle against a 2-cycle whose two nodes are identical. Every entry
  // matches whichever way you unroll them, so bisimulation says equal - which
  // is the coinductive answer, and the one that keeps equality about content.
  src := `let rec g { .n = 1, .next = g };
          let rec h { .a = { .n = 1, .next = h.b }, .b = { .n = 1, .next = h.a } };
          g == h.a`
  expect_prints(t, src, "true")
}

@(test)
test_self_referential_table_equals_itself :: proc(t: ^testing.T) {
  expect_prints(t, "let rec p { .n = 1, .self = p }; p == p.self", "true")
}

@(test)
test_cyclic_equality_of_different_period_can_still_differ :: proc(t: ^testing.T) {
  // The mirror of the test above: same 1-against-2 shape, but the 2-cycle
  // alternates payloads, so unrolling the two against each other diverges on
  // the second step.
  src := `let rec g { .n = 1, .next = g };
          let rec h { .a = { .n = 1, .next = h.b }, .b = { .n = 2, .next = h.a } };
          g == h.a`
  expect_prints(t, src, "false")
}

@(test)
test_a_cycle_is_not_equal_to_a_finite_unrolling :: proc(t: ^testing.T) {
  // Any finite unrolling has to bottom out in something the cycle does not,
  // so no depth of it is ever the same value.
  expect_prints(t, "let rec g { .n = 1, .self = g }; g == { .n = 1, .self = { .n = 1, .self = 1 } }", "false")
}

@(test)
test_cyclic_equality_is_symmetric :: proc(t: ^testing.T) {
  // Comparing entries walks the left operand and looks each key up in the
  // right, so the two operands are not handled identically. The answer must
  // not depend on which side is which.
  src := `let rec g { .a = { .t = "a", .next = g.b }, .b = { .t = "b", .next = g.a } };
          let rec h { .a = { .t = "a", .next = h.b }, .b = { .t = "ZZ", .next = h.a } };
          { (g.a == h.a), (h.a == g.a) }`
  expect_prints(t, src, "{false, false}")
}

@(test)
test_a_cyclic_value_works_as_a_key :: proc(t: ^testing.T) {
  // Nothing stops a cyclic Table being a key, and matching one is the same
  // bisimulation question as matching a value.
  src := `let rec p { .n = 1, .self = p };
          let rec q { .n = 1, .self = q };
          { [p] = "x" } == { [q] = "x" }`
  expect_prints(t, src, "true")
}

@(test)
test_a_failed_key_match_does_not_taint_a_later_comparison :: proc(t: ^testing.T) {
  // Regression. Matching `g.a` against the candidate key `h.b` fails, but the
  // optimistic walk had already recorded "assume g.a and h.b are equal" on its
  // way down. When that state was shared across candidates, the later `.z`
  // comparison of exactly that pair short-circuited to true on the discredited
  // assumption, and two unequal Tables compared equal. `.z` is the whole point
  // of the case: everything else about X and Y genuinely does match.
  base :: `let rec g { .a = { .tag = "a", .next = g.b }, .b = { .tag = "b", .next = g.a } };
           let rec h { .a = { .tag = "a", .next = h.b }, .b = { .tag = "b", .next = h.a } };
           let X { [g.a] = 1, [g.b] = 2, .z = g.a };`
  expect_prints(t, base + ` let Y { [h.b] = 2, [h.a] = 1, .z = h.b }; X == Y`, "false")
  // The same shape where `.z` really does match, so the false above is the
  // mismatch being found and not the comparison having become useless.
  expect_prints(t, base + ` let Y { [h.b] = 2, [h.a] = 1, .z = h.a }; X == Y`, "true")
  // ...and the pair on its own, which is what the tainted state got wrong.
  expect_prints(t, base + ` g.a == h.b`, "false")
}

// ---- printing a graph --------------------------------------------------------

@(test)
test_printing_labels_a_cycle :: proc(t: ^testing.T) {
  expect_prints(t, "let rec p { .n = 1, .self = p }; p", "#1{n: 1, self: #1}")
}

@(test)
test_printing_labels_a_sequence_cycle :: proc(t: ^testing.T) {
  expect_prints(t, "let rec ones {1, ones}; ones", "#1{1, #1}")
}

@(test)
test_printing_labels_the_node_the_back_edge_returns_to :: proc(t: ^testing.T) {
  // The label belongs on Alice, not on the outer Table: she is what the
  // back-edge inside Bob points at.
  src := `let rec people {
    .alice = { .name = "Alice", .friends = { people.bob } },
    .bob   = { .name = "Bob",   .friends = { people.alice } },
  }; people.alice`
  expect_prints(t, src, `#1{name: "Alice", friends: {{name: "Bob", friends: {#1}}}}`)
}

@(test)
test_printing_leaves_acyclic_sharing_alone :: proc(t: ^testing.T) {
  // The same sub-Table reached twice down different branches is ordinary
  // sharing, not a cycle - it must print in full both times, with no label.
  expect_prints(t, "let s { .x = 1 }; { .p = s, .q = s }", "{p: {x: 1}, q: {x: 1}}")
}

// ---- hashing -----------------------------------------------------------------

@(test)
test_hashing_a_cyclic_value_terminates :: proc(t: ^testing.T) {
  // The Merkle fold has no bottom to start from here, so this goes through
  // hash_cyclic.odin instead. What it must not do is recurse forever.
  val, ok, err := run("let rec p { .n = 1, .self = p }; p")
  testing.expect(t, ok, err)
  if !ok do return
  _, herr := value_digest(val)
  testing.expect_value(t, herr.kind, Hash_Error.None)
}

@(test)
test_cyclic_digests_agree_with_cyclic_equality :: proc(t: ^testing.T) {
  // The property the whole of hash_cyclic.odin exists for: values_equal
  // compares cycles by bisimulation, so the digest has to be canonical under
  // bisimulation too, or a content-addressed language would have equal values
  // that hash apart. These are the same three pairs test_cyclic_equality_is_
  // bisimulation asserts equality for.
  same := []([2]string) {
    // Two separately built cycles of the same shape.
    {"let rec p { .n = 1, .self = p }; p", "let rec q { .n = 1, .self = q }; q"},
    // A 1-cycle and a 2-cycle that unroll to the same infinite tree.
    {
      "let rec p { .n = 1, .self = p }; p",
      "let rec p { .n = 1, .self = { .n = 1, .self = p } }; p",
    },
  }
  for pair in same {
    a, aok, aerr := run(pair[0])
    testing.expect(t, aok, aerr)
    b, bok, berr := run(pair[1])
    testing.expect(t, bok, berr)
    if !aok || !bok do continue

    testing.expect(t, values_equal(a, b), "the two are equal, so this pair is the interesting one")
    da, ea := value_digest(a)
    db, eb := value_digest(b)
    testing.expect_value(t, ea.kind, Hash_Error.None)
    testing.expect_value(t, eb.kind, Hash_Error.None)
    testing.expect(t, da == db, "equal cyclic values must hash alike")
  }
}

@(test)
test_the_two_hash_paths_agree_on_acyclic_values :: proc(t: ^testing.T) {
  // §6 asks for *one* encoding, and there are two implementations of it: the
  // Merkle fold (hash.odin) and the graph algorithm (hash_cyclic.odin), which
  // takes over the moment a value contains a cycle anywhere. The parts of that
  // value which are *not* cyclic must come out the same either way - otherwise
  // a Table's digest would depend on whether some unrelated corner of the
  // value it was reached through happened to loop.
  //
  // Asked of the two procedures directly, because from inside the language the
  // fold always wins for an acyclic value and the disagreement would be
  // invisible until something cyclic wrapped it.
  sources := []string {
    `{ .a = 1, .b = { .c = "x", .d = 2.5 } }`,
    `{ 1, 2, 3 }`,
    // A closure, whose captures the two paths order independently - the one
    // place they have actually drifted.
    `let alpha 1; let zeta 2; let beta 3; { .f = func (#arg + alpha + zeta + beta) }`,
    `empty`,
  }
  for src in sources {
    // The interpreter has to outlive the evaluation here: a closure's digest
    // is its body's shape, and the body is a subtree of that program's AST.
    val, interp, ok := run_keeping_the_program(src)
    testing.expect(t, ok, interp.error_message)
    if !ok do continue

    folded, ferr := value_digest(val, interp)
    graphed, gerr := value_digest_cyclic(val, interp)
    testing.expect_value(t, ferr.kind, Hash_Error.None)
    testing.expect_value(t, gerr.kind, Hash_Error.None)
    testing.expect(t, folded == graphed, "the fold and the graph must encode the same value the same way")
  }
}

@(test)
test_cyclic_digests_separate_unequal_cycles :: proc(t: ^testing.T) {
  // Canonical must not mean constant: two cycles that unroll differently have
  // to hash apart, or every cyclic value would share one digest.
  a, aok, aerr := run("let rec p { .n = 1, .self = p }; p")
  testing.expect(t, aok, aerr)
  b, bok, berr := run("let rec p { .n = 2, .self = p }; p")
  testing.expect(t, bok, berr)
  if !aok || !bok do return
  da, _ := value_digest(a)
  db, _ := value_digest(b)
  testing.expect(t, da != db, "different cycles must hash differently")
}

@(test)
test_a_cycle_hashes_the_same_from_either_end :: proc(t: ^testing.T) {
  // The entry-point independence the canonical form is for: `.a` and `.b` of a
  // two-node cycle are not bisimilar (their entries differ), but reaching the
  // *same* node down two different paths must give one digest either way.
  val, ok, err := run("let rec p { .a = { .tag = 1, .back = p }, .b = p.a }; p")
  testing.expect(t, ok, err)
  if !ok do return
  table, is_table := val.(^Table_Value)
  testing.expect(t, is_table)
  if !is_table do return

  a, has_a := table_find(table, "a")
  b, has_b := table_find(table, "b")
  testing.expect(t, has_a && has_b)
  if !has_a || !has_b do return

  da, ea := value_digest(a)
  db, eb := value_digest(b)
  testing.expect_value(t, ea.kind, Hash_Error.None)
  testing.expect_value(t, eb.kind, Hash_Error.None)
  testing.expect(t, da == db, "one node reached two ways is one digest")
}

@(test)
test_hashing_acyclic_values_is_unaffected :: proc(t: ^testing.T) {
  // The cycle check walks the open path only, so a shared-but-acyclic Table
  // still hashes, and two equal values still hash alike.
  a, aok, aerr := run("let s { .x = 1 }; { .p = s, .q = s }")
  testing.expect(t, aok, aerr)
  b, bok, berr := run("{ .p = { .x = 1 }, .q = { .x = 1 } }")
  testing.expect(t, bok, berr)
  if !aok || !bok do return
  da, ea := value_digest(a)
  db, eb := value_digest(b)
  testing.expect_value(t, ea.kind, Hash_Error.None)
  testing.expect_value(t, eb.kind, Hash_Error.None)
  testing.expect(t, da == db, "equal values must hash alike")
}
