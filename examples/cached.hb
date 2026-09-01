// run: hb --dir here=. cached.hb
//
// `cached` (SPEC.md §15): evaluate an expression once, and read the answer
// back on every later run. Like `sha256`, `func` and `async`, it is a bare
// keyword prefix taking one trailing expression - no parentheses of its own.
//
// The cache key is the expression *treated as a function*, hashed as one - so
// two things are part of it besides the code: the `ctx` it runs under, and the
// values of the names it uses. `bump 1` and `bump 10` below are therefore two
// entries and not one, which is what keeps the second call from being answered
// with the first call's result.
//
// What is *not* part of the key is anything the expression goes and reads at
// run time. That is the point of a cache and also its one sharp edge: cache
// `loadfile { .dir = …, .path = "pkg.tar.gz" }` and you get the bytes as they
// were the first time,
// however the file changes afterwards.
//
// Entries live in `ctx.cache`'s directory (`--cache-dir`, else the per-user
// default), one per key, named `sha256-<key>`. A `File` value is stored as an
// ordinary file and a directory value as an ordinary directory, so what a
// build produced is still something you can open; anything else is written as
// HashedBuild text in `sha256-<key>.hb/value.hb`, with any `File` it holds
// stored beside it and referred to by name.
//
// A value that reaches itself (§10) is written with a label on each repeated
// Table and a back-reference after it - `node "1" { ..., .self = ref "1" }` -
// which is what gives a cycle a finite written form.
//
// Evaluates to
// { answer: 42, asking_again_agrees: true, per_argument: { small: 2, large: 11 },
//   file_survives_the_round_trip: true, a_cycle_survives_too: true }.

let answer cached (6 * 7);

// The second ask evaluates nothing: it reads back what the first one wrote.
let asking_again_agrees ((cached (6 * 7)) == 42);

// One entry per captured value, not one per expression.
let bump func (cached (#arg + 1));

// A cached `File` comes back as a `File`, and as the *same* value - a `File`
// is its content (§3), so this holds even though the copy in the cache is at
// a different path than the one it was read from.
let file_survives_the_round_trip
  ((sha256 cached (loadfile { .dir = ctx.dirs.here, .path = "optiona.txt" }))
    == (sha256 loadfile { .dir = ctx.dirs.here, .path = "optiona.txt" }));

// So does a value that reaches itself. The comparison is the whole test: §6
// compares cyclic values by bisimulation, so a back-edge that came back as an
// unfolding of the wrong depth would not be equal to what was stored.
let rec ring { .name = "ring", .self = ring };
let a_cycle_survives_too ((sha256 cached ring) == (sha256 ring));

{
  .answer = answer,
  .asking_again_agrees = asking_again_agrees,
  .per_argument = { .small = bump 1, .large = bump 10 },
  .file_survives_the_round_trip = file_survives_the_round_trip,
  .a_cycle_survives_too = a_cycle_survives_too,
}
