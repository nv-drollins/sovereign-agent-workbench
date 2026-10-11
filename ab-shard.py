#!/usr/bin/env python3
"""A/B a model served 1-node vs sharded 3-node (PP=3).

Answers the product-team question: "can we spread a model that already fits
on one node across three, and what does it cost or gain?"

Measures BOTH regimes, because they move in opposite directions:
  * single stream  -> PP adds hops + sync, expect SLOWER
  * concurrent     -> pipeline stages overlap, expect FASTER aggregate

Usage: ab-shard.py <host:port> <served-name> <label>
Appends a JSON record to ab-results.json so the two runs can be compared
after the fact (and so a reboot between runs loses nothing).
"""
import json, pathlib, statistics, sys, time, urllib.request
import concurrent.futures as cf

HOSTPORT = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8000"
MODEL = sys.argv[2] if len(sys.argv) > 2 else "nemotron-super-120b"
LABEL = sys.argv[3] if len(sys.argv) > 3 else "unlabelled"
URL = f"http://{HOSTPORT}/v1/chat/completions"
OUT = pathlib.Path(__file__).with_name("ab-results.json")

PROMPT = ("Summarise the key compliance obligations in a federal grant award: "
          "reporting cadence, approval thresholds, and closeout duties.")


def one(max_tokens=192):
    body = json.dumps({"model": MODEL,
                       "messages": [{"role": "user", "content": PROMPT}],
                       "max_tokens": max_tokens, "temperature": 0.2}).encode()
    req = urllib.request.Request(URL, data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.load(r)
    el = time.time() - t0
    u = d.get("usage", {})
    return el, u.get("completion_tokens", 0), u.get("prompt_tokens", 0)


print(f"=== {LABEL}  ({MODEL} @ {HOSTPORT}) ===")
print("warmup…")
one(24)

print("\nSINGLE STREAM  (3 runs x 192 tok)")
rates, lats = [], []
for i in range(3):
    el, ct, pt = one()
    r = ct / el if el else 0
    rates.append(r); lats.append(el)
    print(f"  run {i+1}: {el:6.1f}s  {ct:4d} tok  {r:6.2f} tok/s")
single = statistics.median(rates)
print(f"  MEDIAN: {single:.2f} tok/s   (median latency {statistics.median(lats):.1f}s)")

conc_results = {}
for conc in (2, 4, 8):
    print(f"\nCONCURRENT x{conc}")
    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=conc) as ex:
        res = list(ex.map(lambda _: one(), range(conc)))
    wall = time.time() - t0
    tot = sum(r[1] for r in res)
    agg = tot / wall if wall else 0
    conc_results[conc] = {"wall_s": round(wall, 1), "tokens": tot,
                          "aggregate_tok_s": round(agg, 2),
                          "per_stream_tok_s": round(agg / conc, 2)}
    print(f"  wall {wall:5.1f}s  tokens {tot:5d}  "
          f"AGGREGATE {agg:6.2f} tok/s  per-stream {agg/conc:5.2f}")

rec = {"label": LABEL, "model": MODEL, "endpoint": HOSTPORT, "ts": time.time(),
       "single_tok_s": round(single, 2),
       "single_latency_s": round(statistics.median(lats), 1),
       "concurrent": conc_results}

hist = json.loads(OUT.read_text()) if OUT.exists() else []
hist.append(rec)
OUT.write_text(json.dumps(hist, indent=2))
print(f"\nrecorded -> {OUT}")
