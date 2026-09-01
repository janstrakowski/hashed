# Examples

Every file here runs today, and every one of them is executed by the test suite
and asserted against the value its header comment documents — so if the language
changes underneath an example, the build goes red rather than the example
quietly rotting. Adding a `.hb` file here without a corresponding assertion in
`src/examples_test.odin` also fails the suite.

Run one with:

```sh
./hb examples/tables-map.hb        # one that reads nothing needs no flags
./hb -a examples/functions.hb      # print the AST first
./hb dap                           # debug one from your editor
```

[LANGUAGE.md](../LANGUAGE.md) walks the same ground feature by feature, with
prose around each of these.

## Language basics

| Example | Shows |
|---|---|
| `arithmetic.hb` | Integer vs Float, truncating `/`, `%`, precedence, unary minus |
| `numeric-literals.hb` | Hex/octal/binary Integers, `_` grouping, Float exponents |
| `strings.hb` | `Utf8` literals and escapes, `concat`, comparison |
| `comparison-and-logic.hb` | `==`/`<`/`>`, `and`/`or` — and the absence of boolean literals |
| `nothing-and-empty.hb` | `nothing` (unit) vs `empty` (the zero-entry Table) |

## Tables

| Example | Shows |
|---|---|
| `tables-map.hb` | `.field` and `[computed]` keys, field access, `concat` as update |
| `tables-sequence.hb` | `{a, b, c}` shorthand, `[i]` indexing, why `concat` isn't append |
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
| `files-sandboxed.hb` | `ctx.dirs`, directory handles, contained sub-paths, `filetext`, path display |
| `files-symlink.hb` | `readlink` — and why symlinks aren't values of their own |
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
`tree/` (holding `a.txt` and `sub/b.txt`) is the small, unchanging directory
`hashing-directories.hb` opens twice.

## Running one

```sh
./hb examples/files-sandboxed.hb    # from anywhere, with no flags
```

An example that reads or writes declares the directories it uses in its own
prologue (SPEC.md §17), and those paths are relative to the file - which is why
no flags and no particular working directory are needed:

```hashedbuild
#Directory here .
```

The suite runs each example exactly that way, with no arguments at all, and
fails an example that touches the filesystem without declaring anything. There
is no second way to run one, so what is documented is what is tested.

`async-branching.hb` writes `branch-*.marker` files into the directory its
`run:` line hands it - this one, as evidence of which branches ran. `createfile`
is exclusive, so delete them before re-running it.
