# aowllsp

A **Language Server for Nimony, written in Nimony.** A ground-up nimony rewrite
of the (Nim 2) `nimony-lsp`, so the whole editor stack is self-owned and — the
end goal — JS-compilable for an in-browser IDE.

> Status: **broad feature coverage.** ~23 LSP methods handled. Navigation and
> diagnostics run via the `nimony` subprocess; the symbol/token features read NIF
> artifacts through the nimony-native [aowllens](https://github.com/aoughwl/aowllens).
> A future browser build swaps both for in-process calls (see the seam below).

## What works today

- **LSP lifecycle** — `initialize` (advertising every capability below),
  `shutdown` / `exit`.
- **Document sync** — `didOpen` / `didChange` (full sync) / `didSave` /
  `didClose`, with UTF-8 ↔ UTF-16 position mapping (LSP columns are UTF-16).
- **Diagnostics** — semantic errors from `nimony check` **over the live,
  unsaved buffer** (materialized to a sibling temp file, checked, paths mapped
  back), grouped by URI, `Trace` lines as `relatedInformation`, **plus**
  recovering *syntax* diagnostics from
  [aowlsuggest](https://github.com/aoughwl/aowlsuggest) over the same buffer —
  so both semantic and syntax errors reflect what you're typing.
- **Navigation** — go to **definition**, **declaration**, **typeDefinition**,
  **implementation**, find **references**, **documentHighlight**, and **hover**,
  via `nimony check --def/--usages` (idetools), also run **over the live
  buffer** so a symbol you just typed resolves before you save.
- **Symbols** — **documentSymbol** and **workspaceSymbol**, from `aowllens decls`.
- **completion** — module symbols filtered by the identifier prefix under the
  cursor (via `aowllens decls`/`index`).
- **codeAction** — quick-fixes delegated to `aowlsuggest` (its recovering-syntax
  fixes with "did you mean" alternatives).
- **semanticTokens/full** — declaration-site highlighting from `aowllens decls`.
- **rename** / **prepareRename** — WorkspaceEdit across every reference.
- **foldingRange** and **selectionRange** — indentation/word heuristics.
- **cache pruning** — the per-module nimcache pool is bounded (LRU eviction on
  `didClose`), so it can't grow without limit.

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
