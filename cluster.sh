#!/usr/bin/env bash
# Bring up a multi-node vLLM cluster serving ONE large model as ONE endpoint.
#
#   cluster.sh start|stop|status|logs|test
#
# Topology comes from cluster.conf (gitignored) -- NO hardcoded IPs here.
# See cluster.conf.example.
#
# ── Why this shape ───────────────────────────────────────────────────────────
# * Nemotron-Ultra-253B has 128 attention heads and 162 layers.
#   TP=3 is IMPOSSIBLE (128 % 3 != 0). PP=3 is exact (162/3 = 54).
# * The stock `vllm/vllm-openai` image (0.31.0) does NOT ship Ray, so the
#   classic `ray start --head` + `--distributed-executor-backend ray` recipe
#   fails with `ray: command not found` (container exits 127). vLLM 0.31
#   supports native multi-node via the `mp` backend instead:
#   --nnodes N --node-rank R --master-addr <head> --master-port <p>.
#   NOTE: --data-parallel-address is for DATA parallelism (replicas), NOT for
#   splitting one model; using it gives
#   "World size (3) is larger than the number of available GPUs (1)".
# * All nodes must agree on ONE reachable address each. On a point-to-point
#   CX7 mesh that needs static routes PLUS an iptables FORWARD ACCEPT rule --
#   Docker sets FORWARD policy DROP, which silently blocks all transit traffic.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CLUSTER_CONF:-$HERE/cluster.conf}"
[ -f "$CONF" ] || { echo "FAIL: $CONF not found (copy cluster.conf.example)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${HEAD:?set HEAD in cluster.conf}"
: "${WORKERS:?set WORKERS in cluster.conf}"
: "${MODEL_DIR:?}"; : "${MODEL_ID:?}"; : "${SERVED_NAME:?}"; : "${RAY_IFACE:?}"
IMAGE="${IMAGE:-vllm/vllm-openai:latest}"
PORT="${PORT:-8000}"
RPC_PORT="${RPC_PORT:-29500}"
PP="${PP:-3}"
TP="${TP:-1}"
MAX_LEN="${MAX_LEN:-16384}"
GPU_UTIL="${GPU_UTIL:-0.90}"
CONTAINER="${CONTAINER:-vllm-node}"

read -ra WORKER_ARR <<< "$WORKERS"
NNODES=$(( 1 + ${#WORKER_ARR[@]} ))

on() { local h="$1"; shift; ssh -o BatchMode=yes -o ConnectTimeout=8 "nvidia@$h" "bash -lc $(printf '%q' "$*")"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
inf(){ printf '  • %s\n' "$*"; }

_ip_of() { on "$1" "ip -4 -o addr show $RAY_IFACE 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1"; }

start() {
  # Tool-call parsers. WITHOUT --enable-auto-tool-choice vLLM rejects
  # tool_choice:"auto" with a 400, so every agent tool turn fails even
  # though the model and the cluster are fine.
  PARSERS="${PARSERS:-}"
  if [ -z "$PARSERS" ]; then
    case "$SERVED_NAME" in
      *gpt-oss*) PARSERS="--enable-auto-tool-choice --tool-call-parser openai --reasoning-parser openai_gptoss" ;;
      *emotron*) PARSERS="--enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser nemotron_v3" ;;
      *)         PARSERS="" ;;
    esac
  fi
  [ -n "$PARSERS" ] && inf "parsers: $PARSERS"

  local hip; hip="$(_ip_of "$HEAD")"
  [ -n "$hip" ] || { echo "FAIL: no IP on $RAY_IFACE at $HEAD" >&2; exit 1; }
  inf "head: $HEAD ($hip)  nodes=$NNODES  PP=$PP TP=$TP"

  # Preflight: every node must reach the head address ON THE FABRIC.
  # This is the check that would have caught the Docker FORWARD DROP issue.
  for n in "$HEAD" "${WORKER_ARR[@]}"; do
    if on "$n" "ping -c1 -W2 $hip >/dev/null 2>&1"; then
      ok "$n reaches head fabric ip $hip"
    else
      bad "$n CANNOT reach $hip"
      echo "     fix: static routes + 'sudo iptables -I FORWARD 1 -s <fabric>/24 -d 192.168.0.0/16 -j ACCEPT'" >&2
      exit 1
    fi
  done

  # Mount a HOST log dir: a container that exits takes /tmp with it, so an
  # in-container redirect leaves you with an empty `docker logs` and no cause.
  # Uneven pipeline split.
  # The LAST pipeline rank also carries the output layer + the 128K-token
  # vocabulary head, so an even 54/54/54 layer split allocated 106 GB on rank 2
  # vs ~69 GB on ranks 0/1 -> rank 2 thrashed into swap and never loaded.
  # VLLM_PP_LAYER_PARTITION gives rank 2 fewer transformer layers to compensate.
  local ppenv=""
  [ -n "${PP_PARTITION:-}" ] && ppenv="-e VLLM_PP_LAYER_PARTITION=$PP_PARTITION"

  local common="--gpus all --network host --ipc host --shm-size 16g \
    -v $MODEL_DIR:$MODEL_DIR -v /var/tmp/vllm-logs:/logs -e HF_HUB_OFFLINE=1 \
    $ppenv \
    -e NCCL_SOCKET_IFNAME=$RAY_IFACE -e GLOO_SOCKET_IFNAME=$RAY_IFACE"

  echo "=== starting HEAD (serves the HTTP endpoint) ==="
  on "$HEAD" "docker rm -f $CONTAINER >/dev/null 2>&1; \
    docker run -d --name $CONTAINER $common -e VLLM_HOST_IP=$hip \
      --entrypoint /bin/bash $IMAGE -c \
      'vllm serve $MODEL_ID --served-model-name $SERVED_NAME \
         --host 0.0.0.0 --port $PORT \
         --distributed-executor-backend mp \
         --nnodes $NNODES --node-rank 0 \
         --master-addr $hip --master-port $RPC_PORT \
         --pipeline-parallel-size $PP --tensor-parallel-size $TP \
         --max-model-len $MAX_LEN --gpu-memory-utilization $GPU_UTIL \
         ${EAGER:+--enforce-eager} $PARSERS \
         --trust-remote-code 2>&1 | tee /logs/vllm.log'"

  local rank=1
  for w in "${WORKER_ARR[@]}"; do
    local wip; wip="$(_ip_of "$w")"
    echo "=== starting WORKER rank $rank on $w ($wip) ==="
    on "$w" "docker rm -f $CONTAINER >/dev/null 2>&1; \
      docker run -d --name $CONTAINER $common -e VLLM_HOST_IP=$wip \
        --entrypoint /bin/bash $IMAGE -c \
        'vllm serve $MODEL_ID --served-model-name $SERVED_NAME \
           --headless \
           --distributed-executor-backend mp \
           --nnodes $NNODES --node-rank $rank \
           --master-addr $hip --master-port $RPC_PORT \
           --pipeline-parallel-size $PP --tensor-parallel-size $TP \
           --max-model-len $MAX_LEN --gpu-memory-utilization $GPU_UTIL \
           ${EAGER:+--enforce-eager} $PARSERS \
           --trust-remote-code 2>&1 | tee /logs/vllm.log'"
    rank=$((rank+1))
  done

  echo
  inf "loading ~258 GB across $NNODES nodes - expect several minutes"
  inf "watch:  $0 logs     ready:  $0 status"
}

status() {
  echo "=== containers ==="
  for n in "$HEAD" "${WORKER_ARR[@]}"; do
    printf '  %-22s ' "$n"
    local st; st="$(on "$n" "docker ps --format '{{.Status}}' --filter name=$CONTAINER | head -1" 2>/dev/null)"
    [ -n "$st" ] && echo "$st" || echo "DOWN"
  done
  echo "=== endpoint ==="
  local code; code="$(on "$HEAD" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$PORT/v1/models" 2>/dev/null)"
  if [ "$code" = "200" ]; then
    ok "endpoint LIVE (HTTP 200)"
    on "$HEAD" "curl -s http://127.0.0.1:$PORT/v1/models | python3 -c 'import json,sys; print(\"    served id:\", json.load(sys.stdin)[\"data\"][0][\"id\"])'"
  else
    bad "endpoint HTTP ${code:-000} - still loading? see: $0 logs"
  fi
  echo "=== memory per node ==="
  for n in "$HEAD" "${WORKER_ARR[@]}"; do
    on "$n" "free -g | awk '/Mem/{printf \"    %-22s %sG used / %sG\\n\", \"$n\", \$3, \$2}'"
  done
}

logs() { on "${2:-$HEAD}" "tail -n ${1:-40} /var/tmp/vllm-logs/vllm.log 2>/dev/null || docker logs --tail ${1:-40} $CONTAINER 2>&1"; }

stop() {
  for n in "$HEAD" "${WORKER_ARR[@]}"; do
    on "$n" "docker rm -f $CONTAINER >/dev/null 2>&1 && echo '  stopped $n' || echo '  (nothing on $n)'"
  done
}

test_gen() {
  echo "=== single-request generation test ==="
  on "$HEAD" "curl -s http://127.0.0.1:$PORT/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{\"model\":\"$SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":16}'" \
    | head -c 800
  echo
}

case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  logs) logs "${2:-40}" "${3:-$HEAD}" ;;
  test) test_gen ;;
  *) echo "usage: $0 {start|stop|status|logs [n] [node]|test}" >&2; exit 2 ;;
esac
