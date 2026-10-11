#!/usr/bin/env bash
# Sample GPU SM utilisation on every node WHILE a generation runs.
# Answers: is the cluster compute-bound, or are the nodes idle waiting on
# each other (pipeline stalls)?
#
# Run ON the head node.  Usage: load-probe.sh <served-name> [nodes...]
set -uo pipefail
NAME="${1:?need served model name}"
shift
NODES=("$@")
[ ${#NODES[@]} -eq 0 ] && { echo "usage: $0 <served-name> <node> [node...]" >&2; exit 2; }

echo "=== starting samplers on ${#NODES[@]} nodes ==="
for h in "${NODES[@]}"; do
  ssh -o BatchMode=yes "nvidia@$h" \
    'rm -f /tmp/dmon.txt; nohup nvidia-smi dmon -s u -c 30 > /tmp/dmon.txt 2>&1 & disown' 2>/dev/null
done
sleep 2

echo "=== generating ==="
start=$(date +%s)
resp=$(curl -s http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Write four sentences about federal record retention requirements.\"}],\"max_tokens\":160}" \
  --max-time 600)
end=$(date +%s)

toks=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["usage"]["completion_tokens"])
except Exception: print(0)')
el=$((end-start)); [ "$el" -lt 1 ] && el=1
echo "  generated $toks tokens in ${el}s  = $(python3 -c "print(f'{$toks/$el:.2f}')") tok/s"

sleep 3
echo "=== peak SM utilisation per node (column 2 = sm%) ==="
for h in "${NODES[@]}"; do
  printf '  %-14s ' "${h%%.*}"
  ssh -o BatchMode=yes "nvidia@$h" \
    "awk '/^[^#]/ && NF>2 {if (\$2+0 > m) m = \$2+0} END {printf \"peak_sm=%d%%\\n\", m}' /tmp/dmon.txt" 2>/dev/null
done

echo
echo "  interpretation:"
echo "    all nodes LOW  -> pipeline stalls / per-token sync overhead dominates"
echo "    one node HIGH  -> that rank is the bottleneck"
echo "    all nodes HIGH -> genuinely compute-bound"
