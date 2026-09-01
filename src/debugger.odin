package hashedbuild

import "core:sync"
import "core:thread"
import "core:strings"

// A genuinely pausable/resumable evaluation - the engine `hb dap` drives
// (dap.odin). Unlike a pre-computed trace revealed incrementally, an AST node
// this run hasn't reached truly hasn't been evaluated yet: every evaluating
// thread passes through `debugger_gate` (called from `eval`'s own defer, see
// eval.odin) as each node finishes, and stops there if this run's current
// mode says to.
//
// **A stop is after a node, not before it.** The gate runs once a node's
// value exists, so "stopped" always means "this sub-expression just produced
// this value" rather than "this is about to run". That is the shape of a
// language where everything is an expression: there is no statement whose
// effect you would want to catch beforehand, and the interesting thing about
// reaching a node is what it evaluated to. It does mean a breakpoint on a
// line fires as that line's expression *completes*.
//
// **All threads stop together.** `async` (§2, eval_async.odin) gives a run
// real OS threads, and a spawned task inherits the same `Debugger_Run`, so
// its nodes pass through the same gate. When any one thread decides to stop,
// every other thread stops at its own next node too, and the adapter reports
// `allThreadsStopped`. The alternative - freezing one thread while the others
// run on - would let a stopped program keep changing underneath the pane
// showing it.
//
// Own AST/source, kept alive for as long as any of this run's threads might
// still touch them.
// What a paused run does when it is let go again. Set by the adapter before
// each resume; read by every task's gate as it finishes a node.
Debug_Mode :: enum {
  Stop_Next,  // stop at the very next node any task finishes - DAP's stepIn
  Step_Over,  // ... but not one inside a deeper call than `depth_target`
  Step_Out,   // ... only once we are shallower than `depth_target`
  Running,    // do not stop at all, except at a breakpoint
}

// One user-level call on a task's stack, pushed by call_function (eval.odin).
// The debugger reports these as DAP stack frames, innermost last.
Debug_Frame :: struct {
  fn:        ^Function_Value,
  call_node: Node_Idx, // the expression the call was made from, for the caller's line
  arg:       Value,    // what `#arg` is inside it, which is most of what a frame holds
}

// Where a run is stopped: which task, which node, and what that node just
// produced. A snapshot taken under `mu`, since the adapter reads it from a
// different thread than the one that filled it in.
Debug_Stop :: struct {
  thread_id: int,
  node:      Node_Idx,
  value:     Value,
  ok:        bool,
  env:       ^Env,           // the environment that node finished in - the variables pane
  frames:    []Debug_Frame,  // a copy: the stopped thread's own stack keeps moving after it resumes
  reason:    string,         // DAP's stop reason: "step", "breakpoint", "entry", "exception"
  error_message: string,     // set when !ok, so an exception stop can say what failed
}

Debugger_Run :: struct {
  ast:    ast_t,
  src:    string, // owned - also every task's source buffer
  source_name: string, // owned - what a stack trace calls this source
  lines:  Line_Index, // offsets to lines, for breakpoints and stack traces
  interp: Interpreter, // the main/root task
  task:   Task, // the main/root task's thread (task.odin)

  // Everything below is touched by every task's thread plus whichever thread
  // renders the panel - guarded by `mu`, except `step_generation`'s reads
  // inside `cond_wait`'s predicate (also under `mu` by construction).
  mu:              sync.Mutex,
  cond:            sync.Cond, // broadcast-woken: releases *every* paused task at once, not just one
  resume_generation: int,     // incremented once per debugger_resume call
  stopped_sema:    sync.Sema, // posted when a task actually stops, so the adapter can report it
  stop:            bool,      // tells every task to abort at its next opportunity
  finished:        bool, // the main/root task has returned (async tasks may briefly outlive it - see stop_debugger_run)
  final_value:     Value,
  final_ok:        bool,

  // The current run mode and the call depth `Step_Over`/`Step_Out` measure
  // against - see Debug_Mode.
  mode:            Debug_Mode,
  depth_target:    int,
  depth_thread:    int, // the task those depths are about; another task's depth means nothing to them

  // Breakpoint lines (1-based), as `setBreakpoints` last left them. A set
  // rather than a list: the gate asks "is this node's line in here" once per
  // node, which has to stay cheap.
  breakpoints:     map[int]bool,

  // Set while some task is stopped, and cleared by the resume. `stop_info`
  // describes the task that decided to stop; every *other* task parks too,
  // and reports nothing.
  is_stopped:      bool,
  stop_info:       Debug_Stop,

  // Task ids, handed out in spawn order: the root task is 1, and each async
  // task takes the next number (register_debugger_task). DAP calls these
  // threads, and they really are threads.
  next_thread_id:  int,

  // The scope holding the builtins - where a variables pane stops walking
  // outwards, since those are not the program's own names.
  global_env:      ^Env,

  // Whether anything has stopped yet, so the first stop can report DAP's
  // "entry" rather than "step": a client shows the two differently, and the
  // first one is not the result of a step anybody asked for.
  had_first_stop:  bool,

  // Every async task spawned anywhere during this run, so stop_debugger_run
  // can join all of them (not just the root) before freeing anything they
  // might still be touching. Tracking the handle (not the raw thread) lets
  // cleanup reuse Async_Handle's own `awaited` flag to avoid double-joining
  // one the program's own logic already awaited normally.
  spawned_handles: [dynamic]^Async_Handle,
}

// Called from `eval`'s defer (see eval.odin), once per node, after that
// node's result is already computed but before `eval` hands it back to its
// caller. Decides whether this run stops here and, if so, blocks the calling
// thread until the adapter resumes it.
//
// A task that does *not* itself decide to stop still parks whenever another
// task already has - that is what "all threads stop together" means - and
// wakes on the same resume. Either way, if the run has been told to abort,
// the node's result is overwritten with a failure so the abort propagates
// upward through the evaluator's existing recursive !ok short-circuiting,
// exactly the way any other runtime error already does.
debugger_gate :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env, ret_val: ^Value, ret_ok: ^bool) {
  dbg := interp.debugger

  sync.mutex_lock(&dbg.mu)
  if dbg.stop {
    sync.mutex_unlock(&dbg.mu)
    ret_val^ = nil
    ret_ok^ = false
    return
  }

  reason, mine := stop_reason_locked(dbg, interp, node, ret_ok^)
  if !mine && !dbg.is_stopped {
    sync.mutex_unlock(&dbg.mu) // nothing to stop for: straight through
    return
  }

  if mine && !dbg.is_stopped {
    if !dbg.had_first_stop {
      dbg.had_first_stop = true
      if reason == "step" do reason = "entry"
    }
    dbg.is_stopped = true
    dbg.stop_info = Debug_Stop{
      thread_id = interp.thread_id,
      node      = node,
      value     = ret_val^,
      ok        = ret_ok^,
      env       = env,
      frames    = slice_clone_frames(interp.frames[:]),
      reason    = reason,
    }
    if !ret_ok^ do dbg.stop_info.error_message = strings.clone(interp.error_message)
    sync.mutex_unlock(&dbg.mu)
    sync.sema_post(&dbg.stopped_sema) // let the adapter emit `stopped`
    sync.mutex_lock(&dbg.mu)
  }

  target := dbg.resume_generation + 1
  for dbg.resume_generation < target && !dbg.stop {
    sync.cond_wait(&dbg.cond, &dbg.mu)
  }
  aborting := dbg.stop
  sync.mutex_unlock(&dbg.mu)

  if aborting {
    ret_val^ = nil
    ret_ok^ = false
  }
}

// Whether this task stops at this node, and why. Called with `mu` held.
//
// The order matters: a failure and a breakpoint are worth reporting even
// mid-step, and a step that has not reached its depth yet is not a stop at
// all.
@(private = "file")
stop_reason_locked :: proc(dbg: ^Debugger_Run, interp: ^Interpreter, node: Node_Idx, ok: bool) -> (reason: string, stop: bool) {
  // A node that failed is where a person wants to be looking, whatever mode
  // the run is in - the DAP equivalent of an uncaught exception, which in
  // this language means any failure at all (§8: they are all fatal).
  if !ok do return "exception", true

  if len(dbg.breakpoints) > 0 {
    line := line_of_offset(dbg.lines, dbg.ast.nodes[node].span.start)
    if line in dbg.breakpoints do return "breakpoint", true
  }

  switch dbg.mode {
  case .Running:
    return "", false
  case .Stop_Next:
    return "step", true
  case .Step_Over:
    // Only this task's own depth is meaningful: another task's stack has
    // nothing to do with the call we are stepping over.
    if interp.thread_id != dbg.depth_thread do return "", false
    if len(interp.frames) > dbg.depth_target do return "", false
    return "step", true
  case .Step_Out:
    if interp.thread_id != dbg.depth_thread do return "", false
    if len(interp.frames) >= dbg.depth_target do return "", false
    return "step", true
  }
  return "", false
}

// The stopped task's frames, copied while it is parked. Its own `frames` keeps
// moving the moment it resumes, and the adapter answers `stackTrace` after
// that has already started happening.
@(private = "file")
slice_clone_frames :: proc(frames: []Debug_Frame) -> []Debug_Frame {
  out := make([]Debug_Frame, len(frames))
  copy(out, frames)
  return out
}

// Registers an async task's handle with the run it's being debugged under -
// called from spawn_async (eval_async.odin) whenever the spawning
// Interpreter has a debugger attached, so stop_debugger_run can find and
// join it later regardless of whether the program's own logic ever awaits
// it first.
register_debugger_task :: proc(dbg: ^Debugger_Run, h: ^Async_Handle) {
  sync.mutex_lock(&dbg.mu)
  append(&dbg.spawned_handles, h)
  sync.mutex_unlock(&dbg.mu)
}

// The next task id, as DAP names threads: the program itself is 1 and each
// `async` task takes the next number, in spawn order. Handed out *before* the
// thread is spawned - it starts evaluating, and hitting the gate, the instant
// task_spawn returns, and a task with no id could not be told apart there.
debugger_next_thread_id_or_zero :: proc(dbg: ^Debugger_Run) -> int {
  if dbg == nil do return 0 // no debugger attached: nothing names threads
  return debugger_next_thread_id(dbg)
}

@(private = "file")
debugger_next_thread_id :: proc(dbg: ^Debugger_Run) -> int {
  sync.mutex_lock(&dbg.mu)
  dbg.next_thread_id += 1
  id := dbg.next_thread_id
  sync.mutex_unlock(&dbg.mu)
  return id
}

@(private = "file")
debugger_thread_proc :: proc(data: rawptr) {
  dbg := (^Debugger_Run)(data)
  env := make_global_env()
  // Remembered so a variables pane can stop walking the scope chain here:
  // the builtins are always in scope and are never what someone is looking
  // for among a program's own names (dap.odin).
  sync.mutex_lock(&dbg.mu)
  dbg.global_env = env
  sync.mutex_unlock(&dbg.mu)
  val, ok := eval(&dbg.interp, dbg.ast.root, env)
  // A program whose top-level result is itself `async <expr>` (or ends in
  // one via a taken branch) returns the raw, un-awaited handle from eval()
  // - same as main.odin's real run, which awaits the final value before
  // printing it. Do the same here so a fully-stepped run settles on the
  // actual result instead of visibly dangling on "<async: pending>".
  if ok do val, ok = await_value(&dbg.interp, val)
  sync.mutex_lock(&dbg.mu)
  dbg.finished = true
  dbg.final_value = val
  dbg.final_ok = ok
  sync.mutex_unlock(&dbg.mu)
  // Settling is either "stopped somewhere" or "finished", and a waiter blocks
  // on this one semaphore for both. Without this post, a `continue` over a
  // program that simply runs to the end would wait for a stop that is never
  // coming.
  sync.sema_post(&dbg.stopped_sema)
}

// Starts a fresh debugger run over `src_owned` (which the run takes ownership
// of) and returns as soon as it has stopped for the first time - at the first
// node it finishes, with reason "entry". Returns nil if the source doesn't
// parse, or if this target cannot spawn a thread.
//
// `name` is what a stack trace calls the source, which for a real session is
// the path the client asked to launch.
start_debugger_run :: proc(name: string, src_owned: string, dirs: Root_Dirs) -> ^Debugger_Run {
  dbg := new(Debugger_Run)
  dbg.src = src_owned
  dbg.source_name = strings.clone(name)
  dbg.ast = parse(source_t{name = "debug", n_bytes = u64(len(dbg.src)), data = raw_data(dbg.src)}, ast_t{})
  if len(dbg.ast.errors) > 0 {
    ast_destroy(&dbg.ast)
    delete(dbg.source_name)
    delete(dbg.src)
    free(dbg)
    return nil
  }
  dbg.lines = line_index_make(dbg.src)
  dbg.next_thread_id = 1
  // Stop at the very first node, so a session has somewhere to stand before
  // the client has told it anything: `setBreakpoints` and the first
  // `continue` both arrive after `launch`, and a run that had already
  // finished by then would have nothing left to debug.
  dbg.mode = .Stop_Next

  dbg.interp = Interpreter{
    ast         = &dbg.ast,
    src         = dbg.src,
    current_ctx = make_root_context(dirs),
    debugger    = dbg,
    thread_id   = 1,
  }

  // The run evaluates on its own thread so the adapter can answer requests
  // while it sits paused mid-expression. A target without threads (the
  // portable WASI build - see task.odin) therefore has no debugger at all:
  // report that by returning nil rather than trapping inside the runtime.
  spawned: bool
  dbg.task, spawned = task_spawn(debugger_thread_proc, dbg)
  if !spawned {
    line_index_destroy(dbg.lines)
    ast_destroy(&dbg.ast)
    delete(dbg.source_name)
    delete(dbg.src)
    free(dbg)
    return nil
  }
  debugger_wait_until_settled(dbg)
  return dbg
}

// Blocks until the run is either stopped somewhere or finished - the two
// states in which it is safe to answer a client's questions about it. Every
// resume is followed by one of these, which is what keeps the adapter from
// reporting a stack that a running thread is still rewriting.
debugger_wait_until_settled :: proc(dbg: ^Debugger_Run) {
  for {
    sync.mutex_lock(&dbg.mu)
    settled := dbg.is_stopped || dbg.finished
    sync.mutex_unlock(&dbg.mu)
    if settled do return
    sync.sema_wait(&dbg.stopped_sema)
  }
}

// Lets a stopped run go again in `mode`. `depth_target`/`depth_thread` matter
// only for Step_Over and Step_Out, which are defined against one task's call
// depth (see stop_reason_locked). Safe to call on a run that has finished.
debugger_resume :: proc(dbg: ^Debugger_Run, mode: Debug_Mode, depth_target := 0, depth_thread := 0) {
  if dbg == nil do return
  sync.mutex_lock(&dbg.mu)
  free_stop_info(&dbg.stop_info)
  dbg.is_stopped = false
  dbg.mode = mode
  dbg.depth_target = depth_target
  dbg.depth_thread = depth_thread
  dbg.resume_generation += 1
  sync.mutex_unlock(&dbg.mu)
  sync.cond_broadcast(&dbg.cond)
}

@(private = "file")
free_stop_info :: proc(info: ^Debug_Stop) {
  delete(info.frames)
  delete(info.error_message)
  info^ = {}
}

// Replaces the breakpoint set. Lines are 1-based; the answer says which of
// them a node actually starts on, since DAP wants each breakpoint marked
// verified or not rather than silently accepting a line nothing runs at.
debugger_set_breakpoints :: proc(dbg: ^Debugger_Run, lines: []int, allocator := context.allocator) -> []bool {
  verified := make([]bool, len(lines), allocator)
  sync.mutex_lock(&dbg.mu)
  clear(&dbg.breakpoints)
  for line, i in lines {
    dbg.breakpoints[line] = true
    verified[i] = line_has_a_node(dbg, line)
  }
  sync.mutex_unlock(&dbg.mu)
  return verified
}

// Whether any node starts on this line - "is there anything here to stop at".
// A linear scan of the tree, which is fine: it runs once per setBreakpoints
// request, not per node evaluated.
@(private = "file")
line_has_a_node :: proc(dbg: ^Debugger_Run, line: int) -> bool {
  for n in dbg.ast.nodes {
    if line_of_offset(dbg.lines, n.span.start) == line do return true
  }
  return false
}

// Tells every task in a run to abort (if it hasn't finished already), waits
// for all of their threads to actually exit, then frees everything the run
// owns. Safe to call with nil.
stop_debugger_run :: proc(dbg: ^Debugger_Run) {
  if dbg == nil do return

  sync.mutex_lock(&dbg.mu)
  dbg.stop = true
  sync.mutex_unlock(&dbg.mu)
  sync.cond_broadcast(&dbg.cond) // wake every task paused in cond_wait, not just one
  task_join(dbg.task)

  // Join every async task this run ever spawned. A task that was mid-flight
  // (between waking up and reaching its own next pause point, or about to
  // spawn a further async) could still register a new handle after the
  // broadcast above - so drain until a full pass registers nothing new.
  joined := 0
  for {
    sync.mutex_lock(&dbg.mu)
    to_join := make([]^Async_Handle, len(dbg.spawned_handles) - joined, context.temp_allocator)
    copy(to_join, dbg.spawned_handles[joined:])
    joined = len(dbg.spawned_handles)
    sync.mutex_unlock(&dbg.mu)
    if len(to_join) == 0 do break
    for h in to_join {
      // Async_Handle's own `awaited` flag/mutex (eval_async.odin) makes this
      // safe even if the program's own logic already awaited it normally -
      // never double-join the same underlying thread.
      sync.mutex_lock(&h.mu)
      if !h.awaited {
        task_join(h.task)
        h.awaited = true
      }
      sync.mutex_unlock(&h.mu)
    }
  }
  delete(dbg.spawned_handles)

  free_stop_info(&dbg.stop_info)
  delete(dbg.breakpoints)
  line_index_destroy(dbg.lines)
  ast_destroy(&dbg.ast)
  delete(dbg.source_name)
  delete(dbg.src)
  free(dbg)
}


