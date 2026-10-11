#!/usr/bin/env bash
# Measure REAL inbound NIC throughput (not disk growth) and tune the ingress cap.
# Usage: nicrate.sh <iface> <seconds>
#
# WHY not disk growth: huggingface Xet stages into a cache dir and only then
# materialises files, so `du` on the model dir reports 0 MB/s during a healthy
# transfer and then jumps. /proc/net/dev is the ground truth for what the
# download is costing the LAN.
set -eu
IFACE="${1:?usage: nicrate.sh <iface> <seconds>}"
SECS="${2:-30}"
rx() { awk -v i="$IFACE:" '$1==i {print $2}' /proc/net/dev; }
a=$(rx); sleep "$SECS"; b=$(rx)
d=$((b-a))
printf "  inbound: %d MB/s (~%d Mbit/s) over %ss\n" \
  "$((d/SECS/1048576))" "$((d*8/SECS/1000000))" "$SECS"
