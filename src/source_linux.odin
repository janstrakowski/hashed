package hashedbuild

import "core:sys/linux"
import "core:path/filepath"

load_source_file :: proc(dirfd: linux.Fd, path: cstring) -> (res: source_t, errno: linux.Errno) {
  assert(path != nil && len(path) != 0, "path must not be empty")
  fd: linux.Fd
  fd, errno = linux.openat(dirfd, path, {})
  if errno != .NONE {
    return
  }
  defer linux.close(fd)

  statx: linux.Statx
  errno = linux.statx(fd, "", {.EMPTY_PATH}, {.SIZE}, &statx)
  if errno != .NONE {
    return
  }

  memptr: rawptr
  memptr, errno = linux.mmap({}, uint(statx.size), {.READ}, {.PRIVATE}, fd)
  if errno != .NONE {
    return
  }

  res = source_t {
    name = filepath.base(string(path)),
    n_bytes = statx.size,
    data = ([^]u8)(memptr),
  }
  return
}

free_source_file :: proc(source: source_t) -> (errno: linux.Errno) {
  return linux.munmap(source.data, uint(source.n_bytes))
}
