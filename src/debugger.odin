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
// **Every node has two stop points, Enter and Exit.** The gate runs on the
// way in to a node, before any of it has happened, and again on the way out,
// once its value exists. So a stop is either "this is about to be evaluated"
// or "this just produced this value", and a client can tell which.
//
// Both are needed, and neither on its own is enough. Exit is where the value
// is: in a language with no statements and no intermediate variables, the
// value of `filetext (loadfile ...)` has no name, and the only way to see it
// without re-running the effect is to be stopped just after it. Enter is
// where an effect can still be *stopped* - a `writefile` whose arguments are
// all evaluated has nothing between it and the disk except its own Enter,
// which is what makes "break here before it happens" expressible at all.
//
// A **breakpoint fires at Enter**, which is what every other debugger means
// by stopping on a line. `Step_Over` from there runs the whole node and stops
// at its Exit, so the value of the line you broke on is one keystroke away.
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
// Which side of a node a stop is on. See the header: Enter has no value yet,
// Exit has one.
Debug_Phase :: enum {
  Enter,
  Exit,
}

Debug_Mode :: enum {
  Stop_Next,  // stop at the very next node any task finishes - DAP's stepIn
  Step_Over,  // ... but not one inside a deeper call than `depth_target`
  Step_Out,   // ... only once we are shallower than `depth_target`
  Running,    // do not stop at all, except at a breakpoint
}

// One user-level call on a task's stack, pushed by call_function (eval.odin).
// The debugger reports these as DAP stack frames, innermost last.
// One breakpoint line a task is currently inside, and the node that opened
// it - see the breakpoint section below.
Bp_Open :: struct {
  line: int,
  node: Node_Idx,
}

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
  phase:     Debug_Phase, // Enter: nothing of this node has run yet, and `value` is nothing
  nest_depth: int,        // this node's depth in the evaluation, for Step_Over
  value:     Value,
  ok:        bool,
  env:       ^Env,           // the environment that node finished in - the variables pane
  interp:    ^Interpreter,   // the stopped task itself, borrowed - it is parked, so its state holds still
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
  depth_target:    int, // call frames: what Step_Out measures against
  nest_target:     int, // evaluation depth: what Step_Over measures against, so it skips a whole subtree
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

  // Lines some evaluated expression begins on - the lines a breakpoint can be
  // set on at all. Computed once, the first time anything asks
  // (line_starts_an_expression).
  bp_startable: map[int]bool,
  bp_startable_built: bool,

  // Nodes the evaluator never runs - an operator token, a name in binding
  // position - computed once, the first time a breakpoint needs to know
  // (is_evaluated_node). A breakpoint on one of those would be reported
  // verified and then never fire.
  syntax_only: map[Node_Idx]bool,

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
// caller.
debugger_gate :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env, ret_val: ^Value, ret_ok: ^bool) {
  debugger_gate_at(interp, .Exit, node, env, ret_val, ret_ok)
}

// Called from `eval` on the way *in*, before the node has done anything at
// all - which is the only moment an effect it is about to perform can still
// be caught. Returns false when the run is being aborted, and the caller must
// then fail without evaluating.
debugger_gate_enter :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> bool {
  val: Value = nil
  ok := true
  debugger_gate_at(interp, .Enter, node, env, &val, &ok)
  return ok
}

// Decides whether this run stops at this point and, if so, blocks the calling
// thread until the adapter resumes it.
//
// A task that does *not* itself decide to stop still parks whenever another
// task already has - that is what "all threads stop together" means - and
// wakes on the same resume. Either way, if the run has been told to abort,
// the node's result is overwritten with a failure so the abort propagates
// upward through the evaluator's existing recursive !ok short-circuiting,
// exactly the way any other runtime error already does.
@(private = "file")
debugger_gate_at :: proc(
  interp: ^Interpreter, phase: Debug_Phase, node: Node_Idx, env: ^Env, ret_val: ^Value, ret_ok: ^bool,
) {
  dbg := interp.debugger

  sync.mutex_lock(&dbg.mu)
  if dbg.stop {
    sync.mutex_unlock(&dbg.mu)
    ret_val^ = nil
    ret_ok^ = false
    return
  }

  reason, mine := stop_reason_locked(dbg, interp, phase, node, ret_ok^)
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
      thread_id  = interp.thread_id,
      node       = node,
      phase      = phase,
      nest_depth = interp.nest_depth,
      interp     = interp,
      value      = ret_val^,
      ok         = ret_ok^,
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
stop_reason_locked :: proc(
  dbg: ^Debugger_Run, interp: ^Interpreter, phase: Debug_Phase, node: Node_Idx, ok: bool,
) -> (reason: string, stop: bool) {
  // A node that failed is where a person wants to be looking, whatever mode
  // the run is in - the DAP equivalent of an uncaught exception, which in
  // this language means any failure at all (§8: they are all fatal). Only on
  // the way out: on the way in nothing has happened yet, and `ok` there is
  // not a result but the run's own abort flag.
  if phase == .Exit && !ok do return "exception", true

  if len(dbg.breakpoints) > 0 && breakpoint_fires(dbg, interp, phase, node) do return "breakpoint", true

  switch dbg.mode {
  case .Running:
    return "", false
  case .Stop_Next:
    return "step", true
  case .Step_Over:
    // Only this task's own depths are meaningful: another task's stack has
    // nothing to do with the expression we are stepping over.
    if interp.thread_id != dbg.depth_thread do return "", false
    // Measured in evaluation depth rather than call frames, so this skips a
    // whole sub-expression and not merely a whole call: from a node's Enter
    // it lands on that same node's Exit, having run everything in between.
    if interp.nest_depth > dbg.nest_target do return "", false
    return "step", true
  case .Step_Out:
    // Call frames, because this one is DAP's "run until the function returns".
    if interp.thread_id != dbg.depth_thread do return "", false
    if len(interp.frames) >= dbg.depth_target do return "", false
    return "step", true
  }
  return "", false
}

// ---- breakpoints ---------------------------------------------------------------
//
// A breakpoint is a *line*, and a line holds many expressions - `7 / 2` on a
// line of a Table literal is inside an entry, inside the Table, inside the
// program. Stopping at each would fire one breakpoint eight times.
//
// So a line fires once per visit: at the Enter of the first expression the
// evaluator actually reaches that begins on that line, and not again until
// that expression is done. Since Enter runs outermost-first, "the first one
// reached" is the outermost - without anyone having to work out in advance
// which node that is.
//
// That last part is the point, and it is why this does not simply pick a node
// when the breakpoint is set. Which nodes the evaluator visits is a fact
// about `eval`, not about the tree: a Table_Entry is a node, and `eval` is
// never called on one - it reads the key and evaluates the value. A rule that
// picked the widest node on the line picked the entry, reported the
// breakpoint verified, and then never fired it. Reaching a node is the only
// answer that cannot go stale as the evaluator changes.
//
// Nesting is tracked per task, in `interp.bp_open`: a breakpoint line inside
// a function called from another breakpoint line has to open and close within
// it, and two `async` tasks can be inside the same line at once.
@(private = "file")
breakpoint_fires :: proc(dbg: ^Debugger_Run, interp: ^Interpreter, phase: Debug_Phase, node: Node_Idx) -> bool {
  if phase == .Exit {
    // Closing whatever this node opened, so the next visit fires again.
    n := len(interp.bp_open)
    if n > 0 && interp.bp_open[n - 1].node == node do pop(&interp.bp_open)
    return false
  }

  line := node_start_line(dbg, node)
  if !(line in dbg.breakpoints) do return false
  if !is_evaluated_node(dbg, node) do return false

  // Already inside this line: an inner expression of a line that has already
  // stopped is not a second visit.
  n := len(interp.bp_open)
  if n > 0 && interp.bp_open[n - 1].line == line do return false

  append(&interp.bp_open, Bp_Open{line = line, node = node})
  return true
}

// The line an expression starts on. A node that spans several lines belongs
// to the first of them, so a breakpoint on the `{` of a Table literal is a
// breakpoint on the Table.
node_start_line :: proc(dbg: ^Debugger_Run, node: Node_Idx) -> int {
  return line_of_offset(dbg.lines, dbg.ast.nodes[node].span.start)
}

// Whether a breakpoint on this line can ever fire: whether any expression the
// evaluator runs begins there. A comment, a blank line or a lone `}` has none,
// and the adapter reports those unverified rather than letting a client show a
// breakpoint that will never happen.
@(private = "file")
line_starts_an_expression :: proc(dbg: ^Debugger_Run, line: int) -> bool {
  if !dbg.bp_startable_built {
    dbg.bp_startable_built = true
    for _, i in dbg.ast.nodes {
      idx := Node_Idx(i)
      if !is_evaluated_node(dbg, idx) do continue
      dbg.bp_startable[node_start_line(dbg, idx)] = true
    }
  }
  return line in dbg.bp_startable
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

// Is the run parked on a node that a breakpoint now names?
//
// Asked once, when a session finishes configuring. A run parks at the first
// node it *completes*, and for a program beginning `let a 2;` that node is
// the `2` - so a breakpoint on that line, set while the run was parked there,
// would never fire: its gate has already run and will not run again. Reporting
// it as a breakpoint hit instead is both true and what anyone would expect.
// A run parks at its first node the moment it launches, before a client has
// sent any breakpoints - so if one then lands on the line that node begins,
// the run is already exactly where it asked to stop, and that node will never
// be reached again. This turns the stop it already made into that breakpoint's
// hit, rather than reporting a step and stopping a second time.
//
// It *claims* the line as well as relabelling it: the parked task never went
// through `breakpoint_fires` for this node, because there were no breakpoints
// when it stopped, so without this every expression inside the node would fire
// the same breakpoint over again.
debugger_claim_breakpoint_stop :: proc(dbg: ^Debugger_Run) -> bool {
  if dbg == nil do return false
  sync.mutex_lock(&dbg.mu)
  defer sync.mutex_unlock(&dbg.mu)
  if !dbg.is_stopped do return false
  // Enter only: a breakpoint fires on the way in, so a run parked on a node's
  // Exit is already past it.
  if dbg.stop_info.phase != .Enter do return false
  line := node_start_line(dbg, dbg.stop_info.node)
  if !(line in dbg.breakpoints) do return false

  dbg.stop_info.reason = "breakpoint"
  if dbg.stop_info.interp != nil {
    append(&dbg.stop_info.interp.bp_open, Bp_Open{line = line, node = dbg.stop_info.node})
  }
  return true
}


// Lets a stopped run go again in `mode`. `depth_target`/`depth_thread` matter
// only for Step_Over and Step_Out, which are defined against one task's call
// depth (see stop_reason_locked). Safe to call on a run that has finished.
debugger_resume :: proc(
  dbg: ^Debugger_Run, mode: Debug_Mode, depth_target := 0, nest_target := 0, depth_thread := 0,
) {
  if dbg == nil do return
  sync.mutex_lock(&dbg.mu)
  free_stop_info(&dbg.stop_info)
  dbg.is_stopped = false
  dbg.mode = mode
  dbg.depth_target = depth_target
  dbg.nest_target = nest_target
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

// Replaces the breakpoint set. Lines are 1-based, and the answer says which
// of them can ever fire, since DAP wants each breakpoint marked verified or
// not rather than silently accepting a line nothing runs at.
//
// Which node a line fires on is not decided here - see `breakpoint_fires`,
// which lets the run answer it by reaching one. All this needs to know is
// whether any expression *starts* on the line at all: a comment, a blank line
// and a closing brace have none.
debugger_set_breakpoints :: proc(dbg: ^Debugger_Run, lines: []int, allocator := context.allocator) -> []bool {
  verified := make([]bool, len(lines), allocator)
  sync.mutex_lock(&dbg.mu)
  clear(&dbg.breakpoints)
  for line, i in lines {
    dbg.breakpoints[line] = true
    verified[i] = line_starts_an_expression(dbg, line)
  }
  sync.mutex_unlock(&dbg.mu)
  return verified
}

// Whether `eval` ever runs on this node, or whether it is only ever read as
// syntax by whichever node encloses it.
//
// Rather than model every parent's child roles, this asks the question the
// other way round: a node is *not* evaluated if some parent uses that
// particular child slot as syntax. There are two such slots in the grammar -
// a Binary_Expr's operator and a Let_Bind's name - so the answer is a scan
// for those, cached once per run because it is the same answer every time.
@(private = "file")
is_evaluated_node :: proc(dbg: ^Debugger_Run, node: Node_Idx) -> bool {
  if dbg.syntax_only == nil {
    dbg.syntax_only = make(map[Node_Idx]bool)
    for n, i in dbg.ast.nodes {
      #partial switch n.kind {
      case .Binary_Expr:
        // [left, operator, right] - the operator is a token, not a value.
        dbg.syntax_only[dbg.ast.extra_children[n.children_start + 1]] = true
      case .Let_Bind:
        // [bound value, name, body] - the name is what is being bound, and is
        // never looked up (eval_let_bind reads its text).
        dbg.syntax_only[dbg.ast.extra_children[n.children_start + 1]] = true
      }
      _ = i
    }
  }
  return !(node in dbg.syntax_only)
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
  delete(dbg.bp_startable)
  delete(dbg.syntax_only)
  line_index_destroy(dbg.lines)
  ast_destroy(&dbg.ast)
  delete(dbg.source_name)
  delete(dbg.src)
  free(dbg)
}


