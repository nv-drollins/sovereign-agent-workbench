#!/usr/bin/env bash
# Sovereign Agent Workbench — show-floor control.
#
#   demo.sh start | stop | restart | status | check | recover | logs
#
# ONE command per thing an operator needs during an event. Every verb is
# idempotent and safe to repeat.
#
# POST-POWER-CUT: run `demo.sh recover`. Three things never survive a reboot
# and ALL of them fail silently:
#   * CX7 static routes + iptables FORWARD (Docker resets the policy to DROP)
#   * the sandbox->model DNAT rule (Docker flushes the nat table)
#   * the Hermes sandbox, which returns in `Error` phase and never self-heals
#
# Topology comes from cluster.conf + net.conf — no addresses are baked in here.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/cluster.conf" ] || { echo "FAIL: cluster.conf missing (copy the .example)" >&2; exit 1; }
. "$HERE/cluster.conf"
[ -f "$HERE/net.conf" ] && . "$HERE/net.conf"

RETRIEVAL_NODE="${RETRIEVAL_NODE:-$HEAD}"
VERIFY_NODE="${VERIFY_NODE:-$HEAD}"
RECORDS_NODE="${RECORDS_NODE:-$VERIFY_NODE}"
BOOTH_NODE="${BOOTH_NODE:-$HEAD}"
WATCHDOG_NODE="${WATCHDOG_NODE:-$VERIFY_NODE}"
MODEL_FABRIC_IP="${MODEL_FABRIC_IP:-}"
SBX="${SBX:-sovereign-agent}"
TOPOLOGY="${BOOTH_TOPOLOGY:-2 Sparks (TP=2)}"

# ssh -n: without it, an ssh inside a read-loop swallows the loop's stdin and
# later iterations silently never run.
on(){ local h="$1"; shift; ssh -n -o BatchMode=yes -o ConnectTimeout=8 "nvidia@$h" "bash -lc $(printf '%q' "$*")"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
inf(){  printf '  • %s\n' "$*"; }
hr(){   printf '\n\033[1m%s\033[0m\n' "$*"; }

# openshell COLOURS the phase, so the field is really $'\e[32mReady\e[39m'.
# Also never use awk '$NF' here: the local shell expands $NF under `set -u`
# before awk sees it ("NF: unbound variable").
_phase(){ on "$BOOTH_NODE" "openshell sandbox list 2>/dev/null | grep '^$SBX '" 2>/dev/null \
          | sed 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | rev | cut -d' ' -f1 | rev | tr -d '[:space:]'; }
_http(){ on "$1" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 $2" 2>/dev/null; }

start_services(){
  on "$RETRIEVAL_NODE" "cd ~/rag && fuser -k 8700/tcp 2>/dev/null; sleep 1; \
    RAG_DOCS=\$HOME/rag/documents nohup python3 retrieval.py > /tmp/rag.log 2>&1 & disown" >/dev/null 2>&1
  on "$VERIFY_NODE" "cd ~/rag && fuser -k 8800/tcp 2>/dev/null; sleep 1; \
    nohup python3 verifier.py > /tmp/verify.log 2>&1 & disown" >/dev/null 2>&1
  on "$RECORDS_NODE" "cd ~/rag && fuser -k 8900/tcp 2>/dev/null; sleep 1; \
    DOCSVC_DIR=\$HOME/rag/documents nohup python3 docservice.py > /tmp/docsvc.log 2>&1 & disown" >/dev/null 2>&1
  # A backgrounded `&` over ssh dies with the connection, and `setsid nohup`
  # was not enough either. A systemd USER UNIT is the only form that reliably
  # survives ssh disconnect AND a reboot (with linger enabled).
  on "$WATCHDOG_NODE" "mkdir -p ~/.config/environment.d && \
    printf 'MODEL_HEAD=%s\nBOOTH_NODE=%s\nRETRIEVAL_NODE=%s\nMODEL_FABRIC_IP=%s\n' \
      '$HEAD' '$BOOTH_NODE' '$RETRIEVAL_NODE' '${MODEL_FABRIC_IP:-}' \
      > ~/.config/environment.d/booth.conf; \
    systemctl --user daemon-reload" >/dev/null 2>&1
  on "$WATCHDOG_NODE" "systemctl --user restart booth-watchdog.service 2>/dev/null \
    || { pkill -f 'python3 watchdog.py' 2>/dev/null; true; }" >/dev/null 2>&1
  # The sandbox's inference endpoint is fixed at ONBOARD time and cannot be
  # changed later, so DNAT it to wherever the model actually lives now.
  # Re-applied on every start because Docker flushes the nat table.
  [ -n "$MODEL_FABRIC_IP" ] && on "$BOOTH_NODE" "bash ~/booth/model-route.sh on $MODEL_FABRIC_IP" >/dev/null 2>&1
  on "$BOOTH_NODE" "cd ~/booth && fuser -k 8500/tcp 2>/dev/null; sleep 1; \
    BOOTH_TOPOLOGY='$TOPOLOGY' BOOTH_RECORDS_HOST='${RECORDS_FABRIC_IP:-}' \
    BOOTH_NODES='$(echo ${NODES:-} | tr " " ",")' BOOTH_SELF_NODE='${BOOTH_NODE%%.*}' \
    nohup ~/booth/.venv/bin/python booth_app.py > /tmp/booth.log 2>&1 & disown" >/dev/null 2>&1
}

case "${1:-status}" in

start)
  hr "1/3  fabric"
  bash "$HERE/net-setup.sh" apply 2>&1 | grep -E "✓|✗" | sed 's/^/  /' || warn "fabric apply reported problems"
  hr "2/3  model cluster (TP=${TP:-?})"
  bash "$HERE/cluster.sh" start 2>&1 | grep -E "parsers|✓|✗|HEAD|WORKER" | sed 's/^/  /'
  inf "model loads in ~8 min; services start now and connect when it is ready"
  hr "3/3  services"
  start_services; sleep 8
  ok "retrieval, verifier, records repo, watchdog, booth app"
  echo; bash "$0" check
  ;;

stop)
  hr "stopping"
  bash "$HERE/cluster.sh" stop 2>&1 | tail -3 | sed 's/^/  /'
  for n in "$RETRIEVAL_NODE:8700" "$VERIFY_NODE:8800" "$RECORDS_NODE:8900" "$BOOTH_NODE:8500"; do
    on "${n%%:*}" "fuser -k ${n##*:}/tcp 2>/dev/null" >/dev/null 2>&1
  done
  on "$WATCHDOG_NODE" "systemctl --user stop booth-watchdog.service 2>/dev/null; \
    pkill -f 'python3 watchdog.py' 2>/dev/null" >/dev/null 2>&1
  ok "services stopped (model weights stay cached on disk)"
  ;;

restart) bash "$0" stop; sleep 4; bash "$0" start ;;

recover)
  hr "post-reboot recovery"
  inf "re-applying fabric routes + FORWARD rules"
  bash "$HERE/net-setup.sh" apply 2>&1 | grep -E "✓|✗" | sed 's/^/  /'

  # ORDER MATTERS: setup-agent.sh refuses to onboard without a live model
  # endpoint ("no model serving"). Starting the cluster first and WAITING is
  # what makes recovery work unattended -- an earlier version destroyed the
  # sandbox and then failed to rebuild it, leaving the demo worse than before.
  # Do NOT blindly restart: if the model is already serving, tearing it down
  # costs ~8 minutes for nothing. Only start what is actually down.
  if [ "$(_http "$HEAD" "http://127.0.0.1:${PORT:-8000}/v1/models")" = "200" ]; then
    ok "model already serving — leaving it alone"
    inf "restarting the support services only"
    start_services; sleep 8
  else
    inf "model is down — starting cluster + services"
    bash "$0" start >/dev/null 2>&1
    inf "waiting for the model endpoint (up to 12 min)"
    for i in $(seq 1 72); do
      [ "$(_http "$HEAD" "http://127.0.0.1:${PORT:-8000}/v1/models")" = "200" ] && break
      sleep 10
    done
  fi
  if [ "$(_http "$HEAD" "http://127.0.0.1:${PORT:-8000}/v1/models")" != "200" ]; then
    bad "model did not come up — fix that first, then re-run: $0 recover"
    exit 1
  fi
  ok "model endpoint live"

  ph="$(_phase)"
  if [ "$ph" != "Ready" ]; then
    warn "sandbox phase=${ph:-missing} — rebuilding (~2 min)"
    on "$BOOTH_NODE" "nemoclaw $SBX destroy --yes" >/dev/null 2>&1
    AGENT_NODE="$BOOTH_NODE" MODEL_HOST="$HEAD" bash "$HERE/setup-agent.sh" "$SBX" 2>&1 | tail -5 | sed 's/^/  /'
    # the records policy and the lean booth profile both live INSIDE the
    # sandbox, so a rebuild destroys them -- restore both or the first run
    # fails with "Profile 'booth' does not exist" / 403 on the records read.
    if [ -n "${RECORDS_FABRIC_IP:-}" ]; then
      # The committed template carries a placeholder, never a real address.
      on "$BOOTH_NODE" "sed 's/__RECORDS_HOST__/$RECORDS_FABRIC_IP/' \
           \$HOME/booth/records-policy.yaml > /tmp/records-policy.rendered.yaml && \
         nemoclaw $SBX policy-add --from-file /tmp/records-policy.rendered.yaml \
           --trusted-private-host $RECORDS_FABRIC_IP --yes" >/dev/null 2>&1 \
        && ok "records policy re-applied"
    fi
    if [ -f "$HERE/make-booth-profile.py" ]; then
      B64="$(base64 -w0 "$HERE/make-booth-profile.py")"
      on "$BOOTH_NODE" "timeout -k 5 120 openshell sandbox exec --name $SBX --no-tty --timeout 90 \
         --env BOOTH_PROFILE=${BOOTH_PROFILE:-booth} --env HERMES_TARGET_MODEL=${SERVED_NAME:-} \
         -- python3 -c 'import base64,sys;exec(base64.b64decode(sys.argv[1]).decode())' $B64" >/dev/null 2>&1 \
        && ok "booth agent profile re-created"
    fi
  else
    ok "sandbox Ready"
  fi

  echo; bash "$0" check
  ;;

check|status)
  hr "SOVEREIGN AGENT WORKBENCH"
  c="$(_http "$HEAD" "http://127.0.0.1:${PORT:-8000}/v1/models")"
  [ "$c" = "200" ] && ok "model endpoint   ($HEAD, TP=${TP:-?})" \
                   || bad "model endpoint HTTP ${c:-000} — loading? see: $0 logs"
  for n in "$HEAD" ${WORKERS:-}; do
    m=$(on "$n" "free -g | awk '/Mem/{print \$3}'" 2>/dev/null); inf "  ${n%%.*} holding ${m:-?}G"
  done
  c="$(_http "$RETRIEVAL_NODE" http://127.0.0.1:8700/health)"
  [ "$c" = "200" ] && ok "retrieval        (${RETRIEVAL_NODE%%.*}:8700)" || bad "retrieval HTTP ${c:-000}"
  c="$(_http "$RECORDS_NODE" http://127.0.0.1:8900/health)"
  [ "$c" = "200" ] && ok "records repo     (${RECORDS_NODE%%.*}:8900)" || bad "records repo HTTP ${c:-000}"
  c="$(_http "$VERIFY_NODE" http://127.0.0.1:8800/health)"
  [ "$c" = "200" ] && ok "verifier         (${VERIFY_NODE%%.*}:8800)" || bad "verifier HTTP ${c:-000}"
  c="$(_http "$BOOTH_NODE" http://127.0.0.1:8500/)"
  [ "$c" = "200" ] && ok "booth UI         http://$BOOTH_NODE:8500" || bad "booth UI HTTP ${c:-000}"
  ph="$(_phase)"
  [ "$ph" = "Ready" ] && ok "agent sandbox    ($SBX: Ready)" \
    || bad "agent sandbox phase=${ph:-missing} -> $0 recover"
  if [ -n "$MODEL_FABRIC_IP" ]; then
    c="$(_http "$BOOTH_NODE" http://172.18.0.1:8000/v1/models)"
    [ "$c" = "200" ] && ok "sandbox->model   (policy route)" \
      || bad "sandbox->model HTTP ${c:-000} -> on ${BOOTH_NODE%%.*}: bash ~/booth/model-route.sh on $MODEL_FABRIC_IP"
  fi
  # NOTE: `pgrep -fc watchdog.py` over ssh MATCHES ITS OWN command line and
  # always returns >=1. The bracket trick excludes the matcher itself.
  w=$(on "$WATCHDOG_NODE" "systemctl --user is-active booth-watchdog.service >/dev/null 2>&1 \
      && echo 1 || ps -eo cmd | grep -c '[w]atchdog[.]py'" 2>/dev/null)
  [ "${w:-0}" -ge 1 ] 2>/dev/null && ok "watchdog         (${WATCHDOG_NODE%%.*})" || warn "watchdog not running -> $0 start"
  ;;

logs)
  hr "model (head)"; bash "$HERE/cluster.sh" logs "${2:-25}" 2>&1 | tail -25
  hr "booth app";    on "$BOOTH_NODE" "tail -n ${2:-15} /tmp/booth.log" 2>&1 | tail -15
  hr "watchdog";     on "$WATCHDOG_NODE" "tail -n ${2:-12} /tmp/watchdog.log" 2>&1 | tail -12
  ;;

*) echo "usage: $0 {start|stop|restart|status|check|recover|logs [n]}" >&2; exit 2 ;;
esac
