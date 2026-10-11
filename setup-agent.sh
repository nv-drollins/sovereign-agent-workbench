#!/usr/bin/env bash
# Stand up a Hermes agent sandbox on the node that serves the model, and wire
# a SCOPED egress policy so the agent can reach ONLY the inference endpoint.
#
#   setup-agent.sh [sandbox-name]
#
# Idempotent: re-run after a reboot (sandboxes come back in `Error` phase and
# never self-heal) or after the vLLM container is recreated (its bridge IP
# moves, invalidating a policy pinned to the old address).
set -uo pipefail

NODE="${AGENT_NODE:?set AGENT_NODE to the host that serves the model}"
SBX="${1:-${AGENT_SANDBOX:-sovereign-agent}}"   # <= 19 chars, nemoclaw limit
PORT="${MODEL_PORT:-8000}"

# nemoclaw/openshell resolve only in a LOGIN shell (nvm PATH via ~/.profile),
# so every remote command is wrapped in `bash -lc`.
on() { ssh -o BatchMode=yes -o ConnectTimeout=10 "nvidia@$NODE" "bash -lc $(printf '%q' "$*")"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
inf(){ printf '  • %s\n' "$*"; }

[ ${#SBX} -le 19 ] || { echo "FAIL: sandbox name '$SBX' exceeds nemoclaw's 19-char limit" >&2; exit 1; }

echo "=== preflight ==="
on "command -v nemoclaw >/dev/null" && ok "nemoclaw CLI present" || { bad "nemoclaw missing on $NODE"; exit 1; }

# The model may be served on ANOTHER node (e.g. a TP=2 head). Check the
# sandbox node first, then MODEL_HOST, so onboarding does not fail with
# "no model serving" simply because it looked in the wrong place.
MODEL_HOST="${MODEL_HOST:-$NODE}"
SERVED="$(on "curl -s --max-time 5 http://127.0.0.1:$PORT/v1/models | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"data\"][0][\"id\"])' 2>/dev/null")"
if [ -z "$SERVED" ] && [ "$MODEL_HOST" != "$NODE" ]; then
  SERVED="$(ssh -n -o BatchMode=yes "nvidia@$MODEL_HOST" "bash -lc $(printf '%q' "curl -s --max-time 5 http://127.0.0.1:$PORT/v1/models | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"data\"][0][\"id\"])' 2>/dev/null")" 2>/dev/null)"
  [ -n "$SERVED" ] && inf "model is served on $MODEL_HOST (not $NODE)"
fi
[ -n "$SERVED" ] || { bad "no model serving on $NODE:$PORT or $MODEL_HOST:$PORT"; exit 1; }
ok "model serving: $SERVED"

# The sandbox reaches the host over the openshell bridge gateway. vLLM runs with
# --network host, so the HOST's address on that bridge is the right target.
BRIDGE_IP="$(on "ip -4 -o addr show docker0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1")"
OS_IP="$(on "ip -4 -o addr show 2>/dev/null | awk '/172\.18\./{print \$4}' | cut -d/ -f1 | head -1")"
HOST_IP="${OS_IP:-$BRIDGE_IP}"
[ -n "$HOST_IP" ] || { bad "could not resolve a bridge IP on $NODE"; exit 1; }
ok "host bridge ip for sandbox egress: $HOST_IP"

echo "=== sandbox ==="
if on "openshell sandbox list 2>/dev/null | grep -q '^$SBX '"; then
  PHASE="$(on "openshell sandbox list 2>/dev/null | grep '^$SBX '" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | rev | cut -d' ' -f1 | rev | tr -d '[:space:]')"
  inf "sandbox '$SBX' exists (phase: $PHASE)"
  if [ "$PHASE" = "Error" ]; then
    inf "Error phase never self-heals - destroying and recreating"
    on "nemoclaw '$SBX' destroy --yes" >/dev/null 2>&1
    NEED_ONBOARD=1
  fi
else
  NEED_ONBOARD=1
fi

if [ "${NEED_ONBOARD:-0}" = "1" ]; then
  inf "onboarding Hermes sandbox (~60s)..."
  # THREE env vars are mandatory and each fails confusingly when missing:
  #  * NEMOCLAW_TRUSTED_PRIVATE_INFERENCE_HOSTS / _HOSTS -- without them the
  #    SSRF preflight refuses private addresses and aborts with
  #    "SSRF preflight: no HTTP response", which reads as unreachability even
  #    though the endpoint answers 200 from the host AND from a container.
  #  * NEMOCLAW_CONTEXT_WINDOW -- hard floor of 64000; a model served with a
  #    smaller --max-model-len aborts onboarding at step 6/8.
  on "export NEMOCLAW_AGENT=hermes NEMOCLAW_PROVIDER=custom \
        NEMOCLAW_ENDPOINT_URL=http://$HOST_IP:$PORT/v1 \
        NEMOCLAW_MODEL='$SERVED' COMPATIBLE_API_KEY=dummy \
        NEMOCLAW_YES=1 NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
        NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_PREFERRED_API=openai-completions \
        NEMOCLAW_TRUSTED_PRIVATE_INFERENCE_HOSTS=$HOST_IP \
        NEMOCLAW_TRUSTED_PRIVATE_HOSTS=$HOST_IP \
        NEMOCLAW_CONTEXT_WINDOW=${CONTEXT_WINDOW:-64000}; \
      nemoclaw onboard --non-interactive --yes --yes-i-accept-third-party-software --fresh \
        --name '$SBX' --no-gpu --no-sandbox-gpu --agent hermes" 2>&1 | tail -5
fi

PHASE="$(on "openshell sandbox list 2>/dev/null | grep '^$SBX '" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | rev | cut -d' ' -f1 | rev | tr -d '[:space:]')"
[ "$PHASE" = "Ready" ] && ok "sandbox Ready" || { bad "sandbox phase: ${PHASE:-missing}"; }

echo "=== egress policy (deny-by-default; allow ONLY inference) ==="
POLICY=/tmp/sovereign-policy.yaml
on "cat > $POLICY <<'YAML'
preset:
  name: sovereign-inference
  description: \"Agent may reach the local inference endpoint and nothing else\"

network_policies:
  sovereign-inference:
    name: sovereign-inference
    endpoints:
      - host: $HOST_IP
        port: $PORT
        protocol: rest
        enforcement: enforce
        rules:
          - allow: { method: GET,  path: \"/v1/models\" }
          - allow: { method: POST, path: \"/v1/chat/completions\" }
    binaries:
      - { path: /usr/bin/curl }
      - { path: /usr/bin/python3* }
      - { path: /opt/hermes/.venv/bin/python3* }
YAML
echo wrote $POLICY"
# NOTE: user presets may NOT contain allowed_ips (built-ins may) -> use
# --trusted-private-host for a LAN/bridge address.
on "nemoclaw '$SBX' policy-add --from-file $POLICY --trusted-private-host $HOST_IP --yes" 2>&1 | tail -3

echo "=== verify end-to-end (the only proof that matters) ==="
# External `timeout` + retry: `openshell sandbox exec` can wedge past its own --timeout.
for attempt in 1 2 3; do
  RESP="$(on "timeout -k 5 60 openshell sandbox exec --name '$SBX' --no-tty --timeout 30 -- curl -s --max-time 20 http://$HOST_IP:$PORT/v1/models" 2>/dev/null)"
  case "$RESP" in
    *'"object"'*) ok "sandbox CAN reach the model (GET /v1/models 200)"; break ;;
    *policy_denied*) bad "policy_denied - preset did not apply"; break ;;
    *) inf "attempt $attempt: no/!=json response, retrying"; sleep 5 ;;
  esac
done

cat <<EOF

  sandbox : $SBX   on $NODE
  model   : $SERVED  via http://$HOST_IP:$PORT/v1
  policy  : sovereign-inference (deny-by-default, 2 allowed routes)

  demo beats:
    deny   : nemoclaw $SBX policy-remove sovereign-inference --yes
    approve: nemoclaw $SBX policy-add --from-file $POLICY --trusted-private-host $HOST_IP --yes
EOF
