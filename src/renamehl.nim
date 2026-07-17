## renamehl.nim — documentHighlight and rename, built on idetools `references`.
## References come back as zero-width locations; both features widen them to the
## identifier span (length passed in by the caller, which has the document).

import protocol, uris, state, idetools
import aowlkit/json

proc documentHighlightsJson*(cfg: Config; file, uri: string; p: Position;
                             wordLen: int; bufferText = ""): string =
  ## LSP DocumentHighlight[] for the symbol under `p`, restricted to `uri`
  ## (this file). Each range spans the identifier (col .. col+wordLen).
  let locs = references(cfg, file, p, @[], bufferText)
  result = "["
  var first = true
  for i in 0 ..< locs.len:
    if locs[i].uri != uri: continue
    let l = locs[i].rng.start.line
    let c = locs[i].rng.start.character
    if not first: result.add ","
    first = false
    result.add "{\"range\":" & rangeJson(mkRange(l, c, l, c + wordLen)) &
      ",\"kind\":1}"     # 1 = Text
  result.add "]"

proc renameEditJson*(cfg: Config; file: string; p: Position; wordLen: int;
                     newName: string; openDocs: seq[string];
                     bufferText = ""): string =
  ## An LSP WorkspaceEdit renaming the symbol under `p` to `newName` across every
  ## reference (in open documents). Each occurrence's identifier span
  ## (col .. col+wordLen) is replaced with `newName`.
  let locs = references(cfg, file, p, openDocs, bufferText)
  # group edits by uri
  var uris: seq[string] = @[]
  var bodies: seq[string] = @[]
  for i in 0 ..< locs.len:
    let u = locs[i].uri
    let l = locs[i].rng.start.line
    let c = locs[i].rng.start.character
    let edit = "{\"range\":" & rangeJson(mkRange(l, c, l, c + wordLen)) &
      ",\"newText\":" & jStr(newName) & "}"
    var found = -1
    for j in 0 ..< uris.len:
      if uris[j] == u: found = j
    if found < 0:
      uris.add u
      bodies.add edit
    else:
      var b = bodies[found]
      b.add ","
      b.add edit
      bodies[found] = b
  result = "{\"changes\":{"
  for j in 0 ..< uris.len:
    if j > 0: result.add ","
    result.add jStr(uris[j]) & ":[" & bodies[j] & "]"
  result.add "}}"
