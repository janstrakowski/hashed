package hashedbuild

import "core:strings"

// Byte offsets to (line, column) and back. The AST carries spans as byte
// offsets into the source (ast.odin's Span), which is what a parser wants and
// exactly what a debugger cannot use: the Debug Adapter Protocol addresses
// everything by line, since that is what a person points at in an editor.
//
// Built once per source and shared, because the alternative - counting
// newlines from the start of the file on every lookup - is O(file) per node,
// and a stack trace or a breakpoint check does many lookups per stop.
//
// Lines and columns are **1-based**, which is DAP's default (a client can ask
// for 0-based at `initialize` time; dap.odin translates there rather than
// here, so this file has exactly one convention).

Line_Index :: struct {
  // Byte offset of the first character of each line. starts[0] is always 0,
  // so line N occupies [starts[N-1], starts[N]).
  starts: []u32,
}

line_index_make :: proc(src: string, allocator := context.allocator) -> Line_Index {
  starts := make([dynamic]u32, 0, 64, allocator)
  append(&starts, 0)
  for i in 0 ..< len(src) {
    if src[i] == '\n' do append(&starts, u32(i + 1))
  }
  return Line_Index{starts = starts[:]}
}

line_index_destroy :: proc(idx: Line_Index) {
  delete(idx.starts)
}

// The 1-based line holding `offset`. An offset past the end answers with the
// last line rather than failing: a span can legitimately end at EOF, and a
// caller asking where that is wants an answer it can show.
line_of_offset :: proc(idx: Line_Index, offset: u32) -> int {
  if len(idx.starts) == 0 do return 1
  // The last line whose start is <= offset, by binary search.
  lo, hi := 0, len(idx.starts) - 1
  for lo < hi {
    mid := (lo + hi + 1) / 2
    if idx.starts[mid] <= offset {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  return lo + 1
}

// The 1-based column of `offset` within its line, counted in **UTF-16 code
// units**, which is what DAP means by a column unless a client says otherwise
// (`columnsStartAt1`/a custom encoding). Counting bytes would put the caret in
// the wrong place on any line with a non-ASCII character before it.
column_of_offset :: proc(src: string, idx: Line_Index, offset: u32) -> int {
  line := line_of_offset(idx, offset)
  start := idx.starts[line - 1]
  if offset <= start do return 1
  end := min(int(offset), len(src))
  col := 1
  for r in string(src[start:end]) {
    // Anything outside the BMP is a surrogate pair, so two units.
    col += 1 if r <= 0xFFFF else 2
  }
  return col
}

// The source text of one 1-based line, without its newline - what a stop
// event shows next to a location, and what makes a `stopped` readable in a
// client that has not opened the file itself.
line_text :: proc(src: string, idx: Line_Index, line: int) -> string {
  if line < 1 || line > len(idx.starts) do return ""
  start := int(idx.starts[line - 1])
  end := len(src)
  if line < len(idx.starts) do end = int(idx.starts[line])
  return strings.trim_right(src[start:end], "\r\n")
}

line_count :: proc(idx: Line_Index) -> int {
  return len(idx.starts)
}
