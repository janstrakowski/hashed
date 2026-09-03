// Utf8 values (SPEC.md §3/§6): double-quoted literals with the usual
// escapes, joined with `concat` - the same operator that merges Tables, and
// the only way to join strings, since `+` is arithmetic only. There's no
// interpolation. Evaluates to { joined: "hello, world",
// escaped: "quoted \"inline\", tabbed\tand broken\n", same: true }.
{
  .joined = "hello, " concat "world",
  .escaped = "quoted \"inline\", tabbed\tand broken\n",
  .same = ("a" concat "bc") == "abc",
}
