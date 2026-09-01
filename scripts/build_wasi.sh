#!/usr/bin/env bash
# Builds hb for WASI. Two flavours, because no single module suits both:
#
#   portable (default)  runs anywhere preview1 does, including wasmtime.
#                       `async` evaluates inline - see task.odin.
#   --threads           uses wasi-threads: shared memory, atomics, and an
#                       imported wasi.thread-spawn. Runs only on hosts that
#                       implement the proposal (WAMR, WasmEdge builds with it
#                       enabled) - wasmtime removed its support in 2026-06,
#                       and refuses the module outright over the unknown
#                       import.
#
# Usage: scripts/build_wasi.sh [--threads] [-out:path]
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

THREADS=0
OUT=""
for arg in "$@"; do
  case "$arg" in
    --threads) THREADS=1 ;;
    -out:*)    OUT="${arg#-out:}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# -o:size, not the default -o:minimal: that one miscompiles on the pinned
# Odin release (see CLAUDE.md's Odin notes). It also halves the artifact.
COMMON=(-target:wasi_wasm32 -o:size)

if [ "$THREADS" -eq 0 ]; then
  odin build src "${COMMON[@]}" -out:"${OUT:-hb.wasm}"
  exit 0
fi

# The thread entry point has to set the new instance's __stack_pointer before
# any Odin code runs, and Odin can't touch that global - so it is a few lines
# of wasm assembly, compiled here and linked in alongside.
STUB_OBJ=$(mktemp -t hb-thread-start-XXXXXX.o)
trap 'rm -f "$STUB_OBJ"' EXIT
clang --target=wasm32 -matomics -mbulk-memory -c src/thread_start.s -o "$STUB_OBJ"

# --export=wasi_thread_start: nothing inside the module calls it, so the
# linker would otherwise drop it, and the host would fail to spawn with
# "Failed to find thread start function wasi_thread_start".
odin build src "${COMMON[@]}" \
  -define:HB_WASI_THREADS=true \
  -target-features:atomics \
  -extra-linker-flags:"--shared-memory --max-memory=1073741824 --export-memory --export=wasi_thread_start $STUB_OBJ" \
  -out:"${OUT:-hb-threads.wasm}"
