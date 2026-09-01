package hashedbuild

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// `hb dap` - a Debug Adapter Protocol server, and the whole of this project's
// debugging UI, because the UI belongs to somebody else: VS Code, nvim-dap,
// emacs `dape` and Zed all speak this protocol, and GDB now exposes it too.
//
// The protocol is JSON-RPC-ish over stdio, framed with `Content-Length:` like
// LSP. A client sends *requests*; the adapter answers with a *response* of
// the same `seq`/`command`, and may send *events* at any time. See
// https://microsoft.github.io/debug-adapter-protocol/specification.
//
// What this adapter maps onto DAP's vocabulary, and why:
//
//   thread     one evaluating task. The program is thread 1; every `async`
//              (§2) task is another, because they really are OS threads.
//              They stop together (debugger.odin), so every `stopped` event
//              says allThreadsStopped.
//   frame      one user-level call (call_function, eval.odin), plus the
//              program itself at the bottom. A builtin (§16) evaluates no
//              HashedBuild body, so it is not a frame - there would be
//              nothing inside it to look at.
//   scope      "Result" - the value the stopped node just produced - and
//              "Locals", the `let` bindings visible where it stopped.
//   variable   a name bound to a value, rendered by format_value (§3), so a
//              File shows its path and a Table its entries.
//
// **A stop is after a node, not before it** (see debugger.odin's header): a
// `stopped` event means "this expression just produced this value". That is
// what makes the Result scope the interesting one, and it is the one place a
// person used to statement-oriented debuggers has to adjust.

@(private = "file")
Dap_Session :: struct {
  run:   ^Debugger_Run,
  dirs:  Root_Dirs,
  // The launch request's own `seq`, held while the run starts so the response
  // can be sent after `initialized`/`stopped`, in the order clients expect.
  lines_start_at_1:   bool,
  columns_start_at_1: bool,
  // Handles for the variables tree: DAP addresses a compound value by an
  // opaque integer it got from an earlier response, so every value a client
  // might expand is kept here until the next resume.
  var_refs: [dynamic]Value,
  no_debug: bool,
  terminated: bool,
}

// The entry point `hb dap` runs (main.odin). Blocks reading stdin until the
// client disconnects or stdin closes.
run_dap_server :: proc(opts: Cli_Options) {
  s := Dap_Session{lines_start_at_1 = true, columns_start_at_1 = true}
  s.var_refs = make([dynamic]Value, 0, 16)
  defer delete(s.var_refs)
  defer if s.run != nil do stop_debugger_run(s.run)

  reader := dap_reader_make()
  defer dap_reader_destroy(&reader)

  for {
    body, ok := dap_read_message(&reader)
    if !ok do break // stdin closed: the client is gone
    defer delete(body)

    parsed, perr := json.parse(body, json.DEFAULT_SPECIFICATION, true)
    if perr != nil do continue // unparseable framing is the client's problem, not ours
    defer json.destroy_value(parsed)

    msg, is_obj := parsed.(json.Object)
    if !is_obj do continue
    if jv_str(msg, "type") != "request" do continue

    dap_handle_request(&s, msg)
    if s.terminated do break
  }
}

// ---- one request -----------------------------------------------------------------

@(private = "file")
dap_handle_request :: proc(s: ^Dap_Session, msg: json.Object) {
  command := jv_str(msg, "command")
  seq := jv_int(msg, "seq")
  args, _ := jv_obj(msg, "arguments")

  switch command {
  case "initialize":
    // `initialize` establishes how the client counts, before anything is
    // reported back to it - so these two are read here and every line and
    // column below goes through dap_line/dap_column.
    if v, has := args["linesStartAt1"]; has do s.lines_start_at_1 = jv_bool_value(v)
    if v, has := args["columnsStartAt1"]; has do s.columns_start_at_1 = jv_bool_value(v)
    dap_respond(seq, command, proc(w: ^Json_Writer, ctx: rawptr) {
      jw_obj_begin(w)
      // Only what this adapter genuinely does. Claiming a capability it does
      // not implement is how a client ends up sending a request that gets an
      // error instead of a feature.
      jw_kbool(w, "supportsConfigurationDoneRequest", true)
      jw_kbool(w, "supportsEvaluateForHovers", true)
      jw_kbool(w, "supportsTerminateRequest", true)
      jw_kbool(w, "supportsSingleThreadExecutionRequests", false)
      jw_obj_end(w)
    }, nil)
    dap_event("initialized", proc(w: ^Json_Writer, ctx: rawptr) { jw_obj_begin(w); jw_obj_end(w) }, nil)

  case "launch":
    dap_launch(s, seq, args)

  case "setBreakpoints":
    dap_set_breakpoints(s, seq, args)

  case "configurationDone":
    dap_respond_empty(seq, command)

  case "threads":
    dap_threads(s, seq)

  case "stackTrace":
    dap_stack_trace(s, seq)

  case "scopes":
    dap_scopes(s, seq, args)

  case "variables":
    dap_variables(s, seq, args)

  case "continue":
    dap_respond(seq, command, proc(w: ^Json_Writer, ctx: rawptr) {
      jw_obj_begin(w)
      jw_kbool(w, "allThreadsContinued", true)
      jw_obj_end(w)
    }, nil)
    dap_go(s, .Running)

  case "next":
    dap_respond_empty(seq, command)
    dap_go(s, .Step_Over)

  case "stepIn":
    dap_respond_empty(seq, command)
    dap_go(s, .Stop_Next)

  case "stepOut":
    dap_respond_empty(seq, command)
    dap_go(s, .Step_Out)

  case "evaluate":
    dap_evaluate(s, seq, args)

  case "disconnect", "terminate":
    dap_respond_empty(seq, command)
    s.terminated = true

  case:
    dap_error(seq, command, fmt.tprintf("%s is not supported by this adapter", command))
  }
}

// ---- launch ------------------------------------------------------------------------

// DAP leaves `launch`'s arguments entirely to the adapter, so these are ours,
// and they are the command line's: `program`, plus `dirs` naming what the
// program may reach (§9/§16) and an optional `cacheDir`. A launch config is a
// written-down `hb --dir name=path program.hb`.
@(private = "file")
dap_launch :: proc(s: ^Dap_Session, seq: int, args: json.Object) {
  program := jv_str(args, "program")
  if program == "" {
    dap_error(seq, "launch", "launch needs a `program`: the .hb file to run")
    return
  }
  s.no_debug = jv_bool(args, "noDebug")

  named := make([dynamic]Named_Dir, 0, 4, context.temp_allocator)
  if dirs_obj, has := jv_obj(args, "dirs"); has {
    for name, v in dirs_obj {
      path, is_str := v.(json.String)
      if !is_str do continue
      append(&named, Named_Dir{name = name, path = string(path)})
    }
  }
  dirs, dir_err, dir_ok := open_root_dirs(jv_str(args, "cacheDir"), named[:])
  if !dir_ok {
    dap_error(seq, "launch", dir_err)
    return
  }
  s.dirs = dirs

  source, errno := load_source_file(program)
  if errno != .None {
    dap_error(seq, "launch", fmt.tprintf("could not read %s (%v)", program, errno))
    return
  }
  src := strings.clone(string(source.data[:source.n_bytes]))
  free_source_file(source)

  s.run = start_debugger_run(program, src, dirs)
  if s.run == nil {
    dap_error(seq, "launch", fmt.tprintf("%s does not parse, so there is nothing to debug", program))
    return
  }
  dap_respond_empty(seq, "launch")
  dap_report_state(s)
}

// ---- breakpoints ---------------------------------------------------------------------

@(private = "file")
dap_set_breakpoints :: proc(s: ^Dap_Session, seq: int, args: json.Object) {
  lines := make([dynamic]int, 0, 8, context.temp_allocator)
  if bps, has := args["breakpoints"]; has {
    if arr, is_arr := bps.(json.Array); is_arr {
      for entry in arr {
        if o, is_obj := entry.(json.Object); is_obj {
          append(&lines, dap_line_in(s, jv_int(o, "line")))
        }
      }
    }
  }

  // Before `launch`, there is no run to set them on yet. Answering
  // "unverified" is honest and is what clients expect at that point; a real
  // client re-sends them once the session is live.
  verified: []bool
  if s.run != nil {
    verified = debugger_set_breakpoints(s.run, lines[:], context.temp_allocator)
  } else {
    verified = make([]bool, len(lines), context.temp_allocator)
  }

  Ctx :: struct { s: ^Dap_Session, lines: []int, verified: []bool }
  c := Ctx{s = s, lines = lines[:], verified = verified}
  dap_respond(seq, "setBreakpoints", proc(w: ^Json_Writer, ctx: rawptr) {
    c := (^Ctx)(ctx)
    jw_obj_begin(w)
    jw_key(w, "breakpoints")
    jw_arr_begin(w)
    for line, i in c.lines {
      jw_obj_begin(w)
      jw_kbool(w, "verified", c.verified[i])
      jw_kint(w, "line", dap_line_out(c.s, line))
      if !c.verified[i] do jw_kstr(w, "message", "no expression starts on this line")
      jw_obj_end(w)
    }
    jw_arr_end(w)
    jw_obj_end(w)
  }, &c)
}

// ---- state reporting -------------------------------------------------------------------

// Resumes the run and reports wherever it lands: another stop, or the end.
@(private = "file")
dap_go :: proc(s: ^Dap_Session, mode: Debug_Mode) {
  if s.run == nil do return
  clear(&s.var_refs) // every handle a client holds refers to the stop we are leaving

  target, thread := 0, 0
  if mode == .Step_Over || mode == .Step_Out {
    // Both are defined against the stopped task's own call depth.
    target = len(s.run.stop_info.frames)
    thread = s.run.stop_info.thread_id
  }
  effective := mode
  if s.no_debug do effective = .Running
  debugger_resume(s.run, effective, target, thread)
  debugger_wait_until_settled(s.run)
  dap_report_state(s)
}

// One `stopped` or one `terminated`/`exited`, depending on where the run is.
@(private = "file")
dap_report_state :: proc(s: ^Dap_Session) {
  if s.run == nil do return
  if s.run.is_stopped {
    dap_event("stopped", proc(w: ^Json_Writer, ctx: rawptr) {
      s := (^Dap_Session)(ctx)
      info := s.run.stop_info
      jw_obj_begin(w)
      jw_kstr(w, "reason", info.reason)
      jw_kint(w, "threadId", info.thread_id)
      jw_kbool(w, "allThreadsStopped", true)
      // The value that just appeared is the news, so it goes in the event
      // itself as well as in the Result scope - a client shows this line in
      // its debug console without having to ask for anything.
      jw_kstr(w, "description", dap_stop_description(s))
      if !info.ok do jw_kstr(w, "text", info.error_message)
      jw_obj_end(w)
    }, s)
    return
  }

  // Finished. `exited` carries a code so a client can say whether the program
  // succeeded; `terminated` ends the session.
  code := 0 if s.run.final_ok else 1
  Ctx :: struct { code: int }
  c := Ctx{code = code}
  if s.run.final_ok {
    formatted := format_value(s.run.final_value)
    defer delete(formatted)
    dap_output(fmt.tprintf("%s\n", formatted))
  } else {
    dap_output(fmt.tprintf("error: %s\n", s.run.interp.error_message), "stderr")
  }
  dap_event("exited", proc(w: ^Json_Writer, ctx: rawptr) {
    jw_obj_begin(w)
    jw_kint(w, "exitCode", (^Ctx)(ctx).code)
    jw_obj_end(w)
  }, &c)
  dap_event("terminated", proc(w: ^Json_Writer, ctx: rawptr) { jw_obj_begin(w); jw_obj_end(w) }, nil)
}

@(private = "file")
dap_stop_description :: proc(s: ^Dap_Session) -> string {
  info := s.run.stop_info
  text := node_source_text(s.run, info.node)
  if !info.ok do return fmt.tprintf("%s failed", text)
  formatted := format_value(info.value)
  defer delete(formatted)
  return fmt.tprintf("%s => %s", text, formatted)
}

// ---- threads / frames / variables ---------------------------------------------------

@(private = "file")
dap_threads :: proc(s: ^Dap_Session, seq: int) {
  dap_respond(seq, "threads", proc(w: ^Json_Writer, ctx: rawptr) {
    s := (^Dap_Session)(ctx)
    jw_obj_begin(w)
    jw_key(w, "threads")
    jw_arr_begin(w)
    count := 1
    if s.run != nil do count = s.run.next_thread_id
    for id in 1 ..= count {
      jw_obj_begin(w)
      jw_kint(w, "id", id)
      jw_kstr(w, "name", "program" if id == 1 else fmt.tprintf("async %d", id - 1))
      jw_obj_end(w)
    }
    jw_arr_end(w)
    jw_obj_end(w)
  }, s)
}

// The stopped task's stack: the node it stopped at, then one frame per
// user-level call outwards, then the program itself. A frame's *location* is
// where its callee was called from, which is what makes the chain read the
// way a stack trace should.
@(private = "file")
dap_stack_trace :: proc(s: ^Dap_Session, seq: int) {
  if s.run == nil || !s.run.is_stopped {
    dap_error(seq, "stackTrace", "the program is not stopped")
    return
  }
  dap_respond(seq, "stackTrace", proc(w: ^Json_Writer, ctx: rawptr) {
    s := (^Dap_Session)(ctx)
    info := s.run.stop_info
    jw_obj_begin(w)
    jw_key(w, "stackFrames")
    jw_arr_begin(w)

    // Frame 0 is where we stopped; each outer frame is located at the call
    // that entered the frame below it.
    at := info.node
    id := 0
    #reverse for f in info.frames {
      dap_write_frame(w, s, id, dap_frame_name(s, f), at)
      at = f.call_node
      id += 1
    }
    dap_write_frame(w, s, id, "<program>", at)

    jw_arr_end(w)
    jw_kint(w, "totalFrames", len(info.frames) + 1)
    jw_obj_end(w)
  }, s)
}

@(private = "file")
dap_frame_name :: proc(s: ^Dap_Session, f: Debug_Frame) -> string {
  if f.fn != nil && f.fn.name != "" do return f.fn.name // a builtin, named by what it is
  return "func"
}

@(private = "file")
dap_write_frame :: proc(w: ^Json_Writer, s: ^Dap_Session, id: int, name: string, node: Node_Idx) {
  span := s.run.ast.nodes[node].span
  line := line_of_offset(s.run.lines, span.start)
  jw_obj_begin(w)
  jw_kint(w, "id", id)
  jw_kstr(w, "name", name)
  jw_key(w, "source")
  jw_obj_begin(w)
  jw_kstr(w, "name", s.run.source_name)
  jw_kstr(w, "path", s.run.source_name)
  jw_obj_end(w)
  jw_kint(w, "line", dap_line_out(s, line))
  jw_kint(w, "column", dap_column_out(s, column_of_offset(s.run.src, s.run.lines, span.start)))
  jw_kint(w, "endLine", dap_line_out(s, line_of_offset(s.run.lines, span.end)))
  jw_obj_end(w)
}

// Two scopes, and they mean different things here than in a statement
// language. "Result" holds the value the stopped node just produced - the
// whole point of stopping after a node - and "Locals" holds the names in
// scope where it stopped.
@(private = "file")
dap_scopes :: proc(s: ^Dap_Session, seq: int, args: json.Object) {
  if s.run == nil || !s.run.is_stopped {
    dap_error(seq, "scopes", "the program is not stopped")
    return
  }
  result_ref := dap_ref_for(s, s.run.stop_info.value)
  Ctx :: struct { result_ref: int, locals_ref: int }
  c := Ctx{result_ref = result_ref, locals_ref = DAP_LOCALS_REF}
  dap_respond(seq, "scopes", proc(w: ^Json_Writer, ctx: rawptr) {
    c := (^Ctx)(ctx)
    jw_obj_begin(w)
    jw_key(w, "scopes")
    jw_arr_begin(w)
    jw_obj_begin(w)
    jw_kstr(w, "name", "Result")
    jw_kint(w, "variablesReference", c.result_ref)
    jw_kbool(w, "expensive", false)
    jw_obj_end(w)
    jw_obj_begin(w)
    jw_kstr(w, "name", "Locals")
    jw_kint(w, "variablesReference", c.locals_ref)
    jw_kbool(w, "expensive", false)
    jw_obj_end(w)
    jw_arr_end(w)
    jw_obj_end(w)
  }, &c)
}

// Reference 1 is always the Locals scope; everything above is a compound
// value handed out by dap_ref_for. Zero means "not expandable", which is what
// a scalar gets.
DAP_LOCALS_REF :: 1

@(private = "file")
dap_ref_for :: proc(s: ^Dap_Session, v: Value) -> int {
  if !dap_is_expandable(v) do return 0
  append(&s.var_refs, v)
  return DAP_LOCALS_REF + len(s.var_refs)
}

@(private = "file")
dap_is_expandable :: proc(v: Value) -> bool {
  #partial switch t in v {
  case ^Table_Value: return len(t.entries) > 0
  }
  return false
}

@(private = "file")
dap_variables :: proc(s: ^Dap_Session, seq: int, args: json.Object) {
  if s.run == nil || !s.run.is_stopped {
    dap_error(seq, "variables", "the program is not stopped")
    return
  }
  ref := jv_int(args, "variablesReference")

  Entry :: struct { name: string, value: Value }
  entries := make([dynamic]Entry, 0, 8, context.temp_allocator)

  if ref == DAP_LOCALS_REF {
    // Every name visible where the run stopped, innermost scope first, with
    // an outer binding of the same name hidden by the inner one - which is
    // what `let` shadowing means (§10).
    // Stops at the global scope: the builtins are always in scope and are
    // never the names someone is looking for here (debugger.odin).
    seen := make(map[string]bool, 8, context.temp_allocator)
    for e := s.run.stop_info.env; e != nil && e != s.run.global_env; e = e.parent {
      for name, v in e.names {
        if name in seen do continue
        seen[name] = true
        append(&entries, Entry{name = name, value = v})
      }
    }
  } else {
    idx := ref - DAP_LOCALS_REF - 1
    if idx < 0 || idx >= len(s.var_refs) {
      dap_error(seq, "variables", "no such variablesReference")
      return
    }
    if t, is_table := s.var_refs[idx].(^Table_Value); is_table {
      for entry in t.entries {
        // A pane draws the name as a label, so a Utf8 key goes in bare - its
        // quotes would be part of the label rather than of the value. Any
        // other key kind (an Integer, in a sequence) is formatted as itself.
        name, key_is_str := entry.key.(string)
        if !key_is_str do name = format_value(entry.key)
        append(&entries, Entry{name = name, value = entry.value})
      }
    }
  }

  Ctx :: struct { s: ^Dap_Session, entries: []Entry }
  c := Ctx{s = s, entries = entries[:]}
  dap_respond(seq, "variables", proc(w: ^Json_Writer, ctx: rawptr) {
    c := (^Ctx)(ctx)
    jw_obj_begin(w)
    jw_key(w, "variables")
    jw_arr_begin(w)
    for e in c.entries {
      formatted := format_value(e.value)
      defer delete(formatted)
      jw_obj_begin(w)
      jw_kstr(w, "name", e.name)
      jw_kstr(w, "value", formatted)
      jw_kstr(w, "type", value_type_name(e.value))
      jw_kint(w, "variablesReference", dap_ref_for(c.s, e.value))
      jw_obj_end(w)
    }
    jw_arr_end(w)
    jw_obj_end(w)
  }, &c)
}

// ---- evaluate ----------------------------------------------------------------------

// A watch expression, or the debug console. The expression is parsed on its
// own and evaluated in the environment the run stopped in, so it sees exactly
// the names the stopped node could see.
//
// It really evaluates: an expression calling a filesystem builtin will touch
// the filesystem, exactly as it would in the program. That is the same bargain
// every debugger's console makes, and the alternative - a second, weaker
// evaluator that only looks names up - would answer differently from the
// language it is meant to be showing you.
@(private = "file")
dap_evaluate :: proc(s: ^Dap_Session, seq: int, args: json.Object) {
  expr := jv_str(args, "expression")
  if s.run == nil || !s.run.is_stopped {
    dap_error(seq, "evaluate", "the program is not stopped")
    return
  }
  if expr == "" {
    dap_error(seq, "evaluate", "nothing to evaluate")
    return
  }

  src := strings.clone(expr, context.temp_allocator)
  ast := parse(source_t{name = "eval", n_bytes = u64(len(src)), data = raw_data(src)}, ast_t{})
  defer ast_destroy(&ast)
  if len(ast.errors) > 0 {
    dap_error(seq, "evaluate", "that does not parse")
    return
  }

  // A fresh interpreter over the stopped run's context: no debugger attached,
  // so this evaluation does not itself stop at every node.
  interp := Interpreter{
    ast         = &ast,
    src         = src,
    current_ctx = s.run.interp.current_ctx,
  }
  val, ok := eval(&interp, ast.root, s.run.stop_info.env)
  if !ok {
    dap_error(seq, "evaluate", interp.error_message)
    return
  }

  formatted := format_value(val)
  defer delete(formatted)
  Ctx :: struct { s: ^Dap_Session, text: string, val: Value }
  c := Ctx{s = s, text = formatted, val = val}
  dap_respond(seq, "evaluate", proc(w: ^Json_Writer, ctx: rawptr) {
    c := (^Ctx)(ctx)
    jw_obj_begin(w)
    jw_kstr(w, "result", c.text)
    jw_kstr(w, "type", value_type_name(c.val))
    jw_kint(w, "variablesReference", dap_ref_for(c.s, c.val))
    jw_obj_end(w)
  }, &c)
}

// ---- helpers -------------------------------------------------------------------------

@(private = "file")
node_source_text :: proc(run: ^Debugger_Run, node: Node_Idx) -> string {
  span := run.ast.nodes[node].span
  if int(span.end) > len(run.src) do return ""
  text := strings.trim_space(run.src[span.start:span.end])
  if len(text) > 60 do return fmt.tprintf("%s...", text[:57])
  return text
}

// DAP counts lines from 1 unless the client said otherwise at `initialize`;
// everything inside this interpreter counts from 1 (lines.odin), so the
// translation lives at the boundary and only here.
@(private = "file")
dap_line_out :: proc(s: ^Dap_Session, line: int) -> int {
  return line if s.lines_start_at_1 else line - 1
}

@(private = "file")
dap_line_in :: proc(s: ^Dap_Session, line: int) -> int {
  return line if s.lines_start_at_1 else line + 1
}

@(private = "file")
dap_column_out :: proc(s: ^Dap_Session, col: int) -> int {
  return col if s.columns_start_at_1 else col - 1
}
