// One instance of the interpreter. Two roles, same file, because wasi-threads
// makes them the same thing: a fresh instance of the same module against the
// same shared memory, differing only in which export the host calls.
//
//   role "main"    calls _start - the program itself.
//   role "thread"  calls wasi_thread_start(tid, start_arg) - a thread the
//                  program spawned, per the wasi-threads proposal.
//
// Neither role owns the filesystem. Both marshal their WASI calls to the
// terminal worker, which does own it (see wasi.js's remoteImports) - except
// stdin, which the caller must block on itself, and proc_exit, which ends this
// instance rather than returning anything.

import { ExitSignal, RPC, remoteImports } from "./wasi.js";

const STATE_EMPTY = 0, STATE_DATA = 1, STATE_EOF = 2;

let memory = null;
let channel = null;      // this thread's RPC control block
let stdinControl = null; // shared with the page: typed input
let stdinBytes = null;
let pending = null;      // read but not yet consumed

const post = (message) => self.postMessage(message);

// Blocks until the page hands over input, exactly as a terminal read does.
// Only the program's own thread ever reads stdin.
function readStdin(iovsPtr) {
  const view = new DataView(memory.buffer);
  const bufPtr = view.getUint32(iovsPtr, true);
  const wanted = view.getUint32(iovsPtr + 4, true);

  if (!pending || pending.length === 0) {
    post({ type: "waiting-for-input" });
    while (Atomics.load(stdinControl, 0) === STATE_EMPTY) {
      Atomics.wait(stdinControl, 0, STATE_EMPTY);
    }
    if (Atomics.load(stdinControl, 0) === STATE_EOF) {
      Atomics.store(stdinControl, 0, STATE_EMPTY);
      return { bytes: 0 };
    }
    const length = Atomics.load(stdinControl, 1);
    pending = stdinBytes.slice(0, length);
    Atomics.store(stdinControl, 0, STATE_EMPTY);
    Atomics.notify(stdinControl, 0);
  }

  const chunk = pending.subarray(0, wanted);
  pending = pending.subarray(chunk.length);
  new Uint8Array(memory.buffer).set(chunk, bufPtr);
  return { bytes: chunk.length };
}

self.onmessage = async (event) => {
 try {
  const { role, module, sharedMemory, rpc, stdin, tid, startArg } = event.data;
  memory = sharedMemory;
  channel = new Int32Array(rpc);
  if (stdin) {
    stdinControl = new Int32Array(stdin.control);
    stdinBytes = new Uint8Array(stdin.bytes);
  }

  const wasi_snapshot_preview1 = remoteImports({
    channel,
    notify: () => post({ type: "rpc" }),
    localHandlers: {
      // Only stdin, and only when this instance has one - a spawned thread
      // has no terminal to read from.
      fd_read: (fd, iovsPtr, iovsLen, readPtr) => {
        if (fd !== 0 || !stdinControl) return undefined; // not ours: marshal it
        const { bytes } = readStdin(iovsPtr);
        new DataView(memory.buffer).setUint32(readPtr, bytes, true);
        return 0;
      },
    },
  });

  // proc_exit is a throw, not a call: it ends this instance where it stands.
  wasi_snapshot_preview1.proc_exit = (code) => { throw new ExitSignal(code); };

  const instance = await WebAssembly.instantiate(module, {
    env: { memory },
    wasi_snapshot_preview1,
    // The whole of wasi-threads' guest-facing API. Spawning is the host's job,
    // so it goes back to the terminal worker, which starts another one of
    // these in the "thread" role.
    wasi: {
      "thread-spawn": (startArgPtr) => {
        Atomics.store(channel, RPC.OPCODE, -1); // -1: spawn, not a WASI call
        Atomics.store(channel, RPC.ARGS, startArgPtr | 0);
        Atomics.store(channel, RPC.STATE, RPC.PENDING);
        post({ type: "rpc" });
        while (Atomics.load(channel, RPC.STATE) !== RPC.DONE) {
          Atomics.wait(channel, RPC.STATE, RPC.PENDING);
        }
        Atomics.store(channel, RPC.STATE, RPC.IDLE);
        return Atomics.load(channel, RPC.RESULT); // the tid, or negative
      },
    },
  });

  let code = 0;
  try {
    if (role === "thread") instance.exports.wasi_thread_start(tid, startArg);
    else instance.exports._start();
  } catch (err) {
    if (err instanceof ExitSignal) code = err.code;
    else {
      post({ type: "trapped", message: String(err && err.message || err) });
      code = -1;
    }
  }
  post({ type: "exited", role, code });
 } catch (err) {
  // Anything before or around the run - a failed instantiation, most likely -
  // would otherwise be an unhandled rejection in a worker: invisible, and the
  // caller waits forever.
  post({ type: "trapped", message: String(err && err.stack || err) });
  post({ type: "exited", role: event.data.role, code: -1 });
 }
};
