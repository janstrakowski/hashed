package hashedbuild

import "core:thread"

// The native half of task.odin: core:thread, with the callback shape
// flattened to (proc, data) so callers don't carry a ^thread.Thread around.

@(private = "file")
Task_State :: struct {
  th:   ^thread.Thread,
  fn:   Task_Proc,
  data: rawptr,
}

Task :: ^Task_State

// Native builds always have threads.
TASKS_SUPPORTED :: true

@(private = "file")
task_trampoline :: proc(t: ^thread.Thread) {
  state := (^Task_State)(t.data)
  state.fn(state.data)
  // Nothing is freed here on purpose. A spawned thread gets its own context,
  // so freeing this block from inside it hands the pointer to a different
  // allocator than the one that produced it - which aborts with "free():
  // invalid pointer". Cleanup belongs to task_join, on the side that
  // allocated.
}

task_spawn :: proc(fn: Task_Proc, data: rawptr) -> (Task, bool) {
  state := new(Task_State)
  state.fn = fn
  state.data = data

  state.th = thread.create(task_trampoline)
  if state.th == nil {
    free(state)
    return nil, false
  }
  state.th.data = state
  thread.start(state.th)
  return state, true
}

task_join :: proc(task: Task) {
  if task == nil do return
  thread.join(task.th)
  thread.destroy(task.th)
  free(task)
}
