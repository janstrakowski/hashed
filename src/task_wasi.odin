package hashedbuild

import "base:intrinsics"
import "base:runtime"

// The WASI half of task.odin, on the wasi-threads proposal - which is one
// import and one export, with everything else left to the guest:
//
//   wasi.thread-spawn(start_arg) -> tid   the host starts an OS thread and
//                                         instantiates this module afresh on
//                                         it, then calls...
//   wasi_thread_start(tid, start_arg)     ...which lives in thread_start.s,
//                                         because it must set that
//                                         instance's __stack_pointer before
//                                         any Odin code runs, and Odin has
//                                         no way to touch that global.
//
// Only *linear memory* is shared between those instances. Odin package
// variables live there, so the heap and its allocator (thread-safe when the
// atomics feature is on - base/runtime/wasm_allocator.odin) are genuinely
// common, and so is every Value an async task builds. Wasm globals are not
// shared, which is exactly why the stack has to be handed over per thread.
//
// The whole thing is behind HB_WASI_THREADS because it cannot be built
// unconditionally: the atomics intrinsics below refuse to compile without
// -target-features:atomics, and a module importing wasi.thread-spawn is
// rejected outright by hosts that don't implement the proposal - wasmtime
// removed its support in June 2026. scripts/build_wasi.sh builds both
// flavours; without this flag, task_spawn reports failure and eval_async
// evaluates the body inline instead.
HB_WASI_THREADS :: #config(HB_WASI_THREADS, false)

// Passed to the host as an opaque pointer and read back by thread_start.s,
// which takes the stack top from offset 0 - so stack_top must stay first.
Wasi_Task :: struct {
  stack_top: u32,
  fn:        Task_Proc,
  data:      rawptr,
  done:      u32, // 0 while running; the join waits on this word
  stack:     []u8,
}

Task :: ^Wasi_Task

// Only the wasi-threads build can spawn. Anything that needs a thread - async
// (§2), and the debugger's paused run - has to say so rather than pretend.
TASKS_SUPPORTED :: HB_WASI_THREADS

when HB_WASI_THREADS {

  foreign import wasi_threads "wasi"

  @(default_calling_convention = "contextless")
  foreign wasi_threads {
    @(link_name = "thread-spawn")
    wasi_thread_spawn :: proc(start_arg: rawptr) -> i32 ---
  }

  // Each thread gets its own stack out of the shared heap. 1 MiB matches the
  // main stack the linker reserves.
  @(private = "file")
  TASK_STACK_SIZE :: 1024 * 1024

  // Called by thread_start.s on the new instance, once its stack pointer
  // points somewhere that instance owns.
  @(export)
  hb_thread_entry :: proc "c" (tid: i32, arg: rawptr) {
    context = runtime.default_context()
    task := (^Wasi_Task)(arg)
    task.fn(task.data)
    intrinsics.atomic_store(&task.done, 1)
    _ = intrinsics.wasm_memory_atomic_notify32(&task.done, 1)
  }

  task_spawn :: proc(fn: Task_Proc, data: rawptr) -> (Task, bool) {
    task := new(Wasi_Task)
    task.fn = fn
    task.data = data
    task.stack = make([]u8, TASK_STACK_SIZE)
    // Stacks grow downward, so the thread starts at the top of the block.
    task.stack_top = u32(uintptr(raw_data(task.stack))) + TASK_STACK_SIZE

    // A host that implements the import can still refuse - a thread limit,
    // usually (iwasm's --max-threads defaults to 4).
    if wasi_thread_spawn(task) < 0 {
      delete(task.stack)
      free(task)
      return nil, false
    }
    return task, true
  }

  // wasi-threads has no join of its own; waiting is the guest's problem,
  // built from the wasm threads primitives. This blocks on the done word
  // rather than spinning, and rechecks on every wake - wait32 also returns
  // when the value already moved, and can wake spuriously.
  task_join :: proc(task: Task) {
    if task == nil do return
    for intrinsics.atomic_load(&task.done) == 0 {
      _ = intrinsics.wasm_memory_atomic_wait32(&task.done, 0, -1) // -1: no timeout
    }
    delete(task.stack)
    free(task)
  }

} else {

  // The portable WASI build: no atomics, no thread-spawn import, so nothing
  // here can be spawned. Reporting failure is what makes eval_async run the
  // body inline instead.
  task_spawn :: proc(fn: Task_Proc, data: rawptr) -> (Task, bool) {
    return nil, false
  }

  task_join :: proc(task: Task) {}

}
