#!/usr/bin/env bash
# Serve ONE model on ONE node (no multi-node plumbing).
# Used for the fast companion model and as the agent-layer target while a
# larger model downloads.
#
#   serve-single.sh start <node> <model-dir> <served-name> [port] [gpu-util]
#   serve-single.sh stop  <node>
#   serve-single.sh status <node> [port]
#
# WHY a separate script: the multi-node path (cluster.sh) carries --nnodes /
# --node-rank / master-addr plumbing that is pure risk for a single-node model.
set -uo pipefail

ACT="${1:?need action: start, stop or status}"
NODE="${2:?need node hostname}"
CONTAINER="${CONTAINER:-vllm-single}"
IMAGE="${IMAGE:-vllm/vllm-openai:latest}"

on() { ssh -o BatchMode=yes -o ConnectTimeout=8 "nvidia@$NODE" "bash -lc $(printf '%q' "$*")"; }

case "$ACT" in
  start)
    MODEL_DIR="${3:?model dir required}"
    NAME="${4:?served name required}"
    PORT="${5:-8000}"
    UTIL="${6:-0.85}"
    MAXLEN="${MAXLEN:-32768}"
    SNAP="$(on "find $MODEL_DIR -maxdepth 4 -type d -path '*/snapshots/*' | head -1")"
    # WITHOUT a tool-call parser vLLM cannot turn the model's tool syntax into
    # structured tool_calls, so an agent's tools NEVER fire: the model reasons
    # ("Let's call the terminal tool") and then returns reasoning-only, which
    # looks exactly like a broken agent. gpt-oss uses the `openai` parser.
    PARSERS="${PARSERS:-}"
    if [ -z "$PARSERS" ]; then
      case "$NAME" in
        *gpt-oss*)   PARSERS="--enable-auto-tool-choice --tool-call-parser openai --reasoning-parser openai_gptoss" ;;
        *emotron*)   PARSERS="--enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser nemotron_v3" ;;
        *)           PARSERS="" ;;
      esac
    fi
    [ -n "$PARSERS" ] && echo "  parsers:  $PARSERS"
    [ -n "$SNAP" ] || { echo "FAIL: no snapshot dir under $MODEL_DIR on $NODE" >&2; exit 1; }
    echo "  node:     $NODE"
    echo "  snapshot: $SNAP"
    on "mkdir -p /var/tmp/vllm-logs; docker rm -f $CONTAINER >/dev/null 2>&1; \
      docker run -d --name $CONTAINER --gpus all --network host --ipc host --shm-size 16g \
        -v $MODEL_DIR:$MODEL_DIR -v /var/tmp/vllm-logs:/logs -e HF_HUB_OFFLINE=1 \
        --entrypoint /bin/bash $IMAGE -c \
        'vllm serve $SNAP --served-model-name $NAME \
           --host 0.0.0.0 --port $PORT \
           --max-model-len $MAXLEN --gpu-memory-utilization $UTIL \
           $PARSERS \
           --trust-remote-code 2>&1 | tee /logs/single.log'"
    echo "  launched; poll with: $0 status $NODE $PORT"
    ;;
  stop)
    on "docker rm -f $CONTAINER >/dev/null 2>&1 && echo '  stopped on $NODE' || echo '  nothing running on $NODE'"
    ;;
  status)
    PORT="${3:-8000}"
    printf '  container: '; on "docker ps --format '{{.Status}}' --filter name=$CONTAINER | head -1" || echo DOWN
    code="$(on "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$PORT/v1/models" 2>/dev/null)"
    if [ "$code" = "200" ]; then
      printf '  endpoint:  LIVE -> '
      on "curl -s http://127.0.0.1:$PORT/v1/models | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"data\"][0][\"id\"])'"
    else
      echo "  endpoint:  HTTP ${code:-000}"
      on "tr '\\r' '\\n' < /var/tmp/vllm-logs/single.log 2>/dev/null | grep -oE 'shards: *[0-9]+%|Model loading took [0-9.]+ GiB|Application startup complete|ERROR.*' | tail -2"
    fi
    ;;
  *) echo "usage: $0 {start|stop|status} <node> ..." >&2; exit 2 ;;
esac
