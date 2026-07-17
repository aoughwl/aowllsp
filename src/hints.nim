## hints.nim — the "extra" LSP features that ride on the same seams as the core
## ones, no new type info required:
##
##   * signatureHelp   — the callee's declaration line, with the active
##                       parameter highlighted (reuses goto-definition).
##   * codeLens        — a "N references" lens over every top-level decl
##                       (lazy: the count is computed in codeLens/resolve so
##                       opening a file stays cheap).
##   * documentLink    — `import` / `include` module names linked to their file.
##
## Everything here is derived from what `nimony` and `aowllens` already give us
## (definition, references, decls) — no formatter and no new NIF reading.

import std/[strutils, syncio, os]
import protocol, state, uris, idetools, symbols
import aowlkit/json as ajson

# --- line access ------------------------------------------------------------

proc nthLine(text: string; n: int): string =
  ## Line `n` (0-based) of `text`, or "" if out of range.
  var cur = 0
  for ln in splitLines(text):
    if cur == n: return ln
    inc cur
  return ""

proc diskLine(file: string; n: int): string =
  var content = ""
  try:
    content = readFile(file)
  except:
    return ""
  return nthLine(content, n)

proc isIdentChar(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
  (c >= '0' and c <= '9') or c == '_'

# --- signatureHelp ----------------------------------------------------------

proc calleeAt(line: string; col: int; calleeCol: var int;
              activeParam: var int): bool =
  ## Scan LEFT from `col` on `line` to the innermost unmatched '(' of a call,
  ## count top-level commas after it (the active parameter), and find the start
  ## column of the callee identifier just before that '('. Returns false if the
  ## cursor is not inside a call's argument list.
  var i = if col > line.len: line.len else: col
  dec i
  var depth = 0
  var commas = 0
  while i >= 0:
    let c = line[i]
    if c == ')' or c == ']' or c == '}':
      inc depth
    elif c == '(' or c == '[' or c == '{':
      if depth == 0:
        if c != '(': return false        # inside a bracket/brace, not a call
        break
      dec depth
    elif c == ',' and depth == 0:
      inc commas
    dec i
  if i < 0: return false                  # no opening '(' to the left
  activeParam = commas
  # skip spaces between '(' and the callee name
  var j = i - 1
  while j >= 0 and (line[j] == ' ' or line[j] == '\t'): dec j
  if j < 0 or not isIdentChar(line[j]): return false
  var e = j
  while j >= 0 and isIdentChar(line[j]): dec j
  calleeCol = j + 1
  return e >= calleeCol

proc paramLabels(sig: string): seq[string] =
  ## Split the parenthesised parameter group of a declaration line into the
  ## individual parameter substrings (top-level commas only).
  result = @[]
  var depth = 0
  var start = -1
  var i = 0
  while i < sig.len:
    let c = sig[i]
    if start < 0:
      if c == '(': start = i + 1
    else:
      if c == '(' or c == '[' or c == '{': inc depth
      elif c == ']' or c == '}': dec depth
      elif c == ')':
        if depth == 0:
          let piece = strip(substr(sig, start, i - 1))
          if piece.len > 0: result.add piece
          return
        dec depth
      elif c == ',' and depth == 0:
        let piece = strip(substr(sig, start, i - 1))
        if piece.len > 0: result.add piece
        start = i + 1
    inc i

proc signatureHelpJson*(cfg: Config; file: string; line, ch: int;
                        bufferText: string): string =
  ## Best-effort SignatureHelp: the declaration line of the call's callee, with
  ## its parameters split out and the active one selected.
  let ltext = if bufferText.len > 0: nthLine(bufferText, line)
              else: diskLine(file, line)
  if ltext.len == 0: return "null"
  var calleeCol = 0
  var activeParam = 0
  if not calleeAt(ltext, ch, calleeCol, activeParam): return "null"
  let locs = definition(cfg, file, pos(line, calleeCol), bufferText)
  if locs.len == 0: return "null"
  let dfile = uriToPath(locs[0].uri)
  let dline = strip(
    if bufferText.len > 0 and dfile == file: nthLine(bufferText, locs[0].rng.start.line)
    else: diskLine(dfile, locs[0].rng.start.line))
  if dline.len == 0: return "null"
  let params = paramLabels(dline)
  var pj = "["
  for i in 0 ..< params.len:
    if i > 0: pj.add ","
    pj.add "{\"label\":" & ajson.jStr(params[i]) & "}"
  pj.add "]"
  let active = if params.len == 0: 0
               elif activeParam >= params.len: params.len - 1
               else: activeParam
  result = "{\"signatures\":[{\"label\":" & ajson.jStr(dline) &
    ",\"parameters\":" & pj & "}],\"activeSignature\":0,\"activeParameter\":" &
    $active & "}"

# --- codeLens ---------------------------------------------------------------

proc onlyRoutines(kind: string): bool =
  kind == "proc" or kind == "func" or kind == "method" or
  kind == "converter" or kind == "macro" or kind == "template" or
  kind == "iterator" or kind == "type"

proc codeLensesJson*(cfg: Config; file, uri: string): string =
  ## One unresolved lens per top-level routine/type. The reference count is
  ## filled in later by codeLens/resolve, so opening a file spawns no extra
  ## `nimony` runs.
  let decls = fileDecls(cfg, file)
  var parts: seq[string] = @[]
  for i in 0 ..< decls.len:
    let d = decls[i]
    if not onlyRoutines(d.kind): continue
    let rng = rangeJson(mkRange(d.line, d.col, d.line, d.col + d.name.len))
    # `data` carries what resolve needs: the URI and the name's position.
    let data = "{\"uri\":" & ajson.jStr(uri) & ",\"line\":" & $d.line &
      ",\"character\":" & $d.col & "}"
    parts.add "{\"range\":" & rng & ",\"data\":" & data & "}"
  result = "["
  for i in 0 ..< parts.len:
    if i > 0: result.add ","
    result.add parts[i]
  result.add "]"

proc resolveCodeLensJson*(cfg: Config; uri: string; line, ch: int;
                          openRoots: seq[string]; bufferText: string): string =
  ## Fill a lens's command with the reference count for the symbol at its range.
  let file = uriToPath(uri)
  let refs = references(cfg, file, pos(line, ch), openRoots, bufferText)
  let n = refs.len
  let title = (if n == 1: "1 reference" else: $n & " references")
  let rng = rangeJson(mkRange(line, ch, line, ch))
  result = "{\"range\":" & rng & ",\"command\":{\"title\":" & ajson.jStr(title) &
    ",\"command\":\"\"}}"

# --- documentLink -----------------------------------------------------------

proc resolveModule(cfg: Config; docDir, name: string): string =
  ## Map an imported module name to an existing file path, or "" if none found.
  ## Tries the doc's own directory first, then each configured extra path.
  var rel = name
  # `std / strutils` style already normalised by the caller into `std/strutils`.
  let cands = @[docDir & "/" & rel & ".nim",
                docDir & "/" & rel & ".nimony"]
  for c in cands:
    if fileExists(c): return c
  for i in 0 ..< cfg.extraPaths.len:
    let p = cfg.extraPaths[i]
    let c1 = p & "/" & rel & ".nim"
    if fileExists(c1): return c1
    let c2 = p & "/" & rel & ".nimony"
    if fileExists(c2): return c2
  return ""

proc dirOf(p: string): string =
  var i = p.len - 1
  while i >= 0 and p[i] != '/': dec i
  if i <= 0: "." else: substr(p, 0, i - 1)

proc addLink(parts: var seq[string]; lineNo, startCol, endCol: int; target: string) =
  let rng = rangeJson(mkRange(lineNo, startCol, lineNo, endCol))
  parts.add "{\"range\":" & rng & ",\"target\":" & ajson.jStr(pathToUri(target)) & "}"

proc documentLinksJson*(cfg: Config; file, bufferText: string): string =
  ## Link the module names in `import` / `include` / `from ... import` lines to
  ## their files on disk. A name that doesn't resolve is simply skipped.
  let text = if bufferText.len > 0: bufferText
             else: (try: readFile(file) except: "")
  let docDir = dirOf(file)
  var parts: seq[string] = @[]
  var lineNo = 0
  for raw in splitLines(text):
    let ln = raw
    let t = strip(ln)
    var rest = ""
    var kw = 0
    if startsWith(t, "import "): rest = substr(t, 7, t.len - 1); kw = 7
    elif startsWith(t, "include "): rest = substr(t, 8, t.len - 1); kw = 8
    elif startsWith(t, "from "):
      # from X import Y  ->  link only X
      let after = substr(t, 5, t.len - 1)
      let sp = find(after, " ")
      rest = if sp < 0: after else: substr(after, 0, sp - 1)
      kw = 5
    if rest.len > 0:
      # indentation offset so columns line up with the raw line
      var indent = 0
      while indent < ln.len and (ln[indent] == ' ' or ln[indent] == '\t'): inc indent
      # split the import list on commas; each item may be `a/b/c` or `a / b`
      var col = indent + kw
      for item in split(rest, ','):
        let itemTrim = strip(item)
        if itemTrim.len > 0 and itemTrim[0] != '[':
          # normalise `std / foo` -> `std/foo`
          var norm = ""
          for c in itemTrim:
            if c != ' ': norm.add c
          # strip a trailing "as alias" if present (import x as y)
          let asPos = find(norm, "as")
          let modName = norm   # keep full path form for resolution
          let target = resolveModule(cfg, docDir, modName)
          if target.len > 0:
            # place the link over the item's occurrence in the raw line
            let at = find(ln, itemTrim)
            if at >= 0:
              addLink(parts, lineNo, at, at + itemTrim.len, target)
        col = col + item.len + 1
    inc lineNo
  result = "["
  for i in 0 ..< parts.len:
    if i > 0: result.add ","
    result.add parts[i]
  result.add "]"
