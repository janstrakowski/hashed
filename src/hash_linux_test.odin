// SPEC.md §3 hashes no permission bit, and Linux is the only target that can
// prove it: it is the only one that has an executable bit to set. WASI's
// filestat carries no permission bits and Windows has no POSIX exec bit
// (fs.odin), so the same assertion elsewhere would hold without establishing
// anything - which is why this file is `#+build linux` rather than a `when`.
#+build linux
package hashedbuild

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

@(private = "file")
eval_digest :: proc(t: ^testing.T, path: string) -> string {
  src := strings.concatenate({`sha256 loadfile "`, path, `"`})
  defer delete(src)
  ast := parse(source_t{name = "test", n_bytes = u64(len(src)), data = raw_data(src)}, ast_t{})
  cache := strings.concatenate({repo_root(), "/.hash_linux_test_cache"})
  defer delete(cache)
  interp := Interpreter{ast = &ast, src = src, current_ctx = make_root_context(cache)}
  val, ok := eval_program(&interp, ast.root, make_global_env())
  testing.expect(t, ok, interp.error_message)
  digest, is_str := val.(string)
  testing.expect(t, is_str, "expected a Utf8 digest")
  return digest
}

@(test)
test_the_executable_bit_is_not_part_of_a_directory_hash :: proc(t: ^testing.T) {
  root := strings.concatenate({repo_root(), "/.hash_linux_test_exec"})
  defer delete(root)
  file := strings.concatenate({root, "/build.sh"})
  defer delete(file)
  defer os.remove(root)
  defer os.remove(file)

  os.remove(file)
  os.remove(root)
  testing.expect(t, os.make_directory(root) == nil, "could not create the scratch tree")
  _ = os.write_entire_file(file, transmute([]u8)string("#!/bin/sh\necho hi\n"))

  // Two hashes of the same bytes under the same name, differing only in whether
  // the file is a program. §3 does not distinguish them: only Linux can see the
  // difference at all, so hashing it would make one source tree two values
  // depending on where it was checked out.
  cname := strings.clone_to_cstring(file, context.temp_allocator)
  testing.expect(t, linux.chmod(cname, {.IRUSR, .IWUSR}) == .NONE)
  plain := eval_digest(t, root)

  testing.expect(t, linux.chmod(cname, {.IRUSR, .IWUSR, .IXUSR}) == .NONE)
  executable := eval_digest(t, root)

  // That the bit actually landed is half the test - without it the comparison
  // would hold for the wrong reason.
  dir_fd, oerr := fs_open_dir_path(root)
  testing.expect(t, oerr == .None, "could not open the scratch tree")
  if oerr == .None {
    defer fs_close(dir_fd)
    entries, lerr := fs_list_entries_at(dir_fd, context.temp_allocator)
    testing.expect(t, lerr == .None)
    saw := false
    for entry in entries do if entry.name == "build.sh" && entry.is_executable do saw = true
    testing.expect(t, saw, "chmod did not set a bit for the digest to ignore")
  }

  testing.expect_value(t, plain, executable)

  // No other mode bit counts either - the rule is that permissions are not part
  // of what a tree is, not that one particular bit was singled out.
  testing.expect(t, linux.chmod(cname, {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IROTH}) == .NONE)
  testing.expect_value(t, eval_digest(t, root), plain)
}
