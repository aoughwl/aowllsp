## syntaxdiag.nim — recovering *syntax* diagnostics for the LIVE buffer, from
## aowlsuggest (which drives aowlparser). `nimony check` aborts on the first
## syntax error and only sees the on-disk file; aowlsuggest recovers past every
## error and reads the unsaved buffer over stdin — so this fills the gap between
## keystrokes. Off when aowlsuggest isn't configured.

import std/json
import protocol, state, diagnostics
import aowlkit/subprocess

proc severityFrom(s: string): DiagnosticSeverity =
  case s
  of "error": dsError
  of "warning": dsWarning
  of "hint": dsHint
  else: dsError

proc parseOne(el: JsonNode; file: string; d: var FileDiag): bool =
  ## Decode one aowlsuggest diagnostic object (line 1-based, col/endCol 0-based).
  var sev = dsError
  var code = ""
  var msg = ""
  var line = 0
  var col = 0
  var endCol = 0
  var sawLine = false
  for k, v in pairs(el):
    case k
    of "severity": sev = severityFrom(v.getStr)
    of "code": code = v.getStr
    of "message": msg = v.getStr
    of "line": line = int(v.getInt); sawLine = true
    of "col": col = int(v.getInt)
    of "endCol": endCol = int(v.getInt)
    else: discard
  if not sawLine: return false
  let l = if line > 0: line - 1 else: 0
  var ec = endCol
  if ec <= col: ec = col + 1
  let fullMsg = if code.len > 0: msg & " [" & code & "]" else: msg
  d = FileDiag(file: file, diag: Diagnostic(
    rng: mkRange(l, col, l, ec), severity: sev, source: "aowlsuggest",
    message: fullMsg, related: @[]))
  return true

proc syntaxDiagnostics*(cfg: Config; file, bufferText: string): seq[FileDiag] =
  ## Run `aowlsuggest check --stdin --filename:<file> --format:json` over the
  ## buffer and decode its diagnostics. Empty when aowlsuggest is unavailable.
  result = @[]
  if cfg.aowlsuggestExe.len == 0: return
  let args = @["check", "--stdin", "--filename:" & file, "--format:json"]
  let cap = runWithInput(cfg.aowlsuggestExe, args, bufferText)
  if not cap.ok or cap.output.len == 0: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return
  var arr = tree.root
  if arr.kind != JArray: return
  for el in items(arr):
    if el.kind != JObject: continue
    var d = default(FileDiag)
    if parseOne(el, file, d):
      result.add d
