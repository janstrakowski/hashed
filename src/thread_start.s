# The guest half of wasi-threads: the host spawns a fresh instance of this
# module and calls wasi_thread_start(tid, start_arg) on it. Wasm globals are
# per-instance, so the new instance's __stack_pointer still holds the module's
# default - the main thread's stack. Every thread would scribble on the same
# region unless it is repointed here, before any Odin code runs.
#
# start_arg points at a struct whose first field is that thread's stack top.

.globaltype __stack_pointer, i32
.functype hb_thread_entry (i32, i32) -> ()

.globl wasi_thread_start
.type wasi_thread_start,@function
wasi_thread_start:
  .functype wasi_thread_start (i32, i32) -> ()
  local.get 1
  i32.load 0
  global.set __stack_pointer
  local.get 0
  local.get 1
  call hb_thread_entry
  end_function
