#!/usr/bin/env bash
# Persist Wake-on-LAN across reboots on every node.
#
#   persist-wol.sh [config]
#
# WHY: `ethtool -s <iface> wol g` does NOT survive a reboot -- it reverts to
# `d` (disabled). Verified: armed before a cold-boot test, back to `d`
# afterwards. A WoL safety net that silently disarms itself is worse than
# none, because you plan around having it.
#
# Installs a systemd unit so the setting is re-applied on every boot, and
# records each node's MAC so a sleeping node can be woken:
#     wakeonlan <mac>      (or: etherwake -i <iface> <mac>)
#
# CAVEAT worth stating plainly: WoL wakes a machine from SLEEP or from a
# soft power-off ONLY if the BIOS keeps the NIC powered in S5. It cannot
# help after a real power cut -- that needs a physical button.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-$HERE/net.conf}"
[ -f "$CONF" ] || { echo "FAIL: $CONF not found" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
: "${NODES:?set NODES}"

ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
inf(){ printf '  • %s\n' "$*"; }

MACFILE="$HERE/node-macs.txt"
: > "$MACFILE"

for h in $NODES; do
  iface="$(ssh -n -o BatchMode=yes "nvidia@$h" "ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1")"
  mac="$(ssh -n -o BatchMode=yes "nvidia@$h" "cat /sys/class/net/$iface/address 2>/dev/null")"
  [ -z "$iface" ] && { bad "${h%%.*}: no default interface"; continue; }

  ssh -n -o BatchMode=yes "nvidia@$h" "bash -lc $(printf '%q' "
    sudo -n tee /etc/systemd/system/wol-$iface.service >/dev/null <<UNIT
[Unit]
Description=Arm Wake-on-LAN on $iface
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s $iface wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    sudo -n systemctl daemon-reload
    sudo -n systemctl enable --now wol-$iface.service
  ")" >/dev/null 2>&1

  w="$(ssh -n -o BatchMode=yes "nvidia@$h" "sudo -n ethtool $iface 2>/dev/null | grep -i '^\s*Wake-on' | tail -1 | awk '{print \$NF}'")"
  en="$(ssh -n -o BatchMode=yes "nvidia@$h" "systemctl is-enabled wol-$iface.service 2>/dev/null")"
  printf '%s %s %s\n' "${h%%.*}" "$iface" "$mac" >> "$MACFILE"
  if [ "$w" = "g" ] && [ "$en" = "enabled" ]; then
    ok "${h%%.*} $iface $mac  wol=g, unit enabled (survives reboot)"
  else
    bad "${h%%.*} wol=$w unit=$en"
  fi
done

echo
inf "MACs recorded in $MACFILE"
inf "wake a sleeping node:  wakeonlan \$(awk '/<node>/{print \$3}' $MACFILE)"
inf "WoL cannot recover from a full power cut — that needs the physical button"
