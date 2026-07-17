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
 {"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":uri("clean.nim")},"position":{"line":2,"character":8}}},
 {"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":uri("clean.nim")},"position":{"line":2,"character":8}}},
 {"jsonrpc":"2.0","id":4,"method":"textDocument/references","params":{"textDocument":{"uri":uri("clean.nim")},"position":{"line":0,"character":5},"context":{"includeDeclaration":True}}},
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

print("smoke: PASS" if not fail else "smoke: FAILURES above")
sys.exit(fail)
PY
