# Getting started

Everything shown in the [showcase video](README.md#progress) is real, runnable code. This walks through setting HashedBuild up and trying each of those things yourself.

## Setup

You need the [Odin compiler](https://odin-lang.org/) (this project tracks a recent nightly - `odin version` should print something like `dev-2026-08:...`; if your build fails with an unrelated syntax error, your Odin is probably too old).

```sh
git clone https://github.com/janstrakowski/hashedbuild.git
cd hashedbuild
odin build src -out:hb -debug
```

That produces an `hb` binary in the repo root. Everything below assumes you're running it from there (`./hb ...`).

Sanity check:

```sh
./hb -a examples/functions.hb
```

You should see an AST dump followed by `121`.

## The ways to run something

- **`./hb path/to/program.hb`** - run a file for real, print its result.
- **`./hb -e '<expression>'`** - evaluate one expression and exit, like a single REPL submission. Handy for trying anything on this page without opening a file: `./hb -e '{ .a = 1 } concat { .b = 2 }'`.
- **`./hb`** (no arguments) - a line-based REPL. Type an expression, then an empty line to evaluate it; `:q` to quit.
- **`./hb -a path/to/program.hb`** - print the full AST before evaluating. Works with `-e` too.
- **`./hb -i`** - the live terminal editor (needs a real terminal, not a pipe).
- **`./hb --cache-dir <path> ...`** - override where `ctx.cache` writes to (defaults to your XDG cache dir).
- **`./hb --help`**, **`./hb --version`** - usage and version.

## Try each part of the video

### 1. The parser - see the AST

`-a` is the same flag used in the video:

```sh
echo '5 |> (*2 + 1) |> (as x x * x)' > demo.hb
./hb -a demo.hb
```

You'll see the whole expression grammar at work - pipe chaining (`|>`), an omission section (`*2 + 1`, a function of its omitted argument), and an `as`-bind - as one real tree, followed by the evaluated result.

### 2. The evaluator - the REPL

```sh
./hb
```

Type `12 * (3 + 4) - 5`, press Enter, then Enter again on an empty line. You should get `79`. `:q` exits.

### 3. Real concurrency - `async`

The video's timing demo used a deliberately slow computation (a large lookup-heavy sum) specifically so the speedup was visible on a stopwatch - the language has no loops/recursion yet, so there's no real `fib`/`primegen` to reach for. A much simpler, everyday example is in the repo:

```sh
./hb examples/async-basics.hb
```

Open `examples/async-basics.hb` in an editor - it reads two files with `async`, so both reads fire concurrently rather than one after the other, and each is only actually awaited once something (here, `concat`) needs its real value. `examples/async-table.hb` (concurrent entries in a `Table`) and `examples/async-branching.hb` (an untaken branch's `async` work still has to finish, per SPEC.md §2) are worth a look too.

If you want to reproduce something closer to the video's *measured* 2-second comparison: `{0, 0, ..., 0} as t  t[1] + t[2] + ... + t[N]` (many bracket lookups into a large sequence-shaped table) gets slower roughly with `N²`; wrapping several of those in `async` and timing `hb` with and without it will show the same effect. Tune `N` for your machine.

### 4. The debugger - genuinely pausable

```sh
./hb -i
```

Then:

- `Ctrl+E` - open the examples picker, search for `async-branching`, `Enter` to load it.
- `Alt+5` - show the Debugger panel (`Alt+1`-`Alt+4` toggle Source/AST/Result/Steps if you want more room).
- `Ctrl+N` - advance one real step. Every currently-paused task (the main program, and any `async` task in flight) advances together, in lockstep.
- `Ctrl+R` - restart the run from scratch.

Watch for `✂` (a node that's been evaluated), `▶` (about to be evaluated next), `⏳` (something is blocked awaiting it), and `∅` (evaluated only because SPEC.md §2 requires an untaken branch's `async` work to finish anyway - its value gets discarded).

### 5. The live, self-hosted editor

Still in `./hb -i`: start typing an expression in the Source pane and watch the AST and Result panes react on every keystroke. `Alt+1` through `Alt+5` show/hide the Source/AST/Result/Steps/Debugger panels; `Alt+,` and `Alt+.` reorder them. `Ctrl+S` saves, `Ctrl+O` loads by path, `Ctrl+E` opens the examples picker, `Ctrl+Q` quits.

## Where to go next

- **[LANGUAGE.md](LANGUAGE.md)** - every feature that works today, with runnable snippets: values, operators, Tables, functions, pattern matching, failure, files, permissions, concurrency - and an explicit list of what isn't built yet.
- **[examples/](examples/)** - a runnable file per feature, indexed in [examples/README.md](examples/README.md). The test suite runs all of them.
- **`SPEC.md`** - the full, evolving language design, including the parts that don't run yet.
- **[The playground](https://janstrakowski.github.io/hashedbuild/playground.html)** - the whole interpreter running in your browser, with a filesystem that persists between visits. Nothing to install.
