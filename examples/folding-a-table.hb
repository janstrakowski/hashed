// `fold` (SPEC.md §16): the one way to traverse a Table. There are no loops in
// this language and recursion cannot reach a Table's entries on its own, so
// this is the primitive `map`, `filter` and appending are written on top of -
// each of them a few lines of HashedBuild rather than a builtin of its own.
//
// `.step` is called with { .acc, .key, .value } and returns the next
// accumulator.
//
// **Entries are visited in ascending key order, not the order they were
// written.** Two things follow, and they are the reason for the choice. A
// sequence (§5 - keys 1..N) folds in index order, which is what makes folding
// a list of filenames mean anything. And two Tables that compare equal (§6
// ignores entry order) fold to the same answer, which walking them as written
// could not promise. Evaluates to
// { sum: 60, in_index_order: "abc", by_key_not_by_entry: "AMZ",
//   equal_tables_agree: true, length: 3 }.

let sum_step (let s; s.acc + s.value);
let seq_len (let t; fold { .table = t, .init = 0, .step = (let s; s.acc + 1) });
let digits (let t; fold { .table = t, .init = 0, .step = (let s; s.acc * 10 + s.value) });

{
  .sum = fold { .table = {10, 20, 30}, .init = 0, .step = sum_step },
  .in_index_order = fold { .table = {"a", "b", "c"}, .init = "", .step = (let s; s.acc concat s.value) },
  .by_key_not_by_entry =
    fold { .table = { .z = "Z", .a = "A", .m = "M" }, .init = "", .step = (let s; s.acc concat s.value) },
  .equal_tables_agree = (digits { .a = 1, .b = 2 }) == (digits { .b = 2, .a = 1 }),
  .length = seq_len {"x", "y", "z"},
}
