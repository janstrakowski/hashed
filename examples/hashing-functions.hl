// A `Function`'s hash (SPEC.md §15). A closure is a value, so `sha256`
// answers for one - and what it answers is the two things a closure actually
// is: the shape of its body, and the values it captures.
//
// So two functions hash alike exactly when they would compute the same thing.
// The same expression reading the same values is one function; a different
// body, or the same body reading a different value, is a different one. What
// does *not* enter into it is everything else that happened to be in scope
// where the closure was written - which is the property §15's `cached` needs,
// since a cache key that moved whenever an unrelated neighbour changed would
// miss every time.
//
// A builtin (§16) has no body to take a shape from, so it hashes as the
// operation it is. A partially applied one carries what it was built from,
// which is why the two `chperm` results below are told apart by the
// permission they grant rather than by being two objects.
//
// There are no boolean literals, so "false" is spelled `1 > 2`.
//
// Evaluates to { same_body_same_hash: true, different_body_differs: true,
//                captures_count: true, neighbours_do_not: true,
//                builtins_hash_by_what_they_are: true,
//                a_builtin_carries_its_argument: true }.
{
  .same_body_same_hash = (sha256 func (#arg + 1)) == (sha256 func (#arg + 1)),
  .different_body_differs = ((sha256 func (#arg + 1)) == (sha256 func (#arg + 2))) == (1 > 2),

  // Same body, different captured value: a different function.
  .captures_count =
    ((sha256 (let x 1; func (#arg + x))) == (sha256 (let x 2; func (#arg + x)))) == (1 > 2),

  // Same body, same captured value, different surroundings: one function.
  .neighbours_do_not =
    (sha256 (let x 1; let unrelated "zz"; func (#arg + x)))
      == (sha256 (let x 1; func (#arg + x))),

  .builtins_hash_by_what_they_are = ((sha256 loadfile) == (sha256 createfile)) == (1 > 2),
  .a_builtin_carries_its_argument =
    ((sha256 chperm { .name = "io", .enabled = 1 < 2 })
      == (sha256 chperm { .name = "io", .enabled = 1 > 2 })) == (1 > 2),
}
