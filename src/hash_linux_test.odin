// The executable bit is the one part of SPEC.md §3's directory hash that only
// one target can see, so it is the one part tested on only one target. WASI's
// filestat carries no permission bits and Windows has no POSIX exec bit
// (fs.odin), and hashing there treats every file as non-executable - which is
// the language's answer, not a gap, and is what LANGUAGE.md documents.
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
test_the_executable_bit_is_part_of_a_directory_hash :: proc(t: ^testing.T) {
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

  // Two hashes of the same bytes under the same name, differing only in
  // whether the file is a program. §3 asks for exactly that distinction, and
  // it is a real one in a build: a checked-out `configure` that lost its bit
  // is not the same tree.
  cname := strings.clone_to_cstring(file, context.temp_allocator)
  testing.expect(t, linux.chmod(cname, {.IRUSR, .IWUSR}) == .NONE)
  plain := eval_digest(t, root)

  testing.expect(t, linux.chmod(cname, {.IRUSR, .IWUSR, .IXUSR}) == .NONE)
  executable := eval_digest(t, root)

  testing.expect(t, plain != executable, "the exec bit is part of what a directory is")

  // ...and it is only the owner bit that counts. §3 says "the executable flag
  // only - not full POSIX mode", so who else may run it is not part of what
  // the file is.
  testing.expect(t, linux.chmod(cname, {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IROTH}) == .NONE)
  testing.expect_value(t, eval_digest(t, root), executable)
}
