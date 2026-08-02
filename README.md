# Model Safety Skills

_HuggingFace model safety — the model sibling to [David Vogel](https://www.skool.com/@dvogelca?g=cliefnotes)'s `repo-scorecard` / `repo-eval`. Built in his idiom and on his doctrine, with thanks (full credit below)._

Two portable agent skills that check whether a **HuggingFace model** is safe to run
*before* you run it — the model-artifact counterpart to David Vogel's
`repo-scorecard` / `repo-eval` for git repositories.

- **`model-scorecard`** — a 5-second gut check. What format are the weights, does the
  model run its own code when it loads, and is it even safe to look at closely?
- **`model-eval`** — the deep read, for a HuggingFace model **or a model folder already on disk**. Reads the custom code, checks whether it describes
  itself honestly, traces where the model's own output could reach an interpreter, and
  writes a plain-English report a non-technical person can act on.

`bash` + `curl` + `jq` + `python3`-stdlib. No accounts, no API keys, nothing installed,
and **nothing from the model you're checking is ever executed.** Drop the folders into
any agent harness that reads skills.

---

## Why a model-specific tool

Repo-health tools (including the ones this is built on) score the *project* — is it
maintained, does it have a license, how's the bus factor. They can't see the risk that
matters for an AI model: **a HuggingFace model can ship custom Python that runs the
moment you load it** (`trust_remote_code`), and the weights can be in a format that
executes code on open. A model can have millions of downloads, a major-lab name, and a
clean repo score — and still call `eval()` on its own output or tell you to `pip install`
a binary nobody can inspect. That's a different question from "is this project healthy,"
and it needs a different tool. (See [`model-eval/EXAMPLE-baidu-Unlimited-OCR.md`](model-eval/EXAMPLE-baidu-Unlimited-OCR.md)
for a real one.)

## What each skill does

### `model-scorecard` — the gut check
Reads the public HuggingFace API (no download of weights) and returns a coarse
**(format, loader) tier** plus a plain card:

- **E** — loads as data only (safetensors/gguf, no custom code). Low-risk case.
- **D** — non-executing weights, but runs custom code on load → go deeper.
- **C** — pickle-family weights: opening them can run code. Hard flag.
- **C?** — unrecognized format: fails **up** (treated as high-risk), never down.

Reputation never lowers the tier. It's a triage, never a clearance.

### `model-eval` — the deep read
Runs a deterministic collector (executes nothing), then:
1. Writes a description of what the custom code does — **twice**, once reading its
   comments and once ignoring them. If those disagree, the code's prose was steering
   the reader (a finding in itself).
2. **Checks that description against the code's actual call graph** — catching a model
   that misdescribes itself. (An LLM-authored description is a hypothesis; the value is
   catching it *contradicted*, never its say-so.)
3. Traces whether the model's generated output can reach a dangerous operation
   (`eval`, a shell, a deserializer).
4. Produces a report with a **plain-English decision on top** and the full evidence
   (files, line numbers, fingerprint) below.

## The honest ceiling — read this

This is a **negligence detector with an adversary-shaped ceiling.** Be clear-eyed about
what that means:

| Who's shipping the risk | Caught? |
|---|---|
| Lazy repackaging, leftover debug hooks, unadvertised telemetry, a convenience `eval` | **Reliably** — this is most of the real-world incident base |
| A careless maintainer using a dangerous shortcut | **Reliably** |
| A *targeted, evaluator-aware* attacker who obfuscates and hides intent | Only partly — needs the runtime differential (roadmap), plus luck |

Two rules keep it honest:

- **Silence is never "safe."** A quiet scan means "nothing obvious," not "clean."
- **Agreement is not proof.** Every static check reads the same source, so they share a
  blind spot — a clean report still ends in a human look. When a model runs code and was
  only checked from the outside, the verdict is an honest **"disclaimer of opinion"**
  ("not cleared" — not "dangerous," not "safe"), never a green light.

## What's new here vs. what it imports (don't reinvent)

The imported layers are mature — provenance, pickle scanning, the standards doctrine. What's **new here** is the machinery a repo-health tool can't do:

| Built here (new) | What it does |
|---|---|
| **Claim-vs-code contradiction check** | The model writes a description of what the code does; a deterministic scan of the actual call graph then tries to catch that description *lying*. The signal is the contradiction — never the model's say-so. |
| **Dual-pass claim** (with vs. without comments) | Reads the code twice — once trusting its prose, once ignoring it — and treats divergence as a finding. Catches code that *briefs* the reviewer, not just hides from it. |
| **Generation→sink tracing** | Follows whether the model's own output can reach an interpreter (`eval`, a shell, a deserializer) — the "it only outputs text" blind spot. |
| **(format, loader) risk tier + hard ceiling** | Grades by what the artifact is *permitted* to do on load (safetensors vs. pickle vs. custom code); reputation can never lower the tier. |
| **Three-track, un-averaged, plain-English report** | Provenance / code / instructions kept separate and never blended into one number — a decision a non-technical reader can act on, with an honest "disclaimer of opinion" when checked static-only. |

**Imported — don't reinvent:**

| Capability | Where it comes from |
|---|---|
| Repo-health / provenance signals | David Vogel's `repo-scorecard` / `repo-eval` |
| Pickle / serialization opcode scanning | route to `modelscan` / `picklescan` (mature; don't rebuild) |
| Build provenance / signing | SLSA-style attestation checks |
| The scoring & flag doctrine | OpenSSF / SLSA / CISA (via David's rubric lineage) |

## Try it

```bash
# gut check
model-scorecard/scripts/scorecard.sh baidu/Unlimited-OCR

# deep read (the SKILL drives the collector + report; the collector alone:)
model-eval/scripts/collect_signals.sh baidu/Unlimited-OCR
# ...or a model folder already on disk:
MAE_LOCAL_DIR=/path/to/model-folder model-eval/scripts/collect_signals.sh my-local-model

# the falsifiability floor — offline, no network:
bash model-eval/fixtures/run_fixtures.sh     # 11 seeded checks; must be green
```

Optional: set `HF_TOKEN` in the environment for higher API rate limits (never required).

## Roadmap (v2)

The one independent, non-source-reading instrument — a **declared-vs-exercised authority
differential** run in an isolated sandbox — is the headline v2 feature; until it exists,
code-execution-tier models get a disclaimer of opinion by design. Also planned: a
published proof-test catch-rate, and cross-modality checks (registry byte-diff,
hash-reputation).

## Credit

Built in the idiom and on the doctrine of **David Vogel's `repo-scorecard` /
`repo-eval`** ([Clief Notes community](https://www.skool.com/@dvogelca?g=cliefnotes)) — same portable skill shape, same "trust what you
can inspect" ethos, same `bash`/`git`/`curl` philosophy. This project extends that work
onto the model-artifact surface it doesn't cover; the git-repo tools remain the thing to
use for repositories. The underlying standards lineage is OpenSSF, SLSA, and CISA.
Thanks, David.

_By Charles Weeks · The Wizard's Spire · thewizardsspire.com_

## License

MIT — see [`LICENSE`](LICENSE).
