# aowllsp

A **Language Server for Nimony, written in Nimony.** A ground-up nimony rewrite
of the (Nim 2) `nimony-lsp`, so the whole editor stack is self-owned and — the
end goal — JS-compilable for an in-browser IDE.

> Status: **Phase 1.** Lifecycle, full-text document sync, diagnostics, and
> navigation (definition / references / hover) are working. The in-process
> semantic-index features (completion, semantic tokens, call/type hierarchy)
> land in later phases, reading NIF through a nimony-native reader instead of
> shelling out.

## What works today

- **LSP lifecycle** — `initialize` (advertising the capabilities below),
  `shutdown` / `exit`.
- **Document sync** — `didOpen` / `didChange` (full sync) / `didSave` /
  `didClose`, with UTF-8 ↔ UTF-16 position mapping (LSP columns are UTF-16).
- **Diagnostics** — semantic errors from `nimony check` (grouped by URI, `Trace`
  lines as `relatedInformation`) **plus** recovering *syntax* diagnostics from
  [aowlsuggest](https://github.com/aoughwl/aowlsuggest) over the **live buffer**:
  where `nimony check` aborts at the first syntax error and only sees the saved
  file, aowlsuggest recovers past every error and reads the unsaved buffer, so
  you see all of them as you type.
- **Go to definition**, **find references** (across open documents), and
  **hover** (shows the definition's source line) — via `nimony check
  --def/--usages` (idetools).

## Architecture — the subprocess seam

Everything semantic goes through one module, `src/driver.nim`, which runs the
`nimony` binary and captures its output. Each open file is checked as its own
main module into an **isolated per-module nimcache** (`nimcache/lsp/<mangled>/`),
so a file stays warm after one cold compile instead of thrashing a shared cache.

That seam is deliberate: a future **browser** build swaps `driver.run` for
in-process `aowlparser` / `aowlsem` calls (no subprocess), and the drivers above
it don't change. Diagnostics can also be sourced from
[aowlsuggest](https://github.com/aoughwl/aowlsuggest) — the recovering parser
reports *every* syntax error with quick-fixes, where `nimony check` aborts on the
first.

## Shared libraries

- **[aowlkit](https://github.com/aoughwl/aowlkit)** — JSON building, safe
  subprocess capture, temp paths. Consumed via `-p:`; also used by aowlsuggest.
- **aowlhl** — the nimony-native NIF reader that Phase-2 in-process nav will link.

## Layout

| file | role |
|------|------|
| `src/aowllsp.nim` | entry: message loop, lifecycle, dispatch |
| `src/framing.nim` | Content-Length framed stdio transport |
| `src/protocol.nim` | LSP value types + JSON serialization |
| `src/document.nim` | text buffer + UTF-16 ↔ byte mapping |
| `src/state.nim` | config + open-document registry |
| `src/uris.nim` | `file://` URI ↔ path |
| `src/driver.nim` | the `nimony` subprocess seam (per-module nimcache) |
| `src/diagnostics.nim` | parse `nimony check` output |
| `src/idetools.nim` | parse `--def` / `--usages` records |

## Build

```sh
bash build.sh          # -> bin/aowllsp   (needs $HOME/aowlkit; NIMONY overrides the compiler)
bash tests/smoke.sh    # scripted JSON-RPC session
```

Point your editor's LSP client at `bin/aowllsp` for `.nim` / `.aowl` files.
