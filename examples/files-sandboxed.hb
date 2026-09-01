#Directory here .

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
// The first handle comes from the runtime, and only from there: every
// directory a program can reach is named on the command line that ran it,
// `--dir <name>=<path>`, and arrives as `ctx.dirs.<name>`. That is what the
// `run:` line above is - the example's inputs, written down beside its code
// rather than assumed from where the file happens to sit. A run that names no
// directory reaches nothing at all.
//
// `filetext` gets a regular file's bytes back as Utf8, and a File displays
// as its filesystem path (§3) - display-only, since nothing in the language
// reads a path back out as a value. Evaluates to a Table whose `dir` and
// `file` entries are the paths of this directory and of optiona.txt in it,
// with `contained_read` holding that file's text.
let here ctx.dirs.here;
  {
    .dir = here,
    .file = loadfile { .dir = here, .path = "optiona.txt" },
    .contained_read = filetext (loadfile { .dir = here, .path = "optiona.txt" }),
  }
