#!/usr/bin/env bash
# Distribute a staged model from the HEAD node to peers over the CX7 200GbE ring.
# Run ON the head node.  Usage: distribute-model.sh <models-dir> [peer-ip ...]
#
# WHY stream over the ring: pulling 196 GB from the internet three times is
# slow and venue-hostile. One download + a local fan-out is the portable
# pattern (and the ring is otherwise idle).
#
# NOTE: peers are addressed by their CX7 addresses, NOT the 192.168.1.x
# management LAN -- that is the entire point. Defaults are empty so this
# fails loudly rather than guessing another lab's topology.
set -euo pipefail

SRC="${1:?usage: distribute-model.sh <models-dir> [peer-ip ...]}"
shift || true
PEERS=("$@")
if [ "${#PEERS[@]}" -eq 0 ]; then
  echo "FAIL: no peers given." >&2
  echo "  example: $0 \$HOME/models 192.0.2.10 192.0.2.11" >&2
  exit 1
fi

[ -d "$SRC" ] || { echo "FAIL: $SRC not found" >&2; exit 1; }
SIZE_H="$(du -sh "$SRC" | cut -f1)"
echo "=== distributing $SRC ($SIZE_H) from $(hostname) to ${#PEERS[@]} peer(s) ==="

for peer in "${PEERS[@]}"; do
  echo "--- $peer"
  if ! timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 "nvidia@$peer" true 2>/dev/null; then
    echo "    SKIP: cannot ssh to $peer over the ring" >&2; continue
  fi
  pname="$(ssh -o BatchMode=yes "nvidia@$peer" hostname)"
  start=$(date +%s)
  # tar over ssh: no peer-side git/venv needed, preserves the HF cache layout.
  # Owned by the login user on arrival -> teardown never needs sudo.
  # aes128-gcm measured 1024 MB/s vs 682 MB/s for the default cipher on this
  # ring (raw netcat also 682 MB/s -> the cap is peer disk write, not crypto).
  ssh -o BatchMode=yes "nvidia@$peer" "mkdir -p '$SRC'"
  tar -C "$SRC" -cf - . \
    | ssh -o BatchMode=yes -c aes128-gcm@openssh.com "nvidia@$peer" "tar -C '$SRC' -xf -"
  end=$(date +%s); el=$((end-start)); [ "$el" -lt 1 ] && el=1
  rsize="$(ssh -o BatchMode=yes "nvidia@$peer" "du -sh '$SRC' | cut -f1")"
  sbytes=$(du -sb "$SRC" | cut -f1)
  echo "    $pname: $rsize in ${el}s  (~$(( sbytes / el / 1000000 )) MB/s)"
done

echo "=== verifying file-count + byte-size parity ==="
lf=$(find "$SRC" -type f | wc -l); lb=$(du -sb "$SRC" | cut -f1)
printf "  %-14s files=%-6s bytes=%s\n" "$(hostname)" "$lf" "$lb"
rc=0
for peer in "${PEERS[@]}"; do
  read -r rf rb pn < <(ssh -o BatchMode=yes "nvidia@$peer" \
      "echo \$(find '$SRC' -type f | wc -l) \$(du -sb '$SRC' | cut -f1) \$(hostname)" 2>/dev/null || echo "0 0 ?")
  if [ "$rf" = "$lf" ] && [ "$rb" = "$lb" ]; then
    printf "  %-14s files=%-6s bytes=%s  MATCH\n" "$pn" "$rf" "$rb"
  else
    printf "  %-14s files=%-6s bytes=%s  MISMATCH\n" "$pn" "$rf" "$rb"; rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "=== all peers match ===" || echo "=== PARITY FAILED ===" >&2
exit $rc
