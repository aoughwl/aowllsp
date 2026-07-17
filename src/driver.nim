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

import std/[strutils, os, dirs, paths]
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
