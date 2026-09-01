# Examples

Every file here runs today, and every one of them is executed by the test suite
and asserted against the value its header comment documents — so if the language
changes underneath an example, the build goes red rather than the example
quietly rotting. Adding a `.hb` file here without a corresponding assertion in
`src/examples_test.odin` also fails the suite.

Run one with:

```sh
./hb examples/tables-map.hb        # from anywhere - paths resolve to the file
./hb -a examples/functions.hb      # print the AST first
./hb -i                            # the live editor; Ctrl+E opens this list
```

[LANGUAGE.md](../LANGUAGE.md) walks the same ground feature by feature, with
prose around each of these.

Two entries here are not single-value examples and so are not in that table:
`listing/` is a small fixture directory `listing-a-directory.hb` reads, and
`hashmake/` is a whole project - a build description plus a vendored cJSON
checkout - covered by its own test and its own README rather than by an
asserted value.

## Language basics

| Example | Shows |
|---|---|
| `arithmetic.hb` | Integer vs Float, truncating `/`, `%`, precedence, unary minus |
| `numeric-literals.hb` | Hex/octal/binary Integers, `_` grouping, Float exponents |
| `text-slicing.hb` | `textlen`/`textslice`, counting codepoints — and `endswith` built on them |
| `strings.hb` | `Utf8` literals and escapes, `concat`, comparison |
| `comparison-and-logic.hb` | `==`/`<`/`>`, `and`/`or` — and the absence of boolean literals |
| `nothing-and-empty.hb` | `nothing` (unit) vs `empty` (the zero-entry Table) |

## Tables

| Example | Shows |
|---|---|
| `tables-map.hb` | `.field` and `[computed]` keys, field access, `concat` as update |
| `tables-sequence.hb` | `{a, b, c}` shorthand, `[i]` indexing, why `concat` isn't append |
| `folding-a-table.hb` | `fold` — the one traversal, and why it walks in key order |
| `table-and-concat.hb` | Overriding a single field of an existing Table |
| `table-destructuring.hb` | `is { .a as x }` patterns, and testing for a key without failing |
| `sequence-pattern.hb` | `{N}` exact-length patterns with positional binds |

## Functions and control flow

| Example | Shows |
|---|---|
| `functions.hb` | Omission sections, `as`-bind, pipe chaining |
| `functions-and-holes.hb` | `func`/`#arg`, `#arg2`, functions stored in Tables, `asfunc` |
| `guard-chain.hb` | A full guard chain: piped subject, accumulated bindings, `then`/`else` |
| `check-and-invariants.hb` | `check`/`static_check`, and why their failure is fatal |
| `optional.hb` | `present`/`empty` matching |
| `variant.hb` | `:.tag`, `!.tag` check-or-throw |
| `variants-dynamic.hb` | Computed tags (`::key`, `!:`), testing a tag with `is` |

## Files, context, concurrency

| Example | Shows |
|---|---|
| `files-sandboxed.hb` | Directory handles, contained sub-paths, `filetext`, path display |
| `files-symlink.hb` | `readlink` — and why symlinks aren't values of their own |
| `listing-a-directory.hb` | `listdir`, and filtering a listing down to what you want |
| `workdir-containment.hb` | `ctx.dir`, and the three things a handle-less path may reach |
| `running-a-program.hb` | `exec` — a program's inputs and outputs as values |
| `hashing.hb` | `sha256`, and the content identity that makes two Files one value |
| `hashing-directories.hb` | A directory's hash: its entries, and the one digest that reads |
| `hashing-functions.hb` | A closure's hash: its body's shape and the values it captures |
| `hashing-cyclic.hb` | Hashing a value that reaches itself, canonically |
| `cached.hb` | `cached` — evaluate once, read the answer back on every later run |
| `option-picker.hb` | A real program: read, branch, write into `ctx.cache` |
| `context-permissions.hb` | `ctx`, `chctx chperm`, `withctx` — capability narrowing |
| `async-basics.hb` | Two reads in flight at once, awaited implicitly |
| `async-table.hb` | Every Table entry fires before any is awaited |
| `async-branching.hb` | Why an untaken branch's `async` work still runs |

## Supporting files

`choice.txt`, `optiona.txt`, `optionb.txt` are inputs for `option-picker.hb` and
the async examples; `link-to-optiona` is a symlink `files-symlink.hb` reads;
`listing/` holds three files with fixed names so `listing-a-directory.hb` can
assert a stable answer.

`hashmake/` is a whole worked project rather than an example file — a build
description and a vendored cJSON checkout. See `hashmake/README.md`.

`async-branching.hb` writes `branch-*.marker` files next to itself as evidence of
which branches ran. `createfile` is exclusive, so delete them before re-running
it.
