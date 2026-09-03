package hashed

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// The text a `cached` entry's `value.hl` holds, and the reader that turns it
// back into a Value. This is the "subset of HL" half of §15's on-disk layout -
// see cache_store.odin for the layout itself.
//
// **It is written to be read.** A cache directory is something a person opens
// to see what a build produced, so an entry says what it is in the language
// the program was written in:
//
//   { .name = "libz", .version = 3, .built = true, .src = file "sha256-Ab3_", .out = dir "sha256-9xQ1" }
//
// **A separate reader, not `import`.** Everything above is Hashed syntax
// as it stands - `true`, `bytes`, `file` and `dir` are ordinary identifiers,
// and `file "sha256-Ab3_"` is an ordinary call - but none of those names are
// *bound* to anything, so Hashed's own evaluator could not read this back
// even though its parser can read the shape. Reading it here instead is also
// what keeps a cache entry from being able to run anything: this parser
// accepts literals and nothing else, so a tampered-with entry is a parse
// failure rather than code that executes.
//
// **Values that reach themselves** get two more names. `let rec` can build a
// cyclic Table (§10), and a cycle has no finite written form without a way to
// point backwards, so a Table that is reached more than once is written once
// with a label and referred to after that:
//
//   node "1" { .name = "alice", .friend = node "2" { .name = "bob", .friend = ref "1" } }
//
// A definition always precedes every reference to it, because the label is
// assigned at the node's first occurrence in the same walk that emits it - so
// the reader never has to patch anything up afterwards. It does have to create
// each Table *before* filling it in, which is exactly how the evaluator builds
// one (§10: the Table is bound to the name before any entry runs).
//
// Labels are also given to a Table that is merely *shared* rather than cyclic.
// Sharing is not observable in the value model - §6 compares structurally - so
// this is not required for correctness; it is what stops a deeply shared value
// from being written out exponentially.
//
// The one spelling that goes beyond Hashed's own grammar is `\xNN` inside
// a string, for bytes that have no other escape (Hashed's lexer knows
// `\n`, `\t`, `\r`, `\"` and `\\`, and stops a string at a newline). Utf8
// values can hold such bytes, so the format needs a way to write them.
//
// Round-tripping is the whole contract: a value written here and read back has
// to hash identically (hash.odin), or `cached` would return something that is
// not the value it stored. Floats are the only case where that takes care -
// see write_float.

// ---- writing ----------------------------------------------------------------

// `file_names` maps each File in the value to the entry name it was stored
// under, which cache_store.odin fills in as it writes them out. A File that
// isn't in the map cannot be written, and says so.
cache_format_write :: proc(v: Value, file_names: map[^File_Value]string) -> (text: string, ok: bool, why: string) {
  w := Write_Ctx{file_names = file_names}
  w.labels = make(map[^Table_Value]int)
  w.emitted = make(map[^Table_Value]bool)
  defer delete(w.labels)
  defer delete(w.emitted)

  // Pass one decides which Tables need a label; pass two writes. Two passes
  // rather than one because a label has to be on a node's *first* occurrence,
  // and whether a node recurs is only known after the whole value is walked.
  seen := make(map[^Table_Value]bool)
  defer delete(seen)
  plan_labels(v, &seen, &w.labels)

  b: strings.Builder
  strings.builder_init(&b)
  if why = write_value(&b, v, &w); why != "" {
    strings.builder_destroy(&b)
    return "", false, why
  }
  return strings.to_string(b), true, ""
}

@(private = "file")
Write_Ctx :: struct {
  file_names: map[^File_Value]string,
  labels:     map[^Table_Value]int,  // Tables reached more than once, and which label
  emitted:    map[^Table_Value]bool, // ...and whether the definition has been written yet
}

// Marks every Table reached more than once. Terminates on a cycle because a
// node already in `seen` is recorded and not descended into again.
@(private = "file")
plan_labels :: proc(v: Value, seen: ^map[^Table_Value]bool, labels: ^map[^Table_Value]int) {
  resolved, ok := resolve_forward(v)
  if !ok do return

  t, is_table := resolved.(^Table_Value)
  if !is_table do return

  if seen[t] {
    if _, already := labels[t]; !already do labels[t] = len(labels) + 1
    return
  }
  seen[t] = true
  for entry in t.entries {
    plan_labels(entry.key, seen, labels)
    plan_labels(entry.value, seen, labels)
  }
}

// Returns "" on success, or a sentence naming what it could not write. The
// reason travels back rather than a bare false because "this value cannot be
// cached" is not actionable on its own - which part of it, and why, is.
@(private = "file")
write_value :: proc(b: ^strings.Builder, v: Value, w: ^Write_Ctx) -> string {
  // A resolved back-edge is written as whatever it points at; an unresolved one
  // is a Table still being built, which cannot escape into a finished value.
  resolved, forward_ok := resolve_forward(v)
  if !forward_ok do return "a value still being constructed cannot be cached"

  switch av in resolved {
  case Nothing_Value:
    strings.write_string(b, "nothing")

  case bool:
    strings.write_string(b, av ? "true" : "false")

  case i64:
    strings.write_i64(b, av, 10)

  case f64:
    write_float(b, av)

  case string:
    write_quoted(b, transmute([]u8)av)

  case []u8:
    strings.write_string(b, "bytes ")
    write_quoted(b, av)

  case ^Table_Value:
    if label, labelled := w.labels[av]; labelled {
      if w.emitted[av] {
        strings.write_string(b, "ref ")
        write_quoted(b, transmute([]u8)fmt.tprintf("%d", label))
        return ""
      }
      w.emitted[av] = true
      strings.write_string(b, "node ")
      write_quoted(b, transmute([]u8)fmt.tprintf("%d", label))
      strings.write_string(b, " ")
    }
    strings.write_string(b, "{")
    for entry, i in av.entries {
      if i > 0 do strings.write_string(b, ",")
      strings.write_string(b, " ")
      // `.name = v` is the readable form, and exact: in Hashed it means
      // the literal Utf8 key "name". Anything else needs the general
      // `[key] = v` form, since a key can be any value at all.
      if key, is_str := entry.key.(string); is_str && is_identifier_shaped(key) {
        strings.write_string(b, ".")
        strings.write_string(b, key)
      } else {
        strings.write_string(b, "[")
        if why := write_value(b, entry.key, w); why != "" do return why
        strings.write_string(b, "]")
      }
      strings.write_string(b, " = ")
      if why := write_value(b, entry.value, w); why != "" do return why
    }
    strings.write_string(b, len(av.entries) > 0 ? " }" : "}")

  case ^File_Value:
    name, found := w.file_names[av]
    if !found {
      // The caller writes every File out before asking for the text, so this
      // is a bug here rather than anything the program did.
      return fmt.tprintf("a %s in the value was not written to the cache first",
        av.kind == .Directory ? "directory" : "file")
    }
    strings.write_string(b, av.kind == .Directory ? "dir " : "file ")
    write_quoted(b, transmute([]u8)name)

  // The three that have no written form. A closure's meaning is its
  // environment, ctx.cache has no content of its own, and an un-awaited handle
  // is a running thread - none of them is a thing that can be written down and
  // read back as itself.
  case ^Function_Value:
    return "a Function cannot be cached - a closure's meaning is its environment"
  case ^Cache_Value:
    return "ctx.cache cannot be cached - it is write-only and has no content"
  case ^Async_Handle:
    return "an un-awaited async handle cannot be cached"

  case ^Forward_Ref_Value:
    // resolve_forward above returns the ref itself only when it is unresolved,
    // and that case already returned. Unreachable, and spelled out rather than
    // left to a #partial switch so a new Value case fails to compile here.
    return "a value still being constructed cannot be cached"
  }
  return ""
}

// Shortest decimal that reads back as the same f64, checked rather than
// assumed: if the short form doesn't round-trip, 17 significant digits always
// does. A float that came back a hair different would hash differently
// (hash.odin encodes the IEEE bits), so `cached` would hand back a value that
// isn't the one it stored.
//
// The result is also shaped as a Hashed Float literal, which is stricter
// than strconv's output: a digit is required on both sides of the `.` (§3), so
// a mantissa without one gets ".0" appended, and an exponent's redundant "+"
// goes. `inf`/`-inf`/`nan` are spelled as the bare names Hashed has no
// literal for - the reader below knows them; nothing else does.
@(private = "file")
write_float :: proc(b: ^strings.Builder, f: f64) {
  switch {
  case f != f:
    strings.write_string(b, "nan")
    return
  case math.is_inf(f, 1):
    strings.write_string(b, "inf")
    return
  case math.is_inf(f, -1):
    strings.write_string(b, "-inf")
    return
  }

  buf: [40]u8
  text := strconv.write_float(buf[:], f, 'g', -1, 64)
  if parsed, ok := strconv.parse_f64(text); !ok || parsed != f {
    buf2: [40]u8
    text = strconv.write_float(buf2[:], f, 'g', 17, 64)
    write_float_literal(b, text)
    return
  }
  write_float_literal(b, text)
}

@(private = "file")
write_float_literal :: proc(b: ^strings.Builder, text: string) {
  // strconv writes a leading '+' on a positive number here; Hashed's
  // grammar has no unary '+', so it goes.
  t := text
  if len(t) > 0 && t[0] == '+' do t = t[1:]

  mantissa := t
  exponent := ""
  if e := strings.index_any(t, "eE"); e >= 0 {
    mantissa = t[:e]
    exponent = t[e + 1:]
    if len(exponent) > 0 && exponent[0] == '+' do exponent = exponent[1:]
  }

  strings.write_string(b, mantissa)
  if !strings.contains(mantissa, ".") do strings.write_string(b, ".0")
  if exponent != "" {
    strings.write_string(b, "e")
    strings.write_string(b, exponent)
  }
}

@(private = "file")
write_quoted :: proc(b: ^strings.Builder, data: []u8) {
  strings.write_byte(b, '"')
  for c in data {
    switch c {
    case '"':  strings.write_string(b, "\\\"")
    case '\\': strings.write_string(b, "\\\\")
    case '\n': strings.write_string(b, "\\n")
    case '\r': strings.write_string(b, "\\r")
    case '\t': strings.write_string(b, "\\t")
    case:
      // Anything else printable goes through as itself, so a path or a name
      // reads as a path or a name. The rest - control bytes, and NUL, which
      // would end the string as far as any C-shaped reader is concerned - gets
      // the one escape this format has that Hashed's does not.
      if c < 0x20 || c == 0x7f {
        hex := HEX
        strings.write_string(b, "\\x")
        strings.write_byte(b, hex[c >> 4])
        strings.write_byte(b, hex[c & 0xf])
      } else {
        strings.write_byte(b, c)
      }
    }
  }
  strings.write_byte(b, '"')
}

@(private = "file")
HEX :: "0123456789abcdef"

// Whether a Utf8 key can be written as `.name`. Deliberately ASCII-only and
// conservative - a key that doesn't qualify still round-trips perfectly
// through the `[key] = value` form, so the only cost of saying no is a
// slightly noisier entry.
@(private = "file")
is_identifier_shaped :: proc(s: string) -> bool {
  if len(s) == 0 do return false
  for i in 0 ..< len(s) {
    c := s[i]
    is_alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
    is_digit := c >= '0' && c <= '9'
    if !is_alpha && !(is_digit && i > 0) do return false
  }
  return true
}

// ---- reading ----------------------------------------------------------------

// A `file "..."` / `dir "..."` reference, resolved by the caller: the parser
// knows the entry name, cache_store.odin knows the directory it sits in.
Cache_File_Ref :: proc(entry_name: string, is_dir: bool, userdata: rawptr) -> (Value, bool)

@(private = "file")
Reader :: struct {
  src:      string,
  pos:      int,
  resolve:  Cache_File_Ref,
  userdata: rawptr,
  nodes:    map[string]^Table_Value, // labels defined so far, for `ref`
}

// Parses one value and requires the text to end there. Every failure is a
// plain false: an unreadable entry is a corrupt or hand-edited cache, and the
// caller's answer to that is to treat it as a miss or as a fatal read failure,
// not to try to make sense of half of it.
cache_format_read :: proc(src: string, resolve: Cache_File_Ref, userdata: rawptr) -> (Value, bool) {
  r := Reader{src = src, resolve = resolve, userdata = userdata}
  r.nodes = make(map[string]^Table_Value)
  defer delete(r.nodes)
  v, ok := read_value(&r)
  if !ok do return nil, false
  skip_space(&r)
  if r.pos != len(r.src) do return nil, false
  return v, true
}

@(private = "file")
skip_space :: proc(r: ^Reader) {
  for r.pos < len(r.src) {
    switch r.src[r.pos] {
    case ' ', '\t', '\r', '\n': r.pos += 1
    case: return
    }
  }
}

@(private = "file")
accept :: proc(r: ^Reader, lit: string) -> bool {
  skip_space(r)
  if strings.has_prefix(r.src[r.pos:], lit) {
    r.pos += len(lit)
    return true
  }
  return false
}

// A bare word, for the handful of keyword-shaped values (`nothing`, `true`,
// `bytes`, `dir`, ...). Matched as a whole word so that `nothingness` is not
// read as `nothing` followed by junk.
@(private = "file")
accept_word :: proc(r: ^Reader, word: string) -> bool {
  skip_space(r)
  rest := r.src[r.pos:]
  if !strings.has_prefix(rest, word) do return false
  if len(rest) > len(word) {
    c := rest[len(word)]
    if is_identifier_shaped(string([]u8{c})) do return false
  }
  r.pos += len(word)
  return true
}

@(private = "file")
read_value :: proc(r: ^Reader) -> (Value, bool) {
  skip_space(r)
  if r.pos >= len(r.src) do return nil, false

  switch {
  case accept_word(r, "nothing"): return Nothing_Value{}, true
  case accept_word(r, "true"):    return true, true
  case accept_word(r, "false"):   return false, true
  case accept_word(r, "nan"):     return math.nan_f64(), true
  case accept_word(r, "inf"):     return math.inf_f64(1), true

  case accept_word(r, "bytes"):
    s, ok := read_string(r)
    if !ok do return nil, false
    return transmute([]u8)s, true

  case accept_word(r, "file"), accept_word(r, "dir"):
    // accept_word already consumed it; which one it was is recoverable from
    // the byte just before the current position.
    is_dir := r.src[r.pos - 1] == 'r'
    name, ok := read_string(r)
    if !ok || r.resolve == nil do return nil, false
    return r.resolve(name, is_dir, r.userdata)

  case r.src[r.pos] == '"':
    s, ok := read_string(r)
    if !ok do return nil, false
    return s, true

  case accept_word(r, "node"):
    // The Table is created and registered *before* its entries are read, which
    // is what lets an entry refer back to it - the same order §10 gives a
    // `let rec` Table in the evaluator.
    label, label_ok := read_string(r)
    if !label_ok do return nil, false
    if _, taken := r.nodes[label]; taken do return nil, false // a label defined twice
    t := new(Table_Value)
    r.nodes[label] = t
    if !read_table_into(r, t) do return nil, false
    return t, true

  case accept_word(r, "ref"):
    label, label_ok := read_string(r)
    if !label_ok do return nil, false
    t, defined := r.nodes[label]
    if !defined do return nil, false // a reference with no definition before it
    return t, true

  case r.src[r.pos] == '{':
    t := new(Table_Value)
    if !read_table_into(r, t) do return nil, false
    return t, true
  }
  return read_number(r)
}

// Fills an already-created Table, so a `node` definition can register it before
// its own entries are read.
@(private = "file")
read_table_into :: proc(r: ^Reader, t: ^Table_Value) -> bool {
  if !accept(r, "{") do return false
  if accept(r, "}") do return true

  for {
    key: Value
    switch {
    case accept(r, "."):
      start := r.pos
      for r.pos < len(r.src) && is_identifier_shaped(r.src[r.pos:r.pos + 1]) do r.pos += 1
      if r.pos == start do return false
      key = r.src[start:r.pos]
    case accept(r, "["):
      k, ok := read_value(r)
      if !ok || !accept(r, "]") do return false
      key = k
    case:
      return false
    }

    if !accept(r, "=") do return false
    value, ok := read_value(r)
    if !ok do return false
    append(&t.entries, Table_Entry_Value{key = key, value = value})

    if accept(r, ",") do continue
    if accept(r, "}") do return true
    return false
  }
}

@(private = "file")
read_number :: proc(r: ^Reader) -> (Value, bool) {
  skip_space(r)
  start := r.pos
  if r.pos < len(r.src) && r.src[r.pos] == '-' {
    r.pos += 1
    if accept_word(r, "inf") do return math.inf_f64(-1), true
  }
  is_float := false
  for r.pos < len(r.src) {
    c := r.src[r.pos]
    switch {
    case c >= '0' && c <= '9':
      r.pos += 1
    case c == '.':
      is_float = true
      r.pos += 1
    case c == 'e' || c == 'E':
      is_float = true
      r.pos += 1
      if r.pos < len(r.src) && (r.src[r.pos] == '-' || r.src[r.pos] == '+') do r.pos += 1
    case:
      return finish_number(r.src[start:r.pos], is_float)
    }
  }
  return finish_number(r.src[start:r.pos], is_float)
}

@(private = "file")
finish_number :: proc(text: string, is_float: bool) -> (Value, bool) {
  if text == "" || text == "-" do return nil, false
  if is_float {
    f, ok := strconv.parse_f64(text)
    if !ok do return nil, false
    return f, true
  }
  i, ok := strconv.parse_i64_of_base(text, 10)
  if !ok do return nil, false
  return i, true
}

@(private = "file")
read_string :: proc(r: ^Reader) -> (string, bool) {
  skip_space(r)
  if r.pos >= len(r.src) || r.src[r.pos] != '"' do return "", false
  r.pos += 1

  b: strings.Builder
  strings.builder_init(&b)
  for r.pos < len(r.src) {
    c := r.src[r.pos]
    r.pos += 1
    switch c {
    case '"':
      return strings.to_string(b), true
    case '\\':
      if r.pos >= len(r.src) do break
      e := r.src[r.pos]
      r.pos += 1
      switch e {
      case 'n':  strings.write_byte(&b, '\n')
      case 't':  strings.write_byte(&b, '\t')
      case 'r':  strings.write_byte(&b, '\r')
      case '"':  strings.write_byte(&b, '"')
      case '\\': strings.write_byte(&b, '\\')
      case 'x':
        if r.pos + 1 >= len(r.src) do return "", false
        hi, hi_ok := hex_digit(r.src[r.pos])
        lo, lo_ok := hex_digit(r.src[r.pos + 1])
        if !hi_ok || !lo_ok do return "", false
        r.pos += 2
        strings.write_byte(&b, hi << 4 | lo)
      case:
        return "", false // an escape this format doesn't define: corrupt entry
      }
    case:
      strings.write_byte(&b, c)
    }
  }
  return "", false // unterminated
}

@(private = "file")
hex_digit :: proc(c: u8) -> (u8, bool) {
  switch {
  case c >= '0' && c <= '9': return c - '0', true
  case c >= 'a' && c <= 'f': return c - 'a' + 10, true
  case c >= 'A' && c <= 'F': return c - 'A' + 10, true
  }
  return 0, false
}
