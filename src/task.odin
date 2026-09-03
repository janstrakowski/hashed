package hashed

// The one threading primitive §2's `async` needs: start a procedure on
// another thread, and later wait for it. Named here, implemented per target
// (task_linux.odin, task_wasi.odin) for the same reason the filesystem is -
// eval_async.odin shouldn't know which world it is in.
//
// Deliberately smaller than core:thread. No priorities, no names, no
// detaching, no cancellation: `async` fires a task and later awaits exactly
// once, and anything beyond that would be API nobody calls.
//
// Each target provides:
//
//   Task                         a handle to a running task
//   task_spawn(fn, data) -> ok   start it; false means the target can't
//   task_join(task)              wait for it to finish
//
// On WASI a spawn can genuinely fail (the host may not implement
// wasi-threads at all), which is why spawning reports success rather than
// assuming it - see task_wasi.odin.

Task_Proc :: proc(data: rawptr)
