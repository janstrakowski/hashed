// Arithmetic (SPEC.md §4/§6). `Integer` and `Float` are distinct types, and
// the distinction is visible in the results: `/` on two Integers truncates,
// while one Float anywhere promotes the whole expression. Unary minus binds
// tighter than any binary operator, so `-2 - 1` is `(-2) - 1`, never "the
// omitted operand minus 2, minus 1" (§7's omission sections lose that
// ambiguity outright). Evaluates to { int_div: 3, float_div: 3.5,
// remainder: 1, precedence: 14, negation: -3 }.
{
  .int_div = 7 / 2,
  .float_div = 7.0 / 2,
  .remainder = 7 % 3,
  .precedence = 2 + 3 * 4,
  .negation = -2 - 1,
}
