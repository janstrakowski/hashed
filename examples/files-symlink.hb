#Directory here .

// Symlinks are metadata of the directory holding them, not values in their
// own right (SPEC.md §3/§16) - so there's no "symlink value" to get back.
// What you can do is read the target string exactly as stored, without
// following it:
//
//   readlink { .dir = <handle>, .path = <name> }
//
// `symlink { .dir = <handle>, .path = <name>, .target = <string> }` creates
// one and returns `nothing`. It isn't run here because creation is exclusive
// (§16): it would fail the second time you ran this file. `link-to-optiona`
// is a symlink committed next to this example, pointing at optiona.txt.
//
// `ctx.dirs.here` is the directory the `run:` line above handed the program
// (§9/§16), which is where that link lives - a program reaches nothing it was
// not given.
//
// Note the target comes back as the literal string that was stored - a
// relative path stays relative, and nothing checks that it resolves to
// anything at all. Evaluates to "optiona.txt".
let here ctx.dirs.here;
  readlink { .dir = here, .path = "link-to-optiona" }
