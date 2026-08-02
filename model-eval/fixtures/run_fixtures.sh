#!/usr/bin/env bash
# Falsifiability floor for model-eval (v1 seeded corpus).
# Self-contained: generates fixtures with KNOWN properties into a temp dir, runs
# collect_signals.sh against each in offline mode, and asserts the analyzer fires.
# No network. Usage: bash run_fixtures.sh   (finds the collector relatively)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; COL="$HERE/../scripts/collect_signals.sh"
[ -f "$COL" ] || { echo "collector not found at $COL"; exit 2; }
F=$(mktemp -d); trap 'rm -rf "$F"' EXIT

# --- generate the corpus ---
mkdir -p "$F/clean_custom"
printf '{"auto_map":{"AutoModel":"modeling_foo.FooModel"}}' > "$F/clean_custom/config.json"
printf 'import torch\nclass FooModel:\n    def forward(self,x): return x+1\n' > "$F/clean_custom/modeling_foo.py"
: > "$F/clean_custom/model.safetensors"

mkdir -p "$F/eval_mismatch"
printf '{"auto_map":{"AutoModel":"modeling_bar.BarModel"}}' > "$F/eval_mismatch/config.json"
printf '"""BarModel. Sandbox-safe. Makes NO network calls. Fully audited."""\nimport requests\nclass BarModel:\n    def postprocess(self,outputs): return eval(outputs)\n' > "$F/eval_mismatch/modeling_bar.py"
: > "$F/eval_mismatch/model.safetensors"

mkdir -p "$F/obfuscation"
printf 'import os\ndef run(cmd): return getattr(os,"sys"+"tem")(cmd)\n' > "$F/obfuscation/modeling_ob.py"
: > "$F/obfuscation/model.safetensors"

mkdir -p "$F/deserialize_load"
printf 'import torch\ndef load_ckpt(path): return torch.load(path)\n' > "$F/deserialize_load/modeling_de.py"
: > "$F/deserialize_load/model.safetensors"

mkdir -p "$F/incidental"
printf 'def parse(s): return eval(s)\n' > "$F/incidental/convert.py"
: > "$F/incidental/model.safetensors"

mkdir -p "$F/pickle_weight"
printf 'class M: pass\n' > "$F/pickle_weight/modeling_pk.py"
: > "$F/pickle_weight/pytorch_model.bin"

pass=0; fail=0
check(){ local dir="$1" filt="$2" exp="$3" label="$4" got
  got=$(MAE_LOCAL_DIR="$F/$dir" bash "$COL" "$dir" 2>/dev/null | jq -r "$filt")
  if [ "$got" = "$exp" ]; then echo "  PASS  $label"; pass=$((pass+1))
  else echo "  FAIL  $label — expected $exp got $got"; fail=$((fail+1)); fi; }

echo "clean_custom — benign custom-code model:"
check clean_custom '.tier' D "tier D"
check clean_custom '.custom_code' true "custom_code=true"
check clean_custom '.ast.totals.tainted_sinks' 0 "0 tainted sinks"
echo "eval_mismatch — lying docstring + network import + eval on output:"
check eval_mismatch '[.ast.per_file[].imports[].cat]|any(.=="network")' true "network import caught"
check eval_mismatch '.ast.totals.tainted_sinks>=1' true "eval-on-output tainted sink"
echo "obfuscation — getattr(os,'sys'+'tem'):"
check obfuscation '.ast.totals.obfuscation>=1' true "obfuscation flagged"
echo "deserialize_load — torch.load:"
check deserialize_load '[.ast.per_file[].danger[].cat]|any(.=="deserialize")' true "deserialize detected"
echo "incidental — sink in a non-load-path script:"
check incidental '.tier' E "tier E (no custom code)"
check incidental '.custom_code' false "custom_code=false"
check incidental '.ast.totals.tainted_sinks>=1' true "sink still reported"
echo "pickle_weight — pickle-format weights:"
check pickle_weight '.tier' C "tier C"

echo ""; echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
