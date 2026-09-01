// `exec` (SPEC.md §16): running a program, with its inputs and outputs as
// **values** rather than paths.
//
// The command runs in a fresh scratch directory holding nothing but the
// `.inputs` it was handed, and the `.outputs` it declares come back as `File`s.
// That shape is the point rather than a convenience: §15's cache key excludes
// anything an expression reads at run time, so a thinner exec that wrote into
// a directory and let the caller `loadfile` the result afterwards would answer
// with the first run's bytes forever. Here an input is a File and a File is
// its content (§3), so inputs are *in* the key - which is what makes
// `cached exec { … }` correct, and what examples/hashmake/hashmake.hb is built
// on.
//
// **A non-zero exit is not a failure.** It comes back as `.status`, so a build
// can `check` it and show `.stderr` - the useful thing to do with a compiler
// that rejected its input. A command that cannot be started, an input that
// cannot be written, or a declared output that is not there are all fatal
// (§16), as is calling this without `ctx.permissions.exec`.
//
// Worth being plain about: this contains what is *handed to* a program, not
// what that program then does. A compiler started here can read whatever the
// user running it can.
//
// This one shells out to `clang`, so unlike every other example it needs
// something outside the repository; the test that runs it skips itself, with a
// logged reason, where clang isn't installed. Evaluates to
// { compiled: 0, said_its_version: true, ran_what_it_built: "hello from C\n" }.

let source createfile {
  .dir = ctx.cache,
  .content = "#include <stdio.h>\nint main(void){printf(\"hello from C\\n\");return 0;}\n",
};

let version exec { .cmd = "clang", .args = { "--version" } };

let built exec {
  .cmd = "clang",
  .args = { "greet.c", "-o", "greet" },
  .inputs = { ["greet.c"] = source },
  .outputs = { "greet" },
};

// The program just built is the next step's command - which works because a
// File carries its executable bit across the handover.
let ran exec { .cmd = "./greet", .inputs = { ["greet"] = built.outputs["greet"] } };

{
  .compiled = built.status,
  .said_its_version = (textlen version.stdout) > 0,
  .ran_what_it_built = ran.stdout,
}
