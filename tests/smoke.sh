#!/usr/bin/env bash
# smoke.sh — drive aowllsp through a scripted JSON-RPC session and assert the
# core features answer: diagnostics, definition, references, hover.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${AOWLLSP:-$ROOT/bin/aowllsp}"
[ -x "$BIN" ] || { echo "building aowllsp ..."; bash "$ROOT/build.sh" >/dev/null || { echo "build failed"; exit 1; }; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/clean.nim" <<'EOF'
proc greet(name: string): string = "hi " & name

let x = greet("bob")
let z = x
EOF
cat > "$WORK/bad.nim" <<'EOF'
let y: int = "oops"
EOF
cat > "$WORK/linky.nim" <<'EOF'
import clean
echo "linked"
EOF

python3 - "$BIN" "$WORK" <<'PY'
import subprocess, json, sys
BIN, ROOT = sys.argv[1], sys.argv[2]
def uri(p): return "file://"+ROOT+"/"+p
def frame(o):
    b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
clean = open(ROOT+"/clean.nim").read()
bad   = open(ROOT+"/bad.nim").read()
msgs=[
 {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file://"+ROOT,"capabilities":{}}},
 {"jsonrpc":"2.0","method":"initialized","params":{}},
 {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri("bad.nim"),"languageId":"nim","version":1,"text":bad}}},
 {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri("clean.nim"),"languageId":"nim","version":1,"text":clean}}},
 {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri("dirty.nim"),"languageId":"nim","version":1,"text":"if x = 5:\n  discard\nif y = 6:\n  discard\n"}}},
 {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri("linky.nim"),"languageId":"nim","version":1,"text":open(ROOT+"/linky.nim").read()}}},
 {"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":uri("clean.nim")},"position":{"line":2,"character":8}}},
 {"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":uri("clean.nim")},"position":{"line":2,"character":8}}},
 {"jsonrpc":"2.0","id":4,"method":"textDocument/references","params":{"textDocument":{"uri":uri("clean.nim")},"position":{"line":0,"character":5},"context":{"includeDeclaration":True}}},
 {"jsonrpc":"2.0","id":5,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":uri("clean.nim")}}},
 {"jsonrpc":"2.0","id":6,"method":"textDocument/completion","params":{"textDocument":{"uri":uri("clean.nim")},"position":{"line":2,"character":11}}},
 {"jsonrpc":"2.0","id":7,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":uri("clean.nim")}}},
 {"jsonrpc":"2.0","id":8,"method":"textDocument/rename","params":{"textDocument":{"uri":uri("clean.nim")},"position":{"line":0,"character":5},"newName":"welcome"}},
 {"jsonrpc":"2.0","id":10,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":uri("clean.nim")},"position":{"line":2,"character":14}}},
 {"jsonrpc":"2.0","id":11,"method":"textDocument/codeLens","params":{"textDocument":{"uri":uri("clean.nim")}}},
 {"jsonrpc":"2.0","id":12,"method":"codeLens/resolve","params":{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":10}},"data":{"uri":uri("clean.nim"),"line":0,"character":5}}},
 {"jsonrpc":"2.0","id":13,"method":"textDocument/documentLink","params":{"textDocument":{"uri":uri("linky.nim")}}},
 {"jsonrpc":"2.0","id":9,"method":"shutdown"},{"jsonrpc":"2.0","method":"exit"},
]
p=subprocess.run([BIN],input=b"".join(frame(m) for m in msgs),capture_output=True,timeout=180)
out=p.stdout.decode(errors="replace")
notifs=[]; resps={}
i=0
while True:
    h=out.find("\r\n\r\n",i)
    if h<0: break
    cls=[int(ln.split(":")[1]) for ln in out[i:h].split("\r\n") if ln.lower().startswith("content-length:")]
    if not cls: break
    cl=cls[0]; body=out[h+4:h+4+cl]; i=h+4+cl
    try: m=json.loads(body)
    except: continue
    if "method" in m: notifs.append(m)
    elif "id" in m: resps[m["id"]]=m.get("result")

fail=0
def check(cond,msg):
    global fail
    if not cond: print("FAIL:",msg); fail=1

# initialize capabilities
caps=(resps.get(1) or {}).get("capabilities",{})
check(caps.get("definitionProvider") and caps.get("hoverProvider"),"initialize capabilities")
# a diagnostic was published for bad.nim
diag_bad=[n for n in notifs if n["params"]["uri"]==uri("bad.nim") and n["params"]["diagnostics"]]
check(diag_bad,"diagnostics for bad.nim")
# recovering syntax diagnostics from aowlsuggest on the DIRTY buffer: BOTH errors
syn=[d for n in notifs if n["params"]["uri"]==uri("dirty.nim")
       for d in n["params"]["diagnostics"] if d.get("source")=="aowlsuggest"]
synlines=sorted(set(d["range"]["start"]["line"] for d in syn))
check(0 in synlines and 2 in synlines,"aowlsuggest recovers both syntax errors, got %s"%synlines)
# definition resolves to the proc decl (line 0)
d=resps.get(2) or []
check(len(d)==1 and d[0]["range"]["start"]["line"]==0,"definition -> proc decl")
# hover shows the decl line
hv=resps.get(3) or {}
check("proc greet" in json.dumps(hv),"hover shows decl line")
# references include both the decl and the usage
rf=resps.get(4) or []
lines=sorted(set(r["range"]["start"]["line"] for r in rf))
check(0 in lines and 2 in lines,"references include decl+usage, got %s"%lines)
# documentSymbol lists greet
ds=resps.get(5) or []
check(any(s.get("name")=="greet" for s in ds),"documentSymbol includes greet")
# completion returns items
co=resps.get(6) or {}
check(isinstance(co,dict) and len(co.get("items",[]))>0,"completion returns items")
# semanticTokens returns a data array (multiple of 5)
st=resps.get(7) or {}
d=st.get("data",[]) if isinstance(st,dict) else []
check(len(d)>0 and len(d)%5==0,"semanticTokens data is a non-empty multiple of 5, got %d"%len(d))
# rename produces a WorkspaceEdit touching >=1 occurrence
rn=resps.get(8) or {}
edits=sum(len(v) for v in (rn.get("changes",{}) or {}).values()) if isinstance(rn,dict) else 0
check(edits>=1,"rename produces >=1 edit, got %d"%edits)
# signatureHelp: label is the callee's decl line, active param is 0 (first arg)
sh=resps.get(10) or {}
check(isinstance(sh,dict) and sh.get("signatures") and
      "greet" in sh["signatures"][0]["label"] and sh.get("activeParameter")==0,
      "signatureHelp shows greet signature, got %s"%json.dumps(sh))
# codeLens: an unresolved lens over the greet decl (line 0) carrying data
cl=resps.get(11) or []
check(any(l.get("data") and l["range"]["start"]["line"]==0 for l in cl),
      "codeLens over greet decl, got %s"%json.dumps(cl))
# codeLens/resolve: fills a "N reference(s)" command
clr=resps.get(12) or {}
check(isinstance(clr,dict) and "reference" in json.dumps(clr.get("command",{})),
      "codeLens/resolve gives reference count, got %s"%json.dumps(clr))
# documentLink: `import clean` links to clean.nim
dl=resps.get(13) or []
check(any("clean" in (l.get("target") or "") for l in dl),
      "documentLink resolves import clean, got %s"%json.dumps(dl))
# capabilities advertise the new providers
capset=set(k for k in (resps.get(1) or {}).get("capabilities",{}))
for cap in ["documentSymbolProvider","completionProvider","semanticTokensProvider","renameProvider","codeActionProvider","signatureHelpProvider","codeLensProvider","documentLinkProvider"]:
    check(cap in capset, "capability %s advertised"%cap)

print("smoke: PASS" if not fail else "smoke: FAILURES above")
sys.exit(fail)
PY
