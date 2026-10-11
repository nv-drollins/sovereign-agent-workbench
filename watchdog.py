#!/usr/bin/env python3
"""Booth watchdog — the standing job for the verifier/records node.

WHY A WATCHDOG AND NOT A THIRD MODEL
The booth runs unattended for hours with nobody at a terminal. The failure
modes we have actually HIT during this build all look identical from the
aisle (a screen that does nothing) and all have known one-command fixes:

  * the Hermes sandbox returns in `Error` phase after a host reboot and
    NEVER self-heals
  * docker flushes the nat table, so the sandbox->model route disappears
  * a vLLM container exits and the endpoint goes dark
  * the booth app's websocket dies

A model sitting idle on .159 impresses nobody. A watchdog that keeps the
demo alive through all of the above is worth far more on a show floor --
and .159 also already runs the claim verifier, so the node is earning its
place twice.

Checks every INTERVAL seconds, repairs what it safely can, and records a
rolling health history the booth UI can display.

  python3 watchdog.py            # run forever
  python3 watchdog.py --once     # single pass, for testing
"""
from __future__ import annotations

import json, os, subprocess, sys, time
from pathlib import Path

INTERVAL = int(os.environ.get("WATCHDOG_INTERVAL", "45"))
STATE = Path(os.environ.get("WATCHDOG_STATE", "/tmp/watchdog-state.json"))

MODEL_HEAD = os.environ.get("MODEL_HEAD", "")
MODEL_FABRIC_IP = os.environ.get("MODEL_FABRIC_IP", "")
BOOTH_NODE = os.environ.get("BOOTH_NODE", "")
RETRIEVAL_NODE = os.environ.get("RETRIEVAL_NODE", "")
SBX = os.environ.get("SBX", "sovereign-agent")

MAX_REPAIRS_PER_HOUR = int(os.environ.get("WATCHDOG_MAX_REPAIRS", "6"))


def sh(cmd, timeout=45):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def on(host, cmd, timeout=45):
    return sh(f"ssh -o BatchMode=yes -o ConnectTimeout=6 nvidia@{host} "
              f"'bash -lc {json.dumps(cmd)}'", timeout)


def http(host, url, timeout=20):
    rc, out = on(host, f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 6 {url}", timeout)
    return out.strip()[-3:] if out else "000"


# ---------------------------------------------------------------- checks ---
def check_model():
    code = http(MODEL_HEAD, "http://127.0.0.1:8000/v1/models")
    return code == "200", f"model endpoint http={code}"


def check_route():
    code = http(BOOTH_NODE, "http://172.18.0.1:8000/v1/models")
    return code == "200", f"sandbox->model route http={code}"


def check_sandbox():
    rc, out = on(BOOTH_NODE, f"openshell sandbox list 2>/dev/null | grep '^{SBX} '")
    # openshell colours the phase; strip ANSI before comparing
    clean = subprocess.run(["sed", "s/\x1b\\[[0-9;]*m//g"], input=out,
                           capture_output=True, text=True).stdout
    phase = clean.split()[-1] if clean.split() else "missing"
    return phase == "Ready", f"sandbox phase={phase}"


def check_booth():
    code = http(BOOTH_NODE, "http://127.0.0.1:8500/")
    return code == "200", f"booth UI http={code}"


def check_retrieval():
    code = http(RETRIEVAL_NODE, "http://127.0.0.1:8700/health")
    return code == "200", f"retrieval http={code}"


def check_verifier():
    rc, out = sh("curl -s -o /dev/null -w '%{http_code}' --max-time 6 "
                 "http://127.0.0.1:8800/health")
    return out.strip()[-3:] == "200", f"verifier http={out.strip()[-3:]}"


# --------------------------------------------------------------- repairs ---
def repair_route():
    rc, out = on(BOOTH_NODE, f"bash ~/booth/model-route.sh on {MODEL_FABRIC_IP}", 60)
    return rc == 0, out.splitlines()[-1] if out else ""


def repair_booth():
    on(BOOTH_NODE, "cd ~/booth && fuser -k 8500/tcp 2>/dev/null; sleep 1; "
                   "nohup ~/booth/.venv/bin/python booth_app.py > /tmp/booth.log 2>&1 & disown", 40)
    time.sleep(8)
    return http(BOOTH_NODE, "http://127.0.0.1:8500/") == "200", "restarted booth app"


def repair_retrieval():
    on(RETRIEVAL_NODE, "cd ~/rag && fuser -k 8700/tcp 2>/dev/null; sleep 1; "
                       "RAG_DOCS=$HOME/rag/documents nohup python3 retrieval.py "
                       "> /tmp/rag.log 2>&1 & disown", 40)
    time.sleep(5)
    return http(RETRIEVAL_NODE, "http://127.0.0.1:8700/health") == "200", "restarted retrieval"


def repair_verifier():
    sh("cd ~/rag && fuser -k 8800/tcp 2>/dev/null; sleep 1; "
       "nohup python3 verifier.py > /tmp/verify.log 2>&1 & disown", 30)
    time.sleep(4)
    rc, out = sh("curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8800/health")
    return out.strip()[-3:] == "200", "restarted verifier"


# NOTE: deliberately NO auto-repair for the model or the sandbox.
# Re-onboarding a sandbox takes ~2 min and restarting the model ~8 min --
# doing either automatically mid-visit makes a recoverable glitch worse.
# They are REPORTED with the exact fix instead.
CHECKS = [
    ("model",     check_model,     None,             "bash demo.sh start   (model reload ~8 min)"),
    ("route",     check_route,     repair_route,     None),
    ("sandbox",   check_sandbox,   None,             f"nemoclaw {SBX} destroy --yes && bash setup-agent.sh"),
    ("booth",     check_booth,     repair_booth,     None),
    ("retrieval", check_retrieval, repair_retrieval, None),
    ("verifier",  check_verifier,  repair_verifier,  None),
]


def load_state():
    if STATE.exists():
        try:
            return json.loads(STATE.read_text())
        except Exception:
            pass
    return {"repairs": [], "history": [], "started": time.time()}


def one_pass(state, verbose=True):
    now = time.time()
    recent = [r for r in state["repairs"] if now - r["t"] < 3600]
    results = []
    for name, check, repair, manual in CHECKS:
        ok, detail = check()
        entry = {"name": name, "ok": ok, "detail": detail, "repaired": False}
        if not ok and repair:
            if len(recent) >= MAX_REPAIRS_PER_HOUR:
                entry["detail"] += "  [repair suppressed: rate limit]"
            else:
                fixed, msg = repair()
                entry["repaired"] = fixed
                entry["detail"] += f"  -> repair {'OK' if fixed else 'FAILED'}: {msg}"
                rec = {"t": now, "name": name, "ok": fixed}
                state["repairs"].append(rec); recent.append(rec)
        elif not ok and manual:
            entry["detail"] += f"  -> MANUAL: {manual}"
        results.append(entry)
        if verbose:
            mark = "\033[32mOK\033[0m" if entry["ok"] or entry["repaired"] else "\033[31mBAD\033[0m"
            print(f"  [{mark}] {name:10} {entry['detail']}")

    state["history"].append({"t": now, "all_ok": all(r["ok"] or r["repaired"] for r in results),
                             "results": results})
    state["history"] = state["history"][-200:]
    state["repairs"] = [r for r in state["repairs"] if now - r["t"] < 3600]
    state["last"] = now
    STATE.write_text(json.dumps(state, indent=2))
    return results


if __name__ == "__main__":
    st = load_state()
    if "--once" in sys.argv:
        print(f"=== watchdog single pass @ {time.strftime('%H:%M:%S')} ===")
        one_pass(st)
        sys.exit(0)
    print(f"watchdog: every {INTERVAL}s, state -> {STATE}", flush=True)
    while True:
        try:
            print(f"--- {time.strftime('%H:%M:%S')}", flush=True)
            one_pass(st)
        except Exception as e:
            print(f"  watchdog error: {e}", flush=True)
        time.sleep(INTERVAL)
