// Destructuring with `is` (SPEC.md §8). A Table pattern names the fields it
// wants and binds them with `as`; a mismatch is `false`, not a failure,
// which makes `is` the way to *ask* whether a key exists - reading `.url`
// directly on a Table that hasn't got one fails the whole program instead.
//
// Bindings flow rightward: `and`'s right side, and the `then` body, both see
// what the left side bound (which is what guard-chain.hb builds on).
// Evaluates to { name: "xz", digest: "abc123", has_url: false }.
{ .name = "xz", .meta = { .sha256 = "abc123" } } as pkg
  pkg is { .name as name, .meta as meta } and meta is { .sha256 as digest }
    then {
      .name = name,
      .digest = digest,
      .has_url = pkg is { .url as url },
    }
    else "no match"
