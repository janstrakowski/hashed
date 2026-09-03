// Variants as a Table convention (SPEC.md §5): `!.` check-or-throw extracts a
// tagged payload, a `let` names it, and it's then used in an ordinary guard.
// Evaluates to 42.
let response (:.ok 42);
  let default_value 0;
    let value response !.ok;
      value > 0 then value else default_value
