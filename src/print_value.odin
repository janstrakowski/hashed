package hashedbuild

import "core:fmt"
import "core:strings"

// A human-readable rendering of a runtime Value, for the REPL. Not meant to
// be exact, re-parseable source (e.g. an empty sequence and `empty` collapse
// to the same "{}") - just legible output for interactive use.
format_value :: proc(val: Value) -> string {
  b: strings.Builder
  strings.builder_init(&b)
  write_value(&b, val)
  return strings.to_string(b)
}

@(private = "file")
write_value :: proc(b: ^strings.Builder, val: Value) {
  #partial switch v in val {
  case Nothing_Value:
    fmt.sbprint(b, "nothing")
  case i64:
    fmt.sbprintf(b, "%d", v)
  case f64:
    fmt.sbprintf(b, "%v", v)
  case string:
    fmt.sbprintf(b, "%q", v)
  case bool:
    fmt.sbprint(b, v)
  case []u8:
    fmt.sbprintf(b, "<%d bytes>", len(v))
  case ^Table_Value:
    write_table(b, v)
  case ^Function_Value:
    fmt.sbprint(b, "<function>")
  case ^File_Value:
    switch {
    case v.cache_display_path != "":
      fmt.sbprintf(b, "<file: %s>", v.cache_display_path)
    case v.kind == .Directory:
      fmt.sbprint(b, "<directory>")
    case:
      fmt.sbprintf(b, "<file: %d bytes>", len(v.content))
    }
  case ^Cache_Value:
    fmt.sbprint(b, "<cache>")
  case ^Async_Handle:
    // Every real call site awaits the top-level result before formatting it
    // (see eval_async.odin/await_value) - reaching here un-awaited would
    // only happen for a bare `async <expr>` returned with nothing further
    // ever consuming it, so show its state rather than silently misprinting.
    switch {
    case !v.awaited: fmt.sbprint(b, "<async: pending>")
    case v.result_ok: fmt.sbprintf(b, "<async: %s>", format_value(v.result_value))
    case: fmt.sbprintf(b, "<async: error: %s>", v.error_message)
    }
  case:
    fmt.sbprint(b, "<nil>")
  }
}

@(private = "file")
write_table :: proc(b: ^strings.Builder, t: ^Table_Value) {
  strings.write_byte(b, '{')
  seq := is_sequence_shaped(t)
  for entry, i in t.entries {
    if i > 0 do strings.write_string(b, ", ")
    if !seq {
      write_key(b, entry.key)
      strings.write_string(b, ": ")
    }
    write_value(b, entry.value)
  }
  strings.write_byte(b, '}')
}

// A 1-indexed, gap-free run of Integer keys - the "sequence" idiom (§5) -
// prints bare, like a literal; anything else prints its keys explicitly.
@(private = "file")
is_sequence_shaped :: proc(t: ^Table_Value) -> bool {
  for entry, i in t.entries {
    key, is_int := entry.key.(i64)
    if !is_int || key != i64(i + 1) do return false
  }
  return true
}

@(private = "file")
write_key :: proc(b: ^strings.Builder, key: Value) {
  if s, is_str := key.(string); is_str {
    strings.write_string(b, s)
    return
  }
  write_value(b, key)
}
