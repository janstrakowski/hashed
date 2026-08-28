// `#self` (SPEC.md §9): the function currently running, the same way `#arg` is
// the argument it was called with. `let rec` needs a name to recurse through;
// `#self` needs none, so a function written as an omission section or a `func`
// - neither of which has a name at all - can still call itself.
//
// `#self2` reaches one level further out, to the enclosing call still on the
// stack, exactly as `#arg2` does for arguments. In `.countdown` the recursive
// step is made by an *inner* function calling the outer one back through
// `#self2`, with `#arg2` for the argument that outer call was given.
// Evaluates to { fact: 120, countdown: 15 }.
{
  .fact = (func (#arg == 0) then 1 else #arg * (#self (#arg - 1))) 5,
  .countdown = (func (#arg == 0) then 0 else ((func #arg2 + (#self2 (#arg2 - 1))) #arg)) 5,
}
