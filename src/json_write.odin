package hashedbuild

import "core:fmt"
import "core:strconv"
import "core:strings"

// A minimal JSON writer, for building DAP messages (dap.odin).
//
// Odin's core:encoding/json marshals a *typed* value, and every DAP message
// has a different shape - a response body is whatever that request needs -
// so using it would mean a struct per message and a union to hold them.
// Writing the bytes directly is smaller, and it puts string escaping in one
// place, which is the only part that is easy to get wrong.
//
// The writer tracks whether the current object or array already has an
// element, so callers never place commas themselves - the one bookkeeping
// error this shape of code otherwise makes constantly.

Json_Writer :: struct {
  b:     strings.Builder,
  fresh: [dynamic]bool, // per nesting level: is the container still empty?
}

jw_make :: proc(allocator := context.allocator) -> Json_Writer {
  w := Json_Writer{b = strings.builder_make(allocator)}
  w.fresh = make([dynamic]bool, 0, 8, allocator)
  append(&w.fresh, true)
  return w
}

jw_destroy :: proc(w: ^Json_Writer) {
  strings.builder_destroy(&w.b)
  delete(w.fresh)
}

jw_string :: proc(w: ^Json_Writer) -> string {
  return strings.to_string(w.b)
}

@(private = "file")
jw_sep :: proc(w: ^Json_Writer) {
  if !w.fresh[len(w.fresh) - 1] do strings.write_byte(&w.b, ',')
  w.fresh[len(w.fresh) - 1] = false
}

jw_obj_begin :: proc(w: ^Json_Writer) {
  jw_sep(w)
  strings.write_byte(&w.b, '{')
  append(&w.fresh, true)
}

jw_obj_end :: proc(w: ^Json_Writer) {
  pop(&w.fresh)
  strings.write_byte(&w.b, '}')
}

jw_arr_begin :: proc(w: ^Json_Writer) {
  jw_sep(w)
  strings.write_byte(&w.b, '[')
  append(&w.fresh, true)
}

jw_arr_end :: proc(w: ^Json_Writer) {
  pop(&w.fresh)
  strings.write_byte(&w.b, ']')
}

// A key, which is followed by exactly one value-writing call. The key's own
// separator is written here, and the value that follows must not write
// another - hence `fresh` is set true for the value's sake and restored by
// whatever writes it.
jw_key :: proc(w: ^Json_Writer, key: string) {
  jw_sep(w)
  jw_write_escaped(w, key)
  strings.write_byte(&w.b, ':')
  w.fresh[len(w.fresh) - 1] = true
}

jw_str :: proc(w: ^Json_Writer, v: string) {
  jw_sep(w)
  jw_write_escaped(w, v)
}

jw_int :: proc(w: ^Json_Writer, v: int) {
  jw_sep(w)
  buf: [24]u8
  strings.write_string(&w.b, strconv.write_int(buf[:], i64(v), 10))
}

jw_bool :: proc(w: ^Json_Writer, v: bool) {
  jw_sep(w)
  strings.write_string(&w.b, "true" if v else "false")
}

jw_null :: proc(w: ^Json_Writer) {
  jw_sep(w)
  strings.write_string(&w.b, "null")
}

// Convenience for the overwhelmingly common `"key": <scalar>` pairs.
jw_kstr :: proc(w: ^Json_Writer, key: string, v: string) { jw_key(w, key); jw_str(w, v) }
jw_kint :: proc(w: ^Json_Writer, key: string, v: int)    { jw_key(w, key); jw_int(w, v) }
jw_kbool :: proc(w: ^Json_Writer, key: string, v: bool)  { jw_key(w, key); jw_bool(w, v) }

// JSON strings are UTF-8 and may not carry a raw control character. Anything
// below 0x20 therefore becomes an escape - \u00XX for the ones without a
// shorter form - and the two characters that would end the string or start an
// escape are backslashed. Everything else, non-ASCII included, goes through
// as its own UTF-8 bytes, which is exactly what the spec wants.
@(private = "file")
jw_write_escaped :: proc(w: ^Json_Writer, s: string) {
  strings.write_byte(&w.b, '"')
  for i in 0 ..< len(s) {
    c := s[i]
    switch c {
    case '"':  strings.write_string(&w.b, "\\\"")
    case '\\': strings.write_string(&w.b, "\\\\")
    case '\n': strings.write_string(&w.b, "\\n")
    case '\r': strings.write_string(&w.b, "\\r")
    case '\t': strings.write_string(&w.b, "\\t")
    case '\b': strings.write_string(&w.b, "\\b")
    case '\f': strings.write_string(&w.b, "\\f")
    case:
      if c < 0x20 {
        strings.write_string(&w.b, fmt.tprintf("\\u%04x", int(c)))
      } else {
        strings.write_byte(&w.b, c)
      }
    }
  }
  strings.write_byte(&w.b, '"')
}
