#!/usr/bin/env bash
# smoke.sh -- build the server and the aowlmony test client, then run one scripted
# LSP session against bin/aowllsp.exe. No Python: the client is tests/smoke.aowl.
#
#   bash tests/smoke.sh                 # builds bin/aowllsp.exe first if missing
#   AOWLLSP=/path/to/aowllsp.exe bash tests/smoke.sh
#
# The helper CLIs (aowllens.exe / aowlsuggest.exe / aowlfmt.exe) are used when they
# sit next to the server exe; their groups print SKIP otherwise.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${AOWLLSP:-$ROOT/bin/aowllsp.exe}"
AOWLMONY_ROOT="${AOWLMONY_ROOT:-$HOME/dev/toolchain/aowlmony/root}"
JSONREF="${AOWLJSONREF:-$HOME/dev/jsonref/src}"
COMPILER="$AOWLMONY_ROOT/bin/aowlmony.exe"
if command -v cygpath >/dev/null 2>&1; then
  export AOWLMONY_ROOT="$(cygpath -w "$AOWLMONY_ROOT")"; JSONREF="$(cygpath -m "$JSONREF")"
fi
[[ -f "$BIN" ]] || { echo "building aowllsp ..."; bash "$ROOT/build.sh" >/dev/null || { echo "build failed"; exit 1; }; }

# build the client (delete the cached exe first: the compiler exits 0 on failure)
cd "$ROOT/tests"
ok=0
for attempt in 1 2; do
  rm -f nimcache/*/smoke.exe 2>/dev/null || true
  "$COMPILER" c -d:release --path:"$JSONREF" --path:"$ROOT/src" smoke.aowl >_build.log 2>&1 || true
  exe="$(ls -t nimcache/*/smoke.exe 2>/dev/null | head -1 || true)"
  [[ -n "$exe" ]] && { ok=1; break; }
done
[[ $ok -eq 1 ]] || { grep Error _build.log | head; echo "smoke: client build failed"; exit 1; }
rm -f _build.log

WORK="$ROOT/tests/_work"
rm -rf "$WORK"; mkdir -p "$WORK"
if command -v cygpath >/dev/null 2>&1; then BIN="$(cygpath -m "$BIN")"; WORK="$(cygpath -m "$WORK")"; fi
exec "$exe" "$BIN" "$WORK"
