// `check(<condition>, <message>) <body>` (SPEC.md §11): a precondition
// guarding a value. If the condition holds, the result is the body; if not,
// the program fails with that message - and unlike a false `then` (§8), a
// failed check is *fatal*: no `else`, however close, catches it. That's the
// distinction the two constructs exist to draw. `then`/`else` is branching;
// `check` is "this must be true, and if it isn't there's nothing sensible to
// do next".
//
// `static_check` has the same shape, for conditions meant to be settled
// before the program ever runs. Evaluates to 100.
50 as base
  check(base > 0, "base must be positive")
    static_check(1 == 1, "arithmetic still works")
      base * 2
