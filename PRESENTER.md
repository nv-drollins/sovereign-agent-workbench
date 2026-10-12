# Presenter Script — Sovereign Agent Workbench

GTC Washington, D.C. · Ronald Reagan Building · Nov 30 – Dec 3

Everything in this script is a thing the demo actually does. Timings are
measured, not estimated — see **Measured timings** at the end. If a number on
this page stops matching the booth, fix the page.

---

## The one sentence

> An AI agent reads sensitive documents, answers with every claim quoted, and
> **provably cannot reach anything you did not grant it** — on three machines
> sitting on this table, with nothing leaving the room.

Say this first, to everyone, every time. It filters the crowd: the people who
lean in are the ones you want.

---

## 90-second version (the aisle pass-by)

Use when someone slows down but hasn't committed.

1. **Point at the hardware.** "Three desk-side machines. No cloud behind them,
   no network cable to anywhere that matters."
2. **Tap a case file, tap a question, press Run.** Talk while it works (~12–17s):
   "It's fetching a grant award notice from a records service, reading it, and
   answering. Watch the terminal — those are the real commands."
3. **Land on the answer.** "Every claim is quoted from the document. If the
   document doesn't say, it says so rather than guessing."
4. **The hook:** "Now the part people come here for — let me show you what
   stops it." → go to the containment beat.

---

## Full walkthrough — beats in order

### Beat 1 — Framing (30s, before you touch anything)

> "The question I get at every booth is 'where does my data go?' Here the
> answer is: nowhere. These three machines are the whole system. The documents
> are on that one, the model is split across those two, and the agent runs in
> a locked container on the third."

**Do not** open with tokens/sec, parameter counts, or a hardware spec. This
room does not buy on throughput, and a benchmark invites a comparison against a
hyperscaler that you lose.

### Beat 2 — A real answer with real citations (~15s of work)

Pick the document that matches who you're talking to:

| Visitor | Document | Why it lands |
|---|---|---|
| Program / grants staff | **Grant Award Notice** | reporting deadlines, approval thresholds |
| Oversight / IG / audit | **OIG Referral Memorandum** | findings, unverified deliverables, a lapsed COR |
| Acquisition / procurement | **Bid Protest Decision** | tradeoff failure, unstated criteria, OCI |

Press Run on *"What are the three most important deadlines, and what happens if
each is missed?"*

While it runs, narrate the live terminal — this is the most persuasive object
on the screen:

> "That's the agent's actual request to the records service. Not a recording —
> that status code is coming back right now."

When the answer lands:

> "Each of those is in quotes because it's lifted from the document. A
> paraphrase is where these systems get people in trouble."

### Beat 3 — The refusal (the beat that earns trust)

Run *"What does this document NOT tell me that I would need to know?"*

> "This is the one I'd actually want in an agency. It will tell you what the
> document doesn't cover rather than inventing a plausible answer."

A system that only ever succeeds looks rehearsed. One that correctly declines
looks trustworthy.

### Beat 4 — Containment (the payoff)

**Leave the toggle in whichever state it's in and let the visitor drive.**

> "Right now the agent is allowed to read case files. I'm going to take that
> away — not the model, just the documents."

Press **Revoke access**. (~2s. The terminal shows the real `nemoclaw
policy-remove`, timestamped.)

> "Same agent, same question, nothing else changed. Press Run yourself."

It comes back in ~2 seconds:

> *"I could not retrieve 'grant-award' from the records repository. The request
> was refused (HTTP 403). I still have my reasoning model, but I have no
> permission to read that document, so I will not guess at its contents."*

Deliver the line that matters:

> **"It's contained, not broken. It still has its model, it can still think —
> it simply has no permission to read that file. That 403 came from the policy
> gate, not from anything I wrote."**

Press **Grant access** (~4s) and run it again to show it restored.

### Beat 5 — What else it can't reach (optional, for the security-minded)

Press **Prove containment**. Live, not pre-recorded:

- public internet → **BLOCKED**
- code hosting → **BLOCKED**
- the local model → **ALLOWED**

> "Deny by default. The only thing on the allow list is the model in this room
> and the records service — and you just watched me take that one away."

**If they ask to see the permission list** (the best question you'll get), show
them on the operator machine:

```bash
nemoclaw sovereign-agent policy-explain
```

Or just **click the padlock on the screen** — it opens a read-only view of the
policy in force, including the live preset list. Do that instead of the terminal
when a visitor is watching; it makes the same point without a shell.

It prints exactly two active grants: the records repository and the local
inference endpoint. Worth saying out loud:

> "The onboarding tooling installs convenience access to PyPI, npm, Homebrew and
> Hugging Face by default — thirteen public hosts, including GitHub. We stripped
> all four. The agent doesn't install anything at runtime, so it loses nothing,
> and this list is the one I'd want to hand an authorizing official."

`bash demo.sh check` has a permanent **agent permissions** line asserting this,
because a sandbox rebuild silently puts those grants back.

### Beat 6 — The close

> "Everything you saw ran on these three machines. The documents never left,
> the answers never left, and the bill is a purchase order rather than a meter
> that runs every time someone asks a question."

Point at the ledger panel: **bytes sent to any cloud: 0**.

---

## Hard questions — honest answers

**"Is that a real model or a scripted demo?"**
> Real. Nemotron-120B, split across two of these machines. Type your own
> question in the box and watch it work — there's no script behind it.

**"Why split it across two machines? Is it faster?"**
> No, and I'd rather say so. Splitting buys **capacity, not speed** — it's how
> a model too big for one box runs at all. Measured on our own hardware, this
> model runs 14.6 tokens/sec whole on one machine and 12.9 split across two —
> about 12% *slower*. We split only what doesn't fit.

**"Could it be jailbroken into reaching the internet?"**
> The containment isn't in the prompt, so prompt tricks don't apply to it. The
> sandbox has no DNS and no route out; everything goes through a policy proxy
> that matches on method and path. Even if you convinced the agent to try, the
> packet has nowhere to go. That's what the 403 is.

**"What model is it, and where is it from?"**
> NVIDIA Nemotron. We deliberately ruled out models of Chinese origin for this
> audience, regardless of benchmark position — a sovereignty story running on
> weights you're uneasy about undercuts itself.

**"Is that real data?"**
> No — every document is synthetic, generated for this demo, and it says so on
> its face. We don't demo on anything government-shaped.

**"How fast is it really?"**
> About 12 to 17 seconds end to end, including the policy-gated fetch. Single
> stream, this model generates about 13 tokens a second in the split
> configuration you're looking at.

**"What happens if it's wrong?"**
> That's why every claim is quoted — you can check any of them against the
> document on screen in a couple of seconds. The quoting rule is in the agent's
> instructions, and when the document doesn't support an answer it says so
> instead of filling the gap.

⚠ **Do not claim the verifier re-checks the answer.** A claim-verifier service
runs on the third node and is healthy, but the booth app does **not** currently
call it — nothing a visitor sees is verified by it. Either wire it into the run
and put its result on screen, or leave it out of the pitch. Saying it out loud
while it isn't in the path is exactly the kind of thing an engineer in the aisle
will ask you to demonstrate.

**"Can I run this on one box?"**
> Yes — a smaller model on a single Spark is the same software. The three-node
> arrangement is here because this model doesn't fit on one.

**"What did you build versus what ships from NVIDIA?"**
> The sandbox, the policy engine and the model all ship from NVIDIA — NemoClaw
> / OpenShell and Nemotron. The booth app, the records service, the verifier
> and the document corpus are ours.

---

## If something goes wrong on the floor

Say what's happening rather than clicking in silence — this audience reads
recovery as competence.

| Symptom | Say | Do |
|---|---|---|
| Answer slow (>40s) | "First question after an idle period is slower — it's warming up." | Wait. Second run is normal. |
| Screen blank / panels empty | "Give me ten seconds." | `bash demo.sh check` — if **booth data** is ✗, `bash demo.sh restart` |
| Run errors out | "That one didn't complete, let me re-run it." | Press Reset, run again |
| Grant doesn't restore access | — | `bash demo.sh check`, then re-run the grant; the terminal pane shows nemoclaw's refusal text |
| Everything dead after a power event | "We lost power to the rack — one command brings it back." | `bash demo.sh recover` (~9 min) |

The watchdog repairs the cheap things itself every 45s. It will **not**
auto-reload the model or rebuild the sandbox mid-visit — both are multi-minute
and would turn a glitch into an outage. It reports those with the exact command.

---

## Things NOT to say

- ❌ "It's impossible to break out." → say what's enforced and how.
- ❌ "Faster than the cloud." → it isn't, and that's not the pitch.
- ❌ "Scales across three nodes" implying speed. → capacity, not speed.
- ❌ Anything about the documents being realistic. → they're synthetic, say so.
- ❌ Reading the answer aloud off the screen. → the visitor can read; narrate
  what the *system* is doing instead.

---

## Measured timings (re-measure before the show)

Measured on the booth stack, warm, 2026-10-11:

| Beat | Time |
|---|---|
| Answer, grant-award | **17.3s** |
| Answer, ig-referral | **16.4s** |
| Answer, procurement-protest | **11.7s** |
| First run after a restart (cold) | **~50s** — do a warm-up run before doors |
| Revoke access | **2.1s** |
| Denied run (403 path) | **1.9s** |
| Grant access | **4.2s** |
| Full cold-boot recovery | **~9 min**, one command |

**Run one throwaway query before the doors open.** The first run after any
restart is ~3× slower than the rest, and that's the one a visitor shouldn't see.
