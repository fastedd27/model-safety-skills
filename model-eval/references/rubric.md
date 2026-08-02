# model-eval — Scoring Rubric

Loaded by `model-eval/SKILL.md` before scoring. Encodes the honesty architecture
from the spec: **no single blended safety number**, tier-gated ceilings, three
unfused tracks, an audit-opinion top-line. Every line item must trace to a signal
from `collect_signals.sh`; a missing signal scores at an explicit midpoint with an
uncertainty note, never silently best- or worst-cased. **Nothing here is a clearance.**

## 0. Output contract

Never one blended score. Emit four separate artifacts:
1. The `(format, loader)` **TIER** + its ceiling.
2. Three unfused **TRACK** verdicts (Provenance / Artifact / Instruction) — never averaged.
3. The audit-opinion **TOP-LINE** (unqualified / qualified / adverse / disclaimer of opinion).
4. The **RESIDUE** list for the human read (contradictions, opaque authority, unverified claims).

## 1. The (format, loader) tier ladder

Blast radius is a property of the weight FORMAT and its loader, not popularity. The
collector emits a coarse tier; model-eval refines **D → A/B** using the AST totals.

| Tier | Definition (from collector signals) | Ceiling |
|---|---|---|
| E | non-executing weights (safetensors/gguf), no custom code | may rate up to strong |
| D | non-executing weights + custom code, **no** dangerous call-sites | static-only ceiling; residue read |
| C | pickle-family weights (code executes on load) — route pickle check to modelscan/picklescan | hard flag; isolated use only |
| B | custom code with in-process code-exec / deserialize sites (`eval`/`exec`/`pickle.load`/`torch.load`) | disclaimer of opinion if static-only |
| A | custom code with code-exec **and** network/subprocess reach, or install-instructions requiring an unregistered binary | disclaimer of opinion if static-only; human read mandatory |
| C? | unrecognized weight format — **FAIL UP** | treat as high-risk |

**Refinement (D → A/B):** if `ast.totals` has code_exec/deserialize sinks → at least **B**;
if it also has `network` OR `subprocess` danger → **A**. Reputation NEVER lowers a tier.

## 2. Three unfused tracks (never averaged)

- **PROVENANCE** — repo-health signals (David's repo-scorecard/eval, imported): maintenance,
  bus factor, license, downloads (WEAK). Import; do not rebuild.
- **ARTIFACT** — the collector's static read: import-time vs runtime danger, tainted sinks
  (generation→sink candidates), opaque authority, obfuscation, deserialize/`torch.load`,
  seal status, plus the delegated pickle scan.
- **INSTRUCTION** — enumerable documentation patterns: does the README/model card instruct
  installing an unregistered/bundled binary, disabling a check ("just set X"), or make
  unfalsifiable claims ("fully audited", "100% safe")?

A green Provenance beside a red Artifact is the case the tool exists to make un-hideable.
Report the three separately, always.

## 3. Per-mechanism honesty annotations

| Mechanism | Kerckhoffs: survives source disclosure? | Failure mode |
|---|---|---|
| Seal + reconcile | YES | fails LOUD |
| Format/tier detection | YES | fails LOUD (fails up on unknown) |
| Pickle/opcode scan (delegated) | mostly YES | fails LOUD |
| AST danger-scan / tainted sinks | NO — dynamic dispatch, string-built imports, obfuscation evade it | fails SILENT |
| LLM behavioral claim + contradiction | NO | fails SILENT |
| Authority manifest | NO — runtime-constructed targets are opaque | fails SILENT |

Most weight rests on fails-silent mechanisms — which is why silence is never "safe" and a
code-bearing artifact always routes to a human read.

## 4. Hard caps (after track scoring)

- pickle-family weights present → tier **C** floor; Artifact track cannot read "clean".
- unrecognized format → fail up.
- `obfuscation` count > 0 → CRITICAL flag + disclaimer of opinion.
- evidence of exfiltration / obfuscated payload / secrets in code → worst verdict (do not use).
- no license → cap (usability + a signal of lax practice).

## 5. Adverse inference for the uninspectable remainder

The remainder that cannot be read (compiled `.pyc` inside vendored wheels; builds matching
NOTHING in a public registry; multi-GB weight tensors) scores **adversely by default** in a
high-capability (tier A/B/C) artifact — scaled by fraction and nature — never neutrally as
"unknown". Thin innocent explanations carry weight. Absence of a provenance attestation
(`provenance.attestation_files` empty) feeds this rule.

## 6. Aggregation → escalation (materiality)

Individually-immaterial uncertainties SUM. Count: unverified claims + opaque-authority items
(`totals.opaque_authority`) + uninspectable files. Above a threshold, the aggregate FORCES a
tier escalation and downgrades the audit opinion. Uncertainty that cannot move the verdict is
disclosure theater.

## 7. Audit-opinion top-line

- **UNQUALIFIED** — tier E, tracks agree clean, nothing material unread.
- **QUALIFIED** — usable with specific noted conditions/mitigations.
- **ADVERSE** — material danger found (tainted code-exec sinks, pickle, obfuscation).
- **DISCLAIMER OF OPINION** — a code-execution-tier (A/B/C) artifact seen STATIC-ONLY: the
  independent instrument (declared-vs-exercised differential) was not run, so the tool
  REFUSES a confidence-bearing rating. The honest default for the deep skill until the
  differential (v2) exists.

## 8. Flag severities

- **CRITICAL** — obfuscation, exfiltration/secrets, tainted `eval`/`exec` on model output,
  pickle in a "trusted" artifact, typosquat/impersonation, seal drift under a stable revision.
- **WARNING** — code-exec/deserialize sinks, bus factor 1, no license, no security policy,
  opaque-authority over budget, unverifiable maintainer.
- **CAUTION** — sparse docs, no signed releases/attestation, Provenance-only signals, low tests.

## 9. Standing rules

Every claim → a collected signal. Missing signal → explicit midpoint + uncertainty note.
Silence ≠ safety. Agreement across the (correlated, mostly-LLM) mechanisms is NEVER
corroboration — only a deterministic contradiction or an inter-method disagreement is
high-signal. No output is a clearance.
