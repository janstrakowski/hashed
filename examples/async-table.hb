// A `Table` literal fires every entry before awaiting any of them (SPEC.md
// §2) - so these three independent `async` computations actually run
// concurrently with each other, not one after another, even though nothing
// in the syntax says "concurrent" beyond the `async` keyword itself.
// Evaluates to { a: 2, b: 6, c: "This is the payload for option A." }.
{
  .a = async (1 + 1),
  .b = async (2 * 3),
  .c = async filetext (loadfile "optiona.txt"),
}
