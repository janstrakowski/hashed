// Files as values (SPEC.md §3/§16). Every filesystem call is a directory
// handle plus a sub-path inside it:
//
//   loadfile { .dir = <handle>, .path = <sub_path> }
//
// and it is contained to that handle: a sub-path is a sequence of ordinary
// names, so "..", a root, and even a "." are refused outright, as is a
// symlink pointing outward. That containment is the whole point - a program
// handed one directory cannot read outside it, and there is no other kind of
// path for it to try.
//
// The first handle comes from the runtime: `ctx.dir` is the program's main
// directory, which for `hb <file>` is the source file's own - so this example
// reads its neighbours wherever you run it from. `--dir <path>` names a
// different one, `--dir <name>=<path>` adds more under `ctx.dirs.<name>`, and
// `--no-default-dir` hands over none at all. Leaving `.dir` out of a call
// means `ctx.dir`, so `loadfile "optiona.txt"` below is the same call as the
// one above it.
//
// `filetext` gets a regular file's bytes back as Utf8, and a File displays
// as its filesystem path (§3) - display-only, since nothing in the language
// reads a path back out as a value. Evaluates to a Table whose `dir` and
// `file` entries are the paths of this directory and of optiona.txt in it,
// with `contained_read` holding that file's text.
let here ctx.dir;
  {
    .dir = here,
    .file = loadfile { .dir = here, .path = "optiona.txt" },
    .contained_read = filetext (loadfile { .dir = here, .path = "optiona.txt" }),
  }
