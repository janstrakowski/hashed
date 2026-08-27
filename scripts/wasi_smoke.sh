#!/usr/bin/env bash
# Runs the examples under a WASI runtime and checks they agree with the
# native build, which the Odin suite already asserts against SPEC.md (see
# examples_test.odin). Comparing the two targets is what actually covers
# fs_wasi.odin and task_wasi.odin: `odin test` builds natively, so nothing in
# the suite can execute either.
#
# Usage:
#   scripts/wasi_smoke.sh <native-hb> <hb.wasm> <runtime> [runtime-args...]
#
# Examples:
#   scripts/wasi_smoke.sh ./hb hb.wasm wasmtime
#   scripts/wasi_smoke.sh ./hb hb-threads.wasm iwasm --stack-size=4194304 --max-threads=8
set -euo pipefail

NATIVE=${1:?usage: wasi_smoke.sh <native-hb> <hb.wasm> <runtime> [runtime-args...]}
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

failures=0
checked=0
for path in examples/*.hb; do
  name=$(basename "$path")
  case " $SKIP " in *" $name "*) continue;; esac

  rm -f examples/branch-*.marker
  native_out=$("$NATIVE" "$path" 2>&1 || true)
  rm -f examples/branch-*.marker
  wasi_out=$("$RUNTIME" "${RUNTIME_ARGS[@]}" --dir=. "$WASM" "$path" 2>&1 || true)

  checked=$((checked + 1))
  if [ "$native_out" != "$wasi_out" ]; then
    failures=$((failures + 1))
    printf 'MISMATCH %s\n  native: %s\n  wasi:   %s\n' "$name" "$native_out" "$wasi_out"
  fi
done
rm -f examples/branch-*.marker

# A skip list that swallowed everything would pass silently otherwise.
if [ "$checked" -lt 18 ]; then
  echo "only $checked examples compared - the skip list or examples/ is wrong"
  exit 1
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures of $checked examples differ between native and WASI"
  exit 1
fi
echo "$checked examples agree between native and WASI ($RUNTIME)"
