## callhier.nim — LSP call hierarchy.
##
##   * prepareCallHierarchy — resolve the symbol under the cursor to a
##     CallHierarchyItem (name/kind/range), stashing its declaration position in
##     `data` for the follow-up requests.
##   * incomingCalls — every reference to the symbol that sits inside a routine,
##     grouped by the enclosing routine (its caller). Built from idetools
##     references + the file's decl table.
##   * outgoingCalls — the call-expression callees inside the symbol's own body,
##     read from `aowllens calls` (the sem'd artifact). Degrades to an empty list
##     when that command isn't available, so it's never wrong, only sometimes
##     empty.

import std/[strutils, json]
import protocol, state, uris, driver, idetools, symbols
import aowlkit/json as ajson
import aowlkit/subprocess

proc routineKind(kind: string): bool =
  kind == "proc" or kind == "func" or kind == "method" or
  kind == "converter" or kind == "macro" or kind == "template" or
  kind == "iterator"

proc kindNum(kind: string): int =
  if routineKind(kind): 12         # Function
  elif kind == "type": 5           # Class
  elif kind == "const" or kind == "glet" or kind == "let": 14
  else: 13

proc itemJson(name: string; kind: int; uri: string; rng: Range;
              dataUri: string; dataLine, dataCol: int): string =
  ## A CallHierarchyItem carrying the def position in `data` for later requests.
  let r = rangeJson(rng)
  result = "{\"name\":" & ajson.jStr(name) & ",\"kind\":" & $kind &
    ",\"uri\":" & ajson.jStr(uri) & ",\"range\":" & r & ",\"selectionRange\":" & r &
    ",\"data\":{\"uri\":" & ajson.jStr(dataUri) & ",\"line\":" & $dataLine &
    ",\"character\":" & $dataCol & "}}"

# --- prepare ----------------------------------------------------------------

proc prepareCallHierarchy*(cfg: Config; file: string; p: Position;
                           bufferText: string): string =
  let locs = definition(cfg, file, p, bufferText)
  if locs.len == 0: return "null"
  let dfile = uriToPath(locs[0].uri)
  let dline = locs[0].rng.start.line
  let dcol = locs[0].rng.start.character
  # name + kind from the declaration table of the def's file
  let decls = fileDecls(cfg, dfile)
  var name = ""
  var kind = ""
  for i in 0 ..< decls.len:
    if decls[i].line == dline:
      name = decls[i].name; kind = decls[i].kind; break
  if name.len == 0: return "null"
  let rng = mkRange(dline, dcol, dline, dcol + name.len)
  result = "[" & itemJson(name, kindNum(kind), locs[0].uri, rng,
                          locs[0].uri, dline, dcol) & "]"

# --- incoming ---------------------------------------------------------------

proc baseSym(sym: string): string =
  ## `foo.0.abc` -> `foo` (strip the nimony symbol suffix for display).
  var i = 0
  while i < sym.len and sym[i] != '.': inc i
  substr(sym, 0, i - 1)

type CallRec = object
  caller: string   ## enclosing routine sym
  callee: string   ## called sym
  line: int        ## 1-based (aowllens posFragment)
  col: int         ## 0-based

proc allCalls(cfg: Config; snif: string): seq[CallRec] =
  ## Every call edge in the artifact, via `aowllens calls <snif>`. Empty if the
  ## command is unavailable or errors (graceful degradation — never wrong).
  result = @[]
  if cfg.aowllensExe.len == 0 or snif.len == 0: return
  let cap = runCaptured(cfg.aowllensExe, @["calls", snif], "", false)
  if not cap.ok or cap.output.len == 0: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return
  let arr = tree.root
  if arr.kind != JArray: return
  for el in items(arr):
    if el.kind != JObject: continue
    var rec = CallRec(caller: "", callee: "", line: 0, col: 0)
    for k, v in pairs(el):
      case k
      of "caller": rec.caller = v.getStr
      of "callee": rec.callee = v.getStr
      of "line": rec.line = int(v.getInt)
      of "col": rec.col = int(v.getInt)
      else: discard
    if rec.callee.len > 0 and rec.caller.len > 0: result.add rec

proc declPos(decls: seq[SymPos]; name: string; kind: var string;
             dl, dc: var int): bool =
  ## Find the decl whose base name matches `name`; report its kind and position.
  for i in 0 ..< decls.len:
    if decls[i].name == name:
      kind = decls[i].kind; dl = decls[i].line; dc = decls[i].col
      return true
  return false

proc symAtLine(decls: seq[SymPos]; line: int): string =
  for i in 0 ..< decls.len:
    if decls[i].line == line: return decls[i].name
  return ""

# `mid` is CALLED by whoever has a call edge to it → incoming.
proc incomingCallsJson*(cfg: Config; uri: string; line, ch: int;
                        openRoots: seq[string]; bufferText: string): string =
  let file = uriToPath(uri)
  let snif = mainArtifact(cfg, file, ".s.nif")
  let decls = fileDecls(cfg, file)
  let self = symAtLine(decls, line)
  if self.len == 0: return "[]"
  let edges = allCalls(cfg, snif)
  var keys: seq[string] = @[]
  var itemJsons: seq[string] = @[]
  var ranges: seq[string] = @[]
  for i in 0 ..< edges.len:
    if baseSym(edges[i].callee) != self: continue
    let caller = baseSym(edges[i].caller)
    let cl = if edges[i].line > 0: edges[i].line - 1 else: 0
    let rj = rangeJson(mkRange(cl, edges[i].col, cl, edges[i].col + self.len))
    var found = -1
    for k in 0 ..< keys.len:
      if keys[k] == caller: found = k; break
    if found < 0:
      var kd = ""
      var dl = 0
      var dc = 0
      if not declPos(decls, caller, kd, dl, dc): continue
      keys.add caller
      let rng = mkRange(dl, dc, dl, dc + caller.len)
      itemJsons.add itemJson(caller, kindNum(kd), uri, rng, uri, dl, dc)
      ranges.add rj
    else:
      ranges[found] = ranges[found] & "," & rj
  result = "["
  for k in 0 ..< keys.len:
    if k > 0: result.add ","
    result.add "{\"from\":" & itemJsons[k] & ",\"fromRanges\":[" & ranges[k] & "]}"
  result.add "]"

# what `mid` itself CALLS → outgoing.
proc outgoingCallsJson*(cfg: Config; uri: string; line, ch: int;
                        bufferText: string): string =
  let file = uriToPath(uri)
  let snif = mainArtifact(cfg, file, ".s.nif")
  let decls = fileDecls(cfg, file)
  let self = symAtLine(decls, line)
  if self.len == 0: return "[]"
  let edges = allCalls(cfg, snif)
  var keys: seq[string] = @[]
  var itemJsons: seq[string] = @[]
  var ranges: seq[string] = @[]
  for i in 0 ..< edges.len:
    if baseSym(edges[i].caller) != self: continue
    let callee = baseSym(edges[i].callee)
    let cl = if edges[i].line > 0: edges[i].line - 1 else: 0
    let rj = rangeJson(mkRange(cl, edges[i].col, cl, edges[i].col + callee.len))
    var found = -1
    for k in 0 ..< keys.len:
      if keys[k] == callee: found = k; break
    if found < 0:
      # point the callee item at its declaration when it's in this file, else
      # at the call site (editors resolve on click via definition).
      var kd = ""
      var dl = 0
      var dc = 0
      var iuri = uri
      var rl = cl
      var rc = edges[i].col
      if declPos(decls, callee, kd, dl, dc):
        rl = dl; rc = dc
      let rng = mkRange(rl, rc, rl, rc + callee.len)
      keys.add callee
      itemJsons.add itemJson(callee, 12, iuri, rng, iuri, rl, rc)
      ranges.add rj
    else:
      ranges[found] = ranges[found] & "," & rj
  result = "["
  for k in 0 ..< keys.len:
    if k > 0: result.add ","
    result.add "{\"to\":" & itemJsons[k] & ",\"fromRanges\":[" & ranges[k] & "]}"
  result.add "]"
