// The terminal's other half. The interpreter runs here rather than on the
// page for one reason: its REPL blocks on stdin, and blocking the main thread
// would freeze the tab. A worker can block, so `hb` runs its real loop -
// prompts, `:q`, multi-line buffering and all - reading what the visitor types.
//
// Input arrives through a SharedArrayBuffer the page writes into: this side
// sits in Atomics.wait until there is a line to read. That is also why the
// page needs cross-origin isolation (coi-serviceworker.js) - SharedArrayBuffer
// is unavailable without it.
//
// The filesystem lives here too, along with its IndexedDB persistence, so a
// program's writes and the page's `ls` are looking at the same thing.

import { FileSystem, run } from "./wasi.js";

const DB_NAME = "hashedbuild-playground";
const STORE = "state";

// Where ctx.cache (SPEC.md §9/§16) lands. resolve_cache_dir reads
// XDG_CACHE_HOME, so the content-addressed store ends up somewhere the
// visitor can actually look at.
const ENV = { XDG_CACHE_HOME: "/cache", HOME: "/", TERM: "dumb" };

let wasmBytes = null;
let fs = null;
let control = null;   // Int32Array: [0] = state, [1] = byte length
let inputBytes = null; // Uint8Array: the line the page last typed
let pending = null;    // bytes read but not yet consumed by the program

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

// ---- stdin ----------------------------------------------------------------------

// Blocks until the page hands over a line. State 0 means "nothing to read":
// the program waits there, which is exactly what the REPL's scanner does at a
// prompt. State 2 is EOF, which ends that loop the way Ctrl+D would.
const STATE_EMPTY = 0, STATE_DATA = 1, STATE_EOF = 2;

function readStdin(wanted) {
  if (pending && pending.length > 0) {
    const chunk = pending.subarray(0, wanted);
    pending = pending.subarray(chunk.length);
    return chunk;
  }

  post({ type: "waiting-for-input" });
  while (Atomics.load(control, 0) === STATE_EMPTY) {
    Atomics.wait(control, 0, STATE_EMPTY);
  }
  const state = Atomics.load(control, 0);
  if (state === STATE_EOF) {
    Atomics.store(control, 0, STATE_EMPTY);
    return null;
  }

  const length = Atomics.load(control, 1);
  pending = inputBytes.slice(0, length);
  Atomics.store(control, 0, STATE_EMPTY);
  Atomics.notify(control, 0);

  const chunk = pending.subarray(0, wanted);
  pending = pending.subarray(chunk.length);
  return chunk;
}

// ---- commands --------------------------------------------------------------------

async function runHb(args) {
  let code = 0;
  try {
    code = await run({
      wasmBytes, fs, args: ["hb", ...args], env: ENV, stdin: readStdin,
      onStdout: (text) => post({ type: "stdout", text }),
      onStderr: (text) => post({ type: "stderr", text }),
    });
  } catch (err) {
    post({ type: "stderr", text: `the module trapped: ${err.message}\n` });
    code = -1;
  }
  await saveState();
  return code;
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

  switch (message.type) {
    case "boot": {
      control = new Int32Array(message.control);
      inputBytes = new Uint8Array(message.input);
      wasmBytes = await (await fetch("hb.wasm")).arrayBuffer();
      const saved = await loadState();
      fs = saved?.files ? FileSystem.fromSnapshot(saved.files) : await seedFilesystem();
      post({ type: "ready", restored: Boolean(saved?.files), history: saved?.history ?? [] });
      return;
    }
    case "hb": {
      const code = await runHb(message.args);
      post({ type: "done", code });
      return;
    }
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
};
