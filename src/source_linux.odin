package hashedbuild

import "core:linux"
import "core:path/filepath"

load_source_file :: proc(dirfd: int, path: cstring) -> (res: source_t, errno: int) {
  assert(path != nil && path[0] != 0, "path must not be empty")
  fd: linux.Fd
  fd, errno = linux.openat(dirfd, path, {})
  if errno != 0 {
    return 
  }
  defer linux.close(fd)

  statx: linux.Statx
  errno = linux.statx(fd, {}, {.EMPTY_PATH}, {.SIZE}, &statx)
  if errno != 0 {
    return
  }

  memptr: rawptr
  memptr, errno = linux.mmap({}, statx.size, {.READ}, {.PRIVATE}, fd)
  if errno != 0 {
    return
  }

  res = source_t {
    name: filepath.base(string(path)),
    n_bytes: statx.size,
    data: memptr,
  }
  return
}

free_source_file :: proc(source: source_t) -> (errno: int) {
  return linux.munmap(source.data, source.n_bytes)
}
