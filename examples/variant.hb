// Variants as a Table convention (SPEC.md §5): `!.` check-or-throw extracts a
// tagged payload, `as` binds it, and it's then used in an ordinary guard.
// Evaluates to 42.
(:.ok 42) as response
  0 as default_value
    response !.ok as value
      value > 0 then value else default_value
