## driver.nim — the subprocess seam to the `nimony` compiler.
##
## Everything the LSP knows semantically comes through here today: `nimony check`
## for diagnostics, `nimony check --def/--usages` (idetools) for navigation. Each
## open file is checked as its OWN main module into an ISOLATED per-module
## nimcache under `nimcache/lsp/<mangled>/`, so a file stays warm (~ms) after one
## cold compile instead of thrashing a shared cache.
##
## This is the seam a future browser build swaps for in-process aowlparser/
## aowlsem calls — the drivers above it only see `run`.

import std/[strutils, os, dirs, paths, syncio]
import aowlkit/subprocess
import state

proc isAbsPath(p: string): bool =
  p.len > 0 and p[0] == '/'

proc parentDirOf(p: string): string =
  var i = p.len - 1
  while i >= 0 and p[i] != '/': dec i
  if i <= 0: "/" else: substr(p, 0, i - 1)

proc canonFile*(cfg: Config; file: string): string =
  ## The path form handed to nimony: RELATIVE to projectRoot when the file lives
  ## under it (nimony keys its incremental cache by the path string as given, so
  ## every caller must use one consistent form to share a warm cache).
  if cfg.projectRoot.len > 0 and isAbsPath(file):
    let root = cfg.projectRoot & (if cfg.projectRoot[cfg.projectRoot.len-1] == '/': "" else: "/")
    if file.len > root.len and substr(file, 0, root.len - 1) == root:
      return substr(file, root.len, file.len - 1)
  result = file

proc mangle(s: string): string =
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
       (c >= '0' and c <= '9'): result.add c
    else: result.add '_'
  if result.len == 0: result = "main"

proc cacheRoot(cfg: Config): string =
  let root = if cfg.projectRoot.len > 0: cfg.projectRoot else: "."
  root & "/nimcache/lsp"

proc moduleCacheDir*(cfg: Config; canonName: string): string =
  cacheRoot(cfg) & "/" & mangle(canonName)

proc moduleArtifacts*(cfg: Config; file, ext: string): seq[string] =
  ## Every artifact matching `ext` (e.g. ".s.nif", ".s.idx.nif") in the file's
  ## per-module nimcache. Empty when nothing has been checked yet.
  result = @[]
  let dir = moduleCacheDir(cfg, canonFile(cfg, file))
  if not dirExists(dir): return
  try:
    for kind, p in walkDir(path(dir)):
      if kind == pcFile:
        let ps = $p
        if endsWith(ps, ext): result.add ps
  except:
    discard

proc mainArtifact*(cfg: Config; file, ext: string): string =
  ## Best-effort single artifact for `file` (the newest matching `ext`), or "".
  let arts = moduleArtifacts(cfg, file, ext)
  result = ""
  var best = 0'i64
  for i in 0 ..< arts.len:
    var mt = 0'i64
    try: mt = getLastModificationTime(arts[i])
    except: mt = 0'i64
    if result.len == 0 or mt >= best:
      best = mt; result = arts[i]

proc liveArtifact*(cfg: Config; file, bufferText, ext: string): string =
  ## Compile the (possibly massaged) live `bufferText` and return the freshest
  ## matching artifact from the ISOLATED `-live` nimcache — the snif for the
  ## in-flight buffer, not the last-saved file. "" if the compile produced none.
  ## Used by completion so a member query reflects unsaved edits.
  # NB: pass `track` EXPLICITLY (not via its default) — calling through the
  # defaulted `seq[string]=@[]` param trips a nimony hexer bug (isTrivial at
  # decls.nim:46) during this module's build.
  discard runLiveCheck(cfg, file, bufferText, @[])
  let dir = moduleCacheDir(cfg, canonFile(cfg, file)) & "-live"
  if not dirExists(dir): return ""
  # nimony names artifacts by its own scheme, not the temp basename; the module
  # under compilation is written last, so the NEWEST matching artifact is ours —
  # the same heuristic `mainArtifact` uses for the on-disk cache.
  result = ""
  var best = 0'i64
  try:
    for kind, p in walkDir(path(dir)):
      if kind != pcFile: continue
      let ps = $p
      if endsWith(ps, ext) and not endsWith(ps, ".idx.nif"):
        var mt = 0'i64
        try: mt = getLastModificationTime(ps)
        except: mt = 0'i64
        if result.len == 0 or mt >= best:
          best = mt; result = ps
  except:
    discard

proc pruneCaches*(cfg: Config; budgetBytes = 1_000_000_000) =
  ## Bound the nimcache/lsp pool: if it exceeds `budgetBytes`, evict whole
  ## per-module cache dirs oldest-first (by mtime) until back under budget.
  ## Prevents the per-module caches from growing without limit.
  let base = cacheRoot(cfg)
  if not dirExists(base): return
  try:
    var dirs: seq[string] = @[]
    var sizes: seq[int] = @[]
    var recency: seq[int64] = @[]
    var total = 0
    for kind, p in walkDir(path(base)):
      if kind != pcDir: continue
      let d = $p
      var sz = 0
      try:
        for k2, f in walkDir(path(d)):
          if k2 == pcFile:
            try: sz += int(getFileSize($f))
            except: discard
      except: discard
      var mt = 0'i64
      try: mt = getLastModificationTime(d)
      except: mt = 0'i64
      dirs.add d; sizes.add sz; recency.add mt; total += sz
    if total <= budgetBytes: return
    # selection sort by recency ascending (oldest first); evict until under budget
    var idx: seq[int] = @[]
    for i in 0 ..< dirs.len: idx.add i
    for a in 0 ..< idx.len:
      var best = a
      for b in a + 1 ..< idx.len:
        if recency[idx[b]] < recency[idx[best]]: best = b
      let va = idx[a]
      let vb = idx[best]
      idx[a] = vb
      idx[best] = va
    for k in 0 ..< idx.len:
      if total <= budgetBytes: break
      let i = idx[k]
      try:
        removeDir(path(dirs[i]))
        total -= sizes[i]
      except:
        discard
  except:
    discard

proc run*(cfg: Config; sub, file: string; track: seq[string] = @[]): CaptureResult =
  ## Run `nimony <sub> --nimcache:<per-module> [--path ..] [track ..] <file>`.
  if cfg.nimonyExe.len == 0:
    return CaptureResult(output: "", exitCode: 127, ok: false)
  let cf = canonFile(cfg, file)
  var args: seq[string] = @[sub, "--nimcache:" & moduleCacheDir(cfg, cf)]
  for i in 0 ..< cfg.extraPaths.len:
    args.add "--path:" & cfg.extraPaths[i]
  for i in 0 ..< track.len:
    args.add track[i]
  args.add cf
  let workdir =
    if cfg.projectRoot.len > 0: cfg.projectRoot
    else: parentDirOf(file)
  result = runCaptured(cfg.nimonyExe, args, workdir, true)

proc runLiveCheck*(cfg: Config; file, bufferText: string;
                   track: seq[string] = @[]): CaptureResult =
  ## Check the UNSAVED buffer, not the on-disk file: write `bufferText` to a
  ## sibling temp file (same directory, so relative imports resolve), check it
  ## into an ISOLATED live nimcache, then map the temp path back to the real
  ## file in the output so diagnostics/records point at the user's file. This is
  ## what makes semantic diagnostics and navigation reflect in-flight edits.
  if cfg.nimonyExe.len == 0:
    return CaptureResult(output: "", exitCode: 127, ok: false)
  let dir = parentDirOf(file)
  let cf = canonFile(cfg, file)
  # NB: no leading dot — nimony derives the module name from the filename and a
  # dot-prefixed name yields an empty module name (nifreader assertion crash).
  let tempAbs = dir & "/aowllsp_live_" & mangle(cf) & ".nim"
  var wrote = false
  try:
    writeFile(tempAbs, bufferText); wrote = true
  except:
    # can't write next to the file — fall back to the on-disk check
    return run(cfg, "check", file, track)
  let tempRel = canonFile(cfg, tempAbs)
  var args: seq[string] = @["check", "--nimcache:" & moduleCacheDir(cfg, cf) & "-live"]
  for i in 0 ..< cfg.extraPaths.len:
    args.add "--path:" & cfg.extraPaths[i]
  # a --def/--usages track names the file by `cf`; the compiled module is the
  # temp, so rewrite the track's file reference real->temp.
  for i in 0 ..< track.len:
    args.add replace(track[i], cf, tempRel)
  args.add tempRel
  let workdir = if cfg.projectRoot.len > 0: cfg.projectRoot else: dir
  result = runCaptured(cfg.nimonyExe, args, workdir, true)
  # map the temp path back to the real file (tempRel is unique in the output)
  result.output = replace(result.output, tempRel, cf)
  if wrote:
    try: removeFile(path(tempAbs))
    except: discard
