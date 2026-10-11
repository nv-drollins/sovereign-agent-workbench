#!/usr/bin/env bash
# Measure the per-turn prompt size the agent actually sends to vLLM.
# Run ON the serving node. (File, not an inline one-liner: nested quoting
# through ssh -> bash -lc -> openshell collapses.)
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
SBX="${1:-sovereign-agent}"

m() { curl -s http://127.0.0.1:8000/metrics | grep "^$1{" | head -1 | awk "{print \$NF}"; }

echo "=== one trivial agent turn ==="
pb=$(m vllm:prompt_tokens_total); gb=$(m vllm:generation_tokens_total)
s=$(date +%s)
timeout -k 5 200 openshell sandbox exec --name "$SBX" --no-tty --timeout 180 -- \
  hermes ${BOOTH_PROFILE:+-p "$BOOTH_PROFILE"} -z "Reply with exactly: PING" --yolo >/dev/null 2>&1
e=$(date +%s)
pa=$(m vllm:prompt_tokens_total); ga=$(m vllm:generation_tokens_total)

python3 - "$pb" "$pa" "$gb" "$ga" "$((e-s))" <<'PY'
import sys
pb,pa,gb,ga,el = (float(x) for x in sys.argv[1:6])
pt, gt = int(pa-pb), int(ga-gb)
print(f"  prompt tokens sent : {pt}")
print(f"  tokens generated   : {gt}")
print(f"  wall clock         : {int(el)}s")
if gt: print(f"  generation rate    : {gt/el:.1f} tok/s")
print()
print(f"  -> a 'PING' reply costs {pt} prompt tokens of system preamble.")
print("     That preamble is re-sent and re-processed on EVERY turn.")
PY

echo
echo "=== how much of that is bundled skills? ==="
timeout -k 5 60 openshell sandbox exec --name "$SBX" --no-tty --timeout 40 -- \
  find /sandbox/.hermes/skills -name SKILL.md 2>/dev/null | wc -l | sed 's/^/  skills on disk: /'
