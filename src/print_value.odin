package hashed

import "core:fmt"
import "core:strings"

// A human-readable rendering of a runtime Value, for the REPL. Not meant to
// be exact, re-parseable source (e.g. an empty sequence and `empty` collapse
// to the same "{}") - just legible output for interactive use.
//
// A `let rec` value can reach itself (§10), so this cannot simply recurse.
// A Table that a back-edge returns to is given a label and printed as
// `#1{ ... }`; the back-edge itself prints as `#1`:
//
//   #1{ name: "Alice", friends: {{ name: "Bob", friends: {#1} }} }
//
// Only Tables genuinely on a cycle are labelled, so every acyclic value -
// including one that merely shares a sub-Table between two branches - prints
// exactly as it did before any of this existed.
format_value :: proc(val: Value) -> string {
  b: strings.Builder
  strings.builder_init(&b)
  st: Print_State
  defer print_state_destroy(&st)
  mark_cycles(val, &st)
  write_value(&b, val, &st)
  return strings.to_string(b)
}

@(private = "file")
Print_State :: struct {
  cyclic: map[rawptr]bool, // Tables a back-edge returns to - these get a label
  open:   map[rawptr]bool, // Tables currently being written, i.e. above us
  label:  map[rawptr]int,  // assigned when a labelled Table is first opened
  seen:   map[rawptr]bool, // fully explored during the marking pass
  next:   int,
}

@(private = "file")
print_state_destroy :: proc(st: ^Print_State) {
  delete(st.cyclic)
  delete(st.open)
  delete(st.label)
  delete(st.seen)
}

// Finds the Tables that a cycle returns to, by walking the value with the
// current path recorded: meeting a Table that is already on the path is a
// back-edge, and that Table is what needs a label. `seen` stops the walk from
// re-exploring a shared-but-acyclic sub-Table once per reference to it.
@(private = "file")
mark_cycles :: proc(val: Value, st: ^Print_State) {
  resolved, rok := resolve_forward(val)
  if !rok do return
  t, is_table := resolved.(^Table_Value)
  if !is_table do return
  key := rawptr(t)
  if st.open[key] {
    st.cyclic[key] = true
    return
  }
  if st.seen[key] do return
  st.open[key] = true
  for entry in t.entries {
    mark_cycles(entry.key, st)
    mark_cycles(entry.value, st)
  }
  delete_key(&st.open, key)
  st.seen[key] = true
}

@(private = "file")
write_value :: proc(b: ^strings.Builder, val: Value, st: ^Print_State) {
  resolved, rok := resolve_forward(val)
  if !rok {
    // Only reachable from a debugger or editor peering at a `let rec` that is
    // still mid-construction - a finished value never holds an unfilled one.
    fmt.sbprint(b, "<circular>")
    return
  }
  #partial switch v in resolved {
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
    write_table(b, v, st)
  case ^Function_Value:
    fmt.sbprint(b, "<function>")
  case ^File_Value:
    // SPEC.md §3: a File displays its filesystem path, however it was
    // obtained - content (or a byte count) is deliberately not what a human
    // sees here. A path-less File shouldn't happen; show the kind alone
    // rather than inventing something if it ever does.
    kind_word := v.kind == .Directory ? "directory" : "file"
    if v.display_path == "" {
      fmt.sbprintf(b, "<%s>", kind_word)
    } else {
      fmt.sbprintf(b, "<%s: %s>", kind_word, v.display_path)
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
write_table :: proc(b: ^strings.Builder, t: ^Table_Value, st: ^Print_State) {
  key := rawptr(t)
  if st.open[key] {
    // The back-edge. Its label was assigned when this Table was opened above
    // us, so there is always one to write.
    fmt.sbprintf(b, "#%d", st.label[key])
    return
  }
  if st.cyclic[key] {
    st.next += 1
    st.label[key] = st.next
    fmt.sbprintf(b, "#%d", st.next)
  }
  st.open[key] = true
  defer delete_key(&st.open, key)

  strings.write_byte(b, '{')
  seq := is_sequence_shaped(t)
  for entry, i in t.entries {
    if i > 0 do strings.write_string(b, ", ")
    if !seq {
      write_key(b, entry.key, st)
      strings.write_string(b, ": ")
    }
    write_value(b, entry.value, st)
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
write_key :: proc(b: ^strings.Builder, key: Value, st: ^Print_State) {
  if s, is_str := key.(string); is_str {
    strings.write_string(b, s)
    return
  }
  write_value(b, key, st)
}
