package hashedbuild

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:unicode/utf8"

// Clips a string to at most `max_cols` *codepoints*, not bytes. Doesn't
// account for wide (e.g. CJK) or zero-width characters - just enough to stop
// an ordinary multi-byte codepoint (e.g. "§", 2 bytes / 1 column) from
// silently padding one byte short of its real display width and throwing the
// column separator after it off by one, only on rows containing one.
@(private = "file")
clip_to_cols :: proc(s: string, max_cols: int) -> string {
  if max_cols <= 0 do return ""
  count := 0
  i := 0
  for i < len(s) {
    if count >= max_cols do return s[:i]
    _, size := utf8.decode_rune_in_string(s[i:])
    i += size
    count += 1
  }
  return s
}

@(private = "file")
col_count :: proc(s: string) -> int {
  return utf8.rune_count_in_string(s)
}

// Wraps one logical line into one or more display lines of at most `width`
// codepoints each. An empty line still produces exactly one (empty) output
// line, so blank lines keep taking up exactly one row like before wrapping.
@(private = "file")
wrap_line :: proc(line: string, width: int, out: ^[dynamic]string) {
  if width <= 0 || col_count(line) <= width {
    append(out, line)
    return
  }
  remaining := line
  for col_count(remaining) > width {
    chunk := clip_to_cols(remaining, width)
    append(out, chunk)
    remaining = remaining[len(chunk):]
  }
  append(out, remaining)
}

// Wraps every line in `lines` to `width` columns, returning the flattened
// display lines plus, per original line, the display-row index its first
// wrapped segment starts at (`line_starts[i+1]` is always a valid one-past-
// the-end bound for line i's segments, since lines wrap independently).
@(private = "file")
wrap_lines :: proc(lines: []string, width: int, allocator := context.allocator) -> (out: [dynamic]string, line_starts: [dynamic]int) {
  out = make([dynamic]string, 0, len(lines), allocator)
  line_starts = make([dynamic]int, 0, len(lines), allocator)
  for line in lines {
    append(&line_starts, len(out))
    wrap_line(line, width, &out)
  }
  return
}

// Maps a (logical row, logical column) position - e.g. the edit cursor - to
// its wrapped (display row, display column), clamping a position that falls
// exactly on a wrap boundary (a line whose length is a multiple of `width`,
// cursor at its very end) to the last real segment instead of a nonexistent
// one-past-the-end segment that would otherwise land on the next line's row.
@(private = "file")
wrapped_cursor_pos :: proc(line_starts: []int, wrapped_count: int, logical_row: int, logical_col: int, width: int) -> (display_row: int, display_col: int) {
  start := line_starts[logical_row]
  end := line_starts[logical_row + 1] if logical_row + 1 < len(line_starts) else wrapped_count
  segment_count := max(end - start, 1)
  seg := logical_col / width
  col := logical_col % width
  if seg >= segment_count do return start + segment_count - 1, width
  return start + seg, col
}

Prompt_Mode :: enum { None, Save, Load }

// The three panes the live editor can show. `panel_order` is their left-to-
// right display order; `panel_visible` (indexed by kind) is independent of
// order, so a hidden panel keeps its place in line for whenever it's shown
// again instead of being dropped from the arrangement.
Panel_Kind :: enum { Source, Ast, Result, Steps, Debugger }

@(private = "file")
panel_title :: proc(pk: Panel_Kind) -> string {
  #partial switch pk {
  case .Source: return "source"
  case .Ast: return "ast"
  case .Result: return "result"
  case .Steps: return "steps"
  case .Debugger: return "debug"
  }
  return "?"
}

@(private = "file")
toggle_panel :: proc(e: ^Editor, p: Panel_Kind) {
  visible_count := 0
  for pk in Panel_Kind do if e.panel_visible[pk] do visible_count += 1
  if e.panel_visible[p] && visible_count <= 1 do return // always keep at least one panel up
  e.panel_visible[p] = !e.panel_visible[p]
}

@(private = "file")
rotate_panels_left :: proc(e: ^Editor) {
  if len(e.panel_order) < 2 do return
  first := e.panel_order[0]
  copy(e.panel_order[:], e.panel_order[1:])
  e.panel_order[len(e.panel_order) - 1] = first
}

@(private = "file")
rotate_panels_right :: proc(e: ^Editor) {
  if len(e.panel_order) < 2 do return
  last := e.panel_order[len(e.panel_order) - 1]
  copy(e.panel_order[1:], e.panel_order[:len(e.panel_order) - 1])
  e.panel_order[0] = last
}

// A search-and-select popup listing `examples/*.hb`. `items` is the full,
// alphabetized listing; `filtered` holds indices into `items` matching
// `search` (recomputed on every keystroke); `selected` indexes into
// `filtered`, not `items`, since the set of matches changes as you type.
Example_Menu :: struct {
  active:   bool,
  items:    [dynamic]string,
  filtered: [dynamic]int,
  search:   [dynamic]u8,
  selected: int,
}

Editor :: struct {
  buf:            [dynamic]u8,
  cursor:         int, // byte offset into buf, 0..=len(buf)
  current_path:   string, // "" if the buffer has never been saved/loaded to a path
  source_scroll:  int, // first visible source line - follows the cursor automatically
  ast_scroll:     int, // first visible AST line - moved only by PageUp/PageDown/wheel
  panel_visible:  [Panel_Kind]bool,
  panel_order:    [dynamic]Panel_Kind, // left-to-right; filtered by panel_visible at render time
  prompt_mode:    Prompt_Mode,
  prompt_buf:     [dynamic]u8,
  example_menu:   Example_Menu,
  status_message: string, // transient, shown in the footer until the next action; "" if none
  completion_hint: string, // candidate names from the last Tab press, shown while prompting; "" if none
  cache_dir:      string, // CLI --cache-dir override; "" resolves the XDG default (SPEC.md §9/§16)
  debugger:       ^Debugger_Run, // the live, paused-in-place debugger run; nil until first needed
  debug_last_src: string, // buffer content the current `debugger` run was started from - edits auto-restart it
}

editor_init :: proc(e: ^Editor) {
  // Steps and Debugger both start hidden - the most verbose/specialized
  // panels, off by default so the ordinary view stays uncluttered; Alt+4/5
  // reveal them. Still in panel_order so toggling one on gives it a place,
  // and so it participates in Alt+,/. reordering like any other panel.
  e.panel_visible = #partial [Panel_Kind]bool{.Source = true, .Ast = true, .Result = true}
  e.panel_order = make([dynamic]Panel_Kind, 0, len(Panel_Kind))
  append(&e.panel_order, Panel_Kind.Source, Panel_Kind.Ast, Panel_Kind.Result, Panel_Kind.Steps, Panel_Kind.Debugger)
}

editor_destroy :: proc(e: ^Editor) {
  stop_debugger_run(e.debugger)
  delete(e.buf)
  delete(e.panel_order)
  delete(e.prompt_buf)
  delete(e.current_path)
  delete(e.status_message)
  delete(e.completion_hint)
  for it in e.example_menu.items do delete(it)
  delete(e.example_menu.items)
  delete(e.example_menu.filtered)
  delete(e.example_menu.search)
  delete(e.debug_last_src)
}

@(private = "file")
set_completion_hint :: proc(e: ^Editor, msg: string) {
  delete(e.completion_hint)
  e.completion_hint = msg
}

// Takes ownership of `msg` - callers pass either an `fmt.aprintf` result
// directly, or `strings.clone("literal")` for a constant message.
@(private = "file")
set_status :: proc(e: ^Editor, msg: string) {
  delete(e.status_message)
  e.status_message = msg
}

@(private = "file")
find_line_start :: proc(buf: []u8, pos: int) -> int {
  i := pos
  for i > 0 && buf[i - 1] != '\n' do i -= 1
  return i
}

@(private = "file")
find_line_end :: proc(buf: []u8, pos: int) -> int {
  i := pos
  for i < len(buf) && buf[i] != '\n' do i += 1
  return i
}

editor_insert_byte :: proc(e: ^Editor, b: u8) {
  resize(&e.buf, len(e.buf) + 1)
  copy(e.buf[e.cursor + 1:], e.buf[e.cursor:len(e.buf) - 1])
  e.buf[e.cursor] = b
  e.cursor += 1
}

editor_backspace :: proc(e: ^Editor) {
  if e.cursor == 0 do return
  copy(e.buf[e.cursor - 1:], e.buf[e.cursor:])
  resize(&e.buf, len(e.buf) - 1)
  e.cursor -= 1
}

editor_delete_forward :: proc(e: ^Editor) {
  if e.cursor >= len(e.buf) do return
  copy(e.buf[e.cursor:], e.buf[e.cursor + 1:])
  resize(&e.buf, len(e.buf) - 1)
}

editor_move_left :: proc(e: ^Editor) { if e.cursor > 0 do e.cursor -= 1 }
editor_move_right :: proc(e: ^Editor) { if e.cursor < len(e.buf) do e.cursor += 1 }
editor_move_home :: proc(e: ^Editor) { e.cursor = find_line_start(e.buf[:], e.cursor) }
editor_move_end :: proc(e: ^Editor) { e.cursor = find_line_end(e.buf[:], e.cursor) }

editor_move_up :: proc(e: ^Editor) {
  line_start := find_line_start(e.buf[:], e.cursor)
  if line_start == 0 do return
  col := e.cursor - line_start
  prev_line_end := line_start - 1 // the '\n' just before this line
  prev_line_start := find_line_start(e.buf[:], prev_line_end)
  e.cursor = prev_line_start + min(col, prev_line_end - prev_line_start)
}

editor_move_down :: proc(e: ^Editor) {
  line_start := find_line_start(e.buf[:], e.cursor)
  col := e.cursor - line_start
  line_end := find_line_end(e.buf[:], e.cursor)
  if line_end >= len(e.buf) do return
  next_line_start := line_end + 1
  next_line_end := find_line_end(e.buf[:], next_line_start)
  e.cursor = next_line_start + min(col, next_line_end - next_line_start)
}

// (row, col), both 0-indexed, of a byte offset within the buffer - `col` in
// codepoints, not bytes, to match `clip_to_cols`/wrapping's column math.
@(private = "file")
row_col_of :: proc(buf: []u8, pos: int) -> (row: int, col: int) {
  for i in 0 ..< pos {
    if buf[i] == '\n' {
      row += 1
      col = 0
    } else if buf[i] & 0xC0 != 0x80 { // not a UTF-8 continuation byte
      col += 1
    }
  }
  return
}

@(private = "file")
read_byte :: proc() -> (b: u8, ok: bool) {
  buf: [1]u8
  n, err := os.read(os.stdin, buf[:])
  if err != nil || n == 0 do return 0, false
  return buf[0], true
}

// Reads decimal digits from stdin until a non-digit byte, which is returned
// alongside the parsed value (used for SGR mouse reports and `~`-terminated
// special-key sequences).
@(private = "file")
read_int_until_nondigit :: proc() -> (value: int, terminator: u8, ok: bool) {
  for {
    b, bok := read_byte()
    if !bok do return value, 0, false
    if b < '0' || b > '9' do return value, b, true
    value = value * 10 + int(b - '0')
  }
}

Key :: enum {
  None, Char, Enter, Backspace, Delete, Tab,
  Left, Right, Up, Down, Home, End,
  Page_Up, Page_Down, Scroll_Up, Scroll_Down,
  Ctrl_C, Ctrl_Q, Ctrl_D, Ctrl_S, Ctrl_O, Ctrl_E, Ctrl_N, Ctrl_R,
  Alt_1, Alt_2, Alt_3, Alt_4, Alt_5, Alt_Comma, Alt_Period,
}

@(private = "file")
read_key :: proc() -> (key: Key, ch: u8) {
  b, ok := read_byte()
  if !ok do return .Ctrl_Q, 0 // EOF/error on the input stream - nothing left to do but exit

  switch b {
  case 0x03: return .Ctrl_C, 0
  case 0x11: return .Ctrl_Q, 0
  case 0x04: return .Ctrl_D, 0
  case 0x13: return .Ctrl_S, 0
  case 0x0f: return .Ctrl_O, 0
  case 0x05: return .Ctrl_E, 0
  case 0x0e: return .Ctrl_N, 0 // debugger: step forward one "cut"
  case 0x12: return .Ctrl_R, 0 // debugger: restart
  case 0x09: return .Tab, 0
  case '\r', '\n':
    return .Enter, 0
  case 0x7f, 0x08:
    return .Backspace, 0
  case 0x1b: // `ESC [ <letter>`/`ESC [ <digit> ~`/SGR mouse `ESC [ < ...`, or `ESC <char>` (Alt+char,
             // the common "meta sends escape" convention most terminals use)
    b2, ok2 := read_byte()
    if !ok2 do return .None, 0
    if b2 != '[' {
      switch b2 {
      case '1': return .Alt_1, 0
      case '2': return .Alt_2, 0
      case '3': return .Alt_3, 0
      case '4': return .Alt_4, 0
      case '5': return .Alt_5, 0
      case ',': return .Alt_Comma, 0
      case '.': return .Alt_Period, 0
      }
      return .None, 0
    }
    b3, ok3 := read_byte()
    if !ok3 do return .None, 0
    switch b3 {
    case 'A': return .Up, 0
    case 'B': return .Down, 0
    case 'C': return .Right, 0
    case 'D': return .Left, 0
    case 'H': return .Home, 0
    case 'F': return .End, 0
    case '1':
      read_byte() // consume trailing '~'
      return .Home, 0
    case '3':
      read_byte() // consume trailing '~'
      return .Delete, 0
    case '4':
      read_byte() // consume trailing '~'
      return .End, 0
    case '5':
      read_byte() // consume trailing '~'
      return .Page_Up, 0
    case '6':
      read_byte() // consume trailing '~'
      return .Page_Down, 0
    case '<': // SGR mouse: `Cb ; Cx ; Cy (M|m)`
      cb, _, ok_cb := read_int_until_nondigit() // terminator is ';'
      if !ok_cb do return .None, 0
      _, _, ok_cx := read_int_until_nondigit() // Cx, terminator ';'
      if !ok_cx do return .None, 0
      _, _, ok_cy := read_int_until_nondigit() // Cy, terminator M/m
      if !ok_cy do return .None, 0
      if cb & 0x40 != 0 { // wheel event
        return .Scroll_Down if cb & 0x01 != 0 else .Scroll_Up, 0
      }
      return .None, 0
    }
    return .None, 0
  case:
    if b >= 0x20 && b < 0x7f do return .Char, b // printable ASCII; anything else is ignored
    return .None, 0
  }
}

// Live editor with up to three panes - source, AST, and evaluation result -
// re-parsed (and re-evaluated) on every keystroke. Each pane can be hidden,
// shown, and reordered (Alt+1/2/3 toggle Source/Ast/Result, Alt+,/Alt+. rotate
// the display order). Requires stdin to be an actual terminal (see `main.odin`,
// which falls back to the line-based REPL otherwise).
run_live_editor :: proc(cache_dir: string) {
  state, ok := term_enable_raw()
  if !ok {
    fmt.eprintln("error: could not put the terminal into raw mode")
    return
  }
  defer term_restore(state)

  editor: Editor
  editor_init(&editor)
  editor.cache_dir = cache_dir
  defer editor_destroy(&editor)

  // Alternate screen buffer, same as vim/htop/less use - leaving it restores
  // whatever was on screen before (the shell prompt), instead of leaving our
  // last frame sitting in the scrollback. Mouse reporting (SGR encoding) is
  // needed for wheel-scroll events; both are torn down together on exit.
  fmt.print("\x1b[?1049h\x1b[?1000h\x1b[?1006h")
  defer fmt.print("\x1b[?25h\x1b[?1006l\x1b[?1000l\x1b[?1049l")

  fmt.print("\x1b[?25l") // hide cursor while drawing; repositioned + shown each frame

  redraw(&editor)
  for {
    key, ch := read_key()

    if editor.example_menu.active {
      switch key {
      case .Ctrl_C: close_example_menu(&editor)
      case .Enter: load_selected_example(&editor)
      case .Up:
        if editor.example_menu.selected > 0 do editor.example_menu.selected -= 1
      case .Down:
        if editor.example_menu.selected < len(editor.example_menu.filtered) - 1 do editor.example_menu.selected += 1
      case .Backspace:
        if len(editor.example_menu.search) > 0 {
          resize(&editor.example_menu.search, len(editor.example_menu.search) - 1)
          refilter_example_menu(&editor)
        }
      case .Char:
        append(&editor.example_menu.search, ch)
        refilter_example_menu(&editor)
      case .Ctrl_Q, .Ctrl_D: return
      case .None, .Delete, .Left, .Right, .Home, .End, .Tab,
           .Page_Up, .Page_Down, .Scroll_Up, .Scroll_Down, .Ctrl_S, .Ctrl_O, .Ctrl_E, .Ctrl_N, .Ctrl_R,
           .Alt_1, .Alt_2, .Alt_3, .Alt_4, .Alt_5, .Alt_Comma, .Alt_Period:
        // not meaningful while picking an example - ignored
      }
      redraw(&editor)
      continue
    }

    if editor.prompt_mode != .None {
      switch key {
      case .Ctrl_C: editor.prompt_mode = .None
      case .Enter: run_prompt_action(&editor)
      case .Backspace:
        if len(editor.prompt_buf) > 0 do resize(&editor.prompt_buf, len(editor.prompt_buf) - 1)
        set_completion_hint(&editor, "")
      case .Char:
        append(&editor.prompt_buf, ch)
        set_completion_hint(&editor, "")
      case .Tab: complete_prompt_path(&editor)
      case .Ctrl_Q, .Ctrl_D: return
      case .None, .Delete, .Left, .Right, .Up, .Down, .Home, .End,
           .Page_Up, .Page_Down, .Scroll_Up, .Scroll_Down, .Ctrl_S, .Ctrl_O, .Ctrl_E, .Ctrl_N, .Ctrl_R,
           .Alt_1, .Alt_2, .Alt_3, .Alt_4, .Alt_5, .Alt_Comma, .Alt_Period:
        // not meaningful while naming a file - ignored
      }
      redraw(&editor)
      continue
    }

    switch key {
    case .Ctrl_Q, .Ctrl_D, .Ctrl_C: return
    case .Ctrl_S: start_prompt(&editor, .Save)
    case .Ctrl_O: start_prompt(&editor, .Load)
    case .Ctrl_E: open_example_menu(&editor)
    case .Char: editor_insert_byte(&editor, ch)
    case .Enter: editor_insert_byte(&editor, '\n')
    case .Tab: editor_insert_byte(&editor, '\t')
    case .Backspace: editor_backspace(&editor)
    case .Delete: editor_delete_forward(&editor)
    case .Left: editor_move_left(&editor)
    case .Right: editor_move_right(&editor)
    case .Up: editor_move_up(&editor)
    case .Down: editor_move_down(&editor)
    case .Home: editor_move_home(&editor)
    case .End: editor_move_end(&editor)
    case .Page_Up: editor.ast_scroll = max(editor.ast_scroll - 10, 0)
    case .Page_Down: editor.ast_scroll += 10 // clamped against actual content in redraw
    case .Scroll_Up: editor.ast_scroll = max(editor.ast_scroll - 3, 0)
    case .Scroll_Down: editor.ast_scroll += 3 // clamped against actual content in redraw
    case .Alt_1: toggle_panel(&editor, .Source)
    case .Alt_2: toggle_panel(&editor, .Ast)
    case .Alt_3: toggle_panel(&editor, .Result)
    case .Alt_4: toggle_panel(&editor, .Steps)
    case .Alt_5: toggle_panel(&editor, .Debugger)
    case .Alt_Comma: rotate_panels_left(&editor)
    case .Alt_Period: rotate_panels_right(&editor)
    case .Ctrl_N: debugger_step(editor.debugger)
    case .Ctrl_R: restart_debugger(&editor, string(editor.buf[:]))
    case .None:
    }
    redraw(&editor)
  }
}

// Lists `examples/*.hb` fresh every time the menu opens (cheap, and picks up
// files added/removed since the editor started).
@(private = "file")
open_example_menu :: proc(e: ^Editor) {
  m := &e.example_menu
  for it in m.items do delete(it)
  resize(&m.items, 0)
  resize(&m.search, 0)

  entries, err := os.read_all_directory_by_path("examples", context.allocator)
  if err == nil {
    defer os.file_info_slice_delete(entries, context.allocator)
    for entry in entries {
      if entry.type == .Directory do continue
      if strings.has_suffix(entry.name, ".hb") do append(&m.items, strings.clone(entry.name))
    }
  }
  slice.sort(m.items[:])
  m.selected = 0
  m.active = true
  refilter_example_menu(e)
}

@(private = "file")
close_example_menu :: proc(e: ^Editor) {
  e.example_menu.active = false
}

// Case-insensitive substring search - recomputed on every keystroke, cheap
// enough at the scale of an examples directory.
@(private = "file")
refilter_example_menu :: proc(e: ^Editor) {
  m := &e.example_menu
  resize(&m.filtered, 0)
  needle := strings.to_lower(string(m.search[:]), context.temp_allocator)
  for item, i in m.items {
    hay := strings.to_lower(item, context.temp_allocator)
    if strings.contains(hay, needle) do append(&m.filtered, i)
  }
  m.selected = clamp(m.selected, 0, max(len(m.filtered) - 1, 0))
}

@(private = "file")
load_selected_example :: proc(e: ^Editor) {
  m := &e.example_menu
  if len(m.filtered) == 0 do return
  name := m.items[m.filtered[m.selected]]
  path := strings.concatenate({"examples/", name})

  data, err := os.read_entire_file(path, context.allocator)
  if err != nil {
    set_status(e, fmt.aprintf("error: could not read %s", path))
    delete(path)
    close_example_menu(e)
    return
  }
  resize(&e.buf, len(data))
  copy(e.buf[:], data)
  delete(data)
  e.cursor = 0
  e.source_scroll = 0
  delete(e.current_path)
  e.current_path = path
  set_status(e, fmt.aprintf("loaded %s", path))
  close_example_menu(e)
}

@(private = "file")
start_prompt :: proc(e: ^Editor, mode: Prompt_Mode) {
  e.prompt_mode = mode
  set_prompt_buf(e, e.current_path)
  set_completion_hint(e, "")
}

// Splits a partial path into the directory to list, the name fragment being
// completed, and the prefix to re-attach to whatever that fragment completes
// to. "examples/gu" -> ("examples/", "gu", "examples/"); "gu" -> (".", "gu", "").
@(private = "file")
split_for_completion :: proc(prefix: string) -> (dir_for_listing: string, name_part: string, result_prefix: string) {
  idx := strings.last_index(prefix, "/")
  if idx < 0 do return ".", prefix, ""
  return prefix[:idx + 1], prefix[idx + 1:], prefix[:idx + 1]
}

@(private = "file")
common_prefix_of :: proc(a: string, b: string) -> string {
  n := min(len(a), len(b))
  i := 0
  for i < n && a[i] == b[i] do i += 1
  return a[:i]
}

@(private = "file")
set_prompt_buf :: proc(e: ^Editor, s: string) {
  resize(&e.prompt_buf, 0)
  for b in transmute([]u8)s do append(&e.prompt_buf, b)
}

// Classic shell-style completion: one match completes it fully (adding a
// trailing '/' for directories); several complete to their common prefix and
// list the candidates on the hint line; none does nothing.
@(private = "file")
complete_prompt_path :: proc(e: ^Editor) {
  prefix := string(e.prompt_buf[:])
  dir_for_listing, name_part, result_prefix := split_for_completion(prefix)

  entries, err := os.read_all_directory_by_path(dir_for_listing, context.allocator)
  if err != nil {
    set_completion_hint(e, fmt.aprintf("cannot list '%s'", dir_for_listing))
    return
  }
  defer os.file_info_slice_delete(entries, context.allocator)

  matches := make([dynamic]int, 0, 8, context.temp_allocator) // indices into `entries`
  for entry, i in entries {
    if entry.name == "." || entry.name == ".." do continue
    if strings.has_prefix(entry.name, name_part) do append(&matches, i)
  }

  if len(matches) == 0 {
    set_completion_hint(e, strings.clone("no matches"))
    return
  }

  if len(matches) == 1 {
    entry := entries[matches[0]]
    suffix := "/" if entry.type == .Directory else ""
    set_prompt_buf(e, strings.concatenate({result_prefix, entry.name, suffix}))
    set_completion_hint(e, "")
    return
  }

  common := entries[matches[0]].name
  for idx in matches[1:] do common = common_prefix_of(common, entries[idx].name)
  if len(common) > len(name_part) {
    set_prompt_buf(e, strings.concatenate({result_prefix, common}))
  }

  names := make([dynamic]string, 0, len(matches), context.temp_allocator)
  for idx in matches[:min(len(matches), 8)] do append(&names, entries[idx].name)
  joined := strings.join(names[:], "  ")
  if len(matches) > 8 {
    set_completion_hint(e, fmt.aprintf("%s  ... (+%d more)", joined, len(matches) - 8))
  } else {
    set_completion_hint(e, strings.clone(joined))
  }
}

@(private = "file")
run_prompt_action :: proc(e: ^Editor) {
  path := strings.clone(string(e.prompt_buf[:]))
  mode := e.prompt_mode
  e.prompt_mode = .None
  if len(path) == 0 {
    delete(path)
    set_status(e, strings.clone("cancelled - no filename given"))
    return
  }

  switch mode {
  case .Save:
    if err := os.write_entire_file(path, e.buf[:]); err == nil {
      delete(e.current_path)
      e.current_path = path
      set_status(e, fmt.aprintf("saved to %s", path))
    } else {
      set_status(e, fmt.aprintf("error: could not write %s", path))
      delete(path)
    }
  case .Load:
    data, err := os.read_entire_file(path, context.allocator)
    if err != nil {
      set_status(e, fmt.aprintf("error: could not read %s", path))
      delete(path)
      return
    }
    resize(&e.buf, len(data))
    copy(e.buf[:], data)
    delete(data)
    e.cursor = 0
    e.source_scroll = 0
    delete(e.current_path)
    e.current_path = path
    set_status(e, fmt.aprintf("loaded %s", path))
  case .None:
  }
}

// Unsandboxed loadfile/createfile calls (no .dir given) resolve relative
// paths against the edited buffer's own saved/loaded path, if it has one -

// Evaluates the current buffer and renders its result as display lines -
// same ownership contract as `ast_lines`: caller frees every line plus the
// returned slice. Not independently scrollable (results are usually short);
// it just shows from the top, clipped to the pane's height like anything else.
@(private = "file")
compute_result_lines :: proc(ast: ^ast_t, src: string, current_path: string, cache_dir: string) -> [dynamic]string {
  lines := make([dynamic]string, 0, 1)
  if len(ast.errors) > 0 {
    append(&lines, strings.clone("(fix parse errors first)"))
    return lines
  }
  interp := Interpreter{ast = ast, src = src, current_ctx = make_root_context(cache_dir)}
  setup_interp_base_dir(&interp, current_path)
  env := make_global_env()
  val, ok := eval(&interp, ast.root, env)
  if ok do val, ok = await_value(&interp, val) // resolve a bare top-level `async <expr>` (§2)
  if !ok {
    append(&lines, fmt.aprintf("error: %s", interp.error_message))
    return lines
  }
  append(&lines, format_value(val))
  return lines
}

// Re-evaluates the buffer with tracing on and renders one line per recorded
// step - "<indent>source of the sub-expression -> its value", innermost/
// earliest-completing sub-expressions first, building up to the final result
// last (same completion order the evaluator actually works in). Same
// ownership contract as `ast_lines`/`compute_result_lines`.
@(private = "file")
compute_trace_lines :: proc(ast: ^ast_t, src: string, current_path: string, cache_dir: string) -> [dynamic]string {
  lines := make([dynamic]string, 0, 8)
  if len(ast.errors) > 0 {
    append(&lines, strings.clone("(fix parse errors first)"))
    return lines
  }

  interp := Interpreter{ast = ast, src = src, enable_trace = true, current_ctx = make_root_context(cache_dir)}
  setup_interp_base_dir(&interp, current_path)
  env := make_global_env()
  eval(&interp, ast.root, env) // only the trace matters here, not the final value
  defer {
    for step in interp.trace do delete(step.error_message)
    delete(interp.trace)
  }

  if len(interp.trace) == 0 {
    append(&lines, strings.clone("(no steps)"))
    return lines
  }

  for step in interp.trace {
    indent, _ := strings.repeat("  ", step.depth)
    defer delete(indent)
    text := node_text(&interp, step.node)
    label := text if text != "" else fmt.tprintf("%v", ast.nodes[step.node].kind)
    if step.ok {
      // Show the resolved value, not a raw pending handle, for an `async`
      // step - by the time the whole trace is done, everything the program
      // actually consumed has already been awaited anyway, so this is a
      // cheap read, not a new wait (see eval_async.odin).
      shown_value, shown_ok := await_value(&interp, step.value)
      formatted := format_value(shown_value) if shown_ok else fmt.tprintf("error: %s", interp.error_message)
      defer delete(formatted)
      append(&lines, fmt.aprintf("%s%s -> %s", indent, label, formatted))
    } else {
      append(&lines, fmt.aprintf("%s%s -> error: %s", indent, label, step.error_message))
    }
  }
  return lines
}

// Tears down whatever debugger run is currently active (if any) and starts a
// fresh, paused one over `src` - called on Ctrl+R, and automatically from
// redraw_panels whenever the buffer has changed since the running one
// started. The new run does no work until debugger_step (Ctrl+N) is called.
@(private = "file")
restart_debugger :: proc(e: ^Editor, src: string) {
  stop_debugger_run(e.debugger)
  e.debugger = nil
  delete(e.debug_last_src)
  e.debug_last_src = strings.clone(src)
  e.debugger = start_debugger_run(strings.clone(src), e.current_path, e.cache_dir)
}

@(private = "file")
debug_node_label :: proc(interp: ^Interpreter, n: Node_Idx) -> string {
  text := node_text(interp, n)
  return text if text != "" else fmt.tprintf("%v", interp.ast.nodes[n].kind)
}

// The interactive debugger: renders the AST as a tree, where every node some
// task in the live run (see debugger.odin) has actually already stepped past
// shows only its resulting value in place of its whole subtree - the tree
// visibly shrinks from the leaves inward as Ctrl+N genuinely advances every
// currently-paused task by one step (in lockstep - a task per `async`, §2,
// plus the main one), until the root itself is reached and it collapses to
// the program's final value. Unlike a pre-computed trace, a node not yet
// shown here truly hasn't been evaluated. Returns the rendered lines plus how
// many steps have been taken so far, plus whether the main task has finished
// (an async task can only outlive it in the brief window stop_debugger_run's
// drain loop exists for - see debugger.odin - never visibly here).
@(private = "file")
compute_debug_lines :: proc(dbg: ^Debugger_Run) -> (lines: [dynamic]string, steps_taken: int, finished: bool) {
  lines = make([dynamic]string, 0, 16)
  if dbg == nil {
    append(&lines, strings.clone("(fix parse errors first)"))
    return lines, 0, false
  }

  sync.mutex_lock(&dbg.mu)
  defer sync.mutex_unlock(&dbg.mu)

  // A cut can land anywhere in a tree bigger than the pane, and an older cut
  // looks identical to a fresh one at a glance - so pin a summary of the most
  // recent step(s) at the top of the pane (always visible, no hunting
  // through possibly off-screen tree rows). With async, a single ^N can
  // complete more than one task's step at once (everything paused at the
  // time) - all of them share the same, highest `generation` and are all
  // listed and marked, not just whichever happened to be appended last.
  max_gen := 0
  for step in dbg.log do max_gen = max(max_gen, step.generation)
  if max_gen == 0 {
    append(&lines, strings.clone("(no steps yet - press ^N)"))
  } else {
    for step in dbg.log {
      if step.generation != max_gen do continue
      label := debug_node_label(&dbg.interp, step.node)
      tag := " [discarded]" if step.discarded else ""
      if step.ok {
        formatted := format_value(step.value)
        defer delete(formatted)
        append(&lines, fmt.aprintf("just cut: %s -> %s%s", label, formatted, tag))
      } else {
        append(&lines, fmt.aprintf("just cut: %s -> error: %s%s", label, step.error_message, tag))
      }
    }
  }

  // Likewise pin *what's coming next* - every node some task's `eval` call is
  // literally blocked on right now, waiting for the next ^N - so you know
  // where to expect the next round of cuts before it happens. "awaiting" (an
  // `async`'s handle someone is specifically blocked joining, inside
  // await_value - see eval_async.odin) is called out separately, since it
  // explains *why* the consuming node is taking a moment rather than just
  // that it's pending. Both are also marked inline (below) if on screen.
  if dbg.finished && len(dbg.pending) == 0 {
    append(&lines, strings.clone("(finished - nothing left to step)"))
  } else {
    shown := 0
    for node in dbg.pending {
      if shown >= 6 {
        append(&lines, fmt.aprintf("... (+%d more pending)", len(dbg.pending) - shown))
        break
      }
      append(&lines, fmt.aprintf("next up:  %s", debug_node_label(&dbg.interp, node)))
      shown += 1
    }
  }
  shown_awaiting := 0
  for node in dbg.awaiting {
    if shown_awaiting >= 6 {
      append(&lines, fmt.aprintf("... (+%d more awaiting)", len(dbg.awaiting) - shown_awaiting))
      break
    }
    append(&lines, fmt.aprintf("awaiting: %s", debug_node_label(&dbg.interp, node)))
    shown_awaiting += 1
  }
  append(&lines, strings.clone(""))

  // A node evaluated more than once (e.g. a function body called from
  // multiple call sites, or by more than one concurrent async task) only
  // ever shows its *last* recorded value once stepped past - a known
  // simplification, since the static AST has one shared copy of it.
  cut_at := make(map[Node_Idx]int, 0, context.temp_allocator)
  for step, i in dbg.log do cut_at[step.node] = i

  show_pending := !dbg.finished || len(dbg.pending) > 0
  collect_debug_lines(&dbg.interp, dbg.ast.root, 0, dbg.log[:], cut_at, max_gen, dbg.pending, dbg.awaiting, show_pending, &lines)
  return lines, len(dbg.log), dbg.finished
}

@(private = "file")
collect_debug_lines :: proc(interp: ^Interpreter, n: Node_Idx, depth: int, log: []Debug_Step, cut_at: map[Node_Idx]int, max_gen: int, pending: map[Node_Idx]int, awaiting: map[Node_Idx]int, show_pending: bool, out: ^[dynamic]string) {
  ast := interp.ast
  node := ast.nodes[n]
  indent, _ := strings.repeat("  ", depth)
  defer delete(indent)

  // An Async_Expr's own eval() call completes the instant it fires the
  // background task (spawn_async returns a handle immediately - see
  // eval_async.odin) - so it lands in cut_at almost right away, long before
  // the task it started is actually done. Collapsing it like an ordinary cut
  // would hide the one subtree that's still genuinely, concurrently
  // executing - exactly the part worth watching. So it's never collapsed:
  // always recurse into its body, and keep marking *it* pending (▶) for as
  // long as that body isn't fully cut yet, on top of whatever pending/
  // awaiting state its body's own nodes show individually below it.
  is_async_wrapper := node.kind == .Async_Expr
  _, was_spawned := cut_at[n]
  body_done := false
  if is_async_wrapper && node.children_count > 0 {
    body_idx := ast.extra_children[node.children_start]
    _, body_done = cut_at[body_idx]
  }

  if pos, was_stepped := cut_at[n]; was_stepped && !is_async_wrapper {
    step := log[pos]
    fresh := step.generation == max_gen
    symbol := "∅" if step.discarded else "✂"
    marker := fmt.tprintf("%s%s", "→" if fresh else " ", symbol)
    tag := " [discarded]" if step.discarded else ""

    // The root's own per-node log entry can be a raw, un-awaited async
    // handle (eval() returns it as-is there, matching "pass 1: start it,
    // don't wait") even though the run has since resolved it for real (see
    // debugger_thread_proc's own final await) - once the whole run is done,
    // show that resolved result instead of a value that would otherwise
    // visibly dangle on "<async: pending>" forever.
    show_ok, show_val := step.ok, step.value
    if n == ast.root && interp.debugger != nil && interp.debugger.finished && interp.debugger.final_ok {
      show_ok, show_val = true, interp.debugger.final_value
    }

    if show_ok {
      formatted := format_value(show_val)
      defer delete(formatted)
      append(out, fmt.aprintf("%s%s %s%s", indent, marker, formatted, tag))
    } else {
      append(out, fmt.aprintf("%s%s error: %s%s", indent, marker, step.error_message, tag))
    }
    return // not expanded any further - genuinely not evaluated past this point yet
  }

  is_pending := (show_pending && n in pending) || (was_spawned && !body_done)
  is_awaiting := n in awaiting
  prefix := strings.concatenate({"⏳" if is_awaiting else "", "▶ " if is_pending else ""}, context.temp_allocator)
  text := node_text(interp, n)
  if node.children_count == 0 && text != "" {
    append(out, fmt.aprintf("%s%s%v %q", indent, prefix, node.kind, text))
  } else {
    append(out, fmt.aprintf("%s%s%v", indent, prefix, node.kind))
  }

  start := int(node.children_start)
  for i in 0 ..< int(node.children_count) {
    collect_debug_lines(interp, ast.extra_children[start + i], depth + 1, log, cut_at, max_gen, pending, awaiting, show_pending, out)
  }
}

@(private = "file")
redraw :: proc(e: ^Editor) {
  if e.example_menu.active {
    redraw_example_menu(e)
    return
  }
  redraw_panels(e)
}

// The examples search-and-select popup: replaces the whole frame (not an
// overlay on top of the panels) while active.
@(private = "file")
redraw_example_menu :: proc(e: ^Editor) {
  rows, cols := term_size()
  m := &e.example_menu

  b: strings.Builder
  strings.builder_init(&b)
  defer strings.builder_destroy(&b)

  strings.write_string(&b, "\x1b[H\x1b[2J")
  title := "HashedBuild live parser - select an example"
  strings.write_string(&b, clip_to_cols(title, max(cols - 1, 0)))
  strings.write_string(&b, "\r\n")
  fmt.sbprintf(&b, "Search: %s\r\n", string(m.search[:]))
  strings.write_string(&b, "\r\n")

  // title, search, blank, plus one spare row so the last line printed never
  // lands on the terminal's actual last row (see redraw_panels for why).
  list_rows := max(rows - 4, 1)
  if len(m.filtered) == 0 {
    strings.write_string(&b, "(no matching examples)\r\n")
  } else {
    top := 0
    if m.selected >= list_rows do top = m.selected - list_rows + 1
    for i in 0 ..< list_rows {
      idx := top + i
      if idx >= len(m.filtered) do break
      name := m.items[m.filtered[idx]]
      clipped := clip_to_cols(name, max(cols - 3, 0))
      if idx == m.selected {
        fmt.sbprintf(&b, "\x1b[7m> %s\x1b[0m\r\n", clipped)
      } else {
        fmt.sbprintf(&b, "  %s\r\n", clipped)
      }
    }
  }

  strings.write_string(&b, "\r\n")
  fmt.sbprintf(&b, "%d/%d match(es) | Up/Down move, Enter load, Ctrl+C cancel\r\n", len(m.filtered), len(m.items))

  os.write_string(os.stdout, strings.to_string(b))
  screen_row := 2
  screen_col := len("Search: ") + len(m.search) + 1
  fmt.printf("\x1b[%d;%dH\x1b[?25h", screen_row, screen_col)
}

@(private = "file")
redraw_panels :: proc(e: ^Editor) {
  rows, cols := term_size()
  src := string(e.buf[:])

  source := source_t{name = "<live>", n_bytes = u64(len(src)), data = raw_data(src)}
  ast := parse(source, ast_t{})
  defer ast_destroy(&ast)

  ast_content := ast_lines(&ast, src)
  defer {
    for line in ast_content do delete(line)
    delete(ast_content)
  }

  source_content := strings.split(src, "\n")
  defer delete(source_content)

  // Only evaluated when actually shown - same reasoning as Steps below, but
  // doubly so here: this evaluation is a real, synchronous run of whatever
  // the buffer says, side effects included (a createfile, say), not just a
  // wasted computation. Running it while hidden wouldn't just be wasted work,
  // it'd cause an unseen exclusive createfile to race a *visible* debugger
  // run's own attempt at the same path.
  result_content: [dynamic]string
  if e.panel_visible[.Result] {
    result_content = compute_result_lines(&ast, src, e.current_path, e.cache_dir)
  }
  defer {
    for line in result_content do delete(line)
    delete(result_content)
  }

  header_rows := 2 // title + column headers
  // Footer always reserves: blank, message/prompt line, hint line, plus one
  // further spare row so the very last `\r\n` this function writes never lands
  // on the terminal's actual last row (which would scroll the whole screen and
  // invalidate every absolute row number used below, including the final
  // cursor-placement escape).
  footer_rows := 4
  body_rows := max(rows - header_rows - footer_rows - 1, 1)

  // Which panels actually show up this frame, in display order. Never zero -
  // toggle_panel refuses to hide the last visible one.
  visible := make([dynamic]Panel_Kind, 0, len(Panel_Kind), context.temp_allocator)
  for pk in e.panel_order do if e.panel_visible[pk] do append(&visible, pk)
  if len(visible) == 0 do append(&visible, Panel_Kind.Source)

  // Steps re-evaluates the whole buffer a second time (with tracing on) - only
  // pay for that when the panel is actually shown.
  steps_content: [dynamic]string
  if e.panel_visible[.Steps] {
    steps_content = compute_trace_lines(&ast, src, e.current_path, e.cache_dir)
  }
  defer {
    for line in steps_content do delete(line)
    delete(steps_content)
  }

  // The debugger is a live, paused-in-place background evaluation, not
  // recomputed every redraw - only (re)started when the panel is first shown,
  // or the source has actually changed since the running one started (a
  // step count from before the edit wouldn't mean anything in a possibly
  // quite different new tree).
  debug_content: [dynamic]string
  debug_steps_taken: int
  debug_finished: bool
  if e.panel_visible[.Debugger] {
    if e.debugger == nil || src != e.debug_last_src {
      restart_debugger(e, src)
    }
    debug_content, debug_steps_taken, debug_finished = compute_debug_lines(e.debugger)
  }
  defer {
    for line in debug_content do delete(line)
    delete(debug_content)
  }

  n := len(visible)
  // Every row this function prints is kept to at most `cols - 1` characters,
  // never exactly `cols` - right at the edge, some terminals leave the cursor
  // in a "pending wrap" state that can desync row accounting by one.
  sep_width := 3 // " | " between adjacent columns
  col_width := max((cols - 1 - (n - 1) * sep_width) / n, 8)

  // Wrap every panel's logical lines to the shared column width so long
  // lines (long comments, deep AST nesting, big table results) are readable
  // in full across multiple rows instead of losing their tail to clipping.
  source_wrapped, source_line_starts := wrap_lines(source_content[:], col_width, context.temp_allocator)
  ast_wrapped, _ := wrap_lines(ast_content[:], col_width, context.temp_allocator)
  result_wrapped, _ := wrap_lines(result_content[:], col_width, context.temp_allocator)
  steps_wrapped, _ := wrap_lines(steps_content[:], col_width, context.temp_allocator)
  debug_wrapped, _ := wrap_lines(debug_content[:], col_width, context.temp_allocator)

  cursor_row, cursor_col := row_col_of(e.buf[:], e.cursor)
  cursor_display_row, cursor_display_col := wrapped_cursor_pos(
    source_line_starts[:], len(source_wrapped), cursor_row, cursor_col, col_width)

  // Source pane follows the cursor (like an ordinary editor, in wrapped-
  // display-row terms); the AST pane's scroll position is independent, moved
  // only by PageUp/PageDown/wheel.
  if cursor_display_row < e.source_scroll {
    e.source_scroll = cursor_display_row
  } else if cursor_display_row >= e.source_scroll + body_rows {
    e.source_scroll = cursor_display_row - body_rows + 1
  }
  ast_max_scroll := max(len(ast_wrapped) - 1, 0)
  e.ast_scroll = clamp(e.ast_scroll, 0, ast_max_scroll)

  panel_line :: proc(pk: Panel_Kind, i: int, e: ^Editor, source_wrapped, ast_wrapped, result_wrapped, steps_wrapped, debug_wrapped: []string) -> string {
    #partial switch pk {
    case .Source:
      idx := e.source_scroll + i
      return source_wrapped[idx] if idx < len(source_wrapped) else ""
    case .Ast:
      idx := e.ast_scroll + i
      return ast_wrapped[idx] if idx < len(ast_wrapped) else ""
    case .Result:
      return result_wrapped[i] if i < len(result_wrapped) else ""
    case .Steps:
      return steps_wrapped[i] if i < len(steps_wrapped) else ""
    case .Debugger:
      return debug_wrapped[i] if i < len(debug_wrapped) else ""
    }
    return ""
  }

  b: strings.Builder
  strings.builder_init(&b)
  defer strings.builder_destroy(&b)

  strings.write_string(&b, "\x1b[H\x1b[2J") // cursor home, clear screen
  title := "HashedBuild live parser"
  strings.write_string(&b, clip_to_cols(title, max(cols - 1, 0)))
  strings.write_string(&b, "\r\n")

  headers := make([dynamic]string, 0, n, context.temp_allocator)
  for pk in visible do append(&headers, panel_title(pk))
  write_columns(&b, headers[:], col_width)

  for i in 0 ..< body_rows {
    row := make([dynamic]string, 0, n, context.temp_allocator)
    for pk in visible do append(&row, panel_line(pk, i, e, source_wrapped[:], ast_wrapped[:], result_wrapped[:], steps_wrapped[:], debug_wrapped[:]))
    write_columns(&b, row[:], col_width)
  }

  strings.write_string(&b, "\r\n")
  switch {
  case e.prompt_mode == .Save:
    fmt.sbprintf(&b, "Save as: %s", string(e.prompt_buf[:]))
  case e.prompt_mode == .Load:
    fmt.sbprintf(&b, "Load from: %s", string(e.prompt_buf[:]))
  case e.status_message != "":
    strings.write_string(&b, e.status_message)
  case len(ast.errors) > 0:
    fmt.sbprintf(&b, "%d error(s): %s", len(ast.errors), ast.errors[0].message)
  case:
    strings.write_string(&b, "no errors")
  }
  strings.write_string(&b, "\r\n")

  if e.prompt_mode != .None && e.completion_hint != "" {
    hint_clipped := clip_to_cols(e.completion_hint, max(cols - 1, 0))
    fmt.sbprintf(&b, "%s\r\n", hint_clipped)
  } else {
    path_label := e.current_path if e.current_path != "" else "(unsaved)"
    debug_suffix := " (done)" if debug_finished else ""
    fmt.sbprintf(&b, "%s | ^S save ^O open ^E examples ^Q quit | ast %d/%d, debug %d steps%s (^N step ^R restart) | Alt+1-5 panel, Alt+,/. reorder\r\n",
      path_label, e.ast_scroll + 1, max(len(ast_wrapped), 1), debug_steps_taken, debug_suffix)
  }

  os.write_string(os.stdout, strings.to_string(b))

  // Place the real terminal cursor over the source pane's edit position (or
  // the end of the prompt line, while a prompt is active). If the source
  // panel is hidden there's nowhere sensible to put it, so it stays hidden.
  source_col_idx := -1
  for pk, i in visible do if pk == .Source do source_col_idx = i
  screen_row, screen_col: int
  show_cursor := true
  if e.prompt_mode != .None {
    prefix_len := len("Save as: ") if e.prompt_mode == .Save else len("Load from: ")
    // +1 for the blank line the footer writes between the body and this message.
    screen_row = header_rows + body_rows + 2
    screen_col = prefix_len + len(e.prompt_buf) + 1
  } else if source_col_idx >= 0 {
    screen_row = header_rows + (cursor_display_row - e.source_scroll) + 1
    screen_col = source_col_idx * (col_width + sep_width) + cursor_display_col + 1
  } else {
    show_cursor = false
  }
  if show_cursor {
    fmt.printf("\x1b[%d;%dH\x1b[?25h", screen_row, screen_col)
  } else {
    fmt.print("\x1b[?25l")
  }
}

@(private = "file")
write_columns :: proc(b: ^strings.Builder, cells: []string, col_width: int) {
  for cell, i in cells {
    if i > 0 do strings.write_string(b, " | ")
    clipped := clip_to_cols(cell, col_width)
    strings.write_string(b, clipped)
    for _ in 0 ..< col_width - col_count(clipped) do strings.write_byte(b, ' ')
  }
  strings.write_string(b, "\r\n")
}
