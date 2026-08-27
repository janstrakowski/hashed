package hashedbuild

import "core:path/filepath"
import "core:strings"

// The WASI counterpart to source_linux.odin. It reads the file rather than
// mapping it: preview1 has no mmap, and no cwd either, so the path is
// resolved through whatever the host preopened (see fs_wasi.odin).
load_source_file :: proc(path_str: string) -> (res: source_t, err: Fs_Error) {
  assert(len(path_str) != 0, "path must not be empty")

  parent, rel, ok := resolve_source_parent(path_str)
  if !ok do return res, .Access

  fd, oerr := fs_open_read_at(parent, rel, false)
  if oerr != .None do return res, oerr
  defer fs_close(fd)

  data, rerr := fs_read_all(fd)
  if rerr != .None do return res, rerr

  res = source_t{
    name    = filepath.base(path_str),
    n_bytes = u64(len(data)),
    data    = raw_data(data),
  }
  return res, .None
}

// Mirrors free_source_file's Linux contract (there: munmap; here: the read
// buffer goes back to the allocator).
free_source_file :: proc(source: source_t) {
  if source.data == nil do return
  delete(source.data[:source.n_bytes])
}

// Splits a path into the preopened directory that covers it plus the rest,
// via the same resolution the filesystem builtins use.
@(private = "file")
resolve_source_parent :: proc(path: string) -> (Fs_Fd, string, bool) {
  cleaned := clean_path(path)
  parent := fs_cwd_dir()
  if parent == FS_INVALID_FD do return FS_INVALID_FD, "", false
  return parent, strings.trim_prefix(cleaned, "/"), true
}
