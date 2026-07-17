#!/usr/bin/env bash
# Build aowllsp with the Nimony compiler. It links the shared aowlkit library
# (via -p:) and shells out to `nimony` at runtime; no other deps.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
AOWLKIT="${AOWLKIT:-$HOME/aowlkit/src}"
LOCK="${NIMONY_BUILD_LOCK:-$HOME/.nimony-build.lock}"
cd "$ROOT"

build() {
  "$NIMONY" c --base:src -p:"$AOWLKIT" -d:nimony src/aowllsp.nim 2>&1
}

run_locked() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"; flock 9
  fi
  build
}

log="$(run_locked)"; rc=$?
if [ $rc -ne 0 ] || grep -qE '(^|[^a-zA-Z])Error:' <<<"$log"; then
  echo "$log" | grep -E 'Error:' | head -30
  echo "BUILD-FAIL"; echo "BUILD-DONE"; exit 1
fi
mkdir -p bin
exe="$(find nimcache -type f -name aowllsp -executable -printf '%T@ %p\n' 2>/dev/null \
       | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "${exe:-}" ]; then
  echo "build.sh: could not locate built aowllsp in nimcache/" >&2
  echo "BUILD-FAIL"; echo "BUILD-DONE"; exit 1
fi
cp "$exe" bin/aowllsp
echo "built bin/aowllsp"
echo "BUILD-OK"; echo "BUILD-DONE"
