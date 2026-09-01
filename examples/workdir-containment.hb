// `ctx.dir` and the path permissions (SPEC.md §9/§16). A path written without
// a directory handle - `loadfile "notes.txt"` - used to resolve with no
// containment at all. Which of three things it now does is decided by a
// permission, and by nothing else:
//
//   anypath  anywhere, as before: relative to this source file's own
//            directory, or absolute. Granted at the root, so nothing changed
//            for programs that were already written.
//   workdir  contained to `ctx.dir` - the directory this run is rooted at.
//            "..", an absolute path, and a symlink pointing outward are all
//            refused, and "." resolves to ctx.dir rather than through it. The
//            same component-by-component walk the { .dir, .path } form uses,
//            so the guarantee cannot differ between the two spellings.
//   neither  refused outright; only the handle forms work.
//
// `anypath` subsumes `workdir`, so holding both just means anypath. Narrowing
// is what `hashmake` does before evaluating a build file, which is why a
// hashmake.hb cannot read the rest of the machine.
//
// The refusals are not shown here for a reason worth knowing: a denied read is
// a **fatal** failure (§8/§16), so an example that tried to demonstrate one
// would end rather than evaluate to anything. Try it by hand instead:
//
//   ./hb -e '(loadfile "..") chctx chperm { .name = "anypath", .enabled = 1 == 0 }
//                            chctx chperm { .name = "workdir", .enabled = 1 == 1 }'
//
// Evaluates to { root_grants: {io: nothing, exec: nothing, anypath: nothing},
//   contained_grants: {io: nothing, exec: nothing, workdir: nothing},
//   reads_inside: "This is the payload for option A.\n" }.

let deny_any chperm { .name = "anypath", .enabled = 1 == 0 };
let grant_wd chperm { .name = "workdir", .enabled = 1 == 1 };
{
  .root_grants = ctx.permissions,
  .contained_grants = ctx.permissions chctx deny_any chctx grant_wd,
  .reads_inside = (filetext (loadfile "optiona.txt")) chctx deny_any chctx grant_wd,
}
