#!/usr/bin/env bash
# Verify a staged HF snapshot is COMPLETE and loadable.
# Usage: verify-model.sh <models-dir> <repo-id>
#
# Checks (cheap -> strong):
#   1. no *.incomplete leftovers
#   2. config.json parses
#   3. every shard named in the safetensors index EXISTS and is non-empty
#   4. each shard's safetensors header parses (catches truncation that a
#      size check misses)
# NOT a checksum of every byte -- that costs more than a re-download.
set -uo pipefail

DIR="${1:?usage: verify-model.sh <models-dir> <repo-id>}"
REPO="${2:?usage: verify-model.sh <models-dir> <repo-id>}"
VENV="$HOME/.hfvenv"
SNAP="$(find "$DIR" -maxdepth 4 -type d -path "*$(echo "$REPO" | tr '/' '-' | sed 's/^/models--/;s/-/--/' >/dev/null 2>&1; echo '')*/snapshots/*" 2>/dev/null | head -1)"
[ -n "$SNAP" ] || SNAP="$(find "$DIR" -maxdepth 4 -type d -name '*' -path '*/snapshots/*' | head -1)"
[ -d "$SNAP" ] || { echo "FAIL: no snapshot dir under $DIR" >&2; exit 1; }

echo "=== verifying $REPO on $(hostname) ==="
echo "  snapshot: $SNAP"

inc=$(find "$DIR" -name '*.incomplete' | wc -l)
printf "  %-32s %s\n" "incomplete files:" "$inc"
[ "$inc" -eq 0 ] || { echo "FAIL: $inc incomplete file(s)" >&2; exit 1; }

"$VENV/bin/python" - "$SNAP" <<'PY'
import json, os, struct, sys
snap = sys.argv[1]

cfg = os.path.join(snap, "config.json")
with open(cfg) as f:
    c = json.load(f)
print(f"  {'config.json:':32} OK ({c.get('model_type','?')}, "
      f"{c.get('num_hidden_layers','?')} layers)")

idx = os.path.join(snap, "model.safetensors.index.json")
if os.path.exists(idx):
    with open(idx) as f:
        shards = sorted(set(json.load(f)["weight_map"].values()))
else:
    shards = sorted(x for x in os.listdir(snap) if x.endswith(".safetensors"))
print(f"  {'shards referenced:':32} {len(shards)}")

missing, bad, total = [], [], 0
for s in shards:
    p = os.path.join(snap, s)
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        missing.append(s); continue
    total += os.path.getsize(p)
    # safetensors: first 8 bytes = little-endian header length, then JSON
    try:
        with open(p, "rb") as f:
            (n,) = struct.unpack("<Q", f.read(8))
            if n <= 0 or n > 200_000_000:
                bad.append((s, f"absurd header len {n}")); continue
            json.loads(f.read(n).decode("utf-8"))
    except Exception as e:
        bad.append((s, str(e)[:60]))

print(f"  {'shards present:':32} {len(shards)-len(missing)}/{len(shards)}")
print(f"  {'total weight bytes:':32} {total/1e9:.1f} GB")
print(f"  {'headers parsed OK:':32} {len(shards)-len(missing)-len(bad)}")
if missing:
    print("  MISSING:", missing[:5], file=sys.stderr)
if bad:
    print("  CORRUPT:", bad[:5], file=sys.stderr)
sys.exit(1 if (missing or bad) else 0)
PY
rc=$?
[ $rc -eq 0 ] && echo "=== $REPO VERIFIED on $(hostname) ===" \
              || echo "=== $REPO FAILED verification on $(hostname) ===" >&2
exit $rc
