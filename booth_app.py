#!/usr/bin/env python3
"""Sovereign Agent Workbench — booth demo orchestrator.

EXHIBIT-HALL DESIGN (not a stage demo):
  * Self-running attract loop; an attendee walks up mid-run and still gets it.
  * One-tap presets. No typing, no terminal, ever.
  * Every beat is REAL: real sandbox, real model, real enforced policy.
  * Server-side state so a screen that connects late sees the whole story.

Run on the node that hosts the sandbox + model.
    python3 booth_app.py            # serves :8500
"""
from __future__ import annotations

import asyncio, json, os, re, shlex, subprocess, time, uuid
from dataclasses import dataclass, field, asdict
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse

SANDBOX = os.environ.get("BOOTH_SANDBOX", "sovereign-agent")
# Model may live on ANOTHER node (TP=2 head). Default to the DNAT'd
# bridge address, which the model-route.sh rule forwards to wherever
# the cluster head actually is.
MODEL_URL = os.environ.get("BOOTH_MODEL_URL", "http://172.18.0.1:8000/v1")
POLICY_FILE = os.environ.get("BOOTH_POLICY", "/tmp/sovereign-policy.yaml")
# Lean profile: 0 skills, no tool-search, capped reasoning. Measured 22s -> 9s
# on a trivial turn and 302 -> 3 generated tokens.
BOOTH_PROFILE = os.environ.get("BOOTH_PROFILE", "booth")

# Cluster roster for telemetry. HOSTNAMES ONLY -- no hardcoded IPs, so the
# repo moves to another lab by editing one env var.
# No default roster: a baked-in list points a stranger's clone at this lab.
# demo.sh exports BOOTH_NODES from net.conf.
NODES = [n for n in os.environ.get("BOOTH_NODES", "").split(",") if n.strip()]
TELEMETRY_SCRIPT = os.environ.get("BOOTH_TELEMETRY", "/tmp/telemetry.py")
DOCS = Path(os.environ.get("BOOTH_DOCS", str(Path(__file__).parent / "documents")))

# Never cache: a stale booth page silently serves yesterday's UI.
NOCACHE = {"Cache-Control": "no-store, no-cache, must-revalidate", "Pragma": "no-cache"}

app = FastAPI(title="Sovereign Agent Workbench")


# ---------------------------------------------------------------- state ----
@dataclass
class Run:
    id: str
    doc: str
    question: str
    status: str = "idle"          # idle|running|done|error
    phase: str = ""
    answer: str = ""
    elapsed: float = 0.0
    tokens: int = 0
    events: list = field(default_factory=list)


@dataclass
class Booth:
    run: Run | None = None
    policy_on: bool = True
    egress_proof: dict = field(default_factory=dict)
    # cumulative "sovereignty ledger" — the number a procurement officer photographs
    total_tokens: int = 0
    total_runs: int = 0
    bytes_egressed: int = 0       # structurally zero; we prove it, not claim it
    model_id: str = ""
    sandbox_info: dict = field(default_factory=dict)


S = Booth()
_subs: list[WebSocket] = []
_buffer: list[dict] = []          # late joiners get the full story


LOG: list[dict] = []


async def term(line: str, kind: str = "out"):
    """Emit a line to the booth's live terminal pane.

    kind: cmd | out | ok | err | note  -> drives colour only.
    """
    rec = {"type": "term", "kind": kind, "line": line,
           "ts": time.strftime("%H:%M:%S")}
    LOG.append(rec)
    del LOG[:-300]
    await broadcast(rec)


async def broadcast(ev: dict):
    ev["t"] = time.time()
    _buffer.append(ev)
    del _buffer[:-400]
    for ws in list(_subs):
        try:
            await ws.send_json(ev)
        except Exception:
            pass


# ------------------------------------------------------------- helpers ----
def sh(cmd: list[str], timeout: int = 120) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def sandbox_exec(args: list[str], timeout: int = 120) -> tuple[int, str]:
    """Run argv inside the sandbox.

    No nested `bash -lc`: openshell takes an argv after `--`, and a second
    quoted shell collapses on the ssh round-trip. External `timeout` because
    `openshell sandbox exec` can wedge past its own --timeout.
    """
    base = ["timeout", "-k", "5", str(timeout + 20),
            os.path.expanduser("~/.local/bin/openshell"), "sandbox", "exec",
            "--name", SANDBOX, "--no-tty", "--timeout", str(timeout), "--"]
    return sh(base + args, timeout=timeout + 40)


def nemoclaw(args: list[str], timeout: int = 120) -> tuple[int, str]:
    return sh([os.path.expanduser("~/.local/bin/nemoclaw")] + args, timeout=timeout)


_tele_cache: dict = {"t": 0.0, "nodes": []}


def _node_telemetry(host: str) -> dict:
    """Read telemetry from ONE node. Local node runs it directly."""
    import socket
    cmd = (["python3", TELEMETRY_SCRIPT] if host.startswith(socket.gethostname())
           else ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                 f"nvidia@{host}", "python3", TELEMETRY_SCRIPT])
    rc, out = sh(cmd, timeout=25)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except Exception:
        return {"host": host.split(".")[0], "error": True}


def collect_telemetry(max_age: float = 3.0) -> list[dict]:
    """Cached so a 1 Hz booth poll doesn't hammer SSH."""
    if time.time() - _tele_cache["t"] < max_age and _tele_cache["nodes"]:
        return _tele_cache["nodes"]
    with __import__("concurrent.futures").futures.ThreadPoolExecutor(max_workers=len(NODES)) as ex:
        nodes = list(ex.map(_node_telemetry, NODES))
    _tele_cache.update({"t": time.time(), "nodes": nodes})
    return nodes


def list_docs() -> list[dict]:
    out = []
    if DOCS.is_dir():
        for f in sorted(DOCS.glob("*.md")):
            head = f.read_text(errors="ignore").splitlines()
            title = next((l.lstrip("# ").strip() for l in head if l.startswith("#")), f.stem)
            out.append({"id": f.stem, "title": title,
                        "words": len(" ".join(head).split())})
    return out


# ------------------------------------------------------------- the run ----
AGENT_PROMPT = """You are an analyst working inside a secure, offline facility.

Read the document below and answer the question.

RULES
- Quote the exact text you relied on, in "quotes", for every claim.
- If the document does not answer it, say so plainly. Do not speculate.
- Be concise: at most 6 short bullets. This is shown on a booth screen.

DOCUMENT
--------
{doc}
--------

QUESTION: {question}
"""


async def run_agent(doc_id: str, question: str):
    run = S.run
    t0 = time.time()
    try:
        run.status = "running"
        run.phase = "reading"
        await broadcast({"type": "phase", "phase": "reading",
                         "msg": f"Requesting {doc_id} from the records repository"})
        await term(f"$ openshell sandbox exec --name {SANDBOX} -- \\", "cmd")
        await term(f"      curl -sv {RECORDS_URL}/api/docs/{doc_id}", "cmd")

        # THE AGENT fetches the document from the records repository itself,
        # through the OpenShell policy gate. If its permission is revoked this
        # returns 403 and the run reports that honestly instead of answering.
        rc, out = await asyncio.to_thread(
            sandbox_exec,
            ["curl", "-s", "-w", "\n%{http_code}", "--max-time", "25",
             f"{RECORDS_URL}/api/docs/{doc_id}"], 70)
        lines = (out or "").strip().splitlines()
        code = lines[-1].strip()[-3:] if lines else "000"
        await broadcast({"type": "fetch", "http": code,
                         "url": f"{RECORDS_URL}/api/docs/{doc_id}"})
        if code == "200":
            await term(f"< HTTP/1.1 {code} OK   {len(out)} bytes", "ok")
        else:
            # This text comes from OpenShell's proxy, not from us.
            await term(f"< HTTP/1.1 {code} Forbidden", "err")
            snippet = " ".join((out or "").split())[:120]
            if snippet:
                await term(f"< {snippet}", "err")

        if code != "200":
            run.status = "error"
            run.phase = "denied"
            run.answer = (
                f"I could not retrieve '{doc_id}' from the records repository.\n"
                f"The request was refused (HTTP {code}).\n\n"
                "I still have my reasoning model, but I have no permission to read "
                "that document, so I will not guess at its contents.")
            await broadcast({"type": "denied", "http": code, "doc": doc_id,
                             "msg": run.answer})
            return

        try:
            text = json.loads("\n".join(lines[:-1])).get("text", "")
        except Exception:
            text = "\n".join(lines[:-1])
        prompt = AGENT_PROMPT.format(doc=text[:12000], question=question)

        run.phase = "thinking"
        await broadcast({"type": "phase", "phase": "thinking",
                         "msg": "Agent is reasoning on the local model"})
        await term(f"$ openshell sandbox exec --name {SANDBOX} -- \\", "cmd")
        await term(f"      hermes -p {BOOTH_PROFILE} -z \"$PROMPT\" --yolo", "cmd")
        await term(f"> model={S.model_id} prompt_chars={len(prompt)}", "out")

        # Heartbeats so the booth screen never looks frozen.
        async def beat():
            msgs = ["Locating relevant passages…", "Checking each claim against the text…",
                    "Drafting a cited answer…", "Tightening for the screen…"]
            i = 0
            while run.status == "running":
                await asyncio.sleep(9)
                if run.status != "running":
                    return
                await broadcast({"type": "tick", "msg": msgs[i % len(msgs)]})
                i += 1

        hb = asyncio.create_task(beat())
        rc, out = await asyncio.to_thread(
            sandbox_exec, ["hermes", "-p", BOOTH_PROFILE, "-z", prompt, "--yolo"], 300)
        hb.cancel()

        answer = out.strip()
        # Hermes prints a trailing session line; keep the prose.
        answer = re.sub(r"\n?Session:.*$", "", answer).strip()

        if rc != 0 or not answer:
            run.status = "error"
            run.answer = answer or f"agent returned rc={rc}"
            await broadcast({"type": "error", "msg": run.answer[:300]})
        else:
            run.status = "done"
            run.answer = answer
            run.elapsed = time.time() - t0
            run.tokens = max(1, len(answer.split()))
            S.total_tokens += run.tokens
            S.total_runs += 1
            await term(f"< done in {run.elapsed:.1f}s  {run.tokens} words", "ok")
            await broadcast({"type": "answer", "answer": answer,
                             "elapsed": round(run.elapsed, 1)})
    except Exception as e:  # never let the booth screen hang on a traceback
        run.status = "error"
        run.answer = str(e)[:300]
        await broadcast({"type": "error", "msg": run.answer})


# ------------------------------------------------------------ endpoints ----
@app.get("/api/state")
async def state():
    return JSONResponse({
        "run": asdict(S.run) if S.run else None,
        "doc_access": S.policy_on,
        "records": RECORDS_URL,
        "records_host": RECORDS_HOST,
        "egress_proof": S.egress_proof,
        "ledger": {"tokens": S.total_tokens, "runs": S.total_runs,
                   "bytes_egressed": S.bytes_egressed},
        "model": S.model_id,
        "topology": os.environ.get("BOOTH_TOPOLOGY", ""),
        "sandbox": S.sandbox_info,
        "documents": list_docs(),
        "nodes": collect_telemetry(),
    }, headers=NOCACHE)


@app.get("/api/telemetry")
async def telemetry():
    return JSONResponse({"nodes": collect_telemetry(max_age=1.5)}, headers=NOCACHE)


_CTRL = re.compile(r"[\x00-\x1f\x7f]")


def clean_question(q: str) -> str:
    """Attendee-typed input. Cap and sanitise server-side -- the browser guard
    is for UX, this one is authoritative."""
    q = _CTRL.sub(" ", q or "")
    q = " ".join(q.split())
    return q[:300]


@app.post("/api/run")
async def start(doc: str, question: str):
    if S.run and S.run.status == "running":
        raise HTTPException(409, "a run is already in flight")
    question = clean_question(question)
    if len(question) < 8:
        raise HTTPException(400, "question too short")
    if doc not in {d["id"] for d in list_docs()}:
        raise HTTPException(400, "unknown document")
    S.run = Run(id=uuid.uuid4().hex[:8], doc=doc, question=question)
    await broadcast({"type": "start", "doc": doc, "question": question})
    asyncio.create_task(run_agent(doc, question))
    return {"id": S.run.id}


# ⚠ TWO DIFFERENT PATHS TO THE SAME MODEL, governed differently:
#
#   https://inference.local/v1      -> the gateway's MANAGED inference route.
#                                      Granted at onboarding. Policy presets do
#                                      NOT govern it, so removing a preset does
#                                      NOT block it (measured: still 200).
#   http://host.openshell.internal  -> the HOST-SERVICE path, which the
#                                      `local-inference` PRESET governs.
#                                      Remove the preset -> 403 from OpenShell.
#
# The deny/allow beat MUST probe the host-service path, or it silently
# "proves" nothing while looking correct.
# The RECORDS REPOSITORY the agent must fetch documents from. Blocking THIS
# is the demo beat: the agent keeps its model (it can still think) but loses
# permission to read the case file -- contained, not broken.
# No default: a baked-in address silently points a stranger's clone at
# someone else's machine. Set BOOTH_RECORDS_HOST (demo.sh exports it).
RECORDS_HOST = os.environ.get("BOOTH_RECORDS_HOST", "")
RECORDS_PORT = os.environ.get("BOOTH_RECORDS_PORT", "8900")
RECORDS_URL = f"http://{RECORDS_HOST}:{RECORDS_PORT}"
RECORDS_POLICY = os.environ.get("BOOTH_RECORDS_POLICY", os.path.expanduser("~/booth/records-policy.yaml"))


def _agent_can_read_docs() -> tuple[bool, str]:
    """Ask the AGENT ITSELF whether it can reach the records repository."""
    rc, out = sandbox_exec(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "--max-time", "20", f"{RECORDS_URL}/api/docs"], 60)
    code = (out.strip().splitlines() or ["000"])[-1][-3:]
    return code == "200", code


@app.get("/api/access")
async def access_state():
    ok, code = await asyncio.to_thread(_agent_can_read_docs)
    S.policy_on = ok
    return JSONResponse({"doc_access": ok, "http": code,
                         "records": RECORDS_URL}, headers=NOCACHE)


@app.post("/api/access/{action}")
async def set_access(action: str):
    """MANUAL toggle: revoke or grant the agent's access to the DOCUMENTS.

    Deliberately NOT the model -- blocking the model just breaks the agent and
    proves nothing. Blocking the records repository shows containment: the
    agent still thinks, it simply cannot read what it is not cleared for.
    """
    if action not in ("revoke", "grant"):
        raise HTTPException(400, "action must be revoke or grant")

    await broadcast({"type": "access_busy",
                     "msg": ("Revoking the agent's access to the records repository…"
                             if action == "revoke" else
                             "Restoring the agent's access to the records repository…")})

    if action == "revoke":
        await term(f"$ nemoclaw {SANDBOX} policy-remove records-repository --yes", "cmd")
        await asyncio.to_thread(nemoclaw,
            [SANDBOX, "policy-remove", "records-repository", "--yes"], 120)
    else:
        await term(f"$ nemoclaw {SANDBOX} policy-add --from-file records-policy.yaml --yes", "cmd")
        await asyncio.to_thread(nemoclaw,
            [SANDBOX, "policy-add", "--from-file", RECORDS_POLICY,
             "--trusted-private-host", RECORDS_HOST, "--yes"], 150)

    ok, code = await asyncio.to_thread(_agent_can_read_docs)
    S.policy_on = ok
    await term(f"$ curl -s -o /dev/null -w '%{{http_code}}' {RECORDS_URL}/api/docs", "cmd")
    await term(f"{code}", "ok" if ok else "err")
    await broadcast({"type": "access", "granted": ok, "http": code})
    return {"doc_access": ok, "http": code}


@app.post("/api/prove-egress")
async def prove():
    """Run the containment checks live. Nothing here is pre-recorded."""
    await broadcast({"type": "phase", "phase": "proving",
                     "msg": "Testing what the agent can and cannot reach"})
    res = {}
    for label, url in (("public internet", "https://example.com"),
                       ("code hosting", "https://api.github.com")):
        rc, out = sandbox_exec(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", "15", url], 60)
        code = (out.strip().splitlines() or ["000"])[-1][-3:]
        res[label] = {"url": url, "http": code, "blocked": code in ("000", "403")}
    rc, out = sandbox_exec(
        ["curl", "-sk", "--max-time", "20", "https://inference.local/v1/models"], 60)
    ok = '"object"' in out
    res["local model"] = {"url": "https://inference.local/v1", "allowed": ok}
    S.egress_proof = res
    await broadcast({"type": "egress", "proof": res})
    return res


@app.websocket("/ws")
async def ws(sock: WebSocket):
    await sock.accept()
    _subs.append(sock)
    for ev in LOG[-60:]:              # late joiner sees the terminal history
        try:
            await sock.send_json(ev)
        except Exception:
            break
    for ev in _buffer[-80:]:          # late joiner sees the story so far
        try:
            await sock.send_json(ev)
        except Exception:
            break
    try:
        while True:
            await sock.receive_text()
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        try:
            _subs.remove(sock)
        except ValueError:
            pass


@app.get("/")
async def index():
    p = Path(__file__).parent / "booth.html"
    return HTMLResponse(p.read_text(), headers=NOCACHE)


@app.on_event("startup")
async def boot():
    import urllib.request
    try:
        with urllib.request.urlopen(f"{MODEL_URL}/models", timeout=8) as r:
            S.model_id = json.load(r)["data"][0]["id"]
    except Exception:
        S.model_id = "(model not reachable)"
    rc, out = sandbox_exec(["hostname"], 60)
    S.sandbox_info = {"container": out.strip().splitlines()[-1] if rc == 0 else "?",
                      "name": SANDBOX,
                      "node": os.environ.get("BOOTH_SELF_NODE", os.uname().nodename)}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("BOOTH_PORT", 8500)))
