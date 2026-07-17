## idetools.nim — goto-definition / find-references via `nimony check --def/--usages`.
##
## Record (tab-separated):
##   def|use \t symkind \t sym \t sig \t container \t file \t line \t col
## line is 1-based, col is 0-based. The `--def:/--usages:` request line & col are
## 1-based.

import std/strutils
import protocol, uris, state, driver

type
  Rec = object
    kind: string
    file: string
    line, col: int
    valid: bool

proc parseRecord(line: string): Rec =
  result = Rec(kind: "", file: "", line: 0, col: 0, valid: false)
  if not (startsWith(line, "def\t") or startsWith(line, "use\t")): return
  let parts = split(line, '\t')
  if parts.len < 8: return
  result.kind = parts[0]
  result.file = parts[parts.len - 3]
  var ok1 = false
  var ok2 = false
  try:
    result.line = parseInt(strip(parts[parts.len - 2])); ok1 = true
    result.col = parseInt(strip(parts[parts.len - 1])); ok2 = true
  except:
    return
  result.valid = ok1 and ok2

proc absPathOf(cfg: Config; p: string): string =
  if p.len > 0 and p[0] == '/': return p
  let root = if cfg.projectRoot.len > 0: cfg.projectRoot else: "."
  result = root & "/" & p

proc toLocation(cfg: Config; r: Rec): Location =
  let l = max(0, r.line - 1)
  let c = max(0, r.col)
  Location(uri: pathToUri(absPathOf(cfg, r.file)), rng: mkRange(l, c, l, c))

proc locKey(l: Location): string =
  l.uri & "#" & $l.rng.start.line & ":" & $l.rng.start.character

proc containsStr(xs: seq[string]; s: string): bool =
  for i in 0 ..< xs.len:
    if xs[i] == s: return true
  return false

proc collect(cfg: Config; output, want: string; seen: var seq[string];
             acc: var seq[Location]) =
  for line in splitLines(output):
    let r = parseRecord(line)
    if not r.valid: continue
    if want.len > 0 and r.kind != want: continue
    let loc = toLocation(cfg, r)
    let k = locKey(loc)
    if not containsStr(seen, k):
      seen.add k
      acc.add loc

proc definition*(cfg: Config; file: string; p: Position): seq[Location] =
  let cf = canonFile(cfg, file)
  let track = "--def:" & cf & "," & $(p.line + 1) & "," & $(p.character + 1)
  let r = run(cfg, "check", file, @[track])
  result = @[]
  var seen: seq[string] = @[]
  collect(cfg, r.output, "", seen, result)

proc references*(cfg: Config; file: string; p: Position;
                 extraRoots: seq[string] = @[]): seq[Location] =
  let cf = canonFile(cfg, file)
  result = @[]
  var seen: seq[string] = @[]
  # usages inside the target module
  let ut = "--usages:" & cf & "," & $(p.line + 1) & "," & $(p.character + 1)
  let r0 = run(cfg, "check", file, @[ut])
  collect(cfg, r0.output, "use", seen, result)
  # cross-file usages: run the same query rooted at each other open document
  for i in 0 ..< extraRoots.len:
    let e = extraRoots[i]
    if canonFile(cfg, e) == cf: continue
    let r1 = run(cfg, "check", e, @[ut])
    collect(cfg, r1.output, "use", seen, result)
  # declaration site
  let dt = "--def:" & cf & "," & $(p.line + 1) & "," & $(p.character + 1)
  let r2 = run(cfg, "check", file, @[dt])
  collect(cfg, r2.output, "def", seen, result)
