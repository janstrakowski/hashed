# Getting started

Everything shown in the [showcase video](README.md#progress) is real, runnable code. This walks through setting Hashed up and trying each of those things yourself.

## Setup

You need the [Odin compiler](https://odin-lang.org/) (this project tracks a recent nightly - `odin version` should print something like `dev-2026-08:...`; if your build fails with an unrelated syntax error, your Odin is probably too old).

```sh
git clone https://github.com/janstrakowski/hashed.git
cd hashed
odin build src -out:hl -debug
```

That produces an `hl` binary in the repo root. Everything below assumes you're running it from there (`./hl ...`).

Sanity check:

```sh
./hl -a examples/functions.hl
```

You should see an AST dump followed by `121`.

### On Windows

The same, with `hl.exe`. Odin links Windows binaries through the MSVC toolchain, so you also need the **Windows SDK** — otherwise the build stops at `Windows SDK not found.` before compiling anything. Visual Studio Build Tools with the "Desktop development with C++" workload is the smallest thing that provides it:

```
winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

Get Odin itself from the [release page](https://github.com/odin-lang/Odin/releases), not from winget: the `odin-lang.Odin` package lags the nightlies badly enough to matter — it was still on `dev-2026-05` while CI pinned `dev-2026-08`, and `winget upgrade` reports nothing available. Unzip `odin-windows-amd64-<version>.zip` somewhere and put that directory on your `PATH`; it is self-contained, linkers included.

Then clone and build. Clone with `core.symlinks=true` so `examples/link-to-optiona` arrives as a real symlink rather than a text file — that needs Developer Mode on, or an elevated shell, which is the same privilege `symlink` itself needs:

```
git clone -c core.symlinks=true https://github.com/janstrakowski/hashed.git
cd hashed
odin build src -out:hl.exe -debug
.\hl.exe -a examples/functions.hl
```

Everything below reads `./hl`; on Windows that is `.\hl.exe`. Read `-out:hl` as `-out:hl.exe` too. `scripts/` is shell, so the WASI builds want Git Bash (which ships with Git for Windows) rather than PowerShell.

If a freshly built binary refuses to start with *"An Application Control policy has blocked this file"*, that is [Smart App Control](https://support.microsoft.com/en-us/topic/what-is-smart-app-control-285ea03d-fa88-4495-bf75-c251c8d88d29) rather than anything wrong with the build — it blocks unsigned executables it has no reputation for. Building to a path outside the repository, or simply building again, usually gets past it.

## The ways to run something

- **`./hl path/to/program.hl`** - run a file for real, print its result.
- **`./hl -e '<expression>'`** - evaluate one expression and exit, like a single REPL submission. Handy for trying anything on this page without opening a file: `./hl -e '{ .a = 1 } concat { .b = 2 }'`.
- **`./hl`** (no arguments) - a line-based REPL. Type an expression, then an empty line to evaluate it; `:q` to quit.
- **`./hl -a path/to/program.hl`** - print the full AST before evaluating. Works with `-e` too.
- **`./hl -i`** - the live terminal editor (needs a real terminal, not a pipe).
- **`./hl --cache-dir <path> ...`** - override where `ctx.cache` writes to, and where `cached` keeps its entries (defaults to your XDG cache dir; `%LOCALAPPDATA%\hashed` on Windows). Handy for a throwaway cache: point it somewhere temporary and `cached` starts from nothing.
- **`./hl --help`**, **`./hl --version`** - usage and version.

## Try each part of the video

### 1. The parser - see the AST

`-a` is the same flag used in the video:

```sh
echo '5 |> (*2 + 1) |> (let x; x * x)' > demo.hl
./hl -a demo.hl
```

You'll see the whole expression grammar at work - pipe chaining (`|>`), an omission section (`*2 + 1`, a function of its omitted argument), and a `let`-bind with its value omitted (`let x; x * x`, a function whose argument is named) - as one real tree, followed by the evaluated result.

### 2. The evaluator - the REPL

```sh
./hl
```

Type `12 * (3 + 4) - 5`, press Enter, then Enter again on an empty line. You should get `79`. `:q` exits.

### 3. Real concurrency - `async`

The video's timing demo used a deliberately slow computation (a large lookup-heavy sum) specifically so the speedup was visible on a stopwatch. There is a real `fib` to reach for now that `let rec` exists (`./hl -e 'let rec fib (let n; (n < 2) then n else (fib (n - 1)) + (fib (n - 2))); fib 25'` takes a visible moment), but the everyday example already in the repo makes the point with less ceremony:

```sh
./hl examples/async-basics.hl
```

Open `examples/async-basics.hl` in an editor - it reads two files with `async`, so both reads fire concurrently rather than one after the other, and each is only actually awaited once something (here, `concat`) needs its real value. `examples/async-table.hl` (concurrent entries in a `Table`) and `examples/async-branching.hl` (an untaken branch's `async` work still has to finish, per SPEC.md §2) are worth a look too.

If you want to reproduce something closer to the video's *measured* 2-second comparison: `let t {0, 0, ..., 0}; t[1] + t[2] + ... + t[N]` (many bracket lookups into a large sequence-shaped table) gets slower roughly with `N²`; wrapping several of those in `async` and timing `hl` with and without it will show the same effect. Tune `N` for your machine.

### 4. The debugger - genuinely pausable

```sh
./hl -i
```

Then:

- `Ctrl+E` - open the examples picker, search for `async-branching`, `Enter` to load it.
- `Alt+5` - show the Debugger panel (`Alt+1`-`Alt+4` toggle Source/AST/Result/Steps if you want more room).
- `Ctrl+N` - advance one real step. Every currently-paused task (the main program, and any `async` task in flight) advances together, in lockstep.
- `Ctrl+R` - restart the run from scratch.

Watch for `✂` (a node that's been evaluated), `▶` (about to be evaluated next), `⏳` (something is blocked awaiting it), and `∅` (evaluated only because SPEC.md §2 requires an untaken branch's `async` work to finish anyway - its value gets discarded).

### 5. The live, self-hosted editor

Still in `./hl -i`: start typing an expression in the Source pane and watch the AST and Result panes react on every keystroke. `Alt+1` through `Alt+5` show/hide the Source/AST/Result/Steps/Debugger panels; `Alt+,` and `Alt+.` reorder them. `Ctrl+S` saves, `Ctrl+O` loads by path, `Ctrl+E` opens the examples picker, `Ctrl+Q` quits.

## Where to go next

- **[LANGUAGE.md](LANGUAGE.md)** - every feature that works today, with runnable snippets: values, operators, Tables, functions, pattern matching, failure, files, permissions, concurrency - and an explicit list of what isn't built yet.
- **[examples/](examples/)** - a runnable file per feature, indexed in [examples/README.md](examples/README.md). The test suite runs all of them.
- **`SPEC.md`** - the full, evolving language design, including the parts that don't run yet.
- **[The web terminal](https://janstrakowski.github.io/hashed/playground.html)** - the same CLI in your browser: the REPL, running files, and a filesystem that persists between visits. Nothing to install.
