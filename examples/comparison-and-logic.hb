// Comparison and the boolean combinators (SPEC.md §8). Worth knowing what
// isn't here: there are no `true`/`false` literals yet, so every Boolean in
// the language comes out of a comparison, an `is` test (§8), or a builtin -
// which is why "false" below is spelled `1 > 2`.
//
// `and` evaluates its right side in the left side's scope, which is what
// lets a guard chain accumulate bindings (see guard-chain.hb); `or`'s two
// sides are independent, since only one of them ever matters. Evaluates to
// { ordered: true, both: true, either: true, mixed: false }.
{
  .ordered = 1 < 2,
  .both = (1 < 2) and (2 < 3),
  .either = (1 > 2) or (2 < 3),
  .mixed = (1 < 2) and (2 > 3),
}
