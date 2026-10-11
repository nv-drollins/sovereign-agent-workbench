#!/usr/bin/env python3
"""Per-node telemetry for DGX Spark / GB10, read straight from the hardware.

WHY NOT the DGX Dashboard on :11000 — it binds 127.0.0.1 only AND its
/api/v1/telemetry requires an Authorization header (401 without a session).
Scraping an authenticated UI for a booth display is fragile; /proc, /sys and
nvidia-smi are stable and need no login.

GB10 TELEMETRY TRAPS (each cost real debugging time):
  * `nvidia-smi --query-gpu=memory.used` returns [N/A] -- GB10 uses unified
    LPDDR5x. Report the unified pool from /proc/meminfo instead.
  * A SINGLE-SHOT `utilization.gpu` reads ~0 during bursty LLM decode. The
    honest signal is `nvidia-smi dmon -s u` and its `sm` column sampled over
    several ticks; take the MAX of the window.
  * Per-process `used_gpu_memory` is VIRTUAL address space on GB10 (it tracked
    VmSize=283GB for a worker whose RSS was 6GB). Never present it as usage.

Emits one JSON object. Run ON the node.
"""
import json, re, subprocess, time


def run(cmd, timeout=12):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.stdout.strip()
    except Exception:
        return ""


def meminfo():
    d = {}
    try:
        for line in open("/proc/meminfo"):
            k, _, v = line.partition(":")
            d[k] = int(v.split()[0]) * 1024
    except Exception:
        pass
    total = d.get("MemTotal", 0)
    avail = d.get("MemAvailable", 0)
    return {
        "total_gb": round(total / 1e9, 1),
        "used_gb": round((total - avail) / 1e9, 1),
        "avail_gb": round(avail / 1e9, 1),
        "pct": round(100 * (total - avail) / total, 1) if total else 0.0,
    }


def gpu_sm(samples=5):
    """Max SM (compute-engine) utilisation over a short window."""
    out = run(f"nvidia-smi dmon -s u -c {samples} 2>/dev/null", timeout=samples * 2 + 10)
    best = 0
    for line in out.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split()
        # layout: gpu sm mem enc dec ...  (sm is index 1)
        if len(parts) >= 2 and parts[1].isdigit():
            best = max(best, int(parts[1]))
    return best


def gpu_static():
    q = ("nvidia-smi --query-gpu=name,temperature.gpu,power.draw,power.limit,"
         "clocks.sm,clocks.mem,fan.speed --format=csv,noheader,nounits 2>/dev/null")
    vals = [v.strip() for v in run(q).split(",")]
    def num(i):
        try:
            return float(vals[i])
        except Exception:
            return None
    return {
        "name": vals[0] if vals else "unknown",
        "temp_c": num(1),
        "power_w": num(2),
        "power_limit_w": num(3),
        "clock_sm_mhz": num(4),
        "clock_mem_mhz": num(5),
    }


def cpu_pct():
    def snap():
        parts = open("/proc/stat").readline().split()[1:]
        v = [int(x) for x in parts[:8]]
        return sum(v), v[3] + v[4]          # total, idle+iowait
    t1, i1 = snap(); time.sleep(0.4); t2, i2 = snap()
    dt, di = t2 - t1, i2 - i1
    return round(100 * (dt - di) / dt, 1) if dt else 0.0


def vllm_stats(port=8000):
    """Pull the serving metrics that actually mean something at a booth."""
    try:
        import urllib.request
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=4) as r:
            txt = r.read().decode()
    except Exception:
        return None
    def val(metric):
        m = re.search(rf"^{re.escape(metric)}\{{[^}}]*\}}\s+([0-9.e+]+)", txt, re.M)
        return float(m.group(1)) if m else None
    return {
        "running": val("vllm:num_requests_running"),
        "waiting": val("vllm:num_requests_waiting"),
        "prompt_tokens": val("vllm:prompt_tokens_total"),
        "generated_tokens": val("vllm:generation_tokens_total"),
        "kv_cache_pct": (lambda x: round(x * 100, 1) if x is not None else None)(
            val("vllm:gpu_cache_usage_perc")),
    }


print(json.dumps({
    "host": run("hostname"),
    "ts": time.time(),
    "gpu": {**gpu_static(), "sm_pct": gpu_sm()},
    "memory": meminfo(),
    "cpu_pct": cpu_pct(),
    "uptime_h": round(float(open("/proc/uptime").read().split()[0]) / 3600, 1),
    "vllm": vllm_stats(),
}))
