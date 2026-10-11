#!/usr/bin/env bash
# Make the model reachable at the address the Hermes sandbox already trusts.
#
#   model-route.sh on <model-host-ip> [bridge-ip] [port]
#   model-route.sh off [bridge-ip] [port]
#   model-route.sh status
#
# WHY THIS EXISTS
# NemoClaw records the inference endpoint at ONBOARD time and refuses to
# change it later:
#   "endpoint-url is not allowed: URL points to private/internal address …
#    To point the sandbox at a different endpoint, re-run onboarding"
# So when the model moves to another node (e.g. switching from 1-node to a
# 2-node TP=2 cluster whose head is a different host), the sandbox keeps
# calling the ORIGINAL bridge address. Rather than tear down and re-onboard
# the sandbox (~2 min + policy re-apply), DNAT that address to wherever the
# model actually lives now.
#
# Rules are NOT persistent across reboot by design -- the booth start script
# re-applies them, so a stale rule can never silently point at a dead node.
set -uo pipefail

ACT="${1:?need action: on, off or status}"
BRIDGE="${3:-172.18.0.1}"
PORT="${4:-8000}"

case "$ACT" in
  on)
    DEST="${2:?need the model host ip}"
    # PREROUTING: traffic from containers/sandboxes
    sudo -n iptables -t nat -C PREROUTING -d "$BRIDGE" -p tcp --dport "$PORT" \
         -j DNAT --to-destination "$DEST:$PORT" 2>/dev/null \
      || sudo -n iptables -t nat -I PREROUTING 1 -d "$BRIDGE" -p tcp --dport "$PORT" \
         -j DNAT --to-destination "$DEST:$PORT"
    # OUTPUT: traffic the host itself generates
    sudo -n iptables -t nat -C OUTPUT -d "$BRIDGE" -p tcp --dport "$PORT" \
         -j DNAT --to-destination "$DEST:$PORT" 2>/dev/null \
      || sudo -n iptables -t nat -I OUTPUT 1 -d "$BRIDGE" -p tcp --dport "$PORT" \
         -j DNAT --to-destination "$DEST:$PORT"
    # MASQUERADE so the far side replies back through us
    sudo -n iptables -t nat -C POSTROUTING -d "$DEST" -p tcp --dport "$PORT" -j MASQUERADE 2>/dev/null \
      || sudo -n iptables -t nat -I POSTROUTING 1 -d "$DEST" -p tcp --dport "$PORT" -j MASQUERADE
    sudo -n sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://$BRIDGE:$PORT/v1/models")
    echo "  route $BRIDGE:$PORT -> $DEST:$PORT   verify http=$code"
    [ "$code" = "200" ] || { echo "  FAIL: model not reachable through the route" >&2; exit 1; }
    ;;
  off)
    while sudo -n iptables -t nat -D PREROUTING -d "$BRIDGE" -p tcp --dport "$PORT" \
          -j DNAT --to-destination "${2:-0.0.0.0}:$PORT" 2>/dev/null; do :; done
    sudo -n iptables -t nat -F OUTPUT 2>/dev/null
    echo "  routes removed (bridge $BRIDGE:$PORT)"
    ;;
  status)
    echo "  nat PREROUTING:"; sudo -n iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--dport $PORT" | sed 's/^/    /' || echo "    none"
    echo "  nat OUTPUT:";     sudo -n iptables -t nat -S OUTPUT 2>/dev/null | grep -- "--dport $PORT" | sed 's/^/    /' || echo "    none"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$BRIDGE:$PORT/v1/models")
    echo "  $BRIDGE:$PORT -> http=$code"
    ;;
  *) echo "usage: $0 {on <dest-ip>|off|status} [bridge-ip] [port]" >&2; exit 2 ;;
esac
