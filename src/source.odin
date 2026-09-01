package hashedbuild

import "core:path/filepath"

// Whether this build includes the terminal UI - the live editor and its
// debugger (editor.odin, term_*.odin). All three shipping targets have one: a
// real terminal on Linux, a Windows console put into virtual-terminal mode,
// and a browser tab running xterm.js on WASI. Other targets (freestanding
// wasm, say) have no terminal at all, and `-i` says so.
TUI_AVAILABLE :: ODIN_OS == .Linux || ODIN_OS == .Windows || ODIN_OS == .WASI

source_t :: struct {
  name: string,
  n_bytes: u64,
  data: [^]u8,
}

// The directory a program gets as `ctx.dir` (§9): the source file's own, so a
// script behaves the same wherever it is run from. "" - an unsaved editor
// buffer, or the REPL, with no file to be relative to - means the process's
// working directory instead. `filepath.dir` answers "" for a bare filename
// with no directory component, which no target will open, so that case is
// normalised here rather than at each call site.
//
// Lives here, not beside the editor, because main, the editor and the
// debugger all set a run up the same way and none of it is target-specific.
// What the caller does with the answer is open it (open_root_dirs) - unless
// `--dir <path>` named a different directory, or `--no-default-dir` said the
// program is to have no main directory at all.
main_dir_for_source :: proc(current_path: string) -> string {
  if current_path == "" do return "."
  dir_path := filepath.dir(current_path)
  if dir_path == "" do dir_path = "."
  return dir_path
}
