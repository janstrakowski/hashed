# Building a real C project with hashmake

This directory builds [cJSON](https://github.com/DaveGamble/cJSON) — vendored as
a git submodule, pinned to a commit — from source, links it, and runs the
result. It is the worked example for `tools/hashmake`.

```sh
odin build src -out:hb                       # if you haven't already
odin build tools/hashmake -out:hashmake
git submodule update --init                  # if you cloned without --recursive

cd examples/hashmake
../../hashmake --graph      # what depends on what
../../hashmake -n           # the order it would build in
../../hashmake              # build it, and run what it built
```

The last command prints cJSON's own test output — a version banner and a few
formatted JSON documents.

## The graph

```
cJSON.o          cJSON_Utils.o          test.o
   \                   |                  /
    \------------------+-----------------/
                       |
                     link          (clang -o cjson-demo ... -lm)
                       |
                     run           (produces no artifact)
```

**No C file is named anywhere in `hashmake.hb`.** The sources are found by
listing the checkout and filtering on a suffix:

```hashedbuild
let sources fold {
  .table = listdir cjson,
  .init = empty,
  .step = (let s; (endswith { .text = s.value, .suffix = ".c" }) then ... else s.acc),
};
```

`endswith` is not a builtin either — it is four lines written on top of
`textlen` and `textslice`. Add a `.c` file to the checkout and it becomes a node
in this graph with nothing edited here.

The `run` target produces no artifact: it answers with the program's output as
text so hashmake can show it, and hashmake refuses to let anything depend on it.

## What to try

**Watch it not rebuild.** Run `../../hashmake` twice. The second run compiles
nothing — every node's `cached` key is unchanged.

**Watch it rebuild exactly what changed.** Add a comment to one of cJSON's `.c`
files and build again: that one object and the link are rebuilt, the other two
objects are not.

**Watch it come back.** Undo the edit and build again. It is a *hit*, not a
rebuild — the cache is keyed on content, so restoring a file restores the answer.
A timestamp-based tool would rebuild here.

**Watch it refuse to escape.** Add `filetext (loadfile "/etc/hostname")` to a
build function. It fails: the build file is contained to this directory unless
you pass `--allow-any-path`.

## Requirements

`clang` on `PATH`, and the submodule checked out. This is the one example in the
repository that needs a compiler; the test that runs it skips itself, with a
logged reason, where clang is absent.
