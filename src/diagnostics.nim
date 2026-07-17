## diagnostics.nim — parse `nimony check` output into LSP diagnostics.
##
## Line format (line/col 1-based; col is a UTF-8 byte/codepoint):
##   path(line, col) Error: message
##   path(line, col) Trace: message      <- related info for the preceding Error
##   path(line, col) Warning: message
## The trailing `FAILURE:`/`SUCCESS:` build-summary lines are ignored.

import std/[strutils, os]
import protocol, uris, state, driver

type
  FileDiag* = object
    file*: string        ## absolute path
    diag*: Diagnostic

proc parseIntOr(s: string; ok: var bool): int =
  var v = 0
  var any = false
  var i = 0
  while i < s.len and (s[i] == ' ' or s[i] == '\t'): inc i
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    v = v * 10 + (ord(s[i]) - ord('0')); any = true; inc i
  ok = any
  result = v

proc severityOf(kind: string): DiagnosticSeverity =
  case kind
  of "Error": dsError
  of "Warning": dsWarning
  of "Hint": dsHint
  else: dsInformation

proc absPathOf(cfg: Config; p: string): string =
  if p.len > 0 and p[0] == '/': return p
  let root = if cfg.projectRoot.len > 0: cfg.projectRoot else: "."
  result = root & "/" & p

proc knownKind(k: string): bool =
  k == "Error" or k == "Warning" or k == "Trace" or k == "Hint" or k == "Info"

proc parseOne(s: string; path: var string; line, col: var int;
              kind, message: var string): bool =
  ## Parse `path(line, col) Kind: message`. Returns false if the line isn't one.
  let lp = find(s, '(')
  if lp <= 0: return false
  let rp = find(s, ')')
  if rp < 0 or rp < lp: return false
  let inside = substr(s, lp + 1, rp - 1)
  let comma = find(inside, ',')
  if comma < 0: return false
  var ok1 = false
  var ok2 = false
  line = parseIntOr(substr(inside, 0, comma - 1), ok1)
  col = parseIntOr(substr(inside, comma + 1, inside.len - 1), ok2)
  if not (ok1 and ok2): return false
  var rest = strip(substr(s, rp + 1, s.len - 1))
  let colon = find(rest, ':')
  if colon < 0: return false
  kind = strip(substr(rest, 0, colon - 1))
  if not knownKind(kind): return false
  message = strip(substr(rest, colon + 1, rest.len - 1))
  path = strip(substr(s, 0, lp - 1))
  return true

proc parseDiagnostics*(cfg: Config; raw: string): seq[FileDiag] =
  result = @[]
  var lastIdx = -1
  for rawLine in splitLines(raw):
    let line = strip(rawLine)
    if line.len == 0: continue
    if startsWith(line, "FAILURE:") or startsWith(line, "SUCCESS:"): continue
    var p = ""
    var l = 0
    var c = 0
    var kind = ""
    var msg = ""
    if not parseOne(line, p, l, c, kind, msg): continue
    let key = absPathOf(cfg, p)
    let rng = mkRange(max(0, l - 1), max(0, c - 1), max(0, l - 1), max(0, c))
    if kind == "Trace" and lastIdx >= 0:
      var fd = result[lastIdx]
      fd.diag.related.add RelatedInfo(uri: pathToUri(key), rng: rng, message: msg)
      result[lastIdx] = fd
      continue
    var d = Diagnostic(rng: rng, severity: severityOf(kind), source: "nimony",
                       message: msg, related: @[])
    result.add FileDiag(file: key, diag: d)
    lastIdx = result.len - 1

proc computeDiagnostics*(cfg: Config; file: string): seq[FileDiag] =
  ## Run the checker on `file` (absolute path) and parse its diagnostics.
  let r = run(cfg, "check", file)
  result = parseDiagnostics(cfg, r.output)

proc computeDiagnosticsLive*(cfg: Config; file, bufferText: string): seq[FileDiag] =
  ## Semantic diagnostics for the UNSAVED buffer (reflects in-flight edits).
  let r = runLiveCheck(cfg, file, bufferText)
  result = parseDiagnostics(cfg, r.output)
