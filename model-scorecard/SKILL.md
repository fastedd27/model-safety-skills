---
name: model-scorecard
description: Zero-friction safety gut-check for a public HuggingFace model repo. Uses only curl + jq against the public HF API (no tokens, no download) to detect weight format (safetensors vs pickle-family), custom code (trust_remote_code), and assign a coarse (format, loader) risk tier with a plain-language card. Use when asked for a quick "is this model safe to pull?" check, before adopting a HuggingFace model, or as fast triage ahead of the deeper model-eval. NEVER issues a clearance.
argument-hint: <hf owner/repo or HuggingFace URL>
---

# Model Scorecard

## Overview

The zero-friction gut check for a public HuggingFace model — the sibling of
`repo-scorecard` for git repos. `curl` + `jq` only: no tokens, no accounts, no
weight download. It answers one question fast: *what could this model do to me
when it loads, and is it even safe to look at closely?* It **never clears** an
artifact — a code-bearing model always routes to `model-eval` and a human read.

## Workflow

1. Run:

   ```
   scripts/scorecard.sh <owner/repo or HuggingFace URL>
   ```

   The script reads the public HF API file manifest and `config.json`, detects
   the weight format and whether the model runs custom code on load, assigns a
   coarse `(format, loader)` tier, and — for code-bearing models — does a
   grep-level authority heads-up with an alarm budget.

2. Present the card for a non-technical reader. Translate the tier:

   - **Tier E** — loads as data only (non-executing weights, no custom code). The
     low-risk case. Still not a security scan.
   - **Tier D** — non-executing weights, but runs custom code on load
     (`trust_remote_code`). A static look cannot clear it → run `model-eval`.
   - **Tier C** — pickle-family weights (`.bin/.pt/.pth/.ckpt/.pkl`): loading can
     execute arbitrary code. Hard flag. Prefer a safetensors build, and route the
     actual pickle check to `modelscan` / `picklescan`.
   - **Tier C?** — unrecognized weight format: fails **up** (treated as
     high-risk), never down.

3. Never present a blended safety number, and never a clearance. Popularity
   (downloads, likes) is a **weak** signal — say so on the card.

## The (format, loader) tier — why format, not reputation

Blast radius is a property of the weight **format** and its loader, not the
model's popularity. Safetensors and GGUF are non-executing containers;
pickle-family formats execute code on load by design. A ten-million-download
model shipped in a pickle format is still Tier C. Reputation cannot lower the
tier.

## Known limitations (say these out loud)

- **Grep-level heads-up only.** The authority note flags the *presence* of
  network / exec / deserialize calls in the custom code — not whether they are
  reachable or dangerous. Reachability is `model-eval`'s job.
- **Pickle scanning is delegated, not implemented.** For the real opcode-level
  check, route the file to `modelscan` / `picklescan`. This skill only detects
  that a pickle-family format is *present*.
- **Not a security audit, and never a clearance.** A quiet card on a code-bearing
  model means "nothing obvious at a glance," not "safe."
- **Public models only.** Needs `curl`, `jq`, and a network connection.

## Resources

- `scripts/scorecard.sh` — self-contained HF-API scorecard (bash + curl + jq).
