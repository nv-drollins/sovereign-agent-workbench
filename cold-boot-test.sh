#!/usr/bin/env bash
# COLD BOOT TEST — reboot every node and prove `demo.sh recover` brings the
# whole demo back with ONE command and no hand-holding.
#
#   cold-boot-test.sh [--dry-run]
#
# This is the test that matters before an event: a venue power cut is the
# most likely failure, and a recovery path that has never been exercised is
# not a recovery path.
#
# SAFETY
#  * Wake-on-LAN is armed first and MACs recorded, so a node that does not
#    return can be woken remotely instead of needing a physical button.
#  * The control machine is NOT rebooted (it drives the test).
#  * Every phase is timed and logged; nothing is assumed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/cluster.conf"
[ -f "$HERE/net.conf" ] && . "$HERE/net.conf"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
LOG="$HERE/cold-boot-$(date +%Y%m%d-%H%M%S).log"
BOOT_WAIT="${BOOT_WAIT:-300}"      # seconds to wait for ssh to return

ok(){   printf '  \033[32m✓\033[0m %s\n' "$*" | tee -a "$LOG"; }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$*" | tee -a "$LOG"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*" | tee -a "$LOG"; }
inf(){  printf '  • %s\n' "$*" | tee -a "$LOG"; }
hr(){   printf '\n\033[1m%s\033[0m\n' "$*" | tee -a "$LOG"; }
on(){ local h="$1"; shift; ssh -n -o BatchMode=yes -o ConnectTimeout=8 "nvidia@$h" "bash -lc $(printf '%q' "$*")"; }

ALL="$HEAD ${WORKERS:-}"
# cluster.conf only names the MODEL nodes. Service-only nodes (records repo,
# verifier, watchdog) must be rebooted too or the test silently skips them.
for extra in ${NODES:-} "${RECORDS_NODE:-}" "${VERIFY_NODE:-}" "${WATCHDOG_NODE:-}" "${RETRIEVAL_NODE:-}" "${BOOTH_NODE:-}"; do
  [ -z "$extra" ] && continue
  case " $ALL " in *" $extra "*) ;; *) ALL="$ALL $extra" ;; esac
done
ALL="$(echo $ALL)"
echo "cold boot test $(date -Iseconds)" > "$LOG"

hr "0  baseline (must be green before we knock it over)"
if ! bash "$HERE/demo.sh" check 2>&1 | tee -a "$LOG" | grep -q "✗"; then
  ok "stack healthy at start"
else
  bad "stack is NOT healthy — fix before testing recovery"; exit 1
fi

hr "1  arm wake-on-lan + record MACs"
declare -A MACS
for h in $ALL; do
  iface="$(on "$h" "ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1")"
  mac="$(on "$h" "cat /sys/class/net/$iface/address 2>/dev/null")"
  MACS[$h]="$mac"
  on "$h" "sudo -n ethtool -s $iface wol g" >/dev/null 2>&1
  w="$(on "$h" "sudo -n ethtool $iface 2>/dev/null | grep -i '^\s*Wake-on' | tail -1 | awk '{print \$NF}'")"
  [ "$w" = "g" ] && ok "${h%%.*} $iface $mac  wol=g" || warn "${h%%.*} wol=$w (may need a physical button)"
done
printf '%s\n' "${MACS[@]}" >> "$LOG"

if [ "$DRY" = "1" ]; then
  hr "dry run — stopping here"
  inf "would reboot: $ALL"
  inf "wake command if a node sleeps: wakeonlan <mac>   (or etherwake)"
  exit 0
fi

hr "2  reboot every node"
T0=$(date +%s)
for h in $ALL; do
  on "$h" "sudo -n systemctl reboot" >/dev/null 2>&1 &
done
wait
inf "reboot issued to all nodes at $(date +%T)"
sleep 20

hr "3  wait for nodes to return (up to ${BOOT_WAIT}s each)"
DOWN=""
for h in $ALL; do
  back=0
  for _ in $(seq 1 $((BOOT_WAIT/5))); do
    if ssh -n -o BatchMode=yes -o ConnectTimeout=4 "nvidia@$h" true 2>/dev/null; then back=1; break; fi
    sleep 5
  done
  if [ "$back" = "1" ]; then
    ok "${h%%.*} back after $(( $(date +%s) - T0 ))s"
  else
    bad "${h%%.*} did NOT return — try: wakeonlan ${MACS[$h]}"
    DOWN="$DOWN $h"
  fi
done
[ -n "$DOWN" ] && { bad "nodes still down:$DOWN — cannot continue"; exit 1; }

hr "4  confirm the expected post-reboot damage"
# These SHOULD be broken. If they are not, the test is not exercising anything.
dmg=0
on "$HEAD" "ping -c1 -W2 ${FABRIC_PROBE%% *} >/dev/null 2>&1" \
  && warn "fabric still routed (unexpected — routes may have been persisted)" \
  || { inf "fabric routes gone (expected)"; dmg=$((dmg+1)); }
c=$(on "$HEAD" "curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:${PORT:-8000}/v1/models" 2>/dev/null)
[ "$c" = "200" ] && warn "model still serving (containers auto-restarted)" \
  || { inf "model endpoint down (expected)"; dmg=$((dmg+1)); }
inf "$dmg of 2 expected failures present"

hr "5  THE TEST: one command recovery"
R0=$(date +%s)
bash "$HERE/demo.sh" recover 2>&1 | tee -a "$LOG" | tail -30
R1=$(date +%s)
inf "recover took $(( (R1-R0)/60 ))m $(( (R1-R0)%60 ))s"

hr "6  verdict"
if bash "$HERE/demo.sh" check 2>&1 | tee -a "$LOG" | grep -q "✗"; then
  bad "stack NOT fully recovered — see above"
  RC=1
else
  ok "every check green"
  RC=0
fi

hr "7  end-to-end proof (what a visitor would actually do)"
if on "$BOOTH_NODE" "~/booth/.venv/bin/python ~/booth/check-booth.py 127.0.0.1:8500" 2>&1 | tee -a "$LOG" | grep -q "ALL CHECKS PASSED"; then
  ok "document fetched, agent answered, containment proven"
else
  bad "end-to-end run failed after recovery"; RC=1
fi

hr "result"
inf "total elapsed: $(( ($(date +%s)-T0)/60 ))m"
inf "log: $LOG"
[ "$RC" = "0" ] && ok "COLD BOOT RECOVERY VERIFIED" || bad "RECOVERY INCOMPLETE"
exit $RC
