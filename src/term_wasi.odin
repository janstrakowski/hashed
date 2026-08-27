package hashedbuild

import "core:os"
import "core:strconv"

// The terminal layer for WASI, where "the terminal" is a browser tab running
// xterm.js (docs/playground.html). Everything the Linux side does with termios
// and ioctl is either unnecessary here or answered by the host instead:
//
//   raw mode   the page already delivers keystrokes one at a time, unechoed -
//              there is no line discipline in between to turn off.
//   size       WASI has no ioctl, so the host passes COLUMNS/LINES in the
//              environment, the way a terminal-less process is told anywhere.
//   is-a-tty   preview1 cannot answer this; the host only runs the editor when
//              it has a terminal to run it in, so saying yes is the truth.

Term_State :: struct {}

term_enable_raw :: proc() -> (state: Term_State, ok: bool) {
  return Term_State{}, true
}

term_restore :: proc(state: Term_State) {}

term_is_tty :: proc() -> bool {
  return true
}

term_size :: proc() -> (rows: int, cols: int) {
  rows, cols = 24, 80 // the conventional fallback, same as the Linux side
  if value, found := os.lookup_env("LINES", context.temp_allocator); found {
    if parsed, parsed_ok := strconv.parse_int(value); parsed_ok && parsed > 0 do rows = parsed
  }
  if value, found := os.lookup_env("COLUMNS", context.temp_allocator); found {
    if parsed, parsed_ok := strconv.parse_int(value); parsed_ok && parsed > 0 do cols = parsed
  }
  return rows, cols
}
