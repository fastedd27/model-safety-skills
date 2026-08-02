#!/usr/bin/env bash
# model-scorecard — zero-friction safety gut-check for a public HuggingFace model repo.
# curl + jq only, against the public HF API. No tokens or accounts required.
# Optional: if HF_TOKEN is set in the environment, it's used for higher rate limits
# (never required — anonymous access works fine for interactive use).
# Prints a coarse (format,loader) tier + a plain-language card. NEVER a clearance.
# Usage: scorecard.sh <hf owner/repo | https://huggingface.co/owner/repo>
set -uo pipefail

RAW="${1:?Usage: scorecard.sh <hf owner/repo | URL>}"
REPO=$(echo "$RAW" | sed -E 's#https?://huggingface.co/##; s#/+$##; s#\.git$##')

# Optional auth header (portable empty-array idiom, safe under set -u on bash 3.2+).
CURL_AUTH=()
[ -n "${HF_TOKEN:-}" ] && CURL_AUTH=(-H "Authorization: Bearer $HF_TOKEN")
hf_get(){ curl -sfL "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" --max-time "$1" "$2"; }  # $1=timeout $2=url

INFO=$(hf_get 25 "https://huggingface.co/api/models/$REPO") \
  || { echo "ERROR: could not reach HF API for '$REPO' (private, moved, gated, or offline)"; exit 1; }
FILES=$(echo "$INFO" | jq -r '.siblings[].rfilename' 2>/dev/null)
[ -z "$FILES" ] && { echo "ERROR: no file manifest for '$REPO'"; exit 1; }
has(){ grep -qiE "$1" <<<"$FILES"; }

# --- weight format ---
SAFE=$(has '\.safetensors$' && echo 1 || echo 0)
GGUF=$(has '\.gguf$' && echo 1 || echo 0)
PICKLE=$(has '\.(bin|pt|pth|ckpt|pkl|pickle|msgpack|h5)$' && echo 1 || echo 0)
KNOWN_WEIGHTS=$(( SAFE + GGUF + PICKLE ))

# --- custom code / trust_remote_code ---
TAGS=$(echo "$INFO" | jq -r '.tags[]?' 2>/dev/null)
CUSTOM_TAG=$(grep -qiE '^custom_code$' <<<"$TAGS" && echo 1 || echo 0)
MODELING_PY=$(has '(^|/)(modeling|configuration|tokenization|image_processing)_.*\.py$' && echo 1 || echo 0)
CFG=$(hf_get 20 "https://huggingface.co/$REPO/resolve/main/config.json" 2>/dev/null)
AUTOMAP=0; [ -n "$CFG" ] && echo "$CFG" | jq -e '.auto_map' >/dev/null 2>&1 && AUTOMAP=1
CUSTOM=0; { [ "$CUSTOM_TAG" = 1 ] || [ "$AUTOMAP" = 1 ] || [ "$MODELING_PY" = 1 ]; } && CUSTOM=1

# --- coarse (format,loader) tier ---
if   [ "$PICKLE" = 1 ]; then TIER="C"; TLABEL="pickle-family weights — code can execute on load"
elif [ "$KNOWN_WEIGHTS" = 0 ]; then TIER="C?"; TLABEL="UNKNOWN weight format — failing UP, treat as high-risk"
elif [ "$CUSTOM" = 1 ]; then TIER="D"; TLABEL="non-executing weights + custom code (trust_remote_code)"
else TIER="E"; TLABEL="non-executing weights, no custom code"
fi

# --- light authority heads-up (only if custom .py present); alarm budget ---
AUTH_NOTE=""
if [ "$CUSTOM" = 1 ]; then
  PYS=$(grep -iE '\.py$' <<<"$FILES" | head -8)
  hits=0
  for f in $PYS; do
    body=$(hf_get 15 "https://huggingface.co/$REPO/resolve/main/$f" 2>/dev/null) || continue
    n=$(grep -icE '\b(eval|exec|subprocess|os\.system|socket|requests|urllib|pickle\.loads|__import__)\b' <<<"$body")
    hits=$(( hits + n ))
  done
  if   [ "$hits" -eq 0 ]; then AUTH_NOTE="No obvious network/exec/deserialize calls in the custom code (grep-level heads-up only)."
  elif [ "$hits" -le 6 ]; then AUTH_NOTE="Custom code contains ~$hits network/exec/deserialize call-site(s) — run model-eval before trusting."
  else AUTH_NOTE="Custom code reach could not be itemized at a glance (~$hits sensitive call-sites) — treat as full-authority; run model-eval."
  fi
fi

DL=$(echo "$INFO" | jq -r '.downloads // "?"'); LIKES=$(echo "$INFO" | jq -r '.likes // "?"'); MOD=$(echo "$INFO" | jq -r '.lastModified // "?"')

echo "================ MODEL SCORECARD ================"
echo "Model: $REPO"
echo "Tier:  $TIER  — $TLABEL"
echo "------------------------------------------------"
echo "weights:       safetensors=$SAFE gguf=$GGUF pickle_family=$PICKLE"
echo "custom_code:   $CUSTOM   (tag=$CUSTOM_TAG auto_map=$AUTOMAP modeling.py=$MODELING_PY)"
echo "popularity:    downloads=$DL likes=$LIKES (WEAK signals — not a safety control)"
echo "last_modified: $MOD"
echo "---------------- WHAT TO KNOW ------------------"
[ "$PICKLE" = 1 ] && echo "• FLAG: pickle-family weights present — loading can run arbitrary code. Prefer a safetensors build; route the pickle check to modelscan/picklescan."
[ "$TIER" = "C?" ] && echo "• FLAG: no recognized weight format — unrecognized formats fail UP (treated as high-risk), not down."
[ "$CUSTOM" = 1 ] && echo "• This model runs custom code on load (trust_remote_code). $AUTH_NOTE"
[ "$TIER" = "E" ] && echo "• Loads as data only (no custom code, non-executing weights) — the low-risk case. Still not a security scan."
echo ""
echo "This is a GUT CHECK, not a security audit, and NEVER a clearance. For any"
echo "code-bearing model (tier C/D), run model-eval for the deep read; a static"
echo "look cannot clear an artifact that executes code."
echo "================================================"
