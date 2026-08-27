// The canonical guard-chain example from SPEC.md §8: pipe an object into a
// chain of AND'd guards (binding a pattern name partway through) and branch
// on whether they all hold. Evaluates to 5.
5 as object
  object |> (object > 0 and is n as p1 and p1 < 100) then p1 else 0
