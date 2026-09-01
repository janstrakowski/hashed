package hashedbuild

import "core:path/filepath"

source_t :: struct {
  name: string,
  n_bytes: u64,
  data: [^]u8,
}

// The directory a source file sits in, which is what a `// run:` line's
// relative paths are resolved against (run_line.odin). Nothing derives a
// program's *own* directories from this: those come from `--dir` and nowhere
// else (§9/§16).
//
// `filepath.dir` answers "" for a bare filename with no directory component,
// which no target will open, so that case is normalised here rather than at
// each call site. Lives here because it is target-independent and both the
// tests and the editor want it.
dir_of_source :: proc(current_path: string) -> string {
  if current_path == "" do return "."
  dir_path := filepath.dir(current_path)
  if dir_path == "" do dir_path = "."
  return dir_path
}
