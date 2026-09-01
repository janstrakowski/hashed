// run: hb --dir here=. async-basics.hb
//
// The simplest possible `async` (SPEC.md §2): two independent reads fire
// concurrently rather than one after the other, each resolved (awaited)
// automatically the moment `concat` actually needs a concrete value from it -
// no explicit "await" keyword anywhere. Evaluates to "This is the payload
// for option A.\nThis is the payload for option B.\n" - both files' contents
// exactly as they sit on disk, trailing newlines and all, joined with no
// separator of `concat`'s own.
(async filetext (loadfile { .dir = ctx.dirs.here, .path = "optiona.txt" }))
  concat (async filetext (loadfile { .dir = ctx.dirs.here, .path = "optionb.txt" }))
