// A WASI preview1 shim, just large enough for hb.wasm: the 21 imports it
// actually names, no more. Written rather than pulled in because the point of
// the playground is that the filesystem is *ours* - a plain JS object the page
// can persist, hand back, and show in a file list.
//
// Runs unchanged in a browser and in Node, which is what lets the same shim be
// tested headlessly (scripts/playground_test.mjs).

const ERRNO = {
  SUCCESS: 0, ACCESS: 2, BADF: 8, EXIST: 20, INVAL: 28, IO: 29,
  ISDIR: 31, NOENT: 44, NOTDIR: 54, NOTCAPABLE: 76,
};

const FILETYPE = { UNKNOWN: 0, DIRECTORY: 3, REGULAR_FILE: 4, SYMBOLIC_LINK: 7 };

const OFLAGS = { CREATE: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 };

// A file is bytes; a directory is a Map of name -> node; a symlink is a target
// string. Deliberately a plain structure: `snapshot()` and `restore()` below
// are the whole persistence story.
export class FileSystem {
  constructor() {
    this.root = { type: "dir", entries: new Map() };
  }

  static fromSnapshot(snapshot) {
    const fs = new FileSystem();
    for (const [path, entry] of Object.entries(snapshot || {})) {
      if (entry.type === "file") fs.writeFile(path, Uint8Array.from(entry.data));
      else if (entry.type === "symlink") fs.symlink(path, entry.target);
      else fs.mkdirp(path);
    }
    return fs;
  }

  // Flat path -> entry, which survives structuredClone and JSON alike.
  snapshot() {
    const out = {};
    const walk = (node, prefix) => {
      for (const [name, child] of node.entries) {
        const path = prefix ? `${prefix}/${name}` : name;
        if (child.type === "dir") {
          out[path] = { type: "dir" };
          walk(child, path);
        } else if (child.type === "symlink") {
          out[path] = { type: "symlink", target: child.target };
        } else {
          out[path] = { type: "file", data: Array.from(child.data) };
        }
      }
    };
    walk(this.root, "");
    return out;
  }

  split(path) {
    return String(path).split("/").filter((s) => s.length > 0 && s !== ".");
  }

  lookup(path) {
    let node = this.root;
    for (const part of this.split(path)) {
      if (node.type !== "dir") return null;
      const next = node.entries.get(part);
      if (!next) return null;
      node = next;
    }
    return node;
  }

  mkdirp(path) {
    let node = this.root;
    for (const part of this.split(path)) {
      let next = node.entries.get(part);
      if (!next) {
        next = { type: "dir", entries: new Map() };
        node.entries.set(part, next);
      }
      if (next.type !== "dir") return null;
      node = next;
    }
    return node;
  }

  parentOf(path) {
    const parts = this.split(path);
    const name = parts.pop();
    const parent = this.mkdirp(parts.join("/"));
    return { parent, name };
  }

  writeFile(path, data) {
    const { parent, name } = this.parentOf(path);
    if (!parent || !name) return false;
    parent.entries.set(name, { type: "file", data: new Uint8Array(data) });
    return true;
  }

  symlink(path, target) {
    const { parent, name } = this.parentOf(path);
    if (!parent || !name) return false;
    parent.entries.set(name, { type: "symlink", target });
    return true;
  }

  list() {
    const snapshot = this.snapshot();
    return Object.keys(snapshot).sort().map((path) => ({ path, ...snapshot[path] }));
  }
}

// One open descriptor. Directories keep their path so path_open can resolve
// relative to them, which is the whole of WASI's capability model.
class Descriptor {
  constructor(path, node, isPreopen = false) {
    this.path = path;
    this.node = node;
    this.isPreopen = isPreopen;
    this.offset = 0;
  }
}

export class WASI {
  // `args` becomes argv, so args[0] is the program name and args[1..] are what
  // `hb` parses (a file to run, or -e '<expr>').
  // `env` becomes the process environment - which is how ctx.cache is aimed:
  // resolve_cache_dir (builtins_fs.odin) reads XDG_CACHE_HOME, so setting it
  // puts the content-addressed store somewhere the visitor can `ls`.
  // `stdin` is an optional reader: a function returning bytes, or null at EOF.
  // Without one, reading stdin is end-of-file, which is what a program run
  // non-interactively should see.
  constructor({ fs, args = ["hb"], env = {}, stdin = null,
                onStdout = () => {}, onStderr = () => {} }) {
    this.fs = fs;
    this.args = args;
    this.env = env;
    this.stdin = stdin;
    this.onStdout = onStdout;
    this.onStderr = onStderr;
    this.exitCode = null;

    // 0/1/2 are the standard streams; 3 is the preopened root, which is what
    // makes the whole virtual filesystem reachable at all. A program can only
    // ever get at what a preopen covers - here, everything.
    this.fds = new Map();
    this.fds.set(0, new Descriptor("<stdin>", null));
    this.fds.set(1, new Descriptor("<stdout>", null));
    this.fds.set(2, new Descriptor("<stderr>", null));
    this.fds.set(3, new Descriptor("/", fs.root, true));
    this.nextFd = 4;
  }

  setMemory(memory) {
    this.memory = memory;
  }

  get view() {
    return new DataView(this.memory.buffer);
  }

  get bytes() {
    return new Uint8Array(this.memory.buffer);
  }

  readString(ptr, len) {
    return new TextDecoder().decode(this.bytes.subarray(ptr, ptr + len));
  }

  // Resolves a path relative to a directory descriptor, refusing anything that
  // would leave it - the same containment rule §16 describes, enforced here
  // because a host is exactly where WASI expects it to live.
  resolve(dirfd, path) {
    const dir = this.fds.get(dirfd);
    if (!dir || dir.node?.type !== "dir") return null;
    if (path.startsWith("/")) return null;

    const parts = [...this.fs.split(dir.path), ...this.fs.split(path)];
    const base = this.fs.split(dir.path).length;
    const out = [];
    for (const part of parts) {
      if (part === "..") {
        if (out.length <= base) return null; // escapes the preopen
        out.pop();
      } else {
        out.push(part);
      }
    }
    return "/" + out.join("/");
  }

  imports() {
    const enc = new TextEncoder();
    const self = this;

    const writeIovs = (iovsPtr, iovsLen, sink) => {
      let written = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = self.view.getUint32(iovsPtr + i * 8, true);
        const len = self.view.getUint32(iovsPtr + i * 8 + 4, true);
        sink(self.bytes.subarray(ptr, ptr + len));
        written += len;
      }
      return written;
    };

    return {
      args_sizes_get(countPtr, sizePtr) {
        self.view.setUint32(countPtr, self.args.length, true);
        self.view.setUint32(sizePtr, self.args.reduce((n, a) => n + enc.encode(a).length + 1, 0), true);
        return ERRNO.SUCCESS;
      },

      args_get(argvPtr, bufPtr) {
        let ptr = bufPtr;
        for (let i = 0; i < self.args.length; i++) {
          self.view.setUint32(argvPtr + i * 4, ptr, true);
          const encoded = enc.encode(self.args[i] + "\0");
          self.bytes.set(encoded, ptr);
          ptr += encoded.length;
        }
        return ERRNO.SUCCESS;
      },

      environ_sizes_get(countPtr, sizePtr) {
        const pairs = Object.entries(self.env).map(([k, v]) => `${k}=${v}`);
        self.view.setUint32(countPtr, pairs.length, true);
        self.view.setUint32(sizePtr, pairs.reduce((n, p) => n + enc.encode(p).length + 1, 0), true);
        return ERRNO.SUCCESS;
      },

      environ_get(environPtr, bufPtr) {
        let ptr = bufPtr;
        Object.entries(self.env).forEach(([key, value], i) => {
          self.view.setUint32(environPtr + i * 4, ptr, true);
          const encoded = enc.encode(`${key}=${value}\0`);
          self.bytes.set(encoded, ptr);
          ptr += encoded.length;
        });
        return ERRNO.SUCCESS;
      },

      // Descriptor 3 is the one preopen, named "/" - fd_prestat_get on
      // anything else ends the enumeration, which is how a guest discovers
      // what it was granted.
      fd_prestat_get(fd, prestatPtr) {
        const d = self.fds.get(fd);
        if (!d || !d.isPreopen) return ERRNO.BADF;
        self.view.setUint8(prestatPtr, 0); // tag: dir
        self.view.setUint32(prestatPtr + 4, enc.encode(d.path).length, true);
        return ERRNO.SUCCESS;
      },

      fd_prestat_dir_name(fd, pathPtr, pathLen) {
        const d = self.fds.get(fd);
        if (!d || !d.isPreopen) return ERRNO.BADF;
        self.bytes.set(enc.encode(d.path).subarray(0, pathLen), pathPtr);
        return ERRNO.SUCCESS;
      },

      // Descriptors 1 and 2 are streams; anything else is a file in the
      // virtual filesystem, and writing to it has to actually land there -
      // that is what makes createfile persist rather than print.
      fd_write(fd, iovsPtr, iovsLen, writtenPtr) {
        const d = self.fds.get(fd);
        if (d?.node?.type === "file") {
          const written = self.writeInto(d, iovsPtr, iovsLen, d.offset);
          d.offset += written;
          self.view.setUint32(writtenPtr, written, true);
          return ERRNO.SUCCESS;
        }
        const sink = fd === 2 ? self.onStderr : self.onStdout;
        const written = writeIovs(iovsPtr, iovsLen, (chunk) => sink(new TextDecoder().decode(chunk)));
        self.view.setUint32(writtenPtr, written, true);
        return ERRNO.SUCCESS;
      },

      fd_pwrite(fd, iovsPtr, iovsLen, offset, writtenPtr) {
        const d = self.fds.get(fd);
        if (d?.node?.type !== "file") return this.fd_write(fd, iovsPtr, iovsLen, writtenPtr);
        const written = self.writeInto(d, iovsPtr, iovsLen, Number(offset));
        self.view.setUint32(writtenPtr, written, true);
        return ERRNO.SUCCESS;
      },

      fd_read(fd, iovsPtr, iovsLen, readPtr) {
        if (fd === 0) {
          // The interpreter's REPL reads stdin in a loop, so this call has to
          // be able to *wait* - the reader supplied by the terminal blocks on
          // a SharedArrayBuffer until the user has typed something. A null
          // reader, or a null result, is EOF, which ends that loop cleanly.
          const wanted = self.view.getUint32(iovsPtr + 4, true);
          const chunk = self.stdin ? self.stdin(wanted) : null;
          const written = chunk ? chunk.length : 0;
          if (written > 0) self.bytes.set(chunk, self.view.getUint32(iovsPtr, true));
          self.view.setUint32(readPtr, written, true);
          return ERRNO.SUCCESS;
        }
        const d = self.fds.get(fd);
        if (!d || d.node?.type !== "file") return ERRNO.BADF;
        let read = 0;
        for (let i = 0; i < iovsLen; i++) {
          const ptr = self.view.getUint32(iovsPtr + i * 8, true);
          const len = self.view.getUint32(iovsPtr + i * 8 + 4, true);
          const chunk = d.node.data.subarray(d.offset, d.offset + len);
          self.bytes.set(chunk, ptr);
          d.offset += chunk.length;
          read += chunk.length;
          if (chunk.length < len) break;
        }
        self.view.setUint32(readPtr, read, true);
        return ERRNO.SUCCESS;
      },

      fd_pread(fd, iovsPtr, iovsLen, offset, readPtr) {
        const d = self.fds.get(fd);
        if (!d || d.node?.type !== "file") return ERRNO.BADF;
        const saved = d.offset;
        d.offset = Number(offset);
        const rc = this.fd_read(fd, iovsPtr, iovsLen, readPtr);
        d.offset = saved;
        return rc;
      },

      fd_seek(fd, offset, whence, newOffsetPtr) {
        const d = self.fds.get(fd);
        if (!d || d.node?.type !== "file") return ERRNO.BADF;
        const size = d.node.data.length;
        const base = whence === 0 ? 0 : whence === 1 ? d.offset : size;
        d.offset = Math.max(0, Math.min(size, base + Number(offset)));
        self.view.setBigUint64(newOffsetPtr, BigInt(d.offset), true);
        return ERRNO.SUCCESS;
      },

      // The editor's file picker lists a directory, which is the only reason
      // this exists. preview1's dirent layout: a 24-byte header (next cookie,
      // inode, name length, filetype) followed by the raw name, packed back to
      // back until the buffer is full.
      fd_readdir(fd, bufPtr, bufLen, cookie, usedPtr) {
        const d = self.fds.get(fd);
        if (!d || d.node?.type !== "dir") return ERRNO.BADF;

        const names = [...d.node.entries.keys()];
        let offset = 0;
        let index = Number(cookie);
        for (; index < names.length; index++) {
          const name = names[index];
          const child = d.node.entries.get(name);
          const encoded = enc.encode(name);
          if (offset + 24 + encoded.length > bufLen) break;

          const at = bufPtr + offset;
          self.view.setBigUint64(at, BigInt(index + 1), true);        // d_next
          self.view.setBigUint64(at + 8, 0n, true);                   // d_ino
          self.view.setUint32(at + 16, encoded.length, true);         // d_namlen
          self.view.setUint8(at + 20,
            child.type === "dir" ? FILETYPE.DIRECTORY
            : child.type === "symlink" ? FILETYPE.SYMBOLIC_LINK
            : FILETYPE.REGULAR_FILE);
          self.bytes.set(encoded, at + 24);
          offset += 24 + encoded.length;
        }
        self.view.setUint32(usedPtr, offset, true);
        return ERRNO.SUCCESS;
      },

      fd_close(fd) {
        return self.fds.delete(fd) ? ERRNO.SUCCESS : ERRNO.BADF;
      },

      fd_sync() {
        return ERRNO.SUCCESS;
      },

      fd_filestat_get(fd, statPtr) {
        const d = self.fds.get(fd);
        if (!d) return ERRNO.BADF;
        const node = d.node;
        const type = node?.type === "dir" ? FILETYPE.DIRECTORY
          : node?.type === "symlink" ? FILETYPE.SYMBOLIC_LINK
          : node ? FILETYPE.REGULAR_FILE : FILETYPE.UNKNOWN;
        self.writeFilestat(statPtr, type, node?.data?.length ?? 0);
        return ERRNO.SUCCESS;
      },

      path_filestat_get(dirfd, flags, pathPtr, pathLen, statPtr) {
        const path = self.resolve(dirfd, self.readString(pathPtr, pathLen));
        if (path === null) return ERRNO.ACCESS;
        const node = self.fs.lookup(path);
        if (!node) return ERRNO.NOENT;
        const type = node.type === "dir" ? FILETYPE.DIRECTORY
          : node.type === "symlink" ? FILETYPE.SYMBOLIC_LINK
          : FILETYPE.REGULAR_FILE;
        self.writeFilestat(statPtr, type, node.data?.length ?? 0);
        return ERRNO.SUCCESS;
      },

      path_open(dirfd, dirflags, pathPtr, pathLen, oflags, rightsBase, rightsInheriting, fdflags, fdPtr) {
        const rel = self.readString(pathPtr, pathLen);
        const path = self.resolve(dirfd, rel);
        if (path === null) return ERRNO.ACCESS;

        let node = self.fs.lookup(path);
        if (node && (oflags & OFLAGS.EXCL) && (oflags & OFLAGS.CREATE)) return ERRNO.EXIST;
        if (!node && (oflags & OFLAGS.CREATE)) {
          if (!self.fs.writeFile(path, new Uint8Array(0))) return ERRNO.NOENT;
          node = self.fs.lookup(path);
        }
        if (!node) return ERRNO.NOENT;
        if ((oflags & OFLAGS.DIRECTORY) && node.type !== "dir") return ERRNO.NOTDIR;
        // Matching the real thing: opening a directory as a file is refused,
        // which is why the interpreter stats before it opens.
        if (!(oflags & OFLAGS.DIRECTORY) && node.type === "dir") return ERRNO.ISDIR;

        const fd = self.nextFd++;
        self.fds.set(fd, new Descriptor(path, node));
        self.view.setUint32(fdPtr, fd, true);
        return ERRNO.SUCCESS;
      },

      path_create_directory(dirfd, pathPtr, pathLen) {
        const path = self.resolve(dirfd, self.readString(pathPtr, pathLen));
        if (path === null) return ERRNO.ACCESS;
        return self.fs.mkdirp(path) ? ERRNO.SUCCESS : ERRNO.NOTDIR;
      },

      path_symlink(targetPtr, targetLen, dirfd, pathPtr, pathLen) {
        const target = self.readString(targetPtr, targetLen);
        const path = self.resolve(dirfd, self.readString(pathPtr, pathLen));
        if (path === null) return ERRNO.ACCESS;
        if (self.fs.lookup(path)) return ERRNO.EXIST;
        return self.fs.symlink(path, target) ? ERRNO.SUCCESS : ERRNO.NOENT;
      },

      path_readlink(dirfd, pathPtr, pathLen, bufPtr, bufLen, usedPtr) {
        const path = self.resolve(dirfd, self.readString(pathPtr, pathLen));
        if (path === null) return ERRNO.ACCESS;
        const node = self.fs.lookup(path);
        if (!node) return ERRNO.NOENT;
        if (node.type !== "symlink") return ERRNO.INVAL;
        const encoded = enc.encode(node.target);
        self.bytes.set(encoded.subarray(0, bufLen), bufPtr);
        self.view.setUint32(usedPtr, Math.min(encoded.length, bufLen), true);
        return ERRNO.SUCCESS;
      },

      random_get(ptr, len) {
        const buf = self.bytes.subarray(ptr, ptr + len);
        if (globalThis.crypto?.getRandomValues) globalThis.crypto.getRandomValues(buf);
        else for (let i = 0; i < len; i++) buf[i] = (Math.random() * 256) | 0;
        return ERRNO.SUCCESS;
      },

      // Thrown, then caught by run() below: a wasm module has no other way to
      // stop, and letting it propagate would show up as a confusing trap.
      proc_exit(code) {
        self.exitCode = code;
        throw new ExitSignal(code);
      },
    };
  }

  // Splices the iovecs into a file's bytes at `offset`, growing it as needed.
  writeInto(descriptor, iovsPtr, iovsLen, offset) {
    const chunks = [];
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const ptr = this.view.getUint32(iovsPtr + i * 8, true);
      const len = this.view.getUint32(iovsPtr + i * 8 + 4, true);
      chunks.push(this.bytes.slice(ptr, ptr + len));
      total += len;
    }

    const existing = descriptor.node.data;
    const end = offset + total;
    const grown = new Uint8Array(Math.max(existing.length, end));
    grown.set(existing);
    let at = offset;
    for (const chunk of chunks) {
      grown.set(chunk, at);
      at += chunk.length;
    }
    descriptor.node.data = grown;
    return total;
  }

  writeFilestat(ptr, filetype, size) {
    const v = this.view;
    v.setBigUint64(ptr, 0n, true);        // dev
    v.setBigUint64(ptr + 8, 0n, true);    // ino
    v.setUint8(ptr + 16, filetype);
    v.setBigUint64(ptr + 24, 1n, true);   // nlink
    v.setBigUint64(ptr + 32, BigInt(size), true);
    v.setBigUint64(ptr + 40, 0n, true);   // atim
    v.setBigUint64(ptr + 48, 0n, true);   // mtim
    v.setBigUint64(ptr + 56, 0n, true);   // ctim
  }
}

export class ExitSignal extends Error {
  constructor(code) {
    super(`exit ${code}`);
    this.code = code;
  }
}

// Instantiates a fresh module per run. Fresh on purpose: hb is a WASI
// *command* - the host calls _start once and the program ends - so reusing an
// instance would restart a program whose globals and heap are already spent.
export async function run({ wasmBytes, fs, args, env, stdin, onStdout, onStderr }) {
  const wasi = new WASI({ fs, args, env, stdin, onStdout, onStderr });
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    wasi_snapshot_preview1: wasi.imports(),
  });
  wasi.setMemory(instance.exports.memory);

  try {
    instance.exports._start();
    return wasi.exitCode ?? 0;
  } catch (err) {
    if (err instanceof ExitSignal) return err.code;
    throw err;
  }
}
