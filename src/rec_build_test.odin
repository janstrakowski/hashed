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
test_hashing_a_cyclic_value_is_refused :: proc(t: ^testing.T) {
  // §3 pins what a digest encodes, so a cyclic one is a spec decision rather
  // than an implementation detail - until it is made, this must fail cleanly
  // rather than recurse forever. See hash.odin.
  val, ok, err := run("let rec p { .n = 1, .self = p }; p")
  testing.expect(t, ok, err)
  if !ok do return
  _, herr := value_digest(val)
  testing.expect_value(t, herr, Hash_Error.Cyclic)
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
  testing.expect_value(t, ea, Hash_Error.None)
  testing.expect_value(t, eb, Hash_Error.None)
  testing.expect(t, da == db, "equal values must hash alike")
}
