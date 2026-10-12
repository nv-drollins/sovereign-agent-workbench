# Sovereign Agent Workbench

A booth demo for **local AI with enforced containment**: an agent reads
sensitive-style documents, answers with citations, and provably cannot reach
anything it has not been granted — all on hardware in the room.

Built for NVIDIA GTC Washington, D.C. Runs on a 3-node DGX Spark (GB10)
cluster, but the topology is configuration, not code.

---

## What a visitor sees

1. Pick a case file and a question (or type their own).
2. The agent fetches the document **through a policy gate**, reasons on a
   model sharded across two Sparks, and answers with every claim quoted.
3. An operator **revokes the agent's access to the records repository**.
   The same question now returns, in the agent's own words, that it cannot
   read the file — while it still has its model.

A live terminal shows the real commands and the real HTTP codes, including
OpenShell's own `403 policy_denied`. Nothing on screen is pre-recorded.

```
▣ Agent sandbox ──▶ ◆ Reasoning model      🔓 ALLOWED      ▤ Records repository
  non-root           2 Sparks (TP=2)        NemoClaw         every read audited
  no DNS · no route out                     policy gate
```

The lock sits on the path to the **documents**, not the model: cutting the
model just breaks the agent and proves nothing.

---

## Architecture

| Node | Role |
|---|---|
| head + worker | reasoning model, tensor-parallel across two nodes |
| retrieval | BM25 passage search over the corpus |
| records repository | documents served over HTTP, every read audited |
| verifier | checks each quoted span against the source text (service runs; **not yet called by the booth app**) |
| booth | Hermes agent sandbox, web UI, live telemetry |
| watchdog | repairs what it safely can, reports the rest |

Containment is enforced four ways, verified by measurement: forced proxy, no
DNS, no route out, and TLS interception so policy can match method and path.

The agent holds exactly **two** grants — the records repository and the local
model. Onboarding's default package-registry presets (pypi, npm, brew,
huggingface — 13 public hosts including github.com) are stripped by
`setup-agent.sh` on every onboard, and `demo.sh check` asserts they stay gone.

---

## Quick start

```bash
cp net.conf.example net.conf          # node roster + service placement
cp cluster.conf.example cluster.conf  # model, parallelism, paths
bash install.sh --check               # what is missing
bash install.sh                       # install it
bash net-setup.sh apply               # fabric routes (REQUIRED after any boot)
bash demo.sh start                    # bring everything up
bash demo.sh check                    # pass/fail board
```

Then open `http://<booth-node>:8500`.

### Daily operation

```bash
bash demo.sh start | stop | restart | status | check | logs
bash demo.sh recover          # after a power cut — one command
```

### Offline / poor venue internet

```bash
bash make-bundle.sh /media/usb/sovereign-bundle   # build on a connected box
# at the venue:
bash deploy-offline.sh                             # push image + weights
bash install.sh --offline
```

Bundle is ~90 GB (9 GB image + ~80 GB weights). A 128 GB stick is enough.

---

## Attract loop (the idle screen)

After **10 minutes** of no interaction the booth screen runs itself. Any touch,
key or click dismisses it, and it never covers a run in flight.

The copy is **editable without touching code**: edit `slides.json` on the booth
node (`~/booth/slides.json`). The screen picks up changes within ~20 seconds —
no page reload, no restart. A malformed file is ignored and the built-in slides
are used instead, so a typo at the booth cannot blank the screen.

```bash
# which is live right now:
curl -s http://<booth-node>:8500/api/slides | head -c 200
#   "source":"slides.json"   -> your file
#   "source":"built-in (slides.json error: ...)"  -> your file has a typo
```

Slide `type` values: `headline`, `steps`, `facts`, `quote`, `nodes`. The `quote`
slide is skipped automatically until the booth has produced a real answer — it
is never filled with a canned example. `nodes` is drawn live from telemetry.

Clicking the **padlock** on the diagram opens a read-only view of the policy
actually in force: the rendered YAML and the gateway's live preset list. The
content differs by state — granted shows the policy in force, revoked shows what
was removed and the HTTP code the agent now gets.

---

## Adding a document at the booth

An operator can upload a case file from the booth screen. The intake agent —
a **second model instance** on the records node — reads it and returns a title,
a one-line summary and questions specific to that document; the records
repository then writes it to disk, marked synthetic on its face.

```
choose a file  ->  intake agent catalogues it (~8 s)  ->  stored + listed
```

Uploaded documents carry an **added here** badge and a **remove** control that
deletes the file from the records repository, not just from the list. The three
seed documents have no remove control and the repository refuses to delete
them, so the known-good corpus survives an event.

The agent never writes. Its policy grants `GET` on `/api/docs` and
`/api/docs/*` only — verified from inside the sandbox:

```
GET    /api/docs -> 200      POST   /api/docs -> 403
DELETE /api/docs/<id> -> 403
```

If the intake model is unavailable the upload still succeeds, catalogued by a
deterministic parser and labelled as such — never a fabricated summary.

---

## Verification

Nothing here is assumed to work because it started.

```bash
bash check-portable.sh      # no site addresses, hostnames, paths or secrets
bash demo.sh check          # every service, the sandbox phase, the policy route
python3 check-booth.py      # opens the REAL websocket, runs a REAL query,
                            # asserts the answer event reaches the browser
bash prove-doc-block.sh     # 200 -> 403 -> 200 on the document, model untouched
bash cold-boot-test.sh      # reboot every node, prove one-command recovery
```

A health check that only pings HTTP 200 passed for an hour while the demo was
visibly broken. `check-booth.py` exists because of that.

---

## Portability

This repo is handed to other people and installed in other labs, so **no
address, hostname, username or path from any site appears in a committed
file**. `check-portable.sh` enforces it and is mutation-tested — it is proven
to catch injected IPs, hostnames, home paths and secrets, not merely to pass.

Site configuration lives in `net.conf` and `cluster.conf`, both gitignored.

---

## Measured numbers

| | |
|---|---|
| Nemotron-120B, one Spark | 14.6 tok/s single · 65 tok/s at 8 concurrent |
| Nemotron-120B, two Sparks (TP=2) | 12.9 tok/s single · 52 tok/s at 8 concurrent |
| Llama-405B dense, three Sparks | 0.75 tok/s — all nodes 95% SM, bandwidth-bound |
| End-to-end booth answer | 15–20 s including the policy-gated fetch |
| Cold-boot recovery | ~9 min, one command |

**Sharding is a capacity tool, not a speed tool.** A model that fits one node
runs ~11–20% slower when split. It is worth doing only when the model does not
fit — say so rather than letting "scales across three nodes" imply speed.

---

## Documents

The corpus is **synthetic**, generated for demonstration, and each file says so
on its face. No real government data is used anywhere in this demo.
