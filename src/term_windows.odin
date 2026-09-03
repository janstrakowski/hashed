package hashed

import "core:sys/windows"

// The terminal layer for Windows. The editor above it (editor.odin) speaks
// one language on every target - it reads bytes from stdin and writes ANSI
// escape sequences to stdout - so the job here is to get a Windows console
// into the state where that language is understood, and to put it back
// afterwards.
//
// Three console modes matter, and all three are the same idea as the termios
// flags on the Linux side:
//
//   ENABLE_VIRTUAL_TERMINAL_PROCESSING (output)
//       makes the console interpret the escape sequences the editor writes
//       instead of printing them literally. Without it the screen fills with
//       "[2J" and the like.
//   ENABLE_VIRTUAL_TERMINAL_INPUT (input)
//       makes the console *produce* escape sequences for arrow keys, Home,
//       function keys and so on, rather than the WIN32_INPUT_RECORD stream it
//       would otherwise deliver. That is precisely the encoding the editor's
//       key decoder already expects from a Unix terminal, so with this bit
//       set the decoder needs no Windows case at all.
//   ENABLE_LINE_INPUT / ENABLE_ECHO_INPUT / ENABLE_PROCESSED_INPUT (input)
//       cleared, which is what raw mode means: deliver each keystroke as it
//       is typed, don't echo it, and don't turn Ctrl+C into an interrupt.
//       That last one matches the Linux side's ISIG: the editor wants 0x03 as
//       an ordinary byte so it can restore the console before exiting.
//
// Both consoles are restored exactly as found, which is why the original
// modes travel in Term_State rather than being reconstructed from constants.

Term_State :: struct {
  in_mode:   windows.DWORD,
  out_mode:  windows.DWORD,
  in_valid:  bool,
  out_valid: bool,
}

@(private = "file")
std_in :: proc() -> windows.HANDLE {
  return windows.GetStdHandle(windows.STD_INPUT_HANDLE)
}

@(private = "file")
std_out :: proc() -> windows.HANDLE {
  return windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
}

term_enable_raw :: proc() -> (state: Term_State, ok: bool) {
  hin, hout := std_in(), std_out()

  if !windows.GetConsoleMode(hin, &state.in_mode) do return state, false
  state.in_valid = true

  raw_in := state.in_mode
  raw_in &~= windows.ENABLE_LINE_INPUT | windows.ENABLE_ECHO_INPUT | windows.ENABLE_PROCESSED_INPUT
  raw_in |= windows.ENABLE_VIRTUAL_TERMINAL_INPUT
  if !windows.SetConsoleMode(hin, raw_in) do return state, false

  // Output is best-effort on purpose. A redirected stdout has no console mode
  // to set, and the editor only ever runs when stdin is a console anyway;
  // failing the whole thing over it would be worse than writing escapes into
  // a pipe.
  if windows.GetConsoleMode(hout, &state.out_mode) {
    state.out_valid = true
    windows.SetConsoleMode(hout, state.out_mode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
  }
  return state, true
}

term_restore :: proc(state: Term_State) {
  if state.in_valid do windows.SetConsoleMode(std_in(), state.in_mode)
  if state.out_valid do windows.SetConsoleMode(std_out(), state.out_mode)
}

// GetConsoleMode succeeds only on a real console handle, which makes it the
// direct equivalent of isatty() here.
term_is_tty :: proc() -> bool {
  mode: windows.DWORD
  return bool(windows.GetConsoleMode(std_in(), &mode))
}

// The window, not the buffer: srWindow is the visible region, while
// dwSize.Y is the scrollback height (300 by default), which would have the
// editor drawing far below the screen. Falls back to the same conservative
// 24x80 the other targets use.
term_size :: proc() -> (rows: int, cols: int) {
  info: windows.CONSOLE_SCREEN_BUFFER_INFO
  if !windows.GetConsoleScreenBufferInfo(std_out(), &info) do return 24, 80
  rows = int(info.srWindow.Bottom - info.srWindow.Top) + 1
  cols = int(info.srWindow.Right - info.srWindow.Left) + 1
  if rows <= 0 || cols <= 0 do return 24, 80
  return rows, cols
}
