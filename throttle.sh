#!/usr/bin/env bash
# Cap this host's INBOUND bandwidth so a model download stops starving the LAN.
# Usage: throttle.sh on <mbit> [iface] | throttle.sh off [iface] | throttle.sh status [iface]
#
# WHY ingress policing and not `tc` egress shaping: the traffic we need to slow
# is INBOUND (downloads). Egress qdiscs shape what we SEND, which is nearly
# nothing here. The ingress qdisc + police action drops/limits arriving packets,
# and TCP congestion control then backs the senders off.
#
# WHY not a client-side setting: huggingface_hub 2.x (Xet) exposes no rate
# limit -- only HF_XET_HIGH_PERFORMANCE on/off -- and opens ~180 parallel
# connections. The cap has to be at the network layer.
set -uo pipefail

ACTION="${1:?need action: on, off or status}"

_default_iface() { ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1; }

case "$ACTION" in
  on)
    MBIT="${2:?need a rate in mbit}"
    IFACE="${3:-$(_default_iface)}"
    BURST="$(( MBIT * 1024 / 8 ))kb"      # ~1s of burst
    sudo -n tc qdisc del dev "$IFACE" handle ffff: ingress 2>/dev/null
    sudo -n tc qdisc add dev "$IFACE" handle ffff: ingress
    sudo -n tc filter add dev "$IFACE" parent ffff: protocol ip prio 1 u32 \
        match u32 0 0 police rate "${MBIT}mbit" burst "$BURST" drop flowid :1
    echo "throttle ON: $IFACE inbound capped at ${MBIT} Mbit/s (burst $BURST)"
    ;;
  off)
    IFACE="${2:-$(_default_iface)}"
    sudo -n tc qdisc del dev "$IFACE" handle ffff: ingress 2>/dev/null \
      && echo "throttle OFF: $IFACE ingress cap removed" \
      || echo "throttle OFF: no ingress qdisc on $IFACE (nothing to remove)"
    ;;
  status)
    IFACE="${2:-$(_default_iface)}"
    echo "iface: $IFACE"
    if sudo -n tc qdisc show dev "$IFACE" ingress 2>/dev/null | grep -q ingress; then
      echo "  ingress qdisc: PRESENT"
      sudo -n tc -s filter show dev "$IFACE" parent ffff: 2>/dev/null | head -8
    else
      echo "  ingress qdisc: none (unthrottled)"
    fi
    ;;
  *) echo "usage: throttle.sh {on <mbit>|off|status} [iface]" >&2; exit 2 ;;
esac
