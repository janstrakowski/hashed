// Files as values (SPEC.md §3/§16). `loadfile <path>` reads a file or a
// directory relative to *this source file*, not to wherever you ran `hb`
// from. A directory File doubles as a handle, and the two-argument form
//
//   loadfile { .dir = <handle>, .path = <sub_path> }
//
// is contained to it: a sub-path can't escape by "..", by being absolute, or
// through a symlink pointing outward. That containment is the whole point of
// the handle form - it's what lets a program be handed one directory and be
// unable to read outside it.
//
// `filetext` gets a regular file's bytes back as Utf8, and a File displays
// as its filesystem path (§3) - display-only, since nothing in the language
// reads a path back out as a value. Evaluates to a Table whose `dir` and
// `file` entries are the paths of this directory and of optiona.txt in it,
// with `contained_read` holding that file's text.
let here loadfile ".";
  {
    .dir = here,
    .file = loadfile { .dir = here, .path = "optiona.txt" },
    .contained_read = filetext (loadfile { .dir = here, .path = "optiona.txt" }),
  }
