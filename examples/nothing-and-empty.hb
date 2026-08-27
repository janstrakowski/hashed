// Two values that look similar and aren't (SPEC.md §3/§5). `nothing` is the
// unit value - what `symlink` returns, and what sits under each permission
// name in `ctx.permissions`. `empty` is the zero-entry Table, which doubles
// as the "absent" half of the optional idiom: `present <v>` tags a value,
// `empty` is its absence, and `is` tells them apart.
// Evaluates to { unit: nothing, zero_table: {}, present_case: 42,
// empty_case: -1, same: false }.
{
  .unit = nothing,
  .zero_table = empty,
  .present_case = (present 42) is present as v then v else -1,
  .empty_case = empty is present as v then v else -1,
  .same = nothing == empty,
}
