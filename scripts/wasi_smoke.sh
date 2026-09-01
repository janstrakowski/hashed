#!/usr/bin/env bash
# Runs the examples under a WASI runtime and checks they agree with the
# native build, which the Odin suite already asserts against SPEC.md (see
# examples_test.odin). Comparing the two targets is what actually covers
# fs_wasi.odin and task_wasi.odin: `odin test` builds natively, so nothing in
# the suite can execute either.
#
# Usage:
#   scripts/wasi_smoke.sh [--no-threads] <native-hb> <hb.wasm> <runtime> [runtime-args...]
#
# --no-threads says the wasm build has no thread support, so the async
# examples are expected to *fail* with a message saying so, rather than to
# match native. That is an assertion, not a skip: a portable build that
# quietly produced async results would mean `async` had stopped meaning
# concurrently.
#
# Examples:
#   scripts/wasi_smoke.sh --no-threads ./hb hb.wasm wasmtime
#   scripts/wasi_smoke.sh ./hb hb-threads.wasm iwasm --stack-size=4194304 --max-threads=8
set -euo pipefail

NO_THREADS=0
if [ "${1:-}" = "--no-threads" ]; then
  NO_THREADS=1
  shift
fi

NATIVE=${1:?usage: wasi_smoke.sh [--no-threads] <native-hb> <hb.wasm> <runtime> [runtime-args...]}
WASM=${2:?}
RUNTIME=${3:?}
shift 3
RUNTIME_ARGS=("$@")

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

# Skipped, with reasons - not silent omissions:
#   files-sandboxed, option-picker
#       display real paths, which differ by construction: native shows the
#       checkout, WASI shows the path inside its preopen.
SKIP="files-sandboxed.hb option-picker.hb"
ASYNC="async-basics.hb async-branching.hb async-table.hb"

# No flags are reconstructed here any more: an example that reads or writes
# declares its own directories (SPEC.md §17), relative to its own file, so
# both binaries are invoked with nothing but the path - which is also the only
# way a reader would run one.

failures=0
checked=0
async_checked=0
for path in examples/*.hb; do
  name=$(basename "$path")
  case " $SKIP " in *" $name "*) continue;; esac

  rm -f examples/branch-*.marker
  native_out=$("$NATIVE" "$path" 2>&1 || true)
  rm -f examples/branch-*.marker
  # --dir=. here is wasmtime's own preopen flag, not hb's: it is what makes
  # anything reachable inside the module at all.
  wasi_out=$("$RUNTIME" "${RUNTIME_ARGS[@]}" --dir=. "$WASM" "$path" 2>&1 || true)

  if [ "$NO_THREADS" -eq 1 ] && [[ " $ASYNC " == *" $name "* ]]; then
    async_checked=$((async_checked + 1))
    case "$wasi_out" in
      *"async"*"could not start a thread"*) ;;
      *) failures=$((failures + 1))
         printf 'EXPECTED A REFUSAL %s\n  got: %s\n' "$name" "$wasi_out" ;;
    esac
    continue
  fi

  checked=$((checked + 1))
  if [ "$native_out" != "$wasi_out" ]; then
    failures=$((failures + 1))
    printf 'MISMATCH %s\n  native: %s\n  wasi:   %s\n' "$name" "$native_out" "$wasi_out"
  fi
done
rm -f examples/branch-*.marker

# A skip list that swallowed everything would pass silently otherwise.
if [ "$NO_THREADS" -eq 1 ] && [ "$async_checked" -ne 3 ]; then
  echo "expected 3 async examples to check for a refusal, saw $async_checked"
  exit 1
fi

if [ "$checked" -lt 18 ]; then
  echo "only $checked examples compared - the skip list or examples/ is wrong"
  exit 1
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures of $checked examples differ between native and WASI"
  exit 1
fi
if [ "$NO_THREADS" -eq 1 ]; then
  echo "$checked examples agree between native and WASI, and $async_checked async examples refused ($RUNTIME)"
else
  echo "$checked examples agree between native and WASI ($RUNTIME)"
fi
