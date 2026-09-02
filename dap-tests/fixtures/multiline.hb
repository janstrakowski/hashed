// A fixture for dap-tests: one expression spanning many lines, which is what
// most real HashedBuild looks like. Its value is
// {int_div: 3, doubled: 8, negation: -3}.
//
// adapter.test.js walks every line of this file, so the shape matters more
// than the arithmetic: line 8 is where the expression starts, lines 9-11 are
// entries inside it, line 12 is a lone `}` that no expression starts on.
{
  .int_div = 7 / 2,
  .doubled = 4 + 4,
  .negation = -2 - 1,
}
