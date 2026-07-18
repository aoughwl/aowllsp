## completion.nim — LSP textDocument/completion.
##
## Gathers candidate symbols from the `aowllens` NIF-artifact reader (the same
## seam navigation uses) and filters them by the identifier prefix under the
## cursor. Candidates come from three places, unioned + deduped by name:
##   1. `aowllens decls <snif>` on THIS file's main artifact — its own decls.
##   2. `aowllens index <snif>` on the same artifact — the module's exports.
##   3. `aowllens decls` on EVERY `*.s.nif` under `<projectRoot>/nimcache/lsp/`
##      — so symbols from imported modules are offered too.
##
## MEMBER ACCESS (`receiver.<here>`) is TYPE-DIRECTED: when the cursor sits after
## `ident.`, we resolve `ident` to its type via `aowllens members <snif> <ident>`
## and offer ONLY that type's fields, enum values, and the routines that take it as
## their first parameter (UFCS/methods), following `object of Base` for inherited
## members. If the receiver can't be resolved (an expression, an unknown name), we
## fall back to plain prefix completion so nothing is ever lost.
##
## LIMITATIONS (honest scope):
##   * No scope-awareness for PLAIN completion — every module-level symbol in the
##     warm cache is a candidate regardless of visibility at the cursor.
##   * Member resolution is by NAME: a bare-identifier receiver (a local/param/
##     global binding or a type name). A compound receiver (`a.b.`) resolves only
##     if the trailing name `b` is itself a resolvable binding/type.
##   * Filtering is a case-sensitive prefix match on the demangled name.

import std/[strutils, os, dirs, paths, tables, sets, json]
import state, driver
import aowlkit/json
import aowlkit/subprocess

# ── LSP CompletionItemKind mapping ──────────────────────────────────────────

proc among(s: string; xs: openArray[string]): bool =
  for i in 0 ..< xs.len:
    if xs[i] == s: return true
  return false

proc kindToLsp(kind: string): int =
  ## NIF decl tag → LSP CompletionItemKind int.
  if among(kind, ["proc", "func", "method", "converter", "iterator",
                  "template", "macro"]):
    3            # Function
  elif among(kind, ["type", "object"]):
    7            # Class
  elif kind == "enum":
    13           # Enum
  elif among(kind, ["let", "glet", "const"]):
    21           # Constant
  elif among(kind, ["var", "gvar"]):
    6            # Variable
  else:
    1            # Text

# ── prefix extraction ───────────────────────────────────────────────────────

proc isIdentChar(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
  (c >= '0' and c <= '9') or c == '_'

proc reversed(s: string): string =
  result = ""
  var i = s.len - 1
  while i >= 0:
    result.add s[i]
    dec i

proc prefixAt(bufferText: string; line, col: int): string =
  ## The identifier characters immediately to the left of (line, col).
  var lines = split(bufferText, '\n')
  if line < 0 or line >= lines.len: return ""
  let ln = lines[line]
  var c = col
  if c > ln.len: c = ln.len
  if c < 0: c = 0
  var acc = ""
  var i = c - 1
  while i >= 0 and isIdentChar(ln[i]):
    acc.add ln[i]
    dec i
  result = reversed(acc)

proc receiverAt(bufferText: string; line, col: int; startCol: var int): string =
  ## If the cursor is at `receiver.<prefix>` (a `.` immediately precedes the
  ## identifier prefix under the cursor), return the `receiver` identifier and set
  ## `startCol` to the column where it begins (for a position-precise type query).
  ## "" when this is not a member access.
  startCol = -1
  var lines = split(bufferText, '\n')
  if line < 0 or line >= lines.len: return ""
  let ln = lines[line]
  var c = col
  if c > ln.len: c = ln.len
  if c < 0: c = 0
  # step back over the identifier prefix currently being typed
  var i = c - 1
  while i >= 0 and isIdentChar(ln[i]): dec i
  # the char immediately before the prefix must be the member dot
  if i < 0 or ln[i] != '.': return ""
  # The token left of the dot is the receiver. If it ends in a CALL `)` or INDEX
  # `]` suffix (`foo().`, `xs[i].`), bracket-match back over the suffix so we land
  # on the HEAD identifier — the callee / container. `typeat` on that head returns
  # the call's / index's result type (a routine or the `[]` operator resolves to
  # its return type), which IS the receiver expression's type.
  var k = i - 1
  if k >= 0 and (ln[k] == ')' or ln[k] == ']'):
    let closeCh = ln[k]
    let openCh = if closeCh == ')': '(' else: '['
    var depth = 0
    while k >= 0:
      if ln[k] == closeCh: inc depth
      elif ln[k] == openCh:
        dec depth
        if depth == 0: break
      dec k
    if k < 0: return ""            # unbalanced on this line — give up (fall back)
    dec k                          # step to just before the matching open bracket
  # read the head identifier ending at k
  var acc = ""
  var j = k
  while j >= 0 and isIdentChar(ln[j]):
    acc.add ln[j]
    dec j
  if acc.len == 0: return ""       # e.g. `(a + b).x` — no head identifier to resolve
  startCol = j + 1                 # first char of the head identifier
  result = reversed(acc)

# ── member-access LSP kind mapping ──────────────────────────────────────────

proc memberKindToLsp(kind: string): int =
  ## NIF member tag → LSP CompletionItemKind int.
  if kind == "fld": 5            # Field
  elif kind == "efld": 20       # EnumMember
  elif kind == "method": 2      # Method
  elif among(kind, ["proc", "func", "converter", "iterator", "template", "macro"]):
    3                           # Function
  else: 1                       # Text

# ── candidate collection ────────────────────────────────────────────────────

proc addCand(name, kind, sym: string; prefix: string;
             seen: var HashSet[string]; names: var seq[string];
             kindOf: var Table[string, int]; detailOf: var Table[string, string]) =
  if name.len == 0: return
  # Skip compiler-internal locals that are never useful completions.
  if among(kind, ["result", "param"]): return
  if prefix.len > 0 and not startsWith(name, prefix): return
  if seen.containsOrIncl(name): return
  names.add name
  kindOf[name] = kindToLsp(kind)
  detailOf[name] = if kind.len > 0: kind else: sym

proc collectDecls(cfg: Config; snif, prefix: string;
                  seen: var HashSet[string]; names: var seq[string];
                  kindOf: var Table[string, int];
                  detailOf: var Table[string, string]) =
  ## `aowllens decls <snif>` → a JSON array of {sym,name,kind,file,line,col}.
  if cfg.aowllensExe.len == 0 or snif.len == 0: return
  let cap = runCaptured(cfg.aowllensExe, @["decls", snif], "", true)
  if not cap.ok: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return
  var arr = tree.root
  if kind(arr) != JArray: return
  for el in items(arr):
    if kind(el) != JObject: continue
    var name = ""
    var kd = ""
    var sym = ""
    for k, v in pairs(el):
      case k
      of "name": name = getStr(v)
      of "kind": kd = getStr(v)
      of "sym": sym = getStr(v)
      else: discard
    addCand(name, kd, sym, prefix, seen, names, kindOf, detailOf)

proc collectExports(cfg: Config; snif, prefix: string;
                    seen: var HashSet[string]; names: var seq[string];
                    kindOf: var Table[string, int];
                    detailOf: var Table[string, string]) =
  ## `aowllens index <snif>` → an OBJECT with an "exports" array of {sym,name,kind}.
  if cfg.aowllensExe.len == 0 or snif.len == 0: return
  let cap = runCaptured(cfg.aowllensExe, @["index", snif], "", true)
  if not cap.ok: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return
  var obj = tree.root
  if kind(obj) != JObject: return
  for k, v in pairs(obj):
    if k != "exports": continue
    if kind(v) != JArray: continue
    for el in items(v):
      if kind(el) != JObject: continue
      var name = ""
      var kd = ""
      var sym = ""
      for k2, v2 in pairs(el):
        case k2
        of "name": name = getStr(v2)
        of "kind": kd = getStr(v2)
        of "sym": sym = getStr(v2)
        else: discard
      addCand(name, kd, sym, prefix, seen, names, kindOf, detailOf)

proc massageMemberAccess(bufferText: string; line, dotCol: int): string =
  ## Blank the member-access dot and the partial member name after it, so a line
  ## the user is mid-typing (`o.inner.xy`, or a dangling `o.inner.`) PARSES —
  ## otherwise nimony rejects the whole module and there is no `.s.nif` to resolve
  ## the receiver's type against. Every column left of the dot is preserved, so a
  ## position query still lands on the same receiver symbol.
  var lines = split(bufferText, '\n')
  if line < 0 or line >= lines.len: return bufferText
  let ln = lines[line]
  if dotCol < 0 or dotCol >= ln.len or ln[dotCol] != '.': return bufferText
  var e = dotCol + 1
  while e < ln.len and isIdentChar(ln[e]): inc e
  var res = ""
  for k in 0 ..< ln.len:
    if k >= dotCol and k < e: res.add ' '
    else: res.add ln[k]
  lines[line] = res
  result = ""
  for k in 0 ..< lines.len:
    if k > 0: result.add '\n'
    result.add lines[k]

proc typeAtQuery(cfg: Config; snif: string; line, col: int): string =
  ## `aowllens typeat <snif> <line> <col>` → the type base name at that position,
  ## or "" if nothing resolves. `line` is 1-based, `col` 0-based (NIF convention).
  if cfg.aowllensExe.len == 0 or snif.len == 0: return ""
  let cap = runCaptured(cfg.aowllensExe,
                        @["typeat", snif, $line, $col], "", true)
  if not cap.ok: return ""
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return ""
  let obj = tree.root
  if kind(obj) != JObject: return ""
  for k, v in pairs(obj):
    if k == "type": return getStr(v)
  return ""

proc collectMembers(cfg: Config; snif, receiver, prefix: string;
                    seen: var HashSet[string]; names: var seq[string];
                    kindOf: var Table[string, int];
                    detailOf: var Table[string, string]) =
  ## `aowllens members <snif> <receiver>` → a JSON array of {name,kind,detail}.
  ## Adds each member (filtered by `prefix`) to the candidate set. Members that
  ## begin with an operator char (a symbolic proc a `.` can't reach) are skipped.
  if cfg.aowllensExe.len == 0 or snif.len == 0 or receiver.len == 0: return
  let cap = runCaptured(cfg.aowllensExe, @["members", snif, receiver], "", true)
  if not cap.ok: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(cap.output)
  except:
    return
  var arr = tree.root
  if kind(arr) != JArray: return
  for el in items(arr):
    if kind(el) != JObject: continue
    var name = ""
    var kd = ""
    var detail = ""
    for k, v in pairs(el):
      case k
      of "name": name = getStr(v)
      of "kind": kd = getStr(v)
      of "detail": detail = getStr(v)
      else: discard
    if name.len == 0: continue
    if not isIdentChar(name[0]): continue           # skip symbolic operators
    if prefix.len > 0 and not startsWith(name, prefix): continue
    if seen.containsOrIncl(name): continue
    names.add name
    kindOf[name] = memberKindToLsp(kd)
    detailOf[name] = detail

proc lspSnifs(cfg: Config): seq[string] =
  ## Every `*.s.nif` under `<projectRoot>/nimcache/lsp/` (one dir per module).
  result = @[]
  let root = if cfg.projectRoot.len > 0: cfg.projectRoot else: "."
  let base = root & "/nimcache/lsp"
  if not dirExists(base): return
  try:
    for kind, p in walkDir(path(base)):
      let ps = $p
      if kind == pcFile:
        if endsWith(ps, ".s.nif") and not endsWith(ps, ".s.idx.nif"):
          result.add ps
      elif kind == pcDir:
        try:
          for k2, f in walkDir(path(ps)):
            if k2 == pcFile:
              let fs = $f
              if endsWith(fs, ".s.nif") and not endsWith(fs, ".s.idx.nif"):
                result.add fs
        except:
          discard
  except:
    discard

# ── sort (selection, ascending, case-sensitive) ─────────────────────────────

proc sortNames(names: var seq[string]) =
  for a in 0 ..< names.len:
    var best = a
    for b in a + 1 ..< names.len:
      if names[b] < names[best]: best = b
    if best != a:
      let tmp = names[a]
      names[a] = names[best]
      names[best] = tmp

# ── public entry ────────────────────────────────────────────────────────────

proc completions*(cfg: Config; file: string; line, col: int;
                  bufferText: string): string =
  ## Returns `{"isIncomplete":false,"items":[ CompletionItem... ]}` as a string.
  ## line/col are 0-based (LSP). See module doc for scope limitations.
  const cap = 200
  let prefix = prefixAt(bufferText, line, col)

  var seen = initHashSet[string]()
  var names: seq[string] = @[]
  var kindOf = initTable[string, int]()
  var detailOf = initTable[string, string]()

  let mine = mainArtifact(cfg, file, ".s.nif")
  let snifs = lspSnifs(cfg)

  # MEMBER ACCESS: `receiver.<prefix>` → resolve the receiver's type and offer
  # ONLY its members (fields/enum-values/first-param routines).
  #   1. POSITION-PRECISE: ask aowllens `typeat` for the type of the expression at
  #      the receiver's position — this resolves field chains (`a.b.c.`) and
  #      shadowed names exactly, since each occurrence carries its own symbol.
  #   2. NAME-BASED fallback: resolve the receiver identifier by name.
  #   3. Plain prefix completion, if neither resolves.
  # Members are gathered from this file's artifact and the warm cache (the type
  # may be defined in an import).
  var recvStart = -1
  let receiver = receiverAt(bufferText, line, col, recvStart)
  if receiver.len > 0:
    # The live buffer is usually mid-edit (`o.inner.` / `o.inner.xy`), which does
    # NOT parse — so compile a MASSAGED copy (the dangling member access blanked,
    # columns preserved) to get a fresh `.s.nif` that reflects the in-flight edit.
    # Fall back to the last on-disk artifact if that compile yields nothing.
    var typeSnif = mine
    let dotCol = col - prefix.len - 1
    let massaged = massageMemberAccess(bufferText, line, dotCol)
    let live = liveArtifact(cfg, file, massaged, ".s.nif")
    if live.len > 0: typeSnif = live
    # 1. position-precise type resolution (line is 1-based for the NIF)
    if recvStart >= 0:
      let resolved = typeAtQuery(cfg, typeSnif, line + 1, recvStart)
      if resolved.len > 0:
        collectMembers(cfg, typeSnif, resolved, prefix, seen, names, kindOf, detailOf)
        for i in 0 ..< snifs.len:
          collectMembers(cfg, snifs[i], resolved, prefix, seen, names, kindOf, detailOf)
    # 2. name-based fallback when the position query found nothing
    if names.len == 0:
      collectMembers(cfg, typeSnif, receiver, prefix, seen, names, kindOf, detailOf)
      for i in 0 ..< snifs.len:
        collectMembers(cfg, snifs[i], receiver, prefix, seen, names, kindOf, detailOf)
    if names.len > 0:
      sortNames(names)
      if names.len > cap: names.setLen(cap)
      var mitems = ""
      for i in 0 ..< names.len:
        let nm = names[i]
        let ki = getOrDefault(kindOf, nm, 1)
        let dt = getOrDefault(detailOf, nm, "")
        if mitems.len > 0: mitems.add ","
        mitems.add "{\"label\":" & jStr(nm) &
                   ",\"kind\":" & $ki &
                   ",\"detail\":" & jStr(dt) & "}"
      return "{\"isIncomplete\":false,\"items\":[" & mitems & "]}"

  # 1+2: this file's own decls and exports.
  collectDecls(cfg, mine, prefix, seen, names, kindOf, detailOf)
  collectExports(cfg, mine, prefix, seen, names, kindOf, detailOf)

  # 3: decls from every module in the warm LSP cache (imported symbols).
  for i in 0 ..< snifs.len:
    if names.len >= cap and prefix.len == 0: break
    collectDecls(cfg, snifs[i], prefix, seen, names, kindOf, detailOf)

  sortNames(names)
  if names.len > cap:
    names.setLen(cap)

  var items = ""
  for i in 0 ..< names.len:
    let nm = names[i]
    let ki = getOrDefault(kindOf, nm, 1)
    let dt = getOrDefault(detailOf, nm, "")
    if items.len > 0: items.add ","
    items.add "{\"label\":" & jStr(nm) &
              ",\"kind\":" & $ki &
              ",\"detail\":" & jStr(dt) & "}"
  result = "{\"isIncomplete\":false,\"items\":[" & items & "]}"
