#!/usr/bin/env bash
# Sovereign Agent Workbench — installer.
#
#   install.sh              online install (pulls what is missing)
#   install.sh --offline    install from a USB bundle (no internet at all)
#   install.sh --check      report readiness, change nothing
#
# Designed for a show floor: venue internet is usually slow or absent, so the
# offline path is first-class, not an afterthought. Every step is idempotent --
# re-running after a partial failure continues rather than starting over.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${BUNDLE_DIR:-$HERE/bundle}"
MODE="online"
case "${1:-}" in
  --offline) MODE="offline" ;;
  --check)   MODE="check" ;;
  "")        : ;;
  *) echo "usage: $0 [--offline|--check]" >&2; exit 2 ;;
esac

ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
inf(){  printf '  • %s\n' "$*"; }
hr(){   printf '\n\033[1m%s\033[0m\n' "$*"; }

FAIL=0
need(){ command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- config ---
[ -f "$HERE/cluster.conf" ] && . "$HERE/cluster.conf"
[ -f "$HERE/net.conf" ]     && . "$HERE/net.conf"
NODES="${NODES:-}"
if [ -z "$NODES" ]; then
  bad "no node roster. Copy net.conf.example -> net.conf and set NODES."
  exit 1
fi

on(){ local h="$1"; shift; ssh -n -o BatchMode=yes -o ConnectTimeout=8 "nvidia@$h" "bash -lc $(printf '%q' "$*")"; }

# ------------------------------------------------------------ 1. control ---
hr "1/6  control machine"
for c in ssh scp git python3 tar; do
  need "$c" && ok "$c" || { bad "$c missing — install it first"; FAIL=1; }
done
python3 -c 'import sys; sys.exit(0 if sys.version_info>=(3,10) else 1)' 2>/dev/null \
  && ok "python $(python3 -V 2>&1 | cut -d' ' -f2)" || { bad "python >= 3.10 required"; FAIL=1; }

# ------------------------------------------------------------- 2. nodes ----
hr "2/6  nodes reachable"
REACH=""
for h in $NODES; do
  if on "$h" true 2>/dev/null; then ok "$h"; REACH="$REACH $h"
  else bad "$h unreachable over ssh (key auth?)"; FAIL=1; fi
done
[ -z "$REACH" ] && { bad "no reachable nodes"; exit 1; }
# strip the leading space the accumulator leaves, or "${REACH%% *}" yields ""
REACH="$(echo $REACH)"

# ------------------------------------------------- 3. per-node packages ----
hr "3/6  node prerequisites"
for h in $REACH; do
  miss=""
  for c in docker python3 curl tar; do
    on "$h" "command -v $c >/dev/null" || miss="$miss $c"
  done
  on "$h" "id -nG | tr ' ' '\\n' | grep -qx docker" || miss="$miss docker-group"
  if [ -z "$miss" ]; then ok "${h%%.*}: docker, python3, curl, tar"
  else
    bad "${h%%.*}: missing$miss"
    if [ "$MODE" = "check" ]; then FAIL=1; continue; fi
    case "$miss" in
      *docker-group*) warn "run on ${h%%.*}: sudo usermod -aG docker \$USER && re-login" ;;
    esac
    FAIL=1
  fi
done

# ------------------------------------------------------- 4. python deps ----
hr "4/6  booth app dependencies"
APP_NODE="${BOOTH_NODE:-${REACH%% *}}"
if [ "$MODE" = "check" ]; then
  on "$APP_NODE" "[ -x ~/booth/.venv/bin/python ] && ~/booth/.venv/bin/python -c 'import fastapi,uvicorn,websockets' 2>/dev/null" \
    && ok "venv present with fastapi/uvicorn/websockets" || { bad "booth venv incomplete"; FAIL=1; }
else
  on "$APP_NODE" "mkdir -p ~/booth && [ -x ~/booth/.venv/bin/python ] || python3 -m venv ~/booth/.venv" >/dev/null 2>&1
  if [ "$MODE" = "offline" ]; then
    if [ -d "$BUNDLE/wheels" ]; then
      scp -q -r "$BUNDLE/wheels" "nvidia@$APP_NODE:~/booth/" 2>/dev/null
      on "$APP_NODE" "~/booth/.venv/bin/pip install --quiet --no-index --find-links ~/booth/wheels \
         fastapi uvicorn[standard] websockets" >/dev/null 2>&1 \
        && ok "installed from bundled wheels" || { bad "offline pip install failed"; FAIL=1; }
    else
      bad "no $BUNDLE/wheels — build the bundle first (make-bundle.sh)"; FAIL=1
    fi
  else
    # uvicorn WITHOUT [standard] has no websocket support: /ws returns 404 and
    # the booth UI silently shows nothing. Always install the extra.
    on "$APP_NODE" "~/booth/.venv/bin/pip install --quiet --upgrade pip && \
       ~/booth/.venv/bin/pip install --quiet fastapi 'uvicorn[standard]' websockets" >/dev/null 2>&1 \
      && ok "fastapi + uvicorn[standard] + websockets" || { bad "pip install failed"; FAIL=1; }
  fi
fi

# ------------------------------------------------------ 5. project files ---
hr "5/6  project files"
if [ "$MODE" != "check" ]; then
  # booth app + UI + documents
  on "$APP_NODE" "mkdir -p ~/booth/documents" >/dev/null 2>&1
  scp -q "$HERE/booth_app.py" "$HERE/booth.html" "nvidia@$APP_NODE:~/booth/" 2>/dev/null
  scp -q "$HERE"/documents/*.md "nvidia@$APP_NODE:~/booth/documents/" 2>/dev/null
  scp -q "$HERE/model-route.sh" "$HERE/check-booth.py" "nvidia@$APP_NODE:~/booth/" 2>/dev/null
  ok "booth app -> ${APP_NODE%%.*}"

  # records repository + verifier + watchdog
  REC_NODE="${RECORDS_NODE:-${VERIFY_NODE:-}}"
  for h in $REACH; do
    on "$h" "mkdir -p ~/rag/documents" >/dev/null 2>&1
    scp -q "$HERE/retrieval.py" "$HERE/verifier.py" "$HERE/docservice.py" \
           "$HERE/watchdog.py" "$HERE/telemetry.py" "nvidia@$h:~/rag/" 2>/dev/null
    scp -q "$HERE"/documents/*.md "nvidia@$h:~/rag/documents/" 2>/dev/null
  done
  ok "services -> all nodes"
else
  on "$APP_NODE" "[ -f ~/booth/booth_app.py ]" && ok "booth app present" || { bad "booth app missing"; FAIL=1; }
fi

# ----------------------------------------------------------- 6. weights ----
hr "6/6  model weights"
for h in $REACH; do
  sz=$(on "$h" "find ~/models-nemotron -name '*.safetensors' -exec du -Lb {} + 2>/dev/null | awk '{s+=\$1}END{printf \"%.0f\", s/1e9}'" 2>/dev/null)
  if [ "${sz:-0}" -ge 70 ] 2>/dev/null; then ok "${h%%.*}: ${sz} GB"
  else
    bad "${h%%.*}: weights missing or incomplete (${sz:-0} GB)"
    [ "$MODE" = "offline" ] && inf "copy from the USB: rsync -a \$BUNDLE/models-nemotron/ ~/models-nemotron/"
    [ "$MODE" = "online" ]  && inf "run: bash stage-model.sh nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 \$HOME/models-nemotron"
    FAIL=1
  fi
done

hr "result"
if [ "$FAIL" = "0" ]; then
  ok "ready — start with:  bash demo.sh start"
else
  bad "unresolved items above"
  [ "$MODE" = "check" ] || inf "fix them and re-run; this installer is safe to repeat"
fi
exit $FAIL
