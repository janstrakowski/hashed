package hashedbuild

import "core:sync"
import "core:thread"
import "core:strings"

// A genuinely pausable/resumable evaluation, backing the live editor's
// interactive debugger panel. Unlike a pre-computed trace revealed
// incrementally, an AST node this run hasn't reached truly hasn't been
// evaluated yet - every evaluating thread blocks inside
// `debugger_wait_and_publish` (called from `eval`'s own defer, see eval.odin)
// after finishing a node, until `debugger_step` releases *all* currently-
// blocked threads at once for exactly one more node each.
//
// This is also what makes `async` (§2, eval_async.odin) visible: a spawned
// async task gets the *same* `Debugger_Run` propagated into its own
// Interpreter, so its steps land in the same shared, single-tree `log` as
// the main task's - one Ctrl+N advances every currently-paused task by one
// step, in lockstep, rather than debugging only the main thread and running
// every async task to completion unobserved.
//
// Own AST/source, kept alive for as long as any of this run's threads might
// still touch them - the editor reparses on every keystroke for its other
// panels, but this run's tree must stay put across however many redraws
// happen while it's paused mid-evaluation.
Debugger_Run :: struct {
  ast:    ast_t,
  src:    string, // owned - also every task's source buffer
  interp: Interpreter, // the main/root task
  th:     ^thread.Thread, // the main/root task's thread

  // Everything below is touched by every task's thread plus whichever thread
  // renders the panel - guarded by `mu`, except `step_generation`'s reads
  // inside `cond_wait`'s predicate (also under `mu` by construction).
  mu:              sync.Mutex,
  cond:            sync.Cond, // broadcast-woken: releases *every* paused task at once, not just one
  step_generation: int,       // incremented once per debugger_step call
  ready_sema:      sync.Sema, // posted once, the moment the main task's first pending entry appears
  stop:            bool,      // tells every task to abort at its next opportunity
  log:             [dynamic]Debug_Step,
  finished:        bool, // the main/root task has returned (async tasks may briefly outlive it - see stop_debugger_run)
  final_value:     Value,
  final_ok:        bool,

  // Nodes some task's `eval` call is *currently* blocked on - i.e. whichever
  // node(s) the next debugger_step will actually complete. A plain count
  // (not a bool) since, with async, more than one task could genuinely be
  // paused on the very same AST node (e.g. a function called from two
  // concurrent tasks). Keyed entries are exactly what render as "next up"/▶.
  pending: map[Node_Idx]int,

  // Nodes whose `async` handle some task is *currently* blocked awaiting
  // (inside await_value's thread.join - see eval_async.odin) - overlaid on
  // top of `pending` in the panel as "⏳" to distinguish "about to evaluate"
  // from "already evaluated its operands, now specifically waiting on one
  // of them to resolve".
  awaiting: map[Node_Idx]int,

  // Every async task spawned anywhere during this run, so stop_debugger_run
  // can join all of them (not just the root) before freeing anything they
  // might still be touching. Tracking the handle (not the raw thread) lets
  // cleanup reuse Async_Handle's own `awaited` flag to avoid double-joining
  // one the program's own logic already awaited normally.
  spawned_handles: [dynamic]^Async_Handle,
}

// One evaluation step as published to a live run - a snapshot, not a live
// reference, since it's read from a different thread than the one that
// produced it (always under `Debugger_Run.mu`, which gives the necessary
// happens-before edge for the Value/string it carries).
Debug_Step :: struct {
  node:          Node_Idx,
  generation:    int,  // which debugger_step wave produced this - lets the panel group/highlight "just cut"
  discarded:     bool, // evaluated only because §2 requires walking an untaken then/else or and/or side
  ok:            bool,
  value:         Value,
  error_message: string, // owned; only set when !ok
}

// Called from `eval`'s defer (see eval.odin), once per node, after that
// node's result is already computed but before `eval` hands it back to its
// caller. Blocks the calling thread - whichever task it belongs to, main or
// async - until a debugger_step call bumps the step generation, then either
// lets the result through unchanged or - if the run has been told to stop -
// overwrites it with a failure so the abort propagates upward through the
// evaluator's existing recursive !ok short-circuiting, the same way any
// other runtime error already does.
debugger_wait_and_publish :: proc(interp: ^Interpreter, node: Node_Idx, ret_val: ^Value, ret_ok: ^bool) {
  dbg := interp.debugger

  sync.mutex_lock(&dbg.mu)
  if dbg.stop {
    sync.mutex_unlock(&dbg.mu)
    ret_val^ = nil
    ret_ok^ = false
    return
  }

  first_pending := len(dbg.pending) == 0
  dbg.pending[node] += 1
  // Wakes start_debugger_run's wait below the first time this becomes
  // non-empty, so a freshly-started run's very first render is guaranteed to
  // already see a pending node - otherwise the panel could render before any
  // thread got scheduled at all, showing no "next up" even though one
  // genuinely exists already.
  if first_pending {
    sync.mutex_unlock(&dbg.mu)
    sync.sema_post(&dbg.ready_sema)
    sync.mutex_lock(&dbg.mu)
  }

  target := dbg.step_generation + 1
  for dbg.step_generation < target && !dbg.stop {
    sync.cond_wait(&dbg.cond, &dbg.mu)
  }

  dbg.pending[node] -= 1
  if dbg.pending[node] <= 0 do delete_key(&dbg.pending, node)

  stopped := dbg.stop
  if !stopped {
    step := Debug_Step{
      node       = node,
      generation = dbg.step_generation,
      discarded  = interp.discard_depth > 0,
      ok         = ret_ok^,
      value      = ret_val^,
    }
    if !ret_ok^ do step.error_message = strings.clone(interp.error_message)
    append(&dbg.log, step)
  }
  sync.mutex_unlock(&dbg.mu)

  if stopped {
    ret_val^ = nil
    ret_ok^ = false
  }
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

// Marks (or unmarks) that some task is currently blocked inside
// await_value's thread.join, waiting on the async handle `body` (the
// Async_Expr's wrapped-expression node) originally spawned from - called
// from eval_async.odin. Purely cosmetic bookkeeping for the panel; safe to
// call with a nil debugger (checked by the caller).
mark_awaiting :: proc(dbg: ^Debugger_Run, node: Node_Idx, awaiting: bool) {
  sync.mutex_lock(&dbg.mu)
  if awaiting {
    dbg.awaiting[node] += 1
  } else {
    dbg.awaiting[node] -= 1
    if dbg.awaiting[node] <= 0 do delete_key(&dbg.awaiting, node)
  }
  sync.mutex_unlock(&dbg.mu)
}

@(private = "file")
debugger_thread_proc :: proc(t: ^thread.Thread) {
  dbg := cast(^Debugger_Run)t.data
  env := make_global_env()
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
}

// Starts a fresh, paused debugger run over `src_owned` (which the run takes
// ownership of) - nothing evaluates until `debugger_step` is called. Returns
// nil if the source doesn't parse; the caller should show a placeholder and
// try again once it does.
start_debugger_run :: proc(src_owned: string, current_path: string, cache_dir: string) -> ^Debugger_Run {
  dbg := new(Debugger_Run)
  dbg.src = src_owned
  dbg.ast = parse(source_t{name = "debug", n_bytes = u64(len(dbg.src)), data = raw_data(dbg.src)}, ast_t{})
  if len(dbg.ast.errors) > 0 {
    ast_destroy(&dbg.ast)
    delete(dbg.src)
    free(dbg)
    return nil
  }

  dbg.interp = Interpreter{
    ast         = &dbg.ast,
    src         = dbg.src,
    current_ctx = make_root_context(cache_dir),
    debugger    = dbg,
  }
  setup_interp_base_dir(&dbg.interp, current_path)

  dbg.th = thread.create(debugger_thread_proc)
  dbg.th.data = dbg
  thread.start(dbg.th)
  sync.sema_wait(&dbg.ready_sema) // block until the first node's pending state is actually visible
  return dbg
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
  thread.join(dbg.th)
  thread.destroy(dbg.th)

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

  for step in dbg.log do delete(step.error_message)
  delete(dbg.log)
  delete(dbg.pending)
  delete(dbg.awaiting)
  ast_destroy(&dbg.ast)
  delete(dbg.src)
  free(dbg)
}

// Lets every currently-paused task in a run proceed exactly one more step,
// in lockstep. Safe to call with nil, or after the run has already finished
// (the broadcast then just wakes nobody).
debugger_step :: proc(dbg: ^Debugger_Run) {
  if dbg == nil do return
  sync.mutex_lock(&dbg.mu)
  dbg.step_generation += 1
  sync.mutex_unlock(&dbg.mu)
  sync.cond_broadcast(&dbg.cond)
}
