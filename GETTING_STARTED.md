# Getting started

Everything in [README.md](README.md) and [LANGUAGE.md](LANGUAGE.md) is real, runnable code. This walks through setting HashedBuild up and trying it yourself.

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

### On Windows

The same, with `hb.exe`. Odin links Windows binaries through the MSVC toolchain, so you also need the **Windows SDK** — otherwise the build stops at `Windows SDK not found.` before compiling anything. Visual Studio Build Tools with the "Desktop development with C++" workload is the smallest thing that provides it:

```
winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

Get Odin itself from the [release page](https://github.com/odin-lang/Odin/releases), not from winget: the `odin-lang.Odin` package lags the nightlies badly enough to matter — it was still on `dev-2026-05` while CI pinned `dev-2026-08`, and `winget upgrade` reports nothing available. Unzip `odin-windows-amd64-<version>.zip` somewhere and put that directory on your `PATH`; it is self-contained, linkers included.

Then clone and build. Clone with `core.symlinks=true` so `examples/link-to-optiona` arrives as a real symlink rather than a text file — that needs Developer Mode on, or an elevated shell, which is the same privilege `symlink` itself needs:

```
git clone -c core.symlinks=true https://github.com/janstrakowski/hashedbuild.git
cd hashedbuild
odin build src -out:hb.exe -debug
.\hb.exe -a examples/functions.hb
```

Everything below reads `./hb`; on Windows that is `.\hb.exe`. Read `-out:hb` as `-out:hb.exe` too. `scripts/` is shell, so the WASI builds want Git Bash (which ships with Git for Windows) rather than PowerShell.

If a freshly built binary refuses to start with *"An Application Control policy has blocked this file"*, that is [Smart App Control](https://support.microsoft.com/en-us/topic/what-is-smart-app-control-285ea03d-fa88-4495-bf75-c251c8d88d29) rather than anything wrong with the build — it blocks unsigned executables it has no reputation for. Building to a path outside the repository, or simply building again, usually gets past it.

## The ways to run something

- **`./hb path/to/program.hb`** - run a file for real, print its result.
- **`./hb -e '<expression>'`** - evaluate one expression and exit, like a single REPL submission. Handy for trying anything on this page without opening a file: `./hb -e '{ .a = 1 } concat { .b = 2 }'`.
- **`./hb`** (no arguments) - a line-based REPL. Type an expression, then an empty line to evaluate it; `:q` to quit.
- **`./hb -a path/to/program.hb`** - print the full AST before evaluating. Works with `-e` too.
- **`./hb --dir <name>=<path> ...`** - open `<path>` and hand it to the program as `ctx.dirs.<name>`. This is the *only* way a program reaches the filesystem: it can read and write inside the directories named here, by name, and cannot name anything else. Repeatable, so `--dir src=./src --dir out=/tmp/out` hands over two. A run with no `--dir` hands over nothing, and such a program cannot touch the filesystem at all. Any path the shell accepts works here - absolute, relative, `..` and all - because it is resolved before the program starts; the sub-paths a *program* writes may say none of that.

  Every example that reads or writes carries the command line it needs on a `run:` line in its own header, so running one is a copy-and-paste:

  ```sh
  head -1 examples/option-picker.hb        # // run: hb --dir here=. option-picker.hb
  cd examples && ../hb --dir here=. option-picker.hb
  ```

  The same flags go into a debug session's launch configuration, for the same reason: a program being debugged reaches exactly what it was given, and nothing else.
- **`./hb --cache-dir <path> ...`** - override where `ctx.cache` writes to, and where `cached` keeps its entries (defaults to your XDG cache dir; `%LOCALAPPDATA%\hashedbuild` on Windows). Handy for a throwaway cache: point it somewhere temporary and `cached` starts from nothing.
- **`hb dap`** - a debug adapter on stdin/stdout, for an editor to drive. Not something you run by hand; see [Debugging](#debugging) below.
- **`./hb --help`**, **`./hb --version`** - usage and version.

## Try each part

### 1. The parser - see the AST

`-a` is the same flag used in the video:

```sh
echo '5 |> (*2 + 1) |> (let x; x * x)' > demo.hb
./hb -a demo.hb
```

You'll see the whole expression grammar at work - pipe chaining (`|>`), an omission section (`*2 + 1`, a function of its omitted argument), and a `let`-bind with its value omitted (`let x; x * x`, a function whose argument is named) - as one real tree, followed by the evaluated result.

### 2. The evaluator - the REPL

```sh
./hb
```

Type `12 * (3 + 4) - 5`, press Enter, then Enter again on an empty line. You should get `79`. `:q` exits.

### 3. Real concurrency - `async`

The video's timing demo used a deliberately slow computation (a large lookup-heavy sum) specifically so the speedup was visible on a stopwatch. There is a real `fib` to reach for now that `let rec` exists (`./hb -e 'let rec fib (let n; (n < 2) then n else (fib (n - 1)) + (fib (n - 2))); fib 25'` takes a visible moment), but the everyday example already in the repo makes the point with less ceremony:

```sh
./hb examples/async-basics.hb
```

Open `examples/async-basics.hb` in an editor - it reads two files with `async`, so both reads fire concurrently rather than one after the other, and each is only actually awaited once something (here, `concat`) needs its real value. `examples/async-table.hb` (concurrent entries in a `Table`) and `examples/async-branching.hb` (an untaken branch's `async` work still has to finish, per SPEC.md §2) are worth a look too.

If you want to reproduce something closer to the video's *measured* 2-second comparison: `let t {0, 0, ..., 0}; t[1] + t[2] + ... + t[N]` (many bracket lookups into a large sequence-shaped table) gets slower roughly with `N²`; wrapping several of those in `async` and timing `hb` with and without it will show the same effect. Tune `N` for your machine.

## Debugging

There is no debugger UI in this repository, on purpose. `hb dap` speaks the
[Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/) —
the same protocol VS Code, nvim-dap, emacs `dape` and Zed already implement, and
that GDB itself now exposes — so breakpoints, a call stack and a variables pane
come from an editor you already know how to use.

Two things about it are specific to this language, and both follow from what the
language is:

- **A stop happens *after* an expression, not before it.** HashedBuild has no
  statements: a program is one expression, and the interesting thing about
  reaching a sub-expression is what it evaluated to. So "stopped at line 7"
  means line 7's expression *just produced this value*, and the **Result** scope
  holds it. The **Locals** scope holds the `let` bindings in scope there.
- **A session reaches only the directories its launch configuration names**,
  exactly as a command line does (SPEC.md §9/§16). `dirs` in the configuration
  is `--dir` on the command line; a session with no `dirs` cannot touch the
  filesystem at all.

`async` (§2) tasks are real OS threads, so they appear as threads — the program
is thread 1 — and they stop together.

### nvim-dap

```lua
local dap = require("dap")

dap.adapters.hashedbuild = {
  type = "executable",
  command = "/path/to/hb",
  args = { "dap" },
}

dap.configurations.hashedbuild = {
  {
    type = "hashedbuild",
    request = "launch",
    name = "Run this file",
    program = "${file}",
    -- What the program may reach, by name: ctx.dirs.here inside it.
    dirs = { here = "${fileDirname}" },
  },
}
```

`:lua vim.bo.filetype = "hashedbuild"` on a `.hb` buffer, then `:DapToggleBreakpoint`
and `:DapContinue`.

### VS Code

VS Code will not talk to a bare adapter: something has to *contribute* the
debugger type. That contribution ships here, in `editors/vscode/`, and it is
one `package.json` with no code in it - nothing to compile, no npm.

The only thing that cannot be committed is where your `hb` binary is, since a
debugger contribution resolves its adapter path relative to the extension
folder rather than to your workspace. So one script copies the extension into
your extension directory and fills that in:

```sh
odin build src -out:hb.exe                     # or -out:hb on Linux
python3 scripts/install_vscode_debug.py        # pass a path to use another binary
```

Restart VS Code, open a `.hb` file and press **F5**. Re-run the script after
moving the repository or building the binary somewhere else.

This repository's own `.vscode/launch.json` already has two configurations -
the open file, and `examples/option-picker.hb` with its directory - so F5 works
in a fresh clone. For your own project:

```json
{
  "type": "hashedbuild",
  "request": "launch",
  "name": "Run this file",
  "program": "${file}",
  "dirs": { "here": "${fileDirname}" }
}
```

`dirs` is `--dir` written down: each entry becomes `ctx.dirs.<name>`, and it is
the whole of what the program may read or write. Omit it and the program cannot
touch the filesystem at all.

### What the adapter supports

`initialize`, `launch`, `setBreakpoints`, `configurationDone`, `threads`,
`stackTrace`, `scopes`, `variables`, `continue`, `next`, `stepIn`, `stepOut`,
`evaluate`, `disconnect` and `terminate`. `evaluate` really evaluates, in the
scope the run stopped in — so a watch expression that calls a filesystem builtin
touches the filesystem, exactly as it would in the program.

Breakpoints are verified per line: a line no expression starts on comes back
unverified, so a client can grey it out rather than pretend.

`dap-tests/` drives all of this with the protocol's own reference client — see
CLAUDE.md for why that one directory has a `package.json`.

## Where to go next

- **[LANGUAGE.md](LANGUAGE.md)** - every feature that works today, with runnable snippets: values, operators, Tables, functions, pattern matching, failure, files, permissions, concurrency - and an explicit list of what isn't built yet.
- **[examples/](examples/)** - a runnable file per feature, indexed in [examples/README.md](examples/README.md). The test suite runs all of them.
- **`SPEC.md`** - the full, evolving language design, including the parts that don't run yet.
- **`SPEC.md` §9/§16** - why a program reaches only the directories `--dir` names.
