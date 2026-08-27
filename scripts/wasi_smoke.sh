#!/usr/bin/env bash
# Runs the examples under a WASI runtime and checks they agree with the
# native build, which the Odin suite already asserts against SPEC.md (see
# examples_test.odin). Comparing the two targets is what actually covers
# fs_wasi.odin: `odin test` builds natively, so nothing in the suite can
# execute the WASI backend.
#
# Usage: scripts/wasi_smoke.sh <native-hb> <hb.wasm> <wasmtime>
set -euo pipefail

NATIVE=${1:?usage: wasi_smoke.sh <native-hb> <hb.wasm> <wasmtime>}
WASM=${2:?}
WASMTIME=${3:?}
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

# Skipped, with reasons - not silent omissions:
#   async-*        core:thread has no WASI implementation yet (§2)
#   files-sandboxed, option-picker
#                  display real paths, which differ by construction: native
#                  shows the checkout, WASI shows the path inside its preopen
SKIP="async-basics.hb async-branching.hb async-table.hb files-sandboxed.hb option-picker.hb"

failures=0
checked=0
for path in examples/*.hb; do
  name=$(basename "$path")
  case " $SKIP " in *" $name "*) continue;; esac

  rm -f examples/branch-*.marker
  native_out=$("$NATIVE" "$path" 2>&1 || true)
  rm -f examples/branch-*.marker
  wasi_out=$("$WASMTIME" run --dir=. "$WASM" "$path" 2>&1 || true)

  checked=$((checked + 1))
  if [ "$native_out" != "$wasi_out" ]; then
    failures=$((failures + 1))
    printf 'MISMATCH %s\n  native: %s\n  wasi:   %s\n' "$name" "$native_out" "$wasi_out"
  fi
done
rm -f examples/branch-*.marker

# A skip list that swallowed everything would pass silently otherwise.
if [ "$checked" -lt 15 ]; then
  echo "only $checked examples compared - the skip list or examples/ is wrong"
  exit 1
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures of $checked examples differ between native and WASI"
  exit 1
fi
echo "$checked examples agree between native and WASI"
