// Recursion (SPEC.md §10). An ordinary `let` evaluates its bound value before
// the name exists, so a function bound that way cannot call itself. `let rec`
// puts the name in scope first, and since a closure captures the scope it was
// made in rather than a snapshot of its contents, the name is there by the
// time anything actually calls it.
//
// That same "captured by scope, not by value" property is what makes the
// mutual pair below work off a single `rec`: `fns` is one Table holding two
// functions, each of which reaches the other through `fns` - a name that is
// still unbound while the Table is being built, and bound by the time either
// function runs. One `let rec` per function could not do it, since whichever
// came first would name one that did not exist yet.
//
// There are no `true`/`false` literals (see context-permissions.hb), so the
// parity pair answers with 1 and 0. Evaluates to
// { fact: 3628800, fib: 55, even: 1, odd: 0 }.
let rec fact (let n; (n == 0) then 1 else n * (fact (n - 1)));
let rec fib (let n; (n < 2) then n else (fib (n - 1)) + (fib (n - 2)));
let rec fns {
  .even = (let n; (n == 0) then 1 else fns.odd (n - 1)),
  .odd = (let n; (n == 0) then 0 else fns.even (n - 1)),
};
{
  .fact = fact 10,
  .fib = fib 10,
  .even = fns.even 8,
  .odd = fns.odd 8,
}
