## aowllsp — a Language Server for Nimony, written in nimony.
##
## A nimony rewrite of the (Nim 2) nimony-lsp. Phase 1 covers the LSP lifecycle,
## full-text document sync, diagnostics (from `nimony check`), and navigation
## (definition / references / hover via `nimony check --def/--usages`). The
## in-process semantic-index features (completion, semantic tokens, call/type
## hierarchy) come in later phases, reading NIF through the nimony-native reader
## rather than shelling out.
##
## Everything semantic goes through `driver.nim` — the subprocess seam a future
## browser build swaps for in-process aowlparser/aowlsem calls.

import std/[syncio, json, tables, strutils]
import aowlkit/json as kjson
import framing, protocol, uris, state, document, diagnostics, idetools, syntaxdiag
import driver, symbols, completion, codeactions, semtokens, structure, renamehl
import hints, typeinfo

const serverVersion = "0.1.0"

# ── JSON-RPC request parsing (immediate extraction; cursors are lazy) ────────

proc parseHeader(root: JsonNode; meth: var string; hasId: var bool;
                 idJson: var string) =
  for k, v in pairs(root):
    case k
    of "method": meth = v.getStr
    of "id":
      hasId = true
      if v.kind == JString: idJson = "\"" & v.getStr & "\""
      else: idJson = $v.getInt
    else: discard

proc parseInitialize(root: JsonNode; rootUri: var string) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        case k2
        of "rootUri": rootUri = v2.getStr
        of "rootPath":
          if rootUri.len == 0: rootUri = pathToUri(v2.getStr)
        else: discard

proc parseDidOpen(root: JsonNode; uri, langId, text: var string; version: var int) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            case k3
            of "uri": uri = v3.getStr
            of "languageId": langId = v3.getStr
            of "version": version = int(v3.getInt)
            of "text": text = v3.getStr
            else: discard

proc parseDidChange(root: JsonNode; uri, text: var string; version: var int) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            case k3
            of "uri": uri = v3.getStr
            of "version": version = int(v3.getInt)
            else: discard
        elif k2 == "contentChanges":
          for el in items(v2):
            for k3, v3 in pairs(el):
              if k3 == "text": text = v3.getStr   # FULL sync: whole buffer

proc parseUriOnly(root: JsonNode; uri: var string) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            if k3 == "uri": uri = v3.getStr

proc parseDocPos(root: JsonNode; uri: var string; line, character: var int) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            if k3 == "uri": uri = v3.getStr
        elif k2 == "position":
          for k3, v3 in pairs(v2):
            case k3
            of "line": line = int(v3.getInt)
            of "character": character = int(v3.getInt)
            else: discard

proc parseCodeActionRange(root: JsonNode; uri: var string; loLine, hiLine: var int) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            if k3 == "uri": uri = v3.getStr
        elif k2 == "range":
          for k3, v3 in pairs(v2):
            if k3 == "start":
              for k4, v4 in pairs(v3):
                if k4 == "line": loLine = int(v4.getInt)
            elif k3 == "end":
              for k4, v4 in pairs(v3):
                if k4 == "line": hiLine = int(v4.getInt)

proc parseRename(root: JsonNode; uri: var string; line, character: var int;
                 newName: var string) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        case k2
        of "textDocument":
          for k3, v3 in pairs(v2):
            if k3 == "uri": uri = v3.getStr
        of "position":
          for k3, v3 in pairs(v2):
            case k3
            of "line": line = int(v3.getInt)
            of "character": character = int(v3.getInt)
            else: discard
        of "newName": newName = v2.getStr
        else: discard

proc parseLensData(root: JsonNode; uri: var string; line, character: var int) =
  ## codeLens/resolve: params is a CodeLens whose `data` field holds the
  ## {uri,line,character} we stashed when producing the lens.
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "data":
          for k3, v3 in pairs(v2):
            case k3
            of "uri": uri = v3.getStr
            of "line": line = int(v3.getInt)
            of "character": character = int(v3.getInt)
            else: discard

proc parseQuery(root: JsonNode; query: var string) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "query": query = v2.getStr

proc parseSelectionPositions(root: JsonNode; uri: var string;
                             positions: var seq[Position]) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            if k3 == "uri": uri = v3.getStr
        elif k2 == "positions":
          for el in items(v2):
            var line = 0
            var ch = 0
            for k3, v3 in pairs(el):
              case k3
              of "line": line = int(v3.getInt)
              of "character": ch = int(v3.getInt)
              else: discard
            positions.add pos(line, ch)

# ── responses ────────────────────────────────────────────────────────────────

proc sendResult(idJson, resultJson: string) =
  writeMessage("{\"jsonrpc\":\"2.0\",\"id\":" & idJson & ",\"result\":" &
    resultJson & "}")

proc sendNotification(meth, paramsJson: string) =
  writeMessage("{\"jsonrpc\":\"2.0\",\"method\":" & kjson.jStr(meth) &
    ",\"params\":" & paramsJson & "}")

proc locationsJson(locs: seq[Location]): string =
  result = "["
  for i in 0 ..< locs.len:
    if i > 0: result.add ","
    result.add locationJson(locs[i])
  result.add "]"

# ── diagnostics publishing ───────────────────────────────────────────────────

proc publishFor(s: ServerState; file: string) =
  ## Check `file` and publish diagnostics, grouped by URI. Files that produced no
  ## diagnostic this run still get an empty publish so stale markers clear.
  # Semantic diagnostics: over the LIVE buffer when the doc is open (so unsaved
  # edits are reflected), else the on-disk file.
  let mainUriKey = pathToUri(file)
  var fds: seq[FileDiag]
  if s.docs.hasKey(mainUriKey):
    let buf = s.docs.getOrDefault(mainUriKey).text
    fds = computeDiagnosticsLive(s.config, file, buf)
    # recovering SYNTAX diagnostics from aowlsuggest over the same buffer
    let syn = syntaxDiagnostics(s.config, file, buf)
    for i in 0 ..< syn.len: fds.add syn[i]
    # ALSO refresh the on-disk artifact (.s.nif) so the symbol/token/completion
    # features have something to read (they reflect the saved file).
    discard run(s.config, "check", file)
  else:
    fds = computeDiagnostics(s.config, file)
  var byUri = initTable[string, string]()   # uri -> JSON array body
  var order: seq[string] = @[]
  # ensure the checked file always publishes (clears old markers)
  let mainUri = pathToUri(file)
  byUri[mainUri] = ""
  order.add mainUri
  for i in 0 ..< fds.len:
    let uri = pathToUri(fds[i].file)
    if not byUri.hasKey(uri):
      byUri[uri] = ""
      order.add uri
    var body = byUri.getOrDefault(uri, "")
    if body.len > 0: body.add ","
    body.add diagnosticJson(fds[i].diag)
    byUri[uri] = body
  for i in 0 ..< order.len:
    let uri = order[i]
    sendNotification("textDocument/publishDiagnostics",
      "{\"uri\":" & kjson.jStr(uri) & ",\"diagnostics\":[" &
      byUri.getOrDefault(uri, "") & "]}")

proc openDocuments(s: ServerState): seq[string] =
  result = @[]
  for uri, doc in pairs(s.docs):
    result.add uriToPath(uri)

proc docText(s: ServerState; uri: string): string =
  if s.docs.hasKey(uri): s.docs.getOrDefault(uri).text else: ""

proc docWordLen(s: ServerState; uri: string; p: Position): int =
  if s.docs.hasKey(uri):
    let d = s.docs.getOrDefault(uri)
    wordAt(d, p).len
  else:
    0

proc sourceLine(s: ServerState; uri: string; lineNo: int): string =
  ## The text of line `lineNo` (0-based) for `uri` — from the open buffer if we
  ## have it, else from disk.
  if s.docs.hasKey(uri):
    let d = s.docs.getOrDefault(uri)
    return lineText(d, lineNo)
  var content = ""
  try:
    content = readFile(uriToPath(uri))
  except:
    return ""
  var cur = 0
  for ln in splitLines(content):
    if cur == lineNo: return ln
    inc cur
  return ""

# ── main dispatch ────────────────────────────────────────────────────────────

proc handle(s: var ServerState; body: string; shouldExit: var bool) =
  if body.len == 0: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(body)
  except:
    return
  var meth = ""
  var hasId = false
  var idJson = "null"
  parseHeader(tree.root, meth, hasId, idJson)
  case meth
  of "initialize":
    var rootUri = ""
    parseInitialize(tree.root, rootUri)
    s.rootUri = rootUri
    if rootUri.len > 0:
      s.config.projectRoot = uriToPath(rootUri)
    s.initialized = true
    # semantic-tokens legend from the module's exported type list
    var legend = "["
    for i in 0 ..< semTokenTypes.len:
      if i > 0: legend.add ","
      legend.add kjson.jStr(semTokenTypes[i])
    legend.add "]"
    sendResult(idJson, "{\"capabilities\":{" &
      "\"textDocumentSync\":1," &
      "\"definitionProvider\":true," &
      "\"declarationProvider\":true," &
      "\"typeDefinitionProvider\":true," &
      "\"implementationProvider\":true," &
      "\"referencesProvider\":true," &
      "\"documentHighlightProvider\":true," &
      "\"hoverProvider\":true," &
      "\"documentSymbolProvider\":true," &
      "\"workspaceSymbolProvider\":true," &
      "\"completionProvider\":{\"triggerCharacters\":[\".\",\"(\"]}," &
      "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}," &
      "\"codeLensProvider\":{\"resolveProvider\":true}," &
      "\"documentLinkProvider\":{\"resolveProvider\":false}," &
      "\"inlayHintProvider\":true," &
      "\"codeActionProvider\":true," &
      "\"renameProvider\":{\"prepareProvider\":true}," &
      "\"foldingRangeProvider\":true," &
      "\"selectionRangeProvider\":true," &
      "\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":" & legend &
        ",\"tokenModifiers\":[]},\"full\":true}}," &
      "\"serverInfo\":{\"name\":\"aowllsp\",\"version\":\"" & serverVersion & "\"}}")
  of "initialized":
    discard
  of "shutdown":
    s.shutdownRequested = true
    sendResult(idJson, "null")
  of "exit":
    shouldExit = true
  of "textDocument/didOpen":
    var uri = ""
    var langId = ""
    var text = ""
    var version = 0
    parseDidOpen(tree.root, uri, langId, text, version)
    if uri.len > 0:
      openDoc(s, uri, langId, version, text)
      publishFor(s, uriToPath(uri))
  of "textDocument/didChange":
    var uri = ""
    var text = ""
    var version = 0
    parseDidChange(tree.root, uri, text, version)
    if uri.len > 0 and hasDoc(s, uri):
      var d = s.docs.getOrDefault(uri)
      setText(d, version, text)
      s.docs[uri] = d
      publishFor(s, uriToPath(uri))
  of "textDocument/didSave":
    var uri = ""
    parseUriOnly(tree.root, uri)
    if uri.len > 0:
      publishFor(s, uriToPath(uri))
  of "textDocument/didClose":
    var uri = ""
    parseUriOnly(tree.root, uri)
    if uri.len > 0:
      closeDoc(s, uri)
      sendNotification("textDocument/publishDiagnostics",
        "{\"uri\":" & kjson.jStr(uri) & ",\"diagnostics\":[]}")
      pruneCaches(s.config)   # bound the per-module nimcache pool
  of "textDocument/definition":
    var uri = ""
    var line = 0
    var ch = 0
    parseDocPos(tree.root, uri, line, ch)
    if hasId:
      let locs = definition(s.config, uriToPath(uri), pos(line, ch), docText(s, uri))
      sendResult(idJson, locationsJson(locs))
  of "textDocument/references":
    var uri = ""
    var line = 0
    var ch = 0
    parseDocPos(tree.root, uri, line, ch)
    if hasId:
      let locs = references(s.config, uriToPath(uri), pos(line, ch), openDocuments(s), docText(s, uri))
      sendResult(idJson, locationsJson(locs))
  of "textDocument/hover":
    var uri = ""
    var line = 0
    var ch = 0
    parseDocPos(tree.root, uri, line, ch)
    if hasId:
      # Show the definition's source line (nimony's --def leaves the sig field
      # empty, so the declaration line itself is the useful tooltip).
      let locs = definition(s.config, uriToPath(uri), pos(line, ch), docText(s, uri))
      if locs.len > 0:
        let dline = strip(sourceLine(s, locs[0].uri, locs[0].rng.start.line))
        if dline.len > 0:
          let md = "```nim\n" & dline & "\n```"
          sendResult(idJson,
            "{\"contents\":{\"kind\":\"markdown\",\"value\":" & kjson.jStr(md) & "}}")
        else:
          sendResult(idJson, "null")
      else:
        sendResult(idJson, "null")
  of "textDocument/declaration", "textDocument/typeDefinition",
     "textDocument/implementation":
    # Best-effort: nimony idetools resolves the definition; declaration/type/impl
    # all fall back to it.
    var uri = ""
    var line = 0
    var ch = 0
    parseDocPos(tree.root, uri, line, ch)
    if hasId:
      let locs = definition(s.config, uriToPath(uri), pos(line, ch), docText(s, uri))
      sendResult(idJson, locationsJson(locs))
  of "textDocument/documentHighlight":
    var uri = ""
    var line = 0
    var ch = 0
    parseDocPos(tree.root, uri, line, ch)
    if hasId:
      let wlen = docWordLen(s, uri, pos(line, ch))
      sendResult(idJson, documentHighlightsJson(s.config, uriToPath(uri), uri,
        pos(line, ch), wlen, docText(s, uri)))
  of "textDocument/documentSymbol":
    var uri = ""
    parseUriOnly(tree.root, uri)
    if hasId:
      sendResult(idJson, documentSymbols(s.config, uriToPath(uri)))
  of "workspace/symbol":
    var query = ""
    parseQuery(tree.root, query)
    if hasId:
      sendResult(idJson, workspaceSymbols(s.config, query))
  of "textDocument/completion":
    var uri = ""
    var line = 0
    var ch = 0
    parseDocPos(tree.root, uri, line, ch)
    if hasId:
      sendResult(idJson, completions(s.config, uriToPath(uri), line, ch,
        docText(s, uri)))
  of "textDocument/codeAction":
    var uri = ""
    var loLine = 0
    var hiLine = 1000000000
    parseCodeActionRange(tree.root, uri, loLine, hiLine)
    if hasId:
      sendResult(idJson, codeActionsFor(s.config, uriToPath(uri),
        docText(s, uri), loLine, hiLine))
  of "textDocument/semanticTokens/full":
    var uri = ""
    parseUriOnly(tree.root, uri)
    if hasId:
      sendResult(idJson, semanticTokensFull(s.config, uriToPath(uri)))
  of "textDocument/foldingRange":
    var uri = ""
    parseUriOnly(tree.root, uri)
    if hasId:
      sendResult(idJson, foldingRanges(docText(s, uri)))
  of "textDocument/selectionRange":
    var uri = ""
    var positions: seq[Position] = @[]
    parseSelectionPositions(tree.root, uri, positions)
    if hasId:
      sendResult(idJson, selectionRanges(docText(s, uri), positions))
  of "textDocument/prepareRename":
    var uri = ""
    var line = 0
    var ch = 0
    parseDocPos(tree.root, uri, line, ch)
    if hasId:
      let wlen = docWordLen(s, uri, pos(line, ch))
      if wlen > 0:
        sendResult(idJson, rangeJson(mkRange(line, ch, line, ch + wlen)))
      else:
        sendResult(idJson, "null")
  of "textDocument/rename":
    var uri = ""
    var line = 0
    var ch = 0
    var newName = ""
    parseRename(tree.root, uri, line, ch, newName)
    if hasId:
      let wlen = docWordLen(s, uri, pos(line, ch))
      if wlen > 0 and newName.len > 0:
        sendResult(idJson, renameEditJson(s.config, uriToPath(uri),
          pos(line, ch), wlen, newName, openDocuments(s), docText(s, uri)))
      else:
        sendResult(idJson, "null")
  of "textDocument/signatureHelp":
    var uri = ""
    var line = 0
    var ch = 0
    parseDocPos(tree.root, uri, line, ch)
    if hasId:
      sendResult(idJson, signatureHelpJson(s.config, uriToPath(uri),
        line, ch, docText(s, uri)))
  of "textDocument/codeLens":
    var uri = ""
    parseUriOnly(tree.root, uri)
    if hasId:
      sendResult(idJson, codeLensesJson(s.config, uriToPath(uri), uri))
  of "codeLens/resolve":
    # params IS a CodeLens; its `data` carries {uri,line,character}.
    var uri = ""
    var line = 0
    var ch = 0
    parseLensData(tree.root, uri, line, ch)
    if hasId:
      if uri.len > 0:
        sendResult(idJson, resolveCodeLensJson(s.config, uri, line, ch,
          openDocuments(s), docText(s, uri)))
      else:
        sendResult(idJson, "null")
  of "textDocument/documentLink":
    var uri = ""
    parseUriOnly(tree.root, uri)
    if hasId:
      sendResult(idJson, documentLinksJson(s.config, uriToPath(uri),
        docText(s, uri)))
  of "textDocument/inlayHint":
    var uri = ""
    var loLine = 0
    var hiLine = 1000000000
    parseCodeActionRange(tree.root, uri, loLine, hiLine)
    if hasId:
      sendResult(idJson, inlayHintsJson(s.config, uriToPath(uri),
        docText(s, uri)))
  else:
    if hasId:
      sendResult(idJson, "null")

proc main(): int =
  var s = newServerState()
  var body = ""
  var shouldExit = false
  while true:
    if not readMessage(body): break
    handle(s, body, shouldExit)
    if shouldExit: break
  return 0

quit main()
