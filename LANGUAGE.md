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

Names come from `let`, which binds a value for the expression that follows the
`;`:

```hashedbuild
let x 5; x * x       // => 25
```

That is also all the "sequencing" there is: `let <name> <value>; <body>` nests,
so a chain of `let` reads top-to-bottom while remaining a single expression:

```hashedbuild
let a 1; let b 2; a + b        // => 3
```

The `;` terminates the bound value, so that value can be any expression without
needing parens — including one ending in `withctx` (below), which is the one
place the nesting can surprise you in reverse: a `let` written *inside* another
one's bound value has to be parenthesized, `let a (let b 1; b + 1); a`, or it
takes the outer `;` for itself.

## Values

| Type | Written | Notes |
|---|---|---|
| `Integer` | `42`, `0x2A`, `0o52`, `0b101010` | 64-bit; `/` truncates |
| `Float` | `3.5`, `7.0`, `1.5e3` | one Float promotes the whole expression |
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

### Writing numbers

An `Integer` can be written in four bases, and `_` groups digits anywhere
between them:

```hashedbuild
0x2A                 // hex, upper or lower: 0X2a is the same 42
0o52                 // octal - an explicit prefix, not a bare leading zero
0b101010             // binary
1_000_000            // grouping, allowed in every base: 0xFF_FF
```

A literal is a `Float` if and only if it contains a `.` or an exponent — no
suffix says which type is meant:

```hashedbuild
0.5                  // a digit is required on both sides: `.5` is not a Float
1.5e3                // => 1500 ... as a Float
1.5E-3               // the exponent may be signed, and `_`-grouped too
```

Two things to know. A `Float` with nothing after the point **displays without
one** — `1.5e3` prints as `1500`, exactly as the `Integer` 1500 does — and yet
the two are not equal, because no literal is coerced to the other's type. And
malformed grouping (`1__0`, `1_`, `0x_F`) is currently accepted rather than
rejected, which `SPEC.md` §3 says it should not be.

→ `examples/numeric-literals.hb` (§3)

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
let k "sha256"; { [k] = "abc123" }      // computed key: { sha256: "abc123" }
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
let x; x * x                // named argument: the bound value is the blank
asfunc <expr>               // asserts an existing value is callable
```

The third is an ordinary `let` with nothing written between the name and the
`;`. That blank is the same omission as the first line's — it just makes the
whole binding a function of the value that fills it, which is how an argument
gets a name.

Calling is juxtaposition — `f x` — and `|>` pipes a value into a function,
which is what makes chains read left-to-right:

```hashedbuild
5 |> (*2 + 1) |> (let x; x * x)    // => 121
```

`#arg2` reaches the *enclosing* call's argument while that call is still
running. It's a call stack, not a lexical capture: a function that has already
been returned can't reach back through it.

→ `examples/functions.hb`, `examples/functions-and-holes.hb` (§7)

## Recursion

A plain `let` evaluates its value before the name exists, so a function bound
that way can't call itself. `let rec` binds the name first:

```hashedbuild
let rec fact (let n; (n == 0) then 1 else n * (fact (n - 1))); fact 10
// => 3628800
```

A function with no name recurses through `#self` — the function currently
running, alongside `#arg` for the value it was called with. `#self2` reaches
one call further out, exactly as `#arg2` does:

```hashedbuild
(func (#arg == 0) then 1 else #arg * (#self (#arg - 1))) 5      // => 120
```

Two functions that call each other can't be bound one after the other — the
first would name something that doesn't exist yet — so bind one Table of them
recursively instead:

```hashedbuild
let rec fns {
  .even = (let n; (n == 0) then 1 else fns.odd (n - 1)),
  .odd = (let n; (n == 0) then 0 else fns.even (n - 1)),
};
fns.even 8       // => 1  (there are no true/false literals)
```

Recursion has no *specified* depth. The evaluator walks the tree on the host's
own call stack and stops with `evaluation nested too deeply` before running out
of it — a fatal failure like any other, catchable by nothing. How deep that is
depends on the shape of the function's body, not on a fixed number of calls: a
body that nests heavily exhausts the budget in fewer recursions than a simple
one. Deep recursion is not what this language is for; if you hit the limit,
that is the message you get rather than a crash.

→ `examples/recursion.hb`, `examples/recursion-anonymous.hb` (§9/§10)

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

Five distinct failure sources, and exactly one of them is recoverable:

| | Recoverable? |
|---|---|
| `then` with a false condition | yes — by an `else` written immediately after it |
| `check(<cond>, <msg>) <body>` | **no** — fatal, no `else` anywhere catches it |
| `error <msg>` | **no** — same |
| a failed builtin call — missing file, escaping path, denied `io` | **no** — same |
| evaluation nested too deeply — see [Recursion](#recursion) | **no** — same |

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
On Windows the same guarantee covers the forms that platform adds — a
backslash-separated `..\..\x`, a drive-qualified `C:\x` or `C:x`, an alternate
data stream (`name:stream`), and a junction as well as a symlink.

Paths in the single-argument form resolve relative to the source file being
run, not to your shell's working directory — so a script behaves the same
wherever you invoke it from.

→ `examples/files-sandboxed.hb`, `examples/files-symlink.hb`,
`examples/option-picker.hb` (§3, §16)

## Hashing

`sha256` takes one trailing expression, like `func` or `async`, and returns the
digest of the value it evaluates to, base64-encoded as `Utf8`:

```hashedbuild
sha256 "hello"                    // => "Ar9oHTBiuRDqs+ZdbYD2daaU7RcvIDTJNB3UICNP92A="
sha256 loadfile "pkg.tar.gz"      // exactly what sha256sum reports for that file
sha256 { .a = 1, .b = 2 }
```

This is not a checksum utility bolted on the side — it is the value identity
the rest of the language already runs on, made visible. Three consequences
follow from that, and they are the reason to reach for it:

- **A regular `File` hashes as its content bytes and nothing else.** No path,
  no name, no length prefix of the language's own. So
  `sha256 loadfile "pkg.tar.gz"` is the digest `sha256sum` prints for the same
  file, which is what makes it checkable against a hash upstream published.
- **A `Table` hashes over its entries sorted by key**, so the order they were
  written in doesn't matter — `{ .a = 1, .b = 2 }` and `{ .b = 2, .a = 1 }`
  hash alike, exactly as they compare equal.
- **Equal values hash alike, and unequal ones don't.** `Integer` 5 and `Float`
  5.0 are not equal in this language, so they don't collide; nor do `Utf8`
  `"1"` and `Integer` 1.

That last point is what makes `File` equality work at all: two `File`s are the
same value when their bytes match, however they were reached.

```hashedbuild
(loadfile "a.txt") == (loadfile "copy-of-a.txt")   // true, if the bytes match
```

**Every kind of value hashes.** The three that used to have no digest all got
one when `cached` was built, since `cached` needs them:

- A **directory** `File` hashes over its entries — each name, each file's
  content and executable bit, each subdirectory's own hash, and each symlink's
  target string, unresolved (§3). Sorted by name, so readdir order doesn't
  matter. One caveat, and it is a real one: **only Linux can report an
  executable bit.** WASI's `filestat` has no permission bits and Windows has no
  POSIX execute bit, so both hash every entry as non-executable — a tree
  containing an executable therefore hashes differently there than on Linux.
- A **`Function`** hashes as its code (the shape of the expression, so
  reformatting it or writing a comment inside changes nothing), its captured
  `ctx`, and the values of the names it uses.
- **`ctx.cache`** hashes as a constant. It is write-only and has no identity to
  distinguish one from another, and making it a constant is what keeps a cache
  directory valid after it is moved or copied — see below.

Hashing a directory reads the whole tree, so `sha256 <directory>` and `==`
between two directory `File`s are filesystem walks, not cheap comparisons.

→ `examples/hashing.hb` (§3, §6, §15)

## Caching

`cached` takes one trailing expression, like `sha256`, and evaluates it once:
every later run reads the answer back instead of computing it.

```hashedbuild
cached (6 * 7)                          // => 42, and again on every later run
cached (loadfile "pkg.tar.gz")          // the bytes as they were the first time
```

**The key is the expression treated as a function**, hashed with the one hash
system above (§15). Three things go into it, and it is worth knowing which:

- **the code**, structurally — so reformatting an expression or writing a
  comment inside it does not throw its entry away;
- **the `ctx` it runs under** (§9), whole;
- **the values it reads** — the names it uses, and anything it reaches through
  `#arg`/`#self`. So `let bump func (cached (#arg + 1))` gets one entry per
  argument, not one entry.

What is deliberately *not* in the key is anything the expression goes and reads
at run time. That is the point of a cache, and its one sharp edge: cache
`loadfile "pkg.tar.gz"` and you keep getting the bytes from the first run,
however the file changes afterwards.

**Where entries live.** In `ctx.cache`'s directory — `--cache-dir <path>`, else
`$XDG_CACHE_HOME/hashedbuild`, else the per-user default — one entry per key,
named `sha256-<key>`:

```
<cache>/sha256-<key>                  a File value, stored as itself
<cache>/sha256-<key>.hb/              anything else
<cache>/sha256-<key>.hb/value.hb        the value, as HashedBuild text
<cache>/sha256-<key>.hb/sha256-<h>      each File inside it, by content hash
```

A `File` value stays a file and a directory value stays a directory, so what a
build produced is still something you can open, `diff` or copy out. Anything
else is written as text you can read; the `File`s it holds cannot go in text,
so they are stored beside it and referred to by name. Entries are built under a
temporary name and renamed into place, so an interrupted run leaves a `.tmp`
rather than a half-written entry, and two runs racing on one key settle it
without locking anything.

**What it refuses.** `cached` needs `ctx.permissions.io`, since it reads and
writes files, and it needs a `ctx` that still carries `.cache`. A value holding
a `Function`, `ctx.cache`, or an un-awaited `async` handle cannot be written
down and read back as itself, so caching one fails rather than storing
something that would come back different. All of these are fatal failures like
any other (§8).

`async` is positional, and the two placements mean different things:
`async cached <expr>` makes the cache lookup itself asynchronous, while
`cached async <expr>` runs the expression on a thread with the caching wrapper
around it synchronous.

→ `examples/cached.hb` (§15)

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
across runs, and returns the `File` it wrote. Its directory is also where
`cached` keeps its entries (see "Caching"); the two are told apart by their
names, `sha256_<content>` for a blob written this way and `sha256-<key>` for a
cache entry.

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
`import`.

Hashing is complete: every kind of value has a digest, including the three
(directory `File`, `Function`, `ctx.cache`) that used to fail by name. The one
thing to know about it is not a gap but a difference between targets — the
executable bit in a directory's hash, which only Linux can report. See
"Hashing" above.

Also absent: `true`/`false` literals, loops of any kind (recursion is the only
repetition there is — see above), a `Bytes`-returning counterpart to
`filetext`, directory listing as a value, and the `#context` implicit name. `SPEC.md` describes several of these as settled
design; none of them run today.

Removed rather than pending: `serialize` and `serialize_file` were specified in
§15 and are gone as of 2026-08-28 — the canonical byte encoding they would have
exposed still exists, but only as the thing `sha256` hashes over. Both names are
ordinary identifiers again.

## Running somewhere other than Linux

### Windows

Windows is a native target like Linux, built and tested the same way:

```
odin build src -out:hb.exe
.\hb.exe examples/option-picker.hb
```

Everything in this document works there — the same parser, evaluator, `async`
on real threads, the filesystem builtins, and `hb.exe -i` for the live editor
and debugger (the console is put into virtual-terminal mode, so the keys are
the ones listed above, not a separate Windows set).

Four things are visibly Windows rather than Linux, and none of them is a
different language:

- **Paths display with forward slashes and a drive**, so a file shows as
  `<file: C:/Users/you/project/out.txt>`. One form for every target, and Win32
  accepts it as readily as backslashes.
- **You may type either separator.** `"src\lib\x.txt"` and `"src/lib/x.txt"`
  mean the same thing in a sub-path, and both are contained the same way. (On
  Linux a backslash is an ordinary character in a filename, and stays one.)
- **`ctx.cache` lives in `%LOCALAPPDATA%\hashedbuild`** rather than
  `~/.cache/hashedbuild`. `XDG_CACHE_HOME` still wins where it is set, and
  `--cache-dir` still overrides both.
- **`symlink` needs the privilege Windows requires for it**: turn on Developer
  Mode, or run elevated. Without it the call fails the way any refused
  operation does — `symlink: could not create l (Access)`. `readlink` needs no
  privilege and reads junctions as well as symlinks.

That last point also affects **cloning this repository on Windows**:
`examples/link-to-optiona` is committed as a symlink, and git only checks it
out as one when `core.symlinks` is on, which needs the same privilege. Clone
with it enabled to get the real thing:

```
git clone -c core.symlinks=true https://github.com/janstrakowski/hashedbuild.git
```

Without it, git writes an ordinary file holding the target as text, and
`examples/files-symlink.hb` has nothing to read — the test suite detects that
and skips just that example rather than failing.

### WASI

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
is this CLI, compiled to WebAssembly and running in your own tab, with the
repository as its filesystem — the same files you would have after cloning:

```
$ ls                          the repo: src/, examples/, SPEC.md, …
$ cat examples/guard-chain.hb
$ hb examples/guard-chain.hb  run it
$ hb -e '1 + 2 * 3'           evaluate an expression
$ hb                          the REPL, reading what you type
```

`hb` there is the interpreter's **real** REPL loop, blocking on stdin: the
banner, the `hb> ` and `... ` prompts and `:q` come out of the module, not out
of the page. That works because the interpreter runs in a Web Worker, which can
block without freezing the tab, reading a `SharedArrayBuffer` the page writes
into — and that in turn needs cross-origin isolation, which a service worker
supplies since GitHub Pages cannot set the headers itself. Ctrl+D sends
end-of-input.

`hb -i` opens the **live editor** in there too: the same two-to-four-pane TUI as
on a real terminal, re-parsing and re-evaluating on every keystroke, with the
examples picker (Ctrl+E) listing the repository and the debugger stepping a
paused run. It draws ANSI into xterm.js, which the page loads only when you ask
for it. Its keys need a word of explanation, because a browser tab is not a terminal:
`Alt`+number is the browser's tab switcher, so the page takes those keys back
before the browser acts on them — and `Ctrl+N` and `Ctrl+Q` cannot be taken
back at all (they open a window and quit the browser, decided before any page
sees the key), so there they are **`Ctrl+Alt+N`** to step the debugger and
**`Ctrl+Alt+Q`** to quit. The editor's own status line says so when it is
running in a browser.

**`async` runs on real threads there**, which is the same wasi-threads build the
CLI uses — the browser just implements the proposal itself: `thread-spawn`
starts another Worker, instantiating the same module against the same
`WebAssembly.Memory`. That shared memory is also what makes the filesystem work
across threads: every WASI call's arguments are pointers into it, so a spawned
thread marshals the call to whichever worker owns the filesystem and blocks on
the answer, without copying anything.

Anything a program writes stays in your browser's IndexedDB: `createfile` lands
in the filesystem, `ctx.cache` writes to `/cache/hashedbuild`, and both survive
a reload. When the repository itself moves on, a returning visitor's copy of it
is written over to match — anything you made is left alone, and `reset` puts
everything back. No server, nothing sent anywhere, and clearing site data is the
uninstall.

The page is `docs/playground.html`; `docs/terminal-worker.js` owns the
filesystem and spawns threads; `docs/exec-worker.js` is one instance of the
interpreter (the program, or a thread it spawned); and `docs/wasi.js` is the
WASI host under all of it, implementing the preview1 calls the interpreter
imports plus the marshalling that carries them between threads.

## Where to go next

- **[GETTING_STARTED.md](GETTING_STARTED.md)** — installing, the REPL, the live
  editor, and the debugger.
- **[examples/](examples/)** — every snippet above, as a runnable file.
- **[SPEC.md](SPEC.md)** — the full design, including the parts not yet built.
