#!/usr/bin/env python3
"""Pretty-print the booth's cluster telemetry. Run anywhere that can reach the app."""
import json, sys, urllib.request

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8500"
with urllib.request.urlopen(f"http://{host}/api/telemetry", timeout=60) as r:
    d = json.load(r)

print(f"{'node':14} {'GPU':>5} {'MEM':>16} {'TEMP':>6} {'POWER':>8}  role")
print("-" * 72)
for n in d["nodes"]:
    if n.get("error"):
        print(f"{n['host']:14} {'--':>5} {'unreachable':>16}")
        continue
    g, m, v = n["gpu"], n["memory"], n.get("vllm")
    role = "serving model" if v else "idle"
    if v and v.get("running"):
        role += f" ({int(v['running'])} active)"
    print(f"{n['host']:14} {g['sm_pct']:>4}% "
          f"{m['used_gb']:>6.1f}/{m['total_gb']:.0f}GB ({m['pct']:>4.1f}%) "
          f"{(g['temp_c'] or 0):>5.0f}C {(g['power_w'] or 0):>6.1f}W  {role}")
    if v:
        print(f"{'':14} vLLM generated={int(v.get('generated_tokens') or 0):,} "
              f"prompt={int(v.get('prompt_tokens') or 0):,} "
              f"waiting={int(v.get('waiting') or 0)}")
