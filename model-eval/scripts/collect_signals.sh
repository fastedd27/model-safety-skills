#!/usr/bin/env bash
# model-eval collector — deterministic signal collection for a public HuggingFace model.
# EXECUTES NOTHING from the artifact. Downloads only code/text files (never weights).
# Emits typed JSON to stdout for the model-eval SKILL to reason over.
# bash + curl + jq + python3-stdlib. Optional HF_TOKEN for higher rate limits.
# Usage:  collect_signals.sh <hf owner/repo | URL>
# Offline/CI mode:  MAE_LOCAL_DIR=/path/to/dir collect_signals.sh <label>
set -uo pipefail
RAW="${1:?Usage: collect_signals.sh <hf owner/repo | URL>   (or MAE_LOCAL_DIR=dir collect_signals.sh <label>)}"
REPO=$(echo "$RAW" | sed -E 's#https?://huggingface.co/##; s#/+$##; s#\.git$##')
CURL_AUTH=(); [ -n "${HF_TOKEN:-}" ] && CURL_AUTH=(-H "Authorization: Bearer $HF_TOKEN")
hf_get(){ curl -sfL "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" --max-time "$1" "$2"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/code"

if [ -n "${MAE_LOCAL_DIR:-}" ]; then
  D="$MAE_LOCAL_DIR"
  python3 - "$D" > "$TMP/tree.json" <<'PYT'
import os,sys,json,hashlib
d=sys.argv[1]; out=[]; TH=64*1024*1024
def _sha(p,size):
    h=hashlib.sha256()
    if size<=TH:
        with open(p,'rb') as fh:
            for c in iter(lambda: fh.read(1048576), b''): h.update(c)
        return h.hexdigest(), False
    with open(p,'rb') as fh:
        head=fh.read(1048576); fh.seek(max(0,size-1048576)); tail=fh.read(1048576)
    h.update(head); h.update(tail); h.update(str(size).encode())
    return h.hexdigest(), True
for root,_,files in os.walk(d):
    for f in files:
        p=os.path.join(root,f); rel=os.path.relpath(p,d).replace(os.sep,"/")
        size=os.path.getsize(p); oid,partial=_sha(p,size)
        out.append({"type":"file","path":rel,"oid":oid,"size":size,"partial_seal":partial})
print(json.dumps(out))
PYT
  echo '{"tags":[],"siblings":[]}' > "$TMP/info.json"
  ( cd "$D" && find . -name '*.py' | head -40 | while read -r f; do rel=${f#./}; cp "$rel" "$TMP/code/$(echo "$rel" | tr '/' '~')"; done )
  [ -f "$D/config.json" ] && cp "$D/config.json" "$TMP/config.json" || echo '{}' > "$TMP/config.json"
else
  hf_get 25 "https://huggingface.co/api/models/$REPO" > "$TMP/info.json" 2>/dev/null || echo '{}' > "$TMP/info.json"
  hf_get 25 "https://huggingface.co/api/models/$REPO/tree/main?recursive=true" > "$TMP/tree.json" 2>/dev/null || echo '[]' > "$TMP/tree.json"
  jq -e 'type=="array"' "$TMP/tree.json" >/dev/null 2>&1 || echo '[]' > "$TMP/tree.json"
  PYS=$(jq -r '.[]? | select(.type=="file") | .path' "$TMP/tree.json" 2>/dev/null | grep -iE '\.py$' | head -40)
  for f in $PYS; do
    hf_get 20 "https://huggingface.co/$REPO/resolve/main/$f" > "$TMP/code/$(echo "$f" | tr '/' '~')" 2>/dev/null || true
  done
  hf_get 20 "https://huggingface.co/$REPO/resolve/main/config.json" > "$TMP/config.json" 2>/dev/null || true
fi

REPO="$REPO" LOCAL_DIR="${MAE_LOCAL_DIR:-}" python3 - "$TMP" <<'PY'
import ast, json, os, sys, hashlib, re, io, zipfile, pickletools
tmp=sys.argv[1]; repo=os.environ.get("REPO",""); LOCAL_DIR=os.environ.get("LOCAL_DIR","")
def load(p,d):
    try: return json.load(open(p))
    except Exception: return d
tree=load(f"{tmp}/tree.json",[]); info=load(f"{tmp}/info.json",{}); cfg=load(f"{tmp}/config.json",{})
paths=[e.get("path","") for e in tree if isinstance(e,dict) and e.get("type")=="file"]

man=[]
for e in tree:
    if not isinstance(e,dict) or e.get("type")!="file": continue
    sha=(e.get("lfs") or {}).get("oid") or e.get("oid") or ""
    man.append((e.get("path",""), sha))
man.sort()
partial_sealed=sum(1 for e in tree if isinstance(e,dict) and e.get("partial_seal"))
manifest_sha256=hashlib.sha256("\n".join(f"{p}\t{s}" for p,s in man).encode()).hexdigest()

low=[p.lower() for p in paths]
def any_ext(exts): return any(p.endswith(exts) for p in low)
SAFE=any_ext((".safetensors",)); GGUF=any_ext((".gguf",))
PICKLE=any_ext((".bin",".pt",".pth",".ckpt",".pkl",".pickle",".msgpack",".h5"))
tags=[t.lower() for t in info.get("tags",[]) if isinstance(t,str)]
modeling_py=any(re.search(r'(^|/)(modeling|configuration|tokenization|image_processing)_.*\.py$',p) for p in low)
automap=bool(cfg.get("auto_map"))
custom=("custom_code" in tags) or automap or modeling_py
if PICKLE: tier="C"
elif not (SAFE or GGUF or PICKLE): tier="C?"
elif custom: tier="D"
else: tier="E"

# ---- pickle opcode scan (stdlib pickletools; disassembles, executes NOTHING) ----
PICK_SCAN_EXT=(".bin",".pt",".pth",".ckpt",".pkl",".pickle")
DANGER_MOD={"os","posix","nt","subprocess","sys","builtins","__builtin__","socket",
            "shutil","importlib","pty","commands","ctypes","platform","webbrowser",
            "runpy","code","multiprocessing","operator"}
DANGER_NAME={("builtins","eval"),("builtins","exec"),("builtins","__import__"),
             ("builtins","compile"),("builtins","getattr"),("__builtin__","eval"),
             ("__builtin__","exec"),("__builtin__","__import__")}
RAW_CAP=32*1024*1024
def _pk_danger(mod,name):
    if (mod,name) in DANGER_NAME: return True
    return mod.split(".")[0] in DANGER_MOD
def _pk_stream(data):
    r={"opcodes":0,"globals":[],"reduce":0,"error":None}; last=[]
    try:
        for op,arg,pos in pickletools.genops(io.BytesIO(data)):
            r["opcodes"]+=1; nm=op.name
            if nm in ("SHORT_BINUNICODE","BINUNICODE","BINUNICODE8","UNICODE","SHORT_BINSTRING","BINSTRING"):
                if isinstance(arg,(str,bytes)):
                    last.append(arg.decode("utf-8","replace") if isinstance(arg,bytes) else arg); last=last[-2:]
            elif nm=="GLOBAL":
                a=arg or ""
                mod,name=(a.split("\n",1) if "\n" in a else list(a.partition(" ")[::2]))
                r["globals"].append([mod,name])
            elif nm=="STACK_GLOBAL":
                r["globals"].append([last[-2],last[-1]] if len(last)>=2 else ["<stack>","?"])
            elif nm in ("REDUCE","BUILD","INST","OBJ","NEWOBJ","NEWOBJ_EX"):
                r["reduce"]+=1
    except Exception as e:
        r["error"]=str(e)[:140]
    return r
def _pk_file(path):
    res={"file":None,"kind":None,"opcodes":0,"reduce":0,"dangerous":[],"note":None}; streams=[]
    try:
        if zipfile.is_zipfile(path):
            res["kind"]="torch-zip"; zf=zipfile.ZipFile(path)
            ents=[n for n in zf.namelist() if os.path.basename(n)=="data.pkl" or n.lower().endswith(".pkl")]
            if not ents: res["note"]="zip archive with no .pkl entry"
            for n in ents[:6]:
                try: streams.append(_pk_stream(zf.read(n)))
                except Exception as e: res["note"]=f"zip entry read failed: {str(e)[:60]}"
        else:
            res["kind"]="raw-pickle"; sz=os.path.getsize(path)
            with open(path,"rb") as fh: data=fh.read(RAW_CAP)
            if sz>RAW_CAP: res["note"]=f"raw pickle {sz}B > cap; scanned head only (partial)"
            streams.append(_pk_stream(data))
    except Exception as e:
        res["note"]=f"open failed: {str(e)[:80]}"; return res
    for s in streams:
        res["opcodes"]+=s["opcodes"]; res["reduce"]+=s["reduce"]
        for mod,name in s["globals"]:
            if _pk_danger(mod,name): res["dangerous"].append([mod,name])
    return res

pickle_paths=[p for p in paths if p.lower().endswith(PICK_SCAN_EXT)]
pk={"present":bool(PICKLE),"weight_files":pickle_paths,"scan_mode":None,
    "scanned":[],"dangerous_globals":0,"reduce_ops":0,"verdict":None,"note":None}
if PICKLE and LOCAL_DIR and pickle_paths:
    pk["scan_mode"]="local-stdlib-opcode"
    for rel in pickle_paths[:12]:
        fp=os.path.join(LOCAL_DIR,rel)
        if not os.path.exists(fp): continue
        r=_pk_file(fp); r["file"]=rel; pk["scanned"].append(r)
    if len(pickle_paths)>12: pk["note"]=f"{len(pickle_paths)} pickle files; scanned first 12"
    pk["dangerous_globals"]=sum(len(r["dangerous"]) for r in pk["scanned"])
    pk["reduce_ops"]=sum(r["reduce"] for r in pk["scanned"])
    pk["verdict"]=("DANGEROUS_OPCODES" if pk["dangerous_globals"]>0 else "no dangerous opcodes at static read — NOT a clearance")
elif PICKLE and LOCAL_DIR:
    pk["scan_mode"]="local-no-native-pickle"
    pk["note"]="pickle-family format present but no native pickle stream (.bin/.pt/.pkl) to disassemble (e.g. .h5/.msgpack) — tier C stands on format"
elif PICKLE:
    pk["scan_mode"]="hf-not-scanned"
    pk["note"]="pickle weights not downloaded in HF mode (collector never downloads weights); pull the model and re-run with MAE_LOCAL_DIR, or run picklescan/modelscan, to read the opcodes"

CATS=[("network", re.compile(r'(^|\.)(socket|requests|urllib|urlopen|httpx|aiohttp|ftplib|telnetlib)(\.|$)')),
      ("subprocess", re.compile(r'(^|\.)(subprocess|popen|system|spawn)(\.|$)|^os\.(system|popen|exec)')),
      ("deserialize", re.compile(r'(pickle\.load|_pickle|marshal\.load|dill\.load|joblib\.load|yaml\.load|torch\.load)')),
      ("dyn_import", re.compile(r'(^__import__$|importlib)')),]
IMPCATS=[("network", re.compile(r'^(requests|urllib|socket|httpx|aiohttp|ftplib|telnetlib|http)(\.|$)')),
         ("subprocess", re.compile(r'^(subprocess|pty)(\.|$)')),]
CODE_EXEC={"eval","exec","compile"}
def dotted(f):
    parts=[]
    while isinstance(f,ast.Attribute): parts.append(f.attr); f=f.value
    if isinstance(f,ast.Name): parts.append(f.id)
    return ".".join(reversed(parts))
def is_const_str(n): return isinstance(n,ast.Constant) and isinstance(n.value,str)
class V(ast.NodeVisitor):
    def __init__(s): s.depth=0; s.danger=[]; s.env=[]; s.auth=[]; s.sinks=[]; s.obf=0; s.imports=[]
    def visit_FunctionDef(s,n): s.depth+=1; s.generic_visit(n); s.depth-=1
    visit_AsyncFunctionDef=visit_FunctionDef
    def _imp(s,mod,line):
        for c,rx in IMPCATS:
            if rx.search(mod): s.imports.append({"cat":c,"module":mod,"line":line}); return
    def visit_Import(s,n):
        for a in n.names: s._imp(a.name,n.lineno)
        s.generic_visit(n)
    def visit_ImportFrom(s,n):
        if n.module: s._imp(n.module,n.lineno)
        s.generic_visit(n)
    def visit_Call(s,n):
        name=dotted(n.func); base=name.split(".")[-1]; scope="module" if s.depth==0 else "function"
        cat=None
        if base in CODE_EXEC and "." not in name: cat="code_exec"
        if cat is None:
            for c,rx in CATS:
                if rx.search(name): cat=c; break
        if cat:
            s.danger.append({"cat":cat,"name":name or base,"line":n.lineno,"scope":scope})
            if cat in ("code_exec","deserialize","subprocess"):
                tainted=any(not isinstance(a,ast.Constant) for a in n.args) if n.args else False
                s.sinks.append({"name":name or base,"line":n.lineno,"args_tainted":tainted})
        if base in ("open","urlopen","get","post","request","connect","urlretrieve") and n.args:
            a=n.args[0]
            if is_const_str(a): s.auth.append({"line":n.lineno,"target":a.value,"opaque":False})
            elif not isinstance(a,ast.Constant): s.auth.append({"line":n.lineno,"target":None,"opaque":True})
        if base=="getattr" and len(n.args)>=2 and isinstance(n.args[1],(ast.BinOp,ast.JoinedStr,ast.Call)):
            s.obf+=1
        s.generic_visit(n)
    def visit_Subscript(s,n):
        if isinstance(n.value,ast.Attribute) and n.value.attr=="environ" and is_const_str(n.slice):
            s.env.append(n.slice.value)
        s.generic_visit(n)

per_file=[]; tot={"import_time_danger":0,"runtime_danger":0,"sinks":0,"tainted_sinks":0,"opaque_authority":0,"obfuscation":0,"sensitive_imports":0,"parse_errors":0}
for fn in sorted(os.listdir(f"{tmp}/code")):
    disp=fn.replace("~","/"); src=open(f"{tmp}/code/{fn}",encoding="utf-8",errors="replace").read()
    rec={"file":disp,"danger":[],"authority":{"env":[],"targets":[],"opaque_count":0},"sinks":[],"imports":[],"obfuscation":0,"parse_error":None}
    try: t=ast.parse(src)
    except SyntaxError as e:
        rec["parse_error"]=f"{e.msg} @L{e.lineno}"; tot["parse_errors"]+=1; per_file.append(rec); continue
    v=V(); v.visit(t)
    rec["danger"]=v.danger; rec["sinks"]=v.sinks; rec["obfuscation"]=v.obf; rec["imports"]=v.imports
    rec["authority"]["env"]=sorted(set(v.env))
    rec["authority"]["targets"]=[a["target"] for a in v.auth if not a["opaque"]]
    rec["authority"]["opaque_count"]=sum(1 for a in v.auth if a["opaque"])
    for d in v.danger: tot["import_time_danger" if d["scope"]=="module" else "runtime_danger"]+=1
    tot["sinks"]+=len(v.sinks); tot["tainted_sinks"]+=sum(1 for x in v.sinks if x["args_tainted"])
    tot["opaque_authority"]+=rec["authority"]["opaque_count"]; tot["obfuscation"]+=v.obf; tot["sensitive_imports"]+=len(v.imports)
    per_file.append(rec)

prov={"license": (info.get("cardData") or {}).get("license") or next((t.split(":",1)[1] for t in info.get("tags",[]) if isinstance(t,str) and t.startswith("license:")), None),
      "has_model_card": any(p.lower()=="readme.md" for p in paths),
      "attestation_files":[p for p in paths if re.search(r'(\.sig$|\.intoto|attestation|provenance|\.sbom)',p.lower())],
      "downloads": info.get("downloads"), "likes": info.get("likes"), "lastModified": info.get("lastModified")}

out={"repo":repo,"revision":info.get("sha"),"tier":tier,
     "format":{"safetensors":int(SAFE),"gguf":int(GGUF),"pickle_family":int(PICKLE)},
     "custom_code":bool(custom),"custom_code_signals":{"tag":"custom_code" in tags,"auto_map":automap,"modeling_py":modeling_py},
     "seal":{"file_count":len(man),"manifest_sha256":manifest_sha256,"partial_sealed":partial_sealed},
     "code_files_scanned":[r["file"] for r in per_file],
     "ast":{"per_file":per_file,"totals":tot},
     "pickle":pk,
     "provenance":prov,
     "collector_note":"Static only. No artifact code executed. Absence of a signal is not evidence of safety."}
print(json.dumps(out,indent=2))
PY
