#!/usr/bin/env bash
# Build bin/aowllsp.exe with the aowlmony compiler.
#
#   bash build.sh
#
# Overrides: AOWLMONY_ROOT (toolchain root; default ~/dev/toolchain/aowlmony/root),
#            AOWLJSONREF   (jsonref src dir; default ~/dev/jsonref/src).
#
# The compiler writes its exe into nimcache/<hash>/ and exits 0 even when it
# produced nothing, so "no exe found" is the failure signal. The cached exe is
# deleted before each attempt so a failed build can never ship a stale one. The
# compiler's cache is shared, so a spurious failure gets exactly one retry.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOWLMONY_ROOT="${AOWLMONY_ROOT:-$HOME/dev/toolchain/aowlmony/root}"
JSONREF="${AOWLJSONREF:-$HOME/dev/jsonref/src}"
COMPILER="$AOWLMONY_ROOT/bin/aowlmony.exe"
[[ -x "$COMPILER" ]] || { echo "build.sh: no compiler at $COMPILER" >&2; echo BUILD-FAIL; exit 1; }
[[ -d "$JSONREF" ]] || { echo "build.sh: no jsonref dir at $JSONREF" >&2; echo BUILD-FAIL; exit 1; }
if command -v cygpath >/dev/null 2>&1; then
  export AOWLMONY_ROOT="$(cygpath -w "$AOWLMONY_ROOT")"
  JSONREF="$(cygpath -m "$JSONREF")"
fi
mkdir -p "$ROOT/bin"
cd "$ROOT/src"
ok=0
for attempt in 1 2; do
  rm -f nimcache/*/aowllsp.exe 2>/dev/null || true
  "$COMPILER" c -d:release --path:"$JSONREF" --path:. aowllsp.aowl >"$ROOT/bin/build.log" 2>&1 || true
  exe="$(ls -t nimcache/*/aowllsp.exe 2>/dev/null | head -1 || true)"
  if [[ -n "$exe" ]]; then cp "$exe" "$ROOT/bin/aowllsp.exe"; ok=1; break; fi
done
if [[ $ok -eq 1 ]]; then
  rm -f "$ROOT/bin/build.log"
  echo "built bin/aowllsp.exe"; echo "BUILD-OK"
else
  grep -E 'Error' "$ROOT/bin/build.log" | head -30 >&2
  echo "build.sh: no executable produced (see bin/build.log)" >&2
  echo BUILD-FAIL; exit 1
fi
