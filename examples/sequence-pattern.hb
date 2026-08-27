// Sequence-pattern destructuring (SPEC.md §8): `{N}` asserts an exact-length
// sequence, `.1 as .../.2 as ...` bind its elements by position. Evaluates to
// 30.
{10, 20} |> (is {{2}: .1 as lhs, .2 as rhs}) then lhs + rhs
