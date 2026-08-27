// Sequence-shaped Tables (SPEC.md §5): a bare `{a, b, c}` is shorthand for
// the keys 1, 2, 3, read back with `[i]` (1-based), and printed without
// their keys for as long as they stay a gap-free 1..N run.
//
// The one that surprises people: `concat` merges by key, so `{10, 20, 30}
// concat {99}` replaces element 1 rather than appending - the result is no
// longer gap-free-from-1 in source order, so it prints its keys again.
// Evaluates to { second: 20, sum: 60, merged: {2: 20, 3: 30, 1: 99} }.
{10, 20, 30} as xs
  {
    .second = xs[2],
    .sum = xs[1] + xs[2] + xs[3],
    .merged = xs concat {99},
  }
