#!/usr/bin/env bash
# Re-apply the cluster fabric configuration. MUST run after every boot.
#
#   net-setup.sh apply|check [config]
#
# WHY THIS EXISTS
# Two things do NOT survive a power cycle, and both fail SILENTLY in ways that
# look like application bugs:
#
#  1. Static routes across the CX7 mesh. The fabric is six POINT-TO-POINT
#     links, not a shared segment -- each node can only reach its two direct
#     neighbours without routes. Symptom: multi-node vLLM hangs at startup.
#
#  2. iptables FORWARD policy. Docker sets it to DROP on every start, which
#     silently blocks all transit traffic between fabric subnets even though
#     ip_forward=1 and the routes are present. This cost hours to find the
#     first time: everything looks configured and nothing works.
#
# Safe to re-run. Reads the roster from net.conf so no site addresses are
# baked into this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${2:-$HERE/net.conf}"

ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
inf(){ printf '  • %s\n' "$*"; }

[ -f "$CONF" ] || { echo "FAIL: $CONF not found (copy net.conf.example)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
: "${NODES:?set NODES in net.conf}"
: "${FABRIC_SUBNETS:?set FABRIC_SUBNETS in net.conf}"

on(){ local h="$1"; shift; ssh -o BatchMode=yes -o ConnectTimeout=8 "nvidia@$h" "bash -lc $(printf '%q' "$*")"; }

apply_node(){
  local host="$1"
  # 1. allow transit between fabric subnets (Docker's FORWARD DROP blocks it)
  for sn in $FABRIC_SUBNETS; do
    on "$host" "sudo -n iptables -C FORWARD -s ${sn}.0/24 -d 192.168.0.0/16 -j ACCEPT 2>/dev/null \
      || sudo -n iptables -I FORWARD 1 -s ${sn}.0/24 -d 192.168.0.0/16 -j ACCEPT" >/dev/null 2>&1
  done
  on "$host" "sudo -n sysctl -w net.ipv4.ip_forward=1" >/dev/null 2>&1

  # 2. static routes to the subnets this node is NOT directly on
  local var="ROUTES_${host%%.*}"
  var="${var//-/_}"
  local routes="${!var:-}"
  [ -z "$routes" ] && { inf "$host: no routes defined"; return 0; }
  local n=0
  # each entry is "dest_cidr via gateway".
  # NOTE: `ssh` reads stdin and will SWALLOW the remaining loop input, so the
  # second route silently never runs. `ssh -n` (or </dev/null) is required for
  # any ssh inside a read-loop. Symptom: "1 route applied" when 2 were defined.
  while read -r dest gw; do
    [ -z "${dest:-}" ] && continue
    [ -z "${gw:-}" ] && continue
    ssh -n -o BatchMode=yes -o ConnectTimeout=8 "nvidia@$host" \
      "bash -lc $(printf '%q' "ip route show $dest | grep -q . || sudo -n ip route add $dest via $gw")" \
      >/dev/null 2>&1
    n=$((n+1))
  done < <(printf '%s\n' "$routes")
  ok "$host: $n route(s) + FORWARD rules applied"
}

check_all(){
  local fail=0
  for h in $NODES; do
    local p="${h%%.*}"
    local miss=""
    for t in $FABRIC_PROBE; do
      on "$h" "ping -c1 -W2 $t >/dev/null 2>&1" || miss="$miss $t"
    done
    if [ -z "$miss" ]; then ok "$p reaches all fabric probes"
    else bad "$p cannot reach:$miss"; fail=1; fi
  done
  return $fail
}

case "${1:-check}" in
  apply)
    echo "=== applying fabric config ==="
    for h in $NODES; do apply_node "$h"; done
    echo "=== verifying ==="
    check_all || { echo "  routes applied but probes still failing" >&2; exit 1; }
    ;;
  check) echo "=== fabric check ==="; check_all ;;
  *) echo "usage: $0 {apply|check} [config]" >&2; exit 2 ;;
esac
