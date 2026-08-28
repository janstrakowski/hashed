// Functions (SPEC.md §7), which are ordinary values however you write them:
//
//   (*2 + 1)      an omission section - the blank operand is the argument
//   func <body>   an explicit function, argument named `#arg`
//   #arg2         the *enclosing* call's argument, while that call is still
//                 running (it's a call stack, not a lexical capture - a
//                 returned closure can't reach back to it)
//
// Calling is juxtaposition (`f x`), `|>` pipes a value into a function, and
// `asfunc` asserts a value is callable rather than constructing anything.
// Evaluates to { section: 11, explicit: 49, nested: 507, stored: 42,
// asserted: 9 }.
{
  .section = 5 |> (*2 + 1),
  .explicit = (func (#arg * #arg)) 7,
  .nested = (func ((func (#arg + #arg2 * 100)) 7)) 5,
  .stored = let t { .double = func (#arg * 2) }; (t.double) 21,
  .asserted = (asfunc (func (#arg - 1))) 10,
}
