// Tests run natively, never in a WASI build - see eval_test.odin.
#+build linux, windows
package hashedbuild

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

// The kinds §3/§15 leave open fail by name rather than inventing a digest.
@(test)
test_unhashable_values_fail_with_a_reason :: proc(t: ^testing.T) {
  testing.expect(t, strings.contains(eval_failure(t, `sha256 func 1`), "Function has no hash"))
  testing.expect(t, strings.contains(eval_failure(t, `sha256 ctx.cache`), "ctx.cache has no hash"))

  dir := strings.concatenate({`sha256 loadfile "`, repo_root(), `/examples"`})
  defer delete(dir)
  testing.expect(t, strings.contains(eval_failure(t, dir), "directory File has no hash"))
}

// `serialize`/`serialize_file` were removed from the language, so they are
// ordinary identifiers again - not reserved words that parse and then fail.
@(test)
test_serialize_is_an_ordinary_identifier :: proc(t: ^testing.T) {
  testing.expect(t, eval_bool(t, `let serialize 5; serialize == 5`))
  testing.expect(t, eval_bool(t, `{ .serialize_file = 1 } is { .serialize_file as n }  and n == 1`))
}
