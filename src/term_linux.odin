package hashedbuild

import "core:sys/linux"
import "core:sys/posix"

Term_State :: struct {
  orig: posix.termios,
}

// Puts stdin into raw mode: no line buffering, no local echo, no signal
// generation (Ctrl+C is read as a plain byte, 0x03, instead of raising SIGINT -
// the live editor treats it as its own key so it can restore the terminal
// cleanly first), and no software flow control (IXON/IXOFF) - without clearing
// those, the terminal driver itself intercepts Ctrl+S/Ctrl+Q for XOFF/XON
// before the byte ever reaches this program, which is why they'd otherwise
// silently do nothing.
term_enable_raw :: proc() -> (state: Term_State, ok: bool) {
  if posix.tcgetattr(posix.STDIN_FILENO, &state.orig) != .OK do return state, false
  raw := state.orig
  raw.c_lflag -= {.ICANON, .ECHO, .ISIG}
  raw.c_iflag -= {.IXON, .IXOFF}
  raw.c_cc[.VMIN] = 1
  raw.c_cc[.VTIME] = 0
  if posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw) != .OK do return state, false
  return state, true
}

term_restore :: proc(state: Term_State) {
  s := state
  posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &s.orig)
}

term_is_tty :: proc() -> bool {
  return bool(posix.isatty(posix.STDIN_FILENO))
}

@(private = "file")
Winsize :: struct {
  row, col, xpixel, ypixel: u16,
}

@(private = "file")
TIOCGWINSZ :: 0x5413

// Falls back to a conservative default if the ioctl fails (e.g. stdout isn't
// actually a terminal device for some reason).
term_size :: proc() -> (rows: int, cols: int) {
  ws: Winsize
  ret := linux.ioctl(linux.Fd(1), TIOCGWINSZ, uintptr(&ws))
  if int(ret) < 0 || ws.row == 0 || ws.col == 0 {
    return 24, 80
  }
  return int(ws.row), int(ws.col)
}
