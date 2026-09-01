// A directory `File`'s hash (SPEC.md §3). A directory is a value like any
// other, so `sha256` answers for one - but its children are on the disk rather
// than in the value, which makes this the one digest that reads.
//
// §3 computes it over the directory's entries, each hashed with its name and
// sorted by name so the answer is the tree's rather than readdir's: a regular
// file contributes its content hash, a sub-directory contributes its own
// directory hash, and a symlink contributes its target *string*, never
// followed. No permission bits enter into it, and nothing about where the
// directory sits does either - which is why two handles on the same tree are
// one value, and why a tree hashes the same on every target.
//
// The digests themselves are still not written down here: this directory's
// contents change as examples are added, so a literal would be a value that
// went stale the next time someone wrote one. What holds are the properties
// below.
//
// `tree/` is a fixture committed next to this example - a.txt and sub/b.txt -
// so the two handles below read something that does not change underneath
// them. `ctx.dir` is the directory the runtime handed the program (§9/§16),
// this example's own; a call that names no `.dir` resolves against it, so the
// two loads below are the same call written two ways.
//
// Reading a directory is I/O, so the first `sha256` of one needs
// `ctx.permissions.io` like `loadfile` does - and it is only the first, since
// a `File` is an immutable handle (§3) and the digest is fixed once read.
//
// There are no boolean literals, so "false" is spelled `1 > 2` here, the same
// way examples/comparison-and-logic.hb spells it.
//
// Evaluates to { a_tree_is_not_its_file: true, one_tree_is_one_value: true,
//                reading_twice_agrees: true }.
let a loadfile { .dir = ctx.dir, .path = "tree" };
let b loadfile "tree";
{
  // A directory holding a file is not that file. Both digests are built from
  // the same bytes on disk, and §3's tagging is what keeps them apart.
  .a_tree_is_not_its_file = ((sha256 a) == (sha256 loadfile "tree/a.txt")) == (1 > 2),

  // Two separate handles, one tree. §3 makes a File's identity its content,
  // so these are the same value even though they were opened separately - and
  // comparing them is what reads the second one.
  .one_tree_is_one_value = a == b,

  // Two independent walks of the same directory agree. That is §3's "sorted
  // by name for determinism" doing its job: the digest is the tree's, not the
  // order the filesystem happened to hand the entries back in.
  .reading_twice_agrees = (sha256 a) == (sha256 b),
}
