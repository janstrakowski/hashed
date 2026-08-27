# HashedBuild

An Odin implementation of the HashedBuild language. `SPEC.md` is the source of
truth for language behavior — when code and spec disagree, the spec wins, and a
change to behavior means changing both in the same commit.

## Build and test

```sh
odin build src -out:hb    # the CLI (also the shipped binary, kept current)
odin test src             # full suite
./hb -e '<expr>'          # evaluate one expression, like a REPL submission
```

`./hb` is gitignored, not tracked — but it is the binary you and any hand-testing
actually run, so rebuild it as part of every completed feature, not just at the
end of a session.

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
suite passes, `./hb` is rebuilt — squash `dev`'s WIP commits into one commit and
fast-forward `main`. Run the suite in that exact final squashed state, not just
somewhere along the way. Do this when the work is green rather than asking first;
say in the reply that it landed.

**A green commit needs reasonable test coverage, not just a green suite.** A
feature lands with tests that would fail if the feature were reverted — passing
116 existing tests that never touch the new code is not coverage. Reasonable
means the behavior a user could rely on: the happy path, and the failure modes
the code explicitly handles (a rejected path, a missing argument, a permission
denial), not every branch. If the change makes something untestable-as-written,
refactor it until it is testable — extracting a pure function out of `main` is
cheaper than shipping a flag nobody can test. The two standing exceptions are
the terminal UI (`editor.odin`, `debugger.odin`, `term_linux.odin`), where
driving a raw-mode TTY costs more than it's worth, and pure doc/comment edits.
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
