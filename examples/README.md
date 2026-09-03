# Examples

Every file here runs today, and every one of them is executed by the test suite
and asserted against the value its header comment documents — so if the language
changes underneath an example, the build goes red rather than the example
quietly rotting. Adding a `.hl` file here without a corresponding assertion in
`src/examples_test.odin` also fails the suite.

Run one with:

```sh
./hl examples/tables-map.hl        # from anywhere - paths resolve to the file
./hl -a examples/functions.hl      # print the AST first
./hl -i                            # the live editor; Ctrl+E opens this list
```

[LANGUAGE.md](../LANGUAGE.md) walks the same ground feature by feature, with
prose around each of these.

## Language basics

| Example | Shows |
|---|---|
| `arithmetic.hl` | Integer vs Float, truncating `/`, `%`, precedence, unary minus |
| `numeric-literals.hl` | Hex/octal/binary Integers, `_` grouping, Float exponents |
| `strings.hl` | `Utf8` literals and escapes, `concat`, comparison |
| `comparison-and-logic.hl` | `==`/`<`/`>`, `and`/`or` — and the absence of boolean literals |
| `nothing-and-empty.hl` | `nothing` (unit) vs `empty` (the zero-entry Table) |

## Tables

| Example | Shows |
|---|---|
| `tables-map.hl` | `.field` and `[computed]` keys, field access, `concat` as update |
| `tables-sequence.hl` | `{a, b, c}` shorthand, `[i]` indexing, why `concat` isn't append |
| `table-and-concat.hl` | Overriding a single field of an existing Table |
| `table-destructuring.hl` | `is { .a as x }` patterns, and testing for a key without failing |
| `sequence-pattern.hl` | `{N}` exact-length patterns with positional binds |

## Functions and control flow

| Example | Shows |
|---|---|
| `functions.hl` | Omission sections, `as`-bind, pipe chaining |
| `functions-and-holes.hl` | `func`/`#arg`, `#arg2`, functions stored in Tables, `asfunc` |
| `guard-chain.hl` | A full guard chain: piped subject, accumulated bindings, `then`/`else` |
| `check-and-invariants.hl` | `check`/`static_check`, and why their failure is fatal |
| `optional.hl` | `present`/`empty` matching |
| `variant.hl` | `:.tag`, `!.tag` check-or-throw |
| `variants-dynamic.hl` | Computed tags (`::key`, `!:`), testing a tag with `is` |

## Files, context, concurrency

| Example | Shows |
|---|---|
| `files-sandboxed.hl` | Directory handles, contained sub-paths, `filetext`, path display |
| `files-symlink.hl` | `readlink` — and why symlinks aren't values of their own |
| `hashing.hl` | `sha256`, and the content identity that makes two Files one value |
| `hashing-directories.hl` | A directory's hash: its entries, and the one digest that reads |
| `hashing-functions.hl` | A closure's hash: its body's shape and the values it captures |
| `hashing-cyclic.hl` | Hashing a value that reaches itself, canonically |
| `cached.hl` | `cached` — evaluate once, read the answer back on every later run |
| `option-picker.hl` | A real program: read, branch, write into `ctx.cache` |
| `context-permissions.hl` | `ctx`, `chctx chperm`, `withctx` — capability narrowing |
| `async-basics.hl` | Two reads in flight at once, awaited implicitly |
| `async-table.hl` | Every Table entry fires before any is awaited |
| `async-branching.hl` | Why an untaken branch's `async` work still runs |

## Supporting files

`choice.txt`, `optiona.txt`, `optionb.txt` are inputs for `option-picker.hl` and
the async examples; `link-to-optiona` is a symlink `files-symlink.hl` reads.

`async-branching.hl` writes `branch-*.marker` files next to itself as evidence of
which branches ran. `createfile` is exclusive, so delete them before re-running
it.
