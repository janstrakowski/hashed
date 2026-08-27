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

**The playground carries two generated artifacts.** `docs/hb.wasm` is the
interpreter Pages serves, and `docs/repo-files.json` is the repository as the
terminal's filesystem - so *any* commit can make the manifest stale, and a
change to `src/` makes the wasm stale. `.githooks/pre-commit` regenerates the
manifest (enable it once with `git config core.hooksPath .githooks`); rebuild
the wasm with `scripts/build_wasi.sh --threads-web -out:docs/hb.wasm` when the
interpreter changes - the browser runs the *threaded* flavour, which imports
its memory so every spawned thread can share one heap. CI checks both.

**Two targets.** Anything touching the filesystem goes through `fs.odin`
(`fs_linux.odin` / `fs_wasi.odin`) and anything spawning a thread through
`task.odin` (`task_linux.odin` / `task_wasi.odin`); nothing above them names a
syscall or a thread API. Odin picks the file by suffix, so a `_linux.odin` file simply isn't
compiled for WASI - which is also why the terminal UI and the test files are
named or tagged that way. `odin test` only ever builds natively, so the WASI
backends are covered by the smoke script above, not by the suite - once per
flavour, the threaded one under WAMR's iwasm, since wasmtime dropped
wasi-threads.

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

## Delegating to agents

**Trial, started 2026-08-27** — kept in one commit so it can be reverted whole
if it doesn't earn its keep. What to watch: whether delegated work comes back
needing more correction than it saved, and whether bugs that used to surface
while writing tests and examples start slipping through instead.

The split is **discovery vs. transcription**, not tests-and-docs vs. features.
Writing the first example of a new feature is the first honest use of it — that
is where `[k] = v` and `:.ok as v` turned out to be broken (§5/§8), neither of
which reading the evaluator would have found. Writing a test is often what
forces the implementation into a testable shape, as extracting `parse_args` out
of `main` did. Both are development work wearing a different hat, and handing
them to a cold agent trades a short feedback loop for a round trip.

**Keep in-session:** testability refactors; tests and examples for anything
still moving; the first example of any new feature.

**Delegate:** expanding an example corpus over behavior that already works and
has been verified; doc sweeps and index pages; capturing expected values across
many files; repetitive per-case test batches once the surface is stable.

**The landing gate doesn't move.** Delegated work returns as a proposal, never
as a landed commit: run the suite, mutation-check that delegated tests actually
fail when the feature is reverted (a test that passes either way is worse than
no test, and reads as coverage in review), and re-run any doc snippet before it
lands.

**Reuse an agent; don't re-spawn one.** Spawn at first need and keep it for
the rest of the session — `SendMessage` continues an existing agent with its
context intact, so its second and third task skip the re-derivation the first
one paid for. Two standing roles cover this repo: one for docs and examples,
one for test batches. Don't pre-spawn against future work: an idle agent isn't
warm, it's unbriefed, and briefing costs the same whenever it happens.

**Re-brief a kept agent on what moved.** Its picture of the repo is as old as
its last message. Say what changed since, and have it re-read any file it is
about to touch — a kept agent confidently editing a file that has been
rewritten underneath it is the failure this trades for the cold-start saving.

**Warmth doesn't outlive the session.** The next session starts cold whatever
happens here, which is why these conventions live in this file rather than in
any agent's head. A spawn still only pays for units big enough to outweigh the
first briefing; below roughly a few files of independent work, in-session is
faster.

## Git workflow

`main` holds only working features. Its history is linear (no merge commits,
21 and counting) and each commit builds and passes the full suite on its own.

**Rebase, never merge.** No merge commits anywhere, including when catching a
branch up — rebase it instead.

**`dev` is the WIP branch.** Commit to it freely, whether or not the feature is
finished: a half-built parser change, a debugging detour, an experiment worth
keeping overnight. Broken states are fine there; that is what it is for. Push to
`dev` whenever without asking. `dev` is scratch — it gets reset onto `main` after
each feature lands, so force-pushing it is expected and normal.

**Never force-push `main`.**

**Landing a feature.** When it finally emerges — the feature works, the whole
suite passes, `./hb` is rebuilt, and the docs and examples above cover it —
squash `dev`'s WIP commits into one commit and fast-forward `main`. Run the
suite in that exact final squashed state, not just somewhere along the way. Do this when the work is green rather than asking first;
say in the reply that it landed.

**A green commit needs reasonable test coverage, not just a green suite.** A
feature lands with tests that would fail if the feature were reverted — passing
116 existing tests that never touch the new code is not coverage. Reasonable
means the behavior a user could rely on: the happy path, and the failure modes
the code explicitly handles (a rejected path, a missing argument, a permission
denial), not every branch. If the change makes something untestable-as-written,
refactor it until it is testable — extracting a pure function out of `main` is
cheaper than shipping a flag nobody can test. The two standing exceptions are
the terminal UI (`editor.odin`, `debugger.odin`, `term_*.odin`), where driving a
raw-mode TTY from `odin test` costs more than it's worth — though it is no
longer untested: `scripts/playground_browser_test.mjs` drives it for real in a
browser — and pure doc/comment edits.
Taking an exception means saying so in the commit body.

```sh
git switch dev
git rebase main                  # only if main moved; never merge
odin test src && odin build src -out:hb   # must be green here
git reset --soft main && git commit       # collapse the WIP into one commit
git switch main && git merge --ff-only dev
git push origin main
git branch -f dev main && git push --force-with-lease origin dev   # reset WIP branch
```

If a stretch of WIP turns out to contain two unrelated features, land them as
two commits rather than one mixed commit — `main`'s history is per-feature.

**Commit messages.** Imperative subject, then a body explaining *why* the change
was needed and what was rejected, not a restatement of the diff. Reference spec
sections as `§N`. Keep the `Co-Authored-By` / `Claude-Session` trailers.
