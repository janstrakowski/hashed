// Every way a number can be written (SPEC.md §3). An `Integer` is decimal,
// hex, octal or binary - the octal prefix is an explicit `0o`, not C's
// ambiguous bare leading zero - and `_` may be grouped freely between digits
// in any of them.
//
// A literal is a `Float` if and only if it carries a `.` or an exponent, so
// no suffix is ever needed to say which type is meant. A `Float` written with
// a point needs a digit on both sides (`0.5`, never `.5`), which is a
// readability rule rather than a grammatical one.
//
// One display quirk to know: a `Float` with nothing after the point shows
// without one, so `exponent` below prints as `1500` and looks like the
// `Integer` 1500 - though the two are not equal, since no literal is coerced
// to the other's type. Evaluates to
// { hex: 42, octal: 42, binary: 42, grouped: 1000000, exponent: 1500,
//   bases_agree: true }.
{
  .hex = 0x2A,
  .octal = 0o52,
  .binary = 0b101010,
  .grouped = 1_000_000,
  .exponent = 1.5e3,
  .bases_agree = (0x2A == 0o52) and (0o52 == 0b101010),
}
