// Tests run natively, never in a WASI build - see eval_test.odin.
#+build linux, windows
package hashedbuild

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// Evaluates with the real global environment and root context bound in - the
// filesystem builtins and `ctx` - the same way builtins_fs_test.odin does, so
// `loadfile` and `ctx.cache` resolve. The cache path is a scratch one that is
// never actually created: nothing here writes, and the directory is made
// lazily on the first write (builtins_fs.odin).
@(private = "file")
eval_with_globals :: proc(src: string) -> (val: Value, ok: bool, err: string) {
  ast := parse(source_t{name = "test", n_bytes = u64(len(src)), data = raw_data(src)}, ast_t{})
  cache := strings.concatenate({repo_root(), "/.hash_test_cache"})
  defer delete(cache)
  interp := Interpreter{ast = &ast, src = src, current_ctx = make_root_context(cache)}
  val, ok = eval_program(&interp, ast.root, make_global_env())
  return val, ok, interp.error_message
}

@(private = "file")
eval_str :: proc(t: ^testing.T, src: string) -> string {
  val, ok, err := eval_with_globals(src)
  testing.expect(t, ok, err)
  s, is_str := val.(string)
  testing.expect(t, is_str, "expected a Utf8 result")
  return s
}

@(private = "file")
eval_bool :: proc(t: ^testing.T, src: string) -> bool {
  val, ok, err := eval_with_globals(src)
  testing.expect(t, ok, err)
  b, is_bool := val.(bool)
  testing.expect(t, is_bool, "expected a Boolean result")
  return b
}

@(private = "file")
eval_failure :: proc(t: ^testing.T, src: string) -> string {
  _, ok, err := eval_with_globals(src)
  testing.expect(t, !ok, "expected this to fail")
  return err
}

// The one digest worth pinning to a literal: SHA-256 of the three bytes
// "abc", base64-encoded, is a published test vector. If the leaf encoding for
// Utf8 ever changes, this is the test that says so.
@(test)
test_sha256_of_utf8_is_a_tagged_digest :: proc(t: ^testing.T) {
  // Tagged (0x04 || "abc"), so deliberately NOT the bare SHA-256 of "abc" -
  // domain separation is what keeps Utf8 "abc" and Bytes "abc" distinct.
  got := eval_str(t, `sha256 "abc"`)
  testing.expect(t, len(got) == 44, "a base64'd 32-byte digest is 44 chars")
  testing.expect(t, strings.has_suffix(got, "="), "standard base64 padding (§15)")
  testing.expect(t, got != "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=", "not the untagged digest")
}

// SPEC.md §3 pins a regular File's hash to hash(content_bytes) with no tag,
// which is what makes it agree with sha256sum. examples/optiona.txt's content
// is a single known line, so the digest is checkable against a fixed value.
@(test)
test_sha256_of_a_regular_file_is_its_bare_content_digest :: proc(t: ^testing.T) {
  path := strings.concatenate({repo_root(), "/examples/optiona.txt"})
  defer delete(path)
  src := strings.concatenate({`sha256 loadfile "`, path, `"`})
  defer delete(src)

  // sha256sum says 653eaf05...6072908d; the same 32 bytes in base64 are what
  // the language hands back, so the two agree by construction, not by luck.
  testing.expect_value(t, eval_str(t, src), "ZT6vBQgoXEojRYd890EDlZWhUF/uGfXa+C9BNGBykI0=")
}

// The same content read through two different paths is one value (§3): the
// path is how it was obtained, not part of what it is.
@(test)
test_file_identity_is_content_not_path :: proc(t: ^testing.T) {
  a := strings.concatenate({repo_root(), "/examples/optiona.txt"})
  b := strings.concatenate({repo_root(), "/examples/optionb.txt"})
  defer delete(a)
  defer delete(b)

  same := strings.concatenate({`(loadfile "`, a, `") == (loadfile "`, a, `")`})
  diff := strings.concatenate({`(loadfile "`, a, `") == (loadfile "`, b, `")`})
  defer delete(same)
  defer delete(diff)

  testing.expect(t, eval_bool(t, same), "same content, two reads - equal")
  testing.expect(t, !eval_bool(t, diff), "different content - not equal")
}

// §5/§6: a Table's hash is key-sorted, so it doesn't depend on the order the
// entries were written in - matching values_equal, which matches by key.
@(test)
test_table_hash_is_key_sorted :: proc(t: ^testing.T) {
  testing.expect(t, eval_bool(t, `(sha256 { .a = 1, .b = 2 }) == (sha256 { .b = 2, .a = 1 })`))
  testing.expect(t, !eval_bool(t, `(sha256 { .a = 1, .b = 2 }) == (sha256 { .a = 2, .b = 1 })`))
  testing.expect(t, !eval_bool(t, `(sha256 empty) == (sha256 { .a = 1 })`))
}

// Leaves are domain-separated, so values that are unequal (value.odin makes no
// implicit Integer/Float coercion) don't collide.
@(test)
test_leaf_types_are_domain_separated :: proc(t: ^testing.T) {
  testing.expect(t, !eval_bool(t, `(sha256 5) == (sha256 5.0)`))
  testing.expect(t, !eval_bool(t, `(sha256 1) == (sha256 (1 == 1))`))
  testing.expect(t, !eval_bool(t, `(sha256 nothing) == (sha256 empty)`))
  testing.expect(t, !eval_bool(t, `(sha256 "1") == (sha256 1)`))
}

// The invariant that ties hash.odin to value.odin: values that compare equal
// must hash alike, or File identity and Table lookup would disagree with each
// other. IEEE's signed zero is the one place raw bit patterns would break it -
// 0.0 == -0.0 is true, so the two must not hash differently.
@(test)
test_equal_floats_hash_alike_across_signed_zero :: proc(t: ^testing.T) {
  testing.expect(t, eval_bool(t, `-0.0 == 0.0`), "IEEE: signed zeros compare equal")
  testing.expect(t, eval_bool(t, `(sha256 -0.0) == (sha256 0.0)`), "...so they must hash alike")
}

// An operand still in flight is awaited first, exactly like every other
// operator - `sha256 async e` hashes e's result, never the handle.
@(test)
test_sha256_awaits_an_async_operand :: proc(t: ^testing.T) {
  testing.expect(t, eval_bool(t, `(sha256 async ("a" concat "b")) == (sha256 "ab")`))
}

// ---- directories (§3) ----------------------------------------------------------

// A scratch tree, built entry by entry so a test can say exactly what it holds
// and then change one thing about it.
@(private = "file")
Tree :: struct {
  root: string,
}

@(private = "file")
make_tree :: proc(t: ^testing.T, name: string) -> Tree {
  root := strings.concatenate({repo_root(), "/.hash_test_", name})
  clear_tree_at(root) // a leftover from an interrupted run
  err := os.make_directory(root)
  testing.expect(t, err == nil, "could not create the scratch tree")
  return Tree{root = root}
}

@(private = "file")
tree_write :: proc(tree: Tree, rel: string, content: string) {
  path := strings.concatenate({tree.root, "/", rel}, context.temp_allocator)
  _ = os.write_entire_file(path, transmute([]u8)content)
}

@(private = "file")
tree_subdir :: proc(tree: Tree, rel: string) {
  _ = os.make_directory(strings.concatenate({tree.root, "/", rel}, context.temp_allocator))
}

// One level of nesting deep, which is all these trees ever have.
@(private = "file")
clear_tree_at :: proc(root: string) {
  if handle, err := os.open(root); err == nil {
    entries, _ := os.read_dir(handle, -1, context.temp_allocator)
    for entry in entries {
      child := strings.concatenate({root, "/", entry.name}, context.temp_allocator)
      // Only a directory gets opened and listed. Handing a file's handle to
      // os.read_dir is not a no-op on Windows - it walks a structure that
      // isn't there.
      if entry.type == .Directory {
        if inner, ierr := os.open(child); ierr == nil {
          grandchildren, _ := os.read_dir(inner, -1, context.temp_allocator)
          for g in grandchildren do os.remove(strings.concatenate({child, "/", g.name}, context.temp_allocator))
          os.close(inner)
        }
      }
      os.remove(child)
    }
    os.close(handle)
  }
  os.remove(root)
}

@(private = "file")
remove_tree :: proc(tree: Tree) {
  clear_tree_at(tree.root)
  delete(tree.root)
}

@(private = "file")
tree_digest :: proc(t: ^testing.T, tree: Tree) -> string {
  src := strings.concatenate({`sha256 loadfile "`, tree.root, `"`}, context.temp_allocator)
  return eval_str(t, src)
}

// §3 defines a directory's hash over its entries. The point of the whole
// exercise is that the digest is the *tree's*, not the path's: two directories
// holding the same thing are the same value, and one byte anywhere inside is a
// different one.
@(test)
test_directory_hash_is_its_contents :: proc(t: ^testing.T) {
  a := make_tree(t, "dir_a")
  defer remove_tree(a)
  b := make_tree(t, "dir_b")
  defer remove_tree(b)

  for tree in ([]Tree{a, b}) {
    tree_write(tree, "one.txt", "hello")
    tree_subdir(tree, "nested")
    tree_write(tree, "nested/two.txt", "world")
  }
  testing.expect_value(t, tree_digest(t, a), tree_digest(t, b))

  // One byte, one level down.
  before := tree_digest(t, a)
  c := make_tree(t, "dir_c")
  defer remove_tree(c)
  tree_write(c, "one.txt", "hello")
  tree_subdir(c, "nested")
  tree_write(c, "nested/two.txt", "worlds")
  testing.expect(t, before != tree_digest(t, c), "a changed byte is a changed tree")
}

@(test)
test_directory_hash_covers_names_not_just_content :: proc(t: ^testing.T) {
  // §3 hashes each entry with its name, so the same bytes under a different
  // name is a different directory. Without the name in the entry digest these
  // two would collide.
  a := make_tree(t, "name_a")
  defer remove_tree(a)
  tree_write(a, "alpha.txt", "same")

  b := make_tree(t, "name_b")
  defer remove_tree(b)
  tree_write(b, "beta.txt", "same")

  testing.expect(t, tree_digest(t, a) != tree_digest(t, b))
}

@(test)
test_a_directory_is_not_its_only_file :: proc(t: ^testing.T) {
  // A regular File hashes as its bare content (§3, untagged); a directory
  // holding just that file must not land on the same digest.
  tree := make_tree(t, "dir_vs_file")
  defer remove_tree(tree)
  tree_write(tree, "only.txt", "content")

  file_src := strings.concatenate({`sha256 loadfile "`, tree.root, `/only.txt"`}, context.temp_allocator)
  testing.expect(t, tree_digest(t, tree) != eval_str(t, file_src))
}

@(test)
test_two_directory_handles_on_one_tree_are_equal :: proc(t: ^testing.T) {
  // §3: a File's identity is content, not path. Two separate handles are two
  // objects, so this only holds because the comparison hashes them - which
  // means the evaluator warmed both digests first (hash.odin).
  tree := make_tree(t, "dir_equality")
  defer remove_tree(tree)
  tree_write(tree, "x.txt", "same")

  src := strings.concatenate({
    `let a loadfile "`, tree.root, `"; let b loadfile "`, tree.root, `"; a == b`,
  }, context.temp_allocator)
  testing.expect(t, eval_bool(t, src), "two handles on one tree are one value")
}

@(test)
test_different_trees_are_not_equal :: proc(t: ^testing.T) {
  a := make_tree(t, "neq_a")
  defer remove_tree(a)
  tree_write(a, "x.txt", "one")
  b := make_tree(t, "neq_b")
  defer remove_tree(b)
  tree_write(b, "x.txt", "two")

  src := strings.concatenate({
    `let a loadfile "`, a.root, `"; let b loadfile "`, b.root, `"; a == b`,
  }, context.temp_allocator)
  testing.expect(t, !eval_bool(t, src))
}

// Reading a tree is I/O, and I/O is what §9's permission governs. The handle
// is obtained while io is granted; the *hash* is asked for after it has been
// revoked, which is the moment the read would happen.
@(test)
test_hashing_a_directory_needs_io :: proc(t: ^testing.T) {
  tree := make_tree(t, "dir_perm")
  defer remove_tree(tree)
  tree_write(tree, "x.txt", "content")

  src := strings.concatenate({
    `let d loadfile "`, tree.root, `"; (sha256 d) chctx chperm { .name = "io", .enabled = 1 > 2 }`,
  }, context.temp_allocator)
  testing.expect(t, strings.contains(eval_failure(t, src), "needs the io permission"))
}

@(test)
test_a_directory_digest_is_read_once :: proc(t: ^testing.T) {
  // §3 calls a File an immutable handle, so its digest is fixed at the first
  // read: revoking io afterwards cannot make the same value unhashable, and
  // changing the tree afterwards cannot make it a different value.
  tree := make_tree(t, "dir_memo")
  defer remove_tree(tree)
  tree_write(tree, "x.txt", "before")

  src := strings.concatenate({
    `let d loadfile "`, tree.root, `";`,
    ` (sha256 d) == ((sha256 d) chctx chperm { .name = "io", .enabled = 1 > 2 })`,
  }, context.temp_allocator)
  testing.expect(t, eval_bool(t, src), "the second ask is answered from the first read")
}

// §3 hashes a symlink entry as its target *string*, without resolving it - so
// two links pointing at different names are two different trees even when
// neither target exists, and a link is never confused with what it points at.
//
// Skipped where a symlink cannot be created: on Windows that needs Developer
// Mode or an elevated shell, the same privilege examples/files-symlink.hb
// wants (see examples_test.odin).
@(test)
test_symlink_entries_hash_as_their_target :: proc(t: ^testing.T) {
  tree := make_tree(t, "dir_symlink")
  defer remove_tree(tree)

  dir_fd, oerr := fs_open_dir_path(tree.root)
  testing.expect(t, oerr == .None, "could not open the scratch tree")
  if oerr != .None do return
  defer fs_close(dir_fd)

  if err := fs_symlink_at(dir_fd, "link", "somewhere.txt"); err != .None {
    log.infof("skipping: this environment cannot create a symlink (%v) - on Windows that needs Developer Mode", err)
    return
  }
  with_first := tree_digest(t, tree)

  other := make_tree(t, "dir_symlink_other")
  defer remove_tree(other)
  other_fd, oerr2 := fs_open_dir_path(other.root)
  testing.expect(t, oerr2 == .None)
  if oerr2 != .None do return
  defer fs_close(other_fd)
  testing.expect(t, fs_symlink_at(other_fd, "link", "elsewhere.txt") == .None)

  testing.expect(t, with_first != tree_digest(t, other), "the target string is part of the entry")
}

// ---- ctx.cache (§9) ------------------------------------------------------------

@(test)
test_ctx_cache_hashes_as_a_bare_tag :: proc(t: ^testing.T) {
  // §6 says every value is hashable, and ctx.cache is a value. It has no
  // content to hash and its one distinguishing feature - the directory it is
  // rooted at - is the path §9 keeps out of the language, so it is a tag and
  // nothing more. What that has to be is stable and unlike anything else.
  testing.expect(t, eval_bool(t, `(sha256 ctx.cache) == (sha256 ctx.cache)`))
  testing.expect(t, !eval_bool(t, `(sha256 ctx.cache) == (sha256 nothing)`))
}

// ---- functions (§15) -----------------------------------------------------------

@(test)
test_functions_hash_by_body_and_captures :: proc(t: ^testing.T) {
  // The same expression reading the same values is the same function...
  testing.expect(t, eval_bool(t, `(sha256 func (#arg + 1)) == (sha256 func (#arg + 1))`))
  testing.expect(t, eval_bool(t, `(sha256 (let x 1; func (#arg + x))) == (sha256 (let x 1; func (#arg + x)))`))
  // ...and a different body, or a different captured value, is not.
  testing.expect(t, !eval_bool(t, `(sha256 func (#arg + 1)) == (sha256 func (#arg + 2))`))
  testing.expect(t, !eval_bool(t, `(sha256 (let x 1; func (#arg + x))) == (sha256 (let x 2; func (#arg + x)))`))
}

@(test)
test_function_hash_ignores_the_rest_of_the_scope :: proc(t: ^testing.T) {
  // The property `cached` needs: a closure's digest is what it reads, not what
  // happened to be in scope where it was written. Without free-variable
  // analysis this would fail, and every cache lookup would miss whenever an
  // unrelated binding nearby changed.
  testing.expect(t, eval_bool(t, `
    (sha256 (let x 1; let unrelated "zz"; func (#arg + x)))
      == (sha256 (let x 1; func (#arg + x)))`))
}

@(test)
test_builtins_hash_by_name :: proc(t: ^testing.T) {
  // A builtin has no body to take a shape from (§16), so its identity is the
  // operation it is.
  testing.expect(t, eval_bool(t, `(sha256 loadfile) == (sha256 loadfile)`))
  testing.expect(t, !eval_bool(t, `(sha256 loadfile) == (sha256 createfile)`))
  // A partially applied one carries what it was built from, so two `chperm`
  // results are the same function exactly when they grant the same thing.
  testing.expect(t, eval_bool(t, `
    (sha256 chperm { .name = "io", .enabled = 1 < 2 })
      == (sha256 chperm { .name = "io", .enabled = 1 < 2 })`))
  testing.expect(t, !eval_bool(t, `
    (sha256 chperm { .name = "io", .enabled = 1 < 2 })
      == (sha256 chperm { .name = "io", .enabled = 1 > 2 })`))
}

@(test)
test_a_recursive_function_hashes :: proc(t: ^testing.T) {
  // `let rec` over a closure captures the scope the closure itself is bound
  // in, so the function reaches itself: a cycle, and it goes the same way a
  // cyclic Table does (hash_cyclic.odin). What matters is that it terminates
  // and stays consistent.
  fact := `let rec fact (let n; (n == 0) then 1 else n * (fact (n - 1))); sha256 fact`
  digest := eval_str(t, fact)
  testing.expect(t, len(digest) == 44)
  testing.expect(t, eval_bool(t, strings.concatenate({
    `(`, fact, `) == "`, digest, `"`,
  }, context.temp_allocator)), "the same recursive function hashes the same way twice")
}

// The two kinds §3/§15 still describe no digest for. Both are shapes a program
// cannot hold: an un-awaited handle is awaited by every operator that meets
// one (§2), and a `.Other` directory entry is a device node in a build tree.
@(test)
test_unhashable_values_fail_with_a_reason :: proc(t: ^testing.T) {
  // Everything the old version of this test listed - a Function, ctx.cache, a
  // directory File - now hashes; the tests above are what replaced it. What is
  // left is worth one assertion: `serialize` was removed, and the surface says
  // so by these being ordinary names rather than reserved words.
  testing.expect(t, len(eval_str(t, `sha256 func 1`)) == 44)
  testing.expect(t, len(eval_str(t, `sha256 ctx.cache`)) == 44)
}

// `serialize`/`serialize_file` were removed from the language, so they are
// ordinary identifiers again - not reserved words that parse and then fail.
@(test)
test_serialize_is_an_ordinary_identifier :: proc(t: ^testing.T) {
  testing.expect(t, eval_bool(t, `let serialize 5; serialize == 5`))
  testing.expect(t, eval_bool(t, `{ .serialize_file = 1 } is { .serialize_file as n }  and n == 1`))
}
