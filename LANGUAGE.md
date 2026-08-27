# The HashedBuild language, feature by feature

Everything on this page runs in the language as it exists today. Each section
names the example that demonstrates it (`examples/…`, all of which are executed
by the test suite, so they can't drift from the implementation) and the
`SPEC.md` section that defines it.

Try any snippet directly:

```sh
./hb -e '{ .a = 1 } concat { .b = 2 }'      # one expression, then exit
./hb examples/tables-map.hb                 # a whole file
./hb                                        # a REPL: expression, blank line
```

`SPEC.md` is the design document and runs ahead of the implementation. This
page is the opposite: it only describes what works. [What isn't built
yet](#what-isnt-built-yet) at the bottom lists the gap.

---

## The shape of a program

A program is **one expression**. There are no statements, no top-level
declarations, and no entry point — the value that expression evaluates to is the
program's output, which `hb` prints.

Names come from `as`, which binds a value for the expression that follows it:

```hashedbuild
5 as x  x * x        // => 25
```

That is also all the "sequencing" there is: `<value> as <name> <body>` nests,
so a chain of `as` reads top-to-bottom while remaining a single expression.

## Values

| Type | Written | Notes |
|---|---|---|
| `Integer` | `42`, `-3` | 64-bit; `/` truncates |
| `Float` | `3.5`, `7.0` | one Float promotes the whole expression |
| `Utf8` | `"text"` | `\n`, `\t`, `\"` escapes; no interpolation |
| `Boolean` | — | no literals yet; comes out of comparisons and `is` |
| `Nothing` | `nothing` | the unit value |
| `Table` | `{ .a = 1 }`, `{10, 20}`, `empty` | the one composite type |
| `Function` | `func …`, `(*2)`, `asfunc …` | ordinary values |
| `File` | `loadfile "…"` | a file or directory; displays as its path |

→ `examples/arithmetic.hb`, `examples/strings.hb`,
`examples/nothing-and-empty.hb` (§3, §4, §6)

Two things surprise people early:

- **There are no `true`/`false` literals.** Every Boolean comes from a
  comparison (`1 < 2`), an `is` test, or a builtin. Where a false is needed
  literally — `chperm`'s `.enabled`, say — it's spelled `1 == 0`.
- **A `File`'s identity is its content, not its path** (§3). Two files with
  identical bytes are equal, wherever they were read from. The path exists for
  display only; nothing in the language reads it back out as a value.

## Operators

```hashedbuild
1 + 2 * 3          // arithmetic: + - * / %, unary minus binds tightest
7 / 2              // => 3    (Integer division truncates)
7.0 / 2            // => 3.5  (one Float promotes)
"a" concat "bc"    // => "abc"  (concat joins Utf8, and merges Tables)
1 < 2              // comparison: == > >= < <=
(1 < 2) and (2 < 3)
(1 > 2) or (2 < 3)
```

`concat` is one operator with two jobs: joining `Utf8` and merging `Table`s,
where the right side wins on a key collision. That second job is how you
"modify" an immutable value.

→ `examples/arithmetic.hb`, `examples/comparison-and-logic.hb` (§4, §6, §8)

## Tables

The one composite type, used as both record and sequence.

```hashedbuild
{ .name = "xz", .version = "5.8.3" }    // map-style
{ 10, 20, 30 }                          // sequence-style: keys 1, 2, 3
empty                                   // the zero-entry Table
"sha256" as k  { [k] = "abc123" }       // computed key: { sha256: "abc123" }
```

Read a field with `.name`, an element with `[i]` (1-based), and update by
merging:

```hashedbuild
pkg concat { .version = "5.8.4" }       // every other field unchanged
```

Reading a key that isn't there is a **failure**, not `nothing`. To ask whether
it exists, use a pattern (below) rather than an access.

→ `examples/tables-map.hb`, `examples/tables-sequence.hb`,
`examples/table-and-concat.hb` (§5)

## Functions

Three spellings, all producing ordinary values you can store in a Table, pass
around, and call:

```hashedbuild
(*2 + 1)                    // omission section: the blank operand is the argument
func (#arg * #arg)          // explicit; the argument is #arg
asfunc <expr>               // asserts an existing value is callable
```

Calling is juxtaposition — `f x` — and `|>` pipes a value into a function,
which is what makes chains read left-to-right:

```hashedbuild
5 |> (*2 + 1) |> (as x x * x)      // => 121
```

`#arg2` reaches the *enclosing* call's argument while that call is still
running. It's a call stack, not a lexical capture: a function that has already
been returned can't reach back through it.

→ `examples/functions.hb`, `examples/functions-and-holes.hb` (§7)

## Branching and pattern matching

Branching is built from ordinary composable operators rather than dedicated
`if` syntax:

- `<condition> then <happy>` — evaluates `<happy>` if the condition holds, and
  **fails** if it doesn't.
- `… else <bad>` — catches that specific failure, and must sit immediately
  after the `then` it belongs to.
- `<value> is <pattern>` — a Boolean test that also binds names on a match.
- `and` threads bindings rightward; `or` keeps its two sides independent.

```hashedbuild
pkg is { .name as name, .meta as meta } and meta is { .sha256 as digest }
  then digest
  else "no digest"
```

Chaining `then`/`else` gives if/else-if/else without any new grammar. Patterns
cover Tables (`{ .a as x }`), sequences (`{{2}: .1 as lhs, .2 as rhs}`), and
variants (`:.ok as payload`); a mismatch is `false`, never a failure, which is
why `is` is how you probe for a key you're not sure about.

→ `examples/guard-chain.hb`, `examples/table-destructuring.hb`,
`examples/sequence-pattern.hb` (§8)

## Variants and optionals

A variant is a Table convention, not separate syntax: a one-entry Table whose
key is the tag.

```hashedbuild
:.ok 42                 // tag with a literal name
::key "green"           // tag with a computed key
(:.ok 42) !. ok         // extract the payload, or fail
(:.ok 42) is :.ok as v  // test the tag and bind the payload, without failing
present 42              // the optional idiom: this tag is spelled `present`
empty                   // …and this is its absence
```

→ `examples/variant.hb`, `examples/variants-dynamic.hb`,
`examples/optional.hb`, `examples/nothing-and-empty.hb` (§5, §8)

## Failure

Four distinct failure sources, and exactly one of them is recoverable:

| | Recoverable? |
|---|---|
| `then` with a false condition | yes — by an `else` written immediately after it |
| `check(<cond>, <msg>) <body>` | **no** — fatal, no `else` anywhere catches it |
| `error <msg>` | **no** — same |
| a failed builtin call — missing file, escaping path, denied `io` | **no** — same |

`check` is for invariants that must hold; `then`/`else` is for branching. There
is deliberately no way to catch the fatal kinds (§8, §11).

The practical consequence is worth stating plainly: **"read this file, fall back
if it isn't there" is not currently expressible.** A failed `loadfile` ends the
program, `else` or no `else`, so a program has to be arranged so that the reads
it performs are ones that must succeed. Whether to add a recoverable I/O channel
is an open design question, not something the present `then`/`else` can be read
into.

`static_check` has `check`'s shape, for conditions meant to be settled before
the program runs.

→ `examples/check-and-invariants.hb` (§11)

## Files

Filesystem access is a small set of ordinary functions, not syntax (§16):

```hashedbuild
loadfile "notes.txt"                                  // relative to the source file
loadfile { .dir = <handle>, .path = "notes.txt" }     // contained to <handle>
createfile { .path = "out.txt", .content = "hi" }     // exclusive: fails if it exists
symlink { .dir = <handle>, .path = "l", .target = "t" }
readlink { .dir = <handle>, .path = "l" }
filetext <file>                                       // a regular file's bytes as Utf8
```

A directory `File` doubles as a handle, and the handle form is **contained**: a
sub-path can't escape it via `..`, an absolute path, or a symlink pointing
outward. Hand a program one directory handle and it cannot read outside it.

Paths in the single-argument form resolve relative to the source file being
run, not to your shell's working directory — so a script behaves the same
wherever you invoke it from.

→ `examples/files-sandboxed.hb`, `examples/files-symlink.hb`,
`examples/option-picker.hb` (§3, §16)

## Context and permissions

`ctx` is the ambient context. The filesystem builtins check
`ctx.permissions.io` **live**, at the moment they're called, so narrowing the
context genuinely narrows what an expression is allowed to do:

```hashedbuild
<expr> chctx chperm { .name = "io", .enabled = 1 == 0 }   // deny one permission
<expr> withctx (ctx concat { .permissions = empty })      // replace the context
```

The narrowing applies to the expression it's attached to and nothing else.
Ordinary functions capture `ctx` when they're created, so calling one later from
inside a wider context can't grant it more authority than it was made with;
builtins are the deliberate exception, since being restrictable from the outside
is the entire point.

`ctx.cache` is a write-only, content-addressed store: `createfile { .dir =
ctx.cache, .content = … }` writes under the content's own hash, deduplicating
across runs, and returns the `File` it wrote.

→ `examples/context-permissions.hb`, `examples/option-picker.hb` (§9, §16)

## Concurrency

`async <expr>` starts an expression on a real OS thread. Nothing is awaited
explicitly — a value is resolved at the moment something actually needs it:

```hashedbuild
(async filetext (loadfile "a.txt")) concat (async filetext (loadfile "b.txt"))
```

Both reads are in flight before `concat` needs either. Every entry of a Table
literal fires before any of them is awaited, which makes a Table the natural way
to run several things at once.

One rule catches people out: if a branch of a `then`/`else` contains `async`,
the **untaken** branch still runs to completion — only its value is discarded.
A started side effect can't be safely abandoned mid-flight.

The same reasoning applies at the end of a program: **a run waits for every
task it started**, including tasks nothing ever awaited, and including runs
that end in a fatal failure. So a program that dies partway through cannot
leave a `createfile` half-written — the failure is still fatal and still
uncatchable, but the work already in flight finishes first.

→ `examples/async-basics.hb`, `examples/async-table.hb`,
`examples/async-branching.hb` (§2)

## What isn't built yet

Parsed, specified, and rejected by the evaluator with "not implemented":
`import`, `serialize`, `serialize_file`, `sha256`, `cached`.

Also absent: `true`/`false` literals, loops and recursion of any kind, a
`Bytes`-returning counterpart to `filetext`, directory listing as a value, and
the `#context` implicit name. `SPEC.md` describes several of these as settled
design; none of them run today.

## Running somewhere other than Linux

The interpreter also builds for **WASI**, which is what lets it run in a
browser or any wasm runtime. There are two flavours, because no single module
suits every host:

```sh
scripts/build_wasi.sh                      # portable -> hb.wasm
wasmtime run --dir=. hb.wasm examples/tables-map.hb

scripts/build_wasi.sh --threads            # wasi-threads -> hb-threads.wasm
iwasm --max-threads=8 --dir=. hb-threads.wasm examples/async-table.hb
```

**Portable** runs anywhere preview1 does, wasmtime included — but it has no
threads, so `async` **fails** there rather than pretending:

```
error: async: this build has no thread support (see LANGUAGE.md on the WASI flavours)
```

That is deliberate. `async` means *concurrently*; a build that quietly ran the
task inline would hand back the right value having taken exactly the time the
program was written to avoid, and nothing would say so.

**Threaded** uses the wasi-threads proposal: shared linear memory, atomics,
and an imported `wasi.thread-spawn`. `async` then runs on real OS threads, and
the speedup is real - four independent `async` tasks measured 2.81s → 1.03s.
It runs only on hosts implementing the proposal (WAMR, WasmEdge built with it);
wasmtime removed its support in June 2026 and rejects the module over the
unknown import.

Either way, one thing differs from native, enforced by the target rather than
chosen: **a program can only reach what the host preopened for it.** WASI has
no working directory and no absolute paths, so `--dir=.` grants the current
directory and granting nothing makes every filesystem builtin fail - which is
`ctx.permissions.io` (§9) enforced by the runtime instead of the interpreter.
Displayed paths are relative to that preopen, so a file shows as
`/examples/optiona.txt` there and as its checkout path natively.

`scripts/wasi_smoke.sh` runs the examples on a wasm build and compares them
against native; CI does it for both flavours on every push.

## In a browser

[**The terminal**](https://janstrakowski.github.io/hashedbuild/playground.html)
is this same CLI, compiled to WebAssembly and running in your own tab:

```
$ hb tour.hb            run a program
$ hb -e '1 + 2 * 3'     evaluate an expression
$ hb                    the REPL - an expression, then a blank line
$ ls / cat / reset      look around
```

Files written with `createfile` persist between visits, in your browser's
IndexedDB — no server, nothing sent anywhere, and clearing site data is the
uninstall. It is the portable build, so `async` refuses there.

Bare `hb` deserves a note: the real REPL loop reads stdin, which a wasm module
cannot block on in a browser. It doesn't have to — that loop evaluates every
submission with a *fresh* interpreter and environment, so the page runs one
instance per submission and the behaviour is identical, prompts and all.

The page is `docs/playground.html`; the WASI host under it is `docs/wasi.js`,
about 400 lines implementing the 21 preview1 calls the interpreter actually
imports.

## Where to go next

- **[GETTING_STARTED.md](GETTING_STARTED.md)** — installing, the REPL, the live
  editor, and the debugger.
- **[examples/](examples/)** — every snippet above, as a runnable file.
- **[SPEC.md](SPEC.md)** — the full design, including the parts not yet built.
