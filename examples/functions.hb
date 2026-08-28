// Functions (SPEC.md §7): omission sections, the `let`-bind's named-argument
// form, and pipe chaining. Omitting a `let`'s bound value - nothing between
// the name and the `;` - makes the whole binding a function of that omitted
// value, which is how you name an argument. Evaluates to 121.
5 |> (*2 + 1) |> (let x; x * x)
