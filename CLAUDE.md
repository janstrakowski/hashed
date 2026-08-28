# HashedBuild

An Odin implementation of the HashedBuild language. `SPEC.md` is the source of
truth for language behavior — when code and spec disagree, the spec wins, and a
change to behavior means changing both in the same commit.

## Build and test

```sh
odin build src -out:hb                        # the CLI (the shipped binary, kept current)
odin test src                                 # full suite
./hb -e '<expr>'                              # evaluate one expression
scripts/build_wasi.sh                             # portable WASI -> hb.wasm
scripts/build_wasi.sh --threads                   # wasi-threads -> hb-threads.wasm
scripts/build_wasi.sh --threads-web -out:docs/hb.wasm  # what the browser runs
scripts/wasi_smoke.sh ./hb ./hb.wasm wasmtime     # both targets agree
```

On Windows the same two commands, spelled `-out:hb.exe` and
`-out:hbtest.exe` — `odin test` otherwise drops `src.exe` in the working
directory. Linking needs the Windows SDK (Visual Studio Build Tools' C++
workload); without it Odin stops at `Windows SDK not found.` before compiling.
`scripts/` is shell, so the WASI targets want Git Bash there. Two local
environment traps, neither a project problem: **Smart App Control** blocks
freshly built unsigned binaries with "An Application Control policy has blocked
this file" (build outside the repo, or just build again), and **`symlink` needs
Developer Mode** or an elevated shell, without which the symlink round trip and
`files-symlink.hb` skip themselves with a logged reason rather than failing.

**The playground's two artifacts are generated, never committed.**
`docs/hb.wasm` is the interpreter and `docs/repo-files.json` is the repository
as the terminal's filesystem; both are built by `.github/workflows/pages.yml`
on the way to deploying, and by CI before the playground tests run. To work on
the page locally, build them the same way:

```sh
scripts/build_wasi.sh --threads-web -out:docs/hb.wasm
python3 scripts/build_playground_files.py
```

The playground's own test wants both of them built, and a browser:

```sh
python3 scripts/playground_browser_test.py "$(command -v chromium)"
```

They used to be committed, which coupled every tracked file to a build
product: editing any documentation left the manifest stale and turned CI red
until someone regenerated it. A documentation change should be a documentation
change.

**Everything outside the Odin toolchain is a pinned binary or the Python
standard library.** There is no package manager in this repository and nothing
to install before the tests run:

| what | why |
| --- | --- |
| Python 3, stdlib only | the editor key tests, the playground manifest, the playground test and its CDP client |
| `wasmtime` (pinned) | the portable WASI smoke test |
| WAMR's `iwasm` (pinned, built from source) | the threaded WASI smoke test - wasmtime dropped wasi-threads in June 2026 |
| a Chrome or Chromium binary | the playground test drives it over the DevTools protocol |

`scripts/cdp.py` is the reason the last one needs nothing else: it is a small
CDP client - a WebSocket, request/response, and key events - written because
what the tests used of puppeteer-core was a handful of protocol calls, and it
was the only npm dependency the project had. Keep it that way: a new dev
dependency wants a reason that outweighs `pip install`-free, `npm`-free
checkouts.

**Three targets.** Anything touching the filesystem goes through `fs.odin`
(`fs_linux.odin` / `fs_windows.odin` / `fs_wasi.odin`) and anything spawning a
thread through `task.odin` (`task_native.odin` for both native targets, since
`core:thread` is already portable; `task_wasi.odin` where a spawn can fail);
nothing above them names a syscall or a thread API. Odin picks the file by
suffix, so a `_linux.odin` file simply isn't compiled for the others - which is
also why the terminal layer is split that way, and why the test files carry
`#+build linux, windows`. `odin test` only ever builds natively, so Linux and
Windows are covered by the suite itself (a CI job each) while the WASI backends
are covered by the smoke script above - once per flavour, the threaded one
under WAMR's iwasm, since wasmtime dropped wasi-threads.

**The editor's keys are covered on both native targets, by different means.**
`scripts/editor_keys_test.py` drives a pty; `scripts/editor_keys_test_windows.py`
drives a real console, injecting `KEY_EVENT_RECORD`s with `WriteConsoleInputW`
and reading the rendered screen back with `ReadConsoleOutputCharacterW`.
Deliberately not ConPTY: that would turn written bytes into key events and back
into escape sequences, testing its own round trip rather than conhost's
VT-input translation - which is the thing `term_windows.odin` bets on and the
only thing that covers it. The two scripts make the same eight checks, so the
targets can't drift; they read differently because on Windows there is no byte
stream to capture, only a screen. Both assert against observable editor state,
and removing `ENABLE_VIRTUAL_TERMINAL_INPUT` fails five of the eight.

**Windows has no `openat()`,** and that is the one place the three backends
genuinely differ rather than just spelling the same call differently. Nothing
in Win32 opens a name relative to a directory descriptor, so `fs_windows.odin`
numbers its handles in a table and reaches a child by joining onto its parent's
path. Its header says exactly what that preserves (no-follow on the final
component is still atomic; containment still holds for every path a program can
write) and what it does not (the walk is not immune to a concurrent rename).
Read it before changing anything there.

**Paths are `/`-separated on every target,** including Windows, where a display
path reads `C:/Users/you/project`. The Windows-shaped parts of that - a drive
or UNC root, backslash as a second separator, a colon meaning a drive or an
alternate data stream - live behind `WINDOWS_PATHS` in `builtins_fs.odin` and
are `when`-guarded rather than universal, because a backslash is an ordinary
character in a Linux filename and folding it there would rename files.

**The threaded WASI build has a hand-written piece.** `src/thread_start.s` is
the wasi-threads entry point: the host instantiates the module afresh per
thread, and wasm globals are per-instance, so `__stack_pointer` still points
at the main thread's stack until that stub repoints it. Odin cannot touch
that global, which is why those few lines are assembly and why
`scripts/build_wasi.sh` compiles and links them rather than `odin build`
doing everything.

`./hb` is gitignored, not tracked — but it is the binary you and any hand-testing
actually run, so rebuild it as part of every completed feature, not just at the
end of a session.

CI (`.github/workflows/ci.yml`) builds and runs the suite on every push to
`main` and every PR, using the pinned `ODIN_VERSION` — deliberately not on
`dev`, which is allowed to be red. It is a net under the rules below, not a
substitute for running the suite yourself before landing.

Tests must not hardcode an absolute path: `repo_root()` (`builtins_fs_test.odin`)
derives the checkout location from `#directory` at compile time, because CI
checks out somewhere else and `odin test` promises no particular working
directory.

## Odin notes

Traps this project has actually hit, collected because they cost time to
rediscover and the compiler's message doesn't always point at the fix:

- A **composite literal in a `for`/`if` header needs parentheses**:
  `for x in ([]string{"a", "b"})`. Without them it's a syntax error at the
  first comma — the brace is read as the loop body.
- **`fmt` treats `{` as the start of a format verb.** Building an expectation
  that is mostly braces (a Table's printed form, say) with `fmt.tprintf`
  yields `%!(MISSING CLOSE BRACE)`; use `strings.concatenate` instead.
- **A proc can't return a compound-literal slice** — it lives in the callee's
  stack frame. Make it a file-scope `X := []T{...}` value.
- **`os.read_entire_file` returns an `Error`, not a `bool`** (`err != nil`,
  not `!ok`) in the Odin this project tracks.
- **The WASI build needs `-o:size`** (or `-o:none`/`-o:speed`). Odin's default
  for wasm32 is `-o:minimal`, which on `dev-2026-08` emits a module that fails
  validation — `Invalid input WebAssembly code: type mismatch: expected i64,
  found i32`, inside one arbitrary function. It is a codegen bug, not ours:
  the same source builds valid wasm at every other optimisation level, and on
  a newer compiler at `-o:minimal` too. Linking also needs `wasm-ld`, which
  comes from `lld`, not from clang.

## Changing the language

**The language is the user's call. Ask before changing it.** Syntax, semantics,
what a builtin does, what a value displays as, what fails and how — none of it
changes without asking first, however obvious the change looks, and however
much a port or a refactor seems to force it. Present the options and what each
costs; don't pick one and report it afterwards.

What doesn't need asking: implementation work that leaves observable behaviour
identical, and fixing code that contradicts `SPEC.md` — there the spec already
decided, and the code is simply wrong (see the top of this file).

The edge worth naming, because it has already come up: when `SPEC.md`
contradicts *itself*, resolving it is a design decision, not a bug fix. If one
reading is clearly stale — superseded by a later dated resolution, or
self-contradictory in its own sentence — say so and fix it. If both readings
are coherent and pick out different behaviour, stop and ask; the §8/§16
resolution went the first way, and a case like it that went the second way
would be the user's to settle.

## Docs and examples

`main` is public. Anyone who finds this repo should be able to see what the
language can do **today** and try each of it themselves, without reading the
evaluator or guessing which parts of `SPEC.md` are real. Documentation and
examples are therefore part of a feature, not follow-up work — a feature that
nobody outside this repo can discover or run is not finished.

**Every user-visible feature is documented in `LANGUAGE.md`**, the
feature-by-feature tour of what runs. Each entry carries a snippet the reader
can paste straight into `./hb -e '…'` and a pointer to the example that
demonstrates it. Run the snippets before committing them; a doc that lies is
worse than a missing one.

**Every language feature gets an example in `examples/`.** One runnable file
per feature, with a header comment saying what it evaluates to, in the style
the existing ones use. Features where a runnable file isn't the natural
demonstration — a CLI flag, the terminal UI, the debugger — are documented in
`GETTING_STARTED.md` instead; say which route you took in the commit body.

**Docs state what is implemented, never what is planned.** `SPEC.md` is the
design and deliberately runs ahead; `LANGUAGE.md`'s "what isn't built yet"
section is what keeps that difference legible to a reader. Updating it is part
of implementing a feature, and part of removing one. When a feature turns out
to be missing something a user would reasonably expect — no boolean literals,
a failure that can't be caught — say so in the docs rather than writing around
it.

Three parts of this are mechanical, so they can't rot quietly: every
`examples/*.hb` is executed by the suite and asserted against its documented
value; `test_every_example_is_covered_by_a_test` fails when an example lands
without an assertion; and code quoted in `README.md` is compared against the
example it claims to be (`docs_test.odin`), because it drifted once already.

