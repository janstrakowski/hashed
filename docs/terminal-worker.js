// The terminal's other half: it owns the filesystem, and it owns nothing else.
//
// The interpreter itself runs in exec-worker.js - one instance for the
// program, one more for every thread the program spawns (wasi-threads). They
// all share one WebAssembly.Memory created here, which is what lets a spawned
// thread see the heap its spawner allocated from, and they all marshal their
// WASI calls back to this worker, which executes them against the filesystem
// below. Every argument is a pointer into that shared memory, so nothing is
// copied across the boundary - see wasi.js's remoteImports.
//
// This worker must never block: it is the one answering those calls while the
// others sit in Atomics.wait. That is why the module moved out of it.
//
// SharedArrayBuffer is what all of this rests on, hence the page's
// cross-origin isolation (coi-serviceworker.js).

import { FileSystem, WASI, RPC, serveRemoteCall } from "./wasi.js";

const DB_NAME = "hashedbuild-playground";
const STORE = "state";

// Where ctx.cache (SPEC.md §9/§16) lands. resolve_cache_dir reads
// XDG_CACHE_HOME, so the content-addressed store ends up somewhere the
// visitor can actually look at.
const ENV = { XDG_CACHE_HOME: "/cache", HOME: "/", TERM: "dumb" };

let fs = null;
let stdinControl = null; // Int32Array: [0] = state, [1] = byte length
let stdinBytes = null;   // Uint8Array: the line the page last typed

const post = (message) => self.postMessage(message);

// ---- persistence ---------------------------------------------------------------

function openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function loadState() {
  try {
    const db = await openDb();
    return await new Promise((resolve, reject) => {
      const req = db.transaction(STORE, "readonly").objectStore(STORE).get("state");
      req.onsuccess = () => resolve(req.result ?? null);
      req.onerror = () => reject(req.error);
    });
  } catch {
    return null; // private window, blocked storage: start fresh, still works
  }
}

async function saveState(extra = {}) {
  try {
    const db = await openDb();
    const previous = (await loadState()) ?? {};
    await new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).put({ ...previous, ...extra, files: fs.snapshot() }, "state");
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  } catch {
    // Not being able to persist is survivable; the session still works.
  }
}

// ---- the starting filesystem: the repository, as if cloned ----------------------

async function seedFilesystem() {
  const manifest = await (await fetch("repo-files.json")).json();
  const seeded = new FileSystem();
  const enc = new TextEncoder();
  for (const [path, entry] of Object.entries(manifest.files)) {
    if (entry.type === "symlink") seeded.symlink("/" + path, entry.target);
    else seeded.writeFile("/" + path, enc.encode(entry.text));
  }
  // ctx.cache's directory, so it is visible from the start rather than
  // appearing out of nowhere the first time a program writes into it.
  seeded.mkdirp("/cache/hashedbuild");
  return seeded;
}

// ---- running a program ------------------------------------------------------

// A run is one program: a fresh shared memory (a heap is spent once the
// program exits), the main instance, and any threads it spawns. All of them
// talk to this worker over their own RPC channel.
let run = null;

function newChannel() {
  const buffer = new SharedArrayBuffer(RPC.WORDS * 4);
  return { buffer, view: new Int32Array(buffer) };
}

// One WASI instance per run, bound to that run's memory: the imports it
// exposes are what actually executes a marshalled call.
function makeServer(memory) {
  const wasi = new WASI({
    fs,
    args: run.args,
    env: run.env,
    onStdout: (text) => post({ type: "stdout", text }),
    onStderr: (text) => post({ type: "stderr", text }),
  });
  wasi.setMemory(memory);
  return wasi;
}

function startInstance({ role, tid, startArg }) {
  const worker = new Worker("exec-worker.js", { type: "module" });
  const channel = newChannel();
  run.channels.set(worker, channel);

  worker.onerror = (event) => {
    post({ type: "stderr", text: `worker error: ${event.message}\n` });
    finishRun(-1);
  };

  worker.onmessage = (event) => {
    const message = event.data;
    switch (message.type) {
      case "rpc": serveCall(channel.view); break;
      case "waiting-for-input": post({ type: "waiting-for-input" }); break;
      case "trapped": post({ type: "stderr", text: `the module trapped: ${message.message}\n` }); break;
      case "exited":
        run.channels.delete(worker);
        worker.terminate();
        // Only the program's own exit ends the run; a thread finishing is
        // just a thread finishing.
        if (message.role !== "thread") finishRun(message.code);
        break;
    }
  };

  worker.postMessage({
    role, module: run.module, sharedMemory: run.memory,
    rpc: channel.buffer, tid, startArg,
    stdin: role === "thread" ? null : { control: stdinControl.buffer, bytes: stdinBytes.buffer },
  });
  return worker;
}

// Opcode -1 is wasi-threads' thread-spawn, which is the host's job: start
// another instance of the same module, on the same memory, and hand back a
// thread id. Everything else is an ordinary WASI call.
function serveCall(channel) {
  if (Atomics.load(channel, RPC.OPCODE) === -1) {
    const startArg = Atomics.load(channel, RPC.ARGS);
    const tid = run.nextTid++;
    startInstance({ role: "thread", tid, startArg });
    Atomics.store(channel, RPC.RESULT, tid);
    Atomics.store(channel, RPC.STATE, RPC.DONE);
    Atomics.notify(channel, RPC.STATE);
    return;
  }
  serveRemoteCall(run.server, channel, (name, err) => {
    post({ type: "stderr", text: `host error in ${name}: ${err && err.stack || err}\n` });
  });
}

async function finishRun(code) {
  for (const worker of run.channels.keys()) worker.terminate();
  const finished = run;
  run = null;
  await saveState();
  post({ type: "done", code });
  finished.resolve?.();
}

// The module is compiled once and reused for every instance - including the
// spawned ones, which must be the same module to share the memory's layout.
let compiled = null;

async function runHb(args, tui) {
  const env = tui
    ? { ...ENV, COLUMNS: String(tui.columns), LINES: String(tui.rows), TERM: "xterm-256color" }
    : ENV;

  // 18 pages initial matches what the module asks for; the maximum is the
  // 1GB the build declares. Shared, so every instance sees the same heap.
  const memory = new WebAssembly.Memory({ initial: 18, maximum: 16384, shared: true });
  run = {
    memory, module: compiled, args: ["hb", ...args], env,
    channels: new Map(), nextTid: 1,
  };
  run.server = makeServer(memory);
  startInstance({ role: "main" });
}

function listing(prefix) {
  const wanted = prefix ? prefix.replace(/\/$/, "") : "";
  return fs.list()
    .filter((e) => ("/" + e.path).startsWith("/" + wanted.replace(/^\//, "")))
    .map((e) => ({
      path: "/" + e.path,
      kind: e.type,
      detail: e.type === "symlink" ? `-> ${e.target}` : e.type === "dir" ? "" : `${e.data.length}B`,
    }));
}

function fileText(path) {
  const full = path.startsWith("/") ? path : "/" + path;
  const node = fs.lookup(full);
  if (!node) return { error: `no such file: ${path}` };
  if (node.type === "dir") return { error: `${path} is a directory` };
  if (node.type === "symlink") return { error: `${path} is a symlink to ${node.target}` };
  return { text: new TextDecoder().decode(node.data) };
}

self.onmessage = async (event) => {
  const message = event.data;

  try {
  switch (message.type) {
    case "boot": {
      stdinControl = new Int32Array(message.control);
      stdinBytes = new Uint8Array(message.input);
      // compile, not compileStreaming: streaming refuses anything not served
      // as application/wasm, and a static server that gets the MIME type wrong
      // should cost a copy, not the whole terminal.
      compiled = await WebAssembly.compile(await (await fetch("hb.wasm")).arrayBuffer());
      const saved = await loadState();
      fs = saved?.files ? FileSystem.fromSnapshot(saved.files) : await seedFilesystem();
      post({ type: "ready", restored: Boolean(saved?.files), history: saved?.history ?? [] });
      return;
    }
    case "hb":
      // The run reports its own completion (finishRun) once the program's
      // instance exits - it cannot be awaited here, because this worker has to
      // stay free to answer the RPC calls that instance is about to make.
      await runHb(message.args, message.tui);
      return;
    case "ls": post({ type: "listing", entries: listing(message.path) }); return;
    case "cat": post({ type: "cat", ...fileText(message.path) }); return;
    case "reset":
      fs = await seedFilesystem();
      await saveState({ history: [] });
      post({ type: "reset-done" });
      return;
    case "history":
      await saveState({ history: message.history });
      return;
  }
  } catch (err) {
    // An async handler's rejection is invisible in a worker, and the page
    // would wait for a reply that is never coming.
    post({ type: "stderr", text: `terminal worker: ${err && err.stack || err}\n` });
    post({ type: "done", code: -1 });
  }
};
