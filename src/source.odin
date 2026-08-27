package hashedbuild

import "core:path/filepath"

// Whether this build includes the terminal UI - the live editor and its
// debugger (editor.odin, term_*.odin). Both targets have one now: a real
// terminal on Linux, a browser tab running xterm.js on WASI. Other targets
// (freestanding wasm, say) have no terminal at all, and `-i` says so.
TUI_AVAILABLE :: ODIN_OS == .Linux || ODIN_OS == .WASI

source_t :: struct {
  name: string,
  n_bytes: u64,
  data: [^]u8,
}

// The directory a program's relative paths resolve against: the source file's
// own directory, so a script behaves the same wherever it is run from - the
// same reasoning as run_file in main.odin. An unsaved editor buffer just
// falls back to the process's cwd (has_base_dir stays false). Lives here, not
// beside the editor, because the debugger sets a run up the same way and
// neither is target-specific.
setup_interp_base_dir :: proc(interp: ^Interpreter, current_path: string) {
  if current_path == "" do return
  dir_path := filepath.dir(current_path)
  if dir_path == "" do dir_path = "."
  dir_fd, errno := fs_open_dir_path(dir_path)
  if errno == .None {
    interp.base_dir_fd = dir_fd
    interp.has_base_dir = true
    interp.base_dir_path = absolute_dir_path(dir_path)
  }
}
