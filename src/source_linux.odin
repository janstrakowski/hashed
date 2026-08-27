package hashedbuild

import "core:strings"
import "core:sys/linux"
import "core:path/filepath"

// Maps a source file into memory (SPEC.md has nothing to say about this - it
// is purely how the interpreter gets its bytes). The WASI counterpart in
// source_wasi.odin reads instead of mapping; both hand back a source_t and
// free it through free_source_file, which is all the rest of the code knows.
load_source_file :: proc(path_str: string) -> (res: source_t, err: Fs_Error) {
  assert(len(path_str) != 0, "path must not be empty")
  path := strings.clone_to_cstring(path_str, context.temp_allocator)
  fd, errno := linux.openat(linux.AT_FDCWD, path, {})
  if errno != .NONE {
    return res, fs_errno_to_error(errno)
  }
  defer linux.close(fd)

  statx: linux.Statx
  if serr := linux.statx(fd, "", {.EMPTY_PATH}, {.SIZE}, &statx); serr != .NONE {
    return res, fs_errno_to_error(serr)
  }

  memptr, merr := linux.mmap({}, uint(statx.size), {.READ}, {.PRIVATE}, fd)
  if merr != .NONE {
    return res, fs_errno_to_error(merr)
  }

  res = source_t {
    name = filepath.base(path_str),
    n_bytes = statx.size,
    data = ([^]u8)(memptr),
  }
  return res, .None
}

free_source_file :: proc(source: source_t) {
  linux.munmap(source.data, uint(source.n_bytes))
}
