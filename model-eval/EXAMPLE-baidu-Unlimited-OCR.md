# Is this model safe to use? — `baidu/Unlimited-OCR`

**Short answer:** We can't give it a clean bill of health, and there are two real
things to fix first. It is **not malicious — it's careless.** Fine to use if a
technical person handles the fixes below and it runs somewhere isolated.

_(model-eval worked example / S3 verification — a real end-to-end run on the
reference model. Plain-English lead, full evidence below.)_

## In plain English

Unlimited-OCR is a hugely popular text-recognition model — about 2.6 million
downloads, from Baidu, openly licensed. Popularity and a big name tell you nothing
about safety, so we looked at what its code actually **does** when you load and run
it. Two things stood out:

1. **It runs commands built from its own output.** When the model reads a document,
   part of its code takes the text the model produces and *runs it as a program* —
   in seven different spots. In normal use this just draws layout boxes. But it
   means a specially-crafted document could, in theory, steer the model into running
   unintended commands on your machine. This isn't a hidden backdoor; it's a lazy
   shortcut (a dangerous function where a safe one belongs). Real risk, lowish odds,
   easy to fix.

2. **Its setup instructions tell you to install a program nobody can check.** The
   "faster" setup path says to install a bundled software package that exists
   nowhere public to compare against and ships as pre-compiled code you can't read.
   Installing it means trusting code sight-unseen.

The model's actual "brain" (the weights) is in the safe format — that part is fine.
The risk is entirely in the **code that ships alongside it.**

## What we'd tell you to do

- **Don't** use the "faster" setup path or install that bundled package. If you need
  the speed, have someone build it from the official source instead.
- **Do** run it on an isolated machine — not one with access to anything you care
  about — and either avoid the layout/coordinate feature or have a developer swap
  the seven risky spots for the safe equivalent (a ~10-minute change).
- **Have a technical person check the three items** in "Needs a human look" before
  this touches real work.

## Why we won't just say "safe"

We looked at this from the outside — reading the code, not running it in a
controlled trap (that deeper test is a future feature). Our honest position: when a
model ships code that runs on load, an outside read can catch obvious problems but
can't *prove* it's clean. So the verdict is **"not cleared" — not "dangerous," not
"safe."** That's the honest answer, and it's exactly why the human look matters.

---

## The details (for the technical reader)

**Verdict:** Tier B (ships code with in-process code-execution) · **Disclaimer of
opinion, leaning adverse** · evaluated static-only.

**Three separate checks, kept separate** (never averaged into one score):

| Check | Result | Evidence |
|---|---|---|
| Reputation | Strong, but irrelevant to safety | 2.6M downloads, MIT, active, major org. Popularity is not a safety control. |
| The code itself | **RED** | `eval()` on model-generated output at `modeling_unlimitedocr.py` L1099/1101/1104/1112/1113/1128 (+L66); `torch.load` (pickle-based) at `deepencoder.py` L1049 on load. Nothing dangerous at import time. |
| The instructions | **RED** | README's SGLang path: `uv pip install wheel/sglang-0.0.0.dev…whl` — an unregistered, compiled binary. Requires `trust_remote_code=True`. |

**Did the code lie about itself?** No. We described what the code does twice — once
reading its comments, once ignoring them — and the two matched. Honest-but-sloppy,
not deceptive. (Divergence there would have been a red flag on its own.)

**The risky data path:** model output → `outputs` → `eval(outputs)[...]` — confirmed
reachable. This is the "generation is an execution surface" case.

**Can't-inspect items (counted against it):** the bundled `.dev` wheel (compiled, no
public-registry match) and no build attestation.

**Needs a human look (the residue):**
1. Seven `eval()` calls on model output → patch to `ast.literal_eval`, or don't use
   the grounding/layout output mode on untrusted documents.
2. `torch.load` on load → confirm the checkpoint source.
3. The bundled SGLang wheel → build from pinned upstream or skip.

**Fingerprint (for change-detection):** 20 files, `sha256 1c15890a…da34d` — computed
from the hub's published hashes, no weights downloaded. Re-check on any update; a
change here under the same version is itself a red flag.

**How much to trust this:** the fingerprint, the format/tier call, and the
`eval`/`torch.load` detection are solid (deterministic — they'd survive an attacker
who read our tool). The plain-English reasoning about *reachability* is a best-effort
read that a determined attacker could evade — which is the whole reason a code-bearing
model always ends in a human look, never an automatic "pass."
