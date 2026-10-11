#!/usr/bin/env bash
# Measure head->peer transfer throughput over the CX7 ring, 3 ways.
# Run ON the head node.  Usage: bench-link.sh <peer-cx7-ip>
set -u
PEER="${1:?usage: bench-link.sh <peer-ip>}"
GB=4
MB=$((GB*1024))

bench() {  # $1 = label, then the pipeline runs via "$@"
  local label="$1"; shift
  local s e el
  s=$(date +%s)
  "$@"
  e=$(date +%s); el=$((e-s)); [ "$el" -lt 1 ] && el=1
  printf "  %-22s %4ds = %5d MB/s (%d Gbit/s)\n" "$label" "$el" "$((MB/el))" "$((MB*8/el/1000))"
  ssh -o BatchMode=yes "nvidia@$PEER" "rm -f /tmp/nt.bin" 2>/dev/null
}

send_ssh() { dd if=/dev/zero bs=1M count="$MB" 2>/dev/null \
  | ssh -o BatchMode=yes "nvidia@$PEER" "cat > /tmp/nt.bin"; }
send_ssh_fast() { dd if=/dev/zero bs=1M count="$MB" 2>/dev/null \
  | ssh -o BatchMode=yes -c aes128-gcm@openssh.com "nvidia@$PEER" "cat > /tmp/nt.bin"; }
send_nc() {
  ssh -o BatchMode=yes "nvidia@$PEER" \
      'nohup sh -c "nc -l -p 9999 > /tmp/nt.bin" >/dev/null 2>&1 & disown' 2>/dev/null
  sleep 2
  dd if=/dev/zero bs=1M count="$MB" 2>/dev/null | nc -q 1 "$PEER" 9999
}

echo "=== $(hostname) -> $PEER ($(ssh -o BatchMode=yes nvidia@$PEER hostname 2>/dev/null)), ${GB}GB ==="
bench "ssh (default cipher)" send_ssh
bench "ssh (aes128-gcm)"     send_ssh_fast
if ssh -o BatchMode=yes "nvidia@$PEER" 'command -v nc >/dev/null' 2>/dev/null; then
  bench "raw TCP (netcat)"   send_nc
else
  echo "  raw TCP (netcat)       nc not installed on peer"
fi
