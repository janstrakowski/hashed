package hashedbuild

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

// The wire half of `hb dap` (dap.odin): DAP's framing, its message envelopes,
// and the small readers that get typed values back out of a parsed request.
//
// Framing is LSP's - `Content-Length: N\r\n\r\n` followed by N bytes of JSON.
// Nothing else in the header block matters to this adapter, so anything that
// is not Content-Length is skipped rather than rejected: a client is allowed
// to send more.

// ---- reading -----------------------------------------------------------------------

Dap_Reader :: struct {
  buf: [dynamic]u8, // everything read from stdin and not yet consumed
}

dap_reader_make :: proc() -> Dap_Reader {
  return Dap_Reader{buf = make([dynamic]u8, 0, 4096)}
}

dap_reader_destroy :: proc(r: ^Dap_Reader) {
  delete(r.buf)
}

// Reads one whole message, blocking until it has all of it. `ok` is false
// once stdin is closed and nothing complete remains - which is how a session
// ends when a client exits without saying `disconnect`.
dap_read_message :: proc(r: ^Dap_Reader) -> (body: []u8, ok: bool) {
  chunk: [4096]u8
  for {
    if body, found := dap_take_message(r); found do return body, true
    n, err := os.read(os.stdin, chunk[:])
    if err != nil || n <= 0 do return nil, false
    append(&r.buf, ..chunk[:n])
  }
}

// Pulls a complete message out of the buffer if there is one, leaving the
// rest for next time - stdin arrives in whatever sizes the OS feels like, so
// a read can carry half a message or three of them.
@(private = "file")
dap_take_message :: proc(r: ^Dap_Reader) -> ([]u8, bool) {
  header_end := dap_find(r.buf[:], "\r\n\r\n")
  if header_end < 0 do return nil, false

  length := -1
  header := string(r.buf[:header_end])
  for line in strings.split_iterator(&header, "\r\n") {
    colon := strings.index_byte(line, ':')
    if colon < 0 do continue
    if !strings.equal_fold(strings.trim_space(line[:colon]), "content-length") do continue
    if n, parsed := strconv.parse_int(strings.trim_space(line[colon + 1:])); parsed do length = n
  }
  if length < 0 do return nil, false // no length: wait for more rather than guess

  start := header_end + 4
  if len(r.buf) < start + length do return nil, false

  body := make([]u8, length)
  copy(body, r.buf[start:start + length])
  remove_range(&r.buf, 0, start + length)
  return body, true
}

@(private = "file")
dap_find :: proc(haystack: []u8, needle: string) -> int {
  return strings.index(string(haystack), needle)
}

// ---- writing -----------------------------------------------------------------------

// Every message carries a monotonically increasing `seq`, and responses and
// events interleave freely - a `stopped` can arrive between a request and its
// response - so the counter and the write itself are guarded. The adapter is
// single-threaded today; the lock is here because the run's own threads are
// one `dap_output` away from writing too.
@(private = "file")
dap_out: struct {
  mu:  sync.Mutex,
  seq: int,
}

// `hb dap --log <path>`: every message in and out, appended as it happens.
// A protocol bug is almost always a disagreement about what was sent, and
// this is the only way to settle one - twice now, what a client actually did
// was not what the adapter was written to expect.
@(private = "file")
dap_log: struct {
  mu:      sync.Mutex,
  file:    ^os.File,
  enabled: bool,
}

dap_log_open :: proc(path: string) {
  if path == "" do return
  file, err := os.open(path, os.File_Flags{.Write, .Create, .Append})
  if err != nil do return // a log that cannot be written is not worth failing over
  dap_log.file = file
  dap_log.enabled = true
  dap_log_write("--- session start ---")
}

dap_log_close :: proc() {
  if !dap_log.enabled do return
  dap_log_write("--- session end ---")
  os.close(dap_log.file)
  dap_log.enabled = false
}

dap_log_write :: proc(line: string) {
  if !dap_log.enabled do return
  sync.mutex_lock(&dap_log.mu)
  defer sync.mutex_unlock(&dap_log.mu)
  os.write_string(dap_log.file, line)
  os.write_string(dap_log.file, "\n")
}

// A body-writing callback plus its context, because Odin's `proc` values do
// not capture. Every response and event below is built this way: the envelope
// is written once, here, and the callback fills in the part that differs.
Dap_Body_Proc :: proc(w: ^Json_Writer, ctx: rawptr)

dap_respond :: proc(request_seq: int, command: string, body: Dap_Body_Proc, ctx: rawptr) {
  w := jw_make(context.temp_allocator)
  jw_obj_begin(&w)
  jw_kint(&w, "seq", dap_next_seq())
  jw_kstr(&w, "type", "response")
  jw_kint(&w, "request_seq", request_seq)
  jw_kbool(&w, "success", true)
  jw_kstr(&w, "command", command)
  if body != nil {
    jw_key(&w, "body")
    body(&w, ctx)
  }
  jw_obj_end(&w)
  dap_write(jw_string(&w))
}

dap_respond_empty :: proc(request_seq: int, command: string) {
  dap_respond(request_seq, command, nil, nil)
}

// A failed request. DAP wants `success: false` with a message, not a dropped
// response - a client that never gets an answer just waits.
dap_error :: proc(request_seq: int, command: string, message: string) {
  w := jw_make(context.temp_allocator)
  jw_obj_begin(&w)
  jw_kint(&w, "seq", dap_next_seq())
  jw_kstr(&w, "type", "response")
  jw_kint(&w, "request_seq", request_seq)
  jw_kbool(&w, "success", false)
  jw_kstr(&w, "command", command)
  jw_kstr(&w, "message", message)
  jw_obj_end(&w)
  dap_write(jw_string(&w))
}

dap_event :: proc(event: string, body: Dap_Body_Proc, ctx: rawptr) {
  w := jw_make(context.temp_allocator)
  jw_obj_begin(&w)
  jw_kint(&w, "seq", dap_next_seq())
  jw_kstr(&w, "type", "event")
  jw_kstr(&w, "event", event)
  if body != nil {
    jw_key(&w, "body")
    body(&w, ctx)
  }
  jw_obj_end(&w)
  dap_write(jw_string(&w))
}

// Program output, as the client's debug console shows it. `category` is
// "stdout" unless something went wrong.
dap_output :: proc(text: string, category := "stdout") {
  Ctx :: struct { text, category: string }
  c := Ctx{text = text, category = category}
  dap_event("output", proc(w: ^Json_Writer, ctx: rawptr) {
    c := (^Ctx)(ctx)
    jw_obj_begin(w)
    jw_kstr(w, "category", c.category)
    jw_kstr(w, "output", c.text)
    jw_obj_end(w)
  }, &c)
}

@(private = "file")
dap_next_seq :: proc() -> int {
  sync.mutex_lock(&dap_out.mu)
  defer sync.mutex_unlock(&dap_out.mu)
  dap_out.seq += 1
  return dap_out.seq
}

// Content-Length is in **bytes**, not characters - the one framing mistake
// that survives every ASCII test and breaks the first time a program prints a
// non-ASCII character.
@(private = "file")
dap_write :: proc(payload: string) {
  sync.mutex_lock(&dap_out.mu)
  defer sync.mutex_unlock(&dap_out.mu)
  dap_log_write(fmt.tprintf("<-- %s", payload))
  header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(payload))
  os.write_string(os.stdout, header)
  os.write_string(os.stdout, payload)
  os.flush(os.stdout)
}

// ---- reading values out of a parsed request ------------------------------------------
//
// A client may omit anything optional, and may send a number where the spec
// says integer, so each of these answers a usable zero rather than failing:
// a missing `line` is 0, which is not a line, and the caller treats it as one
// it never matches.

jv_str :: proc(o: json.Object, key: string) -> string {
  v, has := o[key]
  if !has do return ""
  s, is_str := v.(json.String)
  if !is_str do return ""
  return string(s)
}

jv_int :: proc(o: json.Object, key: string) -> int {
  v, has := o[key]
  if !has do return 0
  #partial switch n in v {
  case json.Integer: return int(n)
  case json.Float:   return int(n)
  }
  return 0
}

jv_bool :: proc(o: json.Object, key: string) -> bool {
  v, has := o[key]
  if !has do return false
  return jv_bool_value(v)
}

jv_bool_value :: proc(v: json.Value) -> bool {
  b, is_bool := v.(json.Boolean)
  return bool(b) if is_bool else false
}

jv_obj :: proc(o: json.Object, key: string) -> (json.Object, bool) {
  v, has := o[key]
  if !has do return nil, false
  obj, is_obj := v.(json.Object)
  return obj, is_obj
}
