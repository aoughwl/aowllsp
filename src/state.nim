## state.nim — server configuration and the open-document registry.

import std/[tables, envvars]
import document

type
  Config* = object
    nimonyExe*: string        ## path to the `nimony` binary
    aowlsuggestExe*: string   ## path to `aowlsuggest` (recovering syntax diags); "" = off
    aowllensExe*: string      ## path to `aowllens` (NIF artifact reader); "" = off
    aowlfmtExe*: string       ## path to `aowlfmt` (verified formatter); "" = off
    extraPaths*: seq[string]   ## extra --path entries
    projectRoot*: string       ## workspace root (filesystem path)

  ServerState* = object
    config*: Config
    docs*: Table[string, Document]   ## keyed by URI
    rootUri*: string
    initialized*: bool
    shutdownRequested*: bool

proc getEnvOr(name, dflt: string): string =
  var v = ""
  try: v = getEnv(name)
  except: v = ""
  if v.len > 0: v else: dflt

proc defaultConfig*(): Config =
  Config(
    nimonyExe: getEnvOr("NIMONY_EXE", "/home/savant/nimony/bin/nimony"),
    aowlsuggestExe: getEnvOr("AOWLSUGGEST", "/home/savant/aowlsuggest/bin/aowlsuggest"),
    aowllensExe: getEnvOr("AOWLLENS", "/home/savant/aowllens/bin/aowllens"),
    aowlfmtExe: getEnvOr("AOWLFMT", "/home/savant/aowlfmt/bin/aowlfmt"),
    extraPaths: @[],
    projectRoot: "")

proc newServerState*(): ServerState =
  ServerState(config: defaultConfig(), docs: initTable[string, Document](),
              rootUri: "", initialized: false, shutdownRequested: false)

proc openDoc*(s: var ServerState; uri, languageId: string; version: int; text: string) =
  s.docs[uri] = newDocument(uri, languageId, version, text)

proc closeDoc*(s: var ServerState; uri: string) =
  if s.docs.hasKey(uri): s.docs.del(uri)

proc hasDoc*(s: ServerState; uri: string): bool =
  s.docs.hasKey(uri)
