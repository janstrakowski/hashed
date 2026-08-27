// Optional values (SPEC.md §5): matching `present`/`empty` via `is`, binding
// the payload when present. Evaluates to 42.
(present 42) as x
  x is present as v then v else 0
