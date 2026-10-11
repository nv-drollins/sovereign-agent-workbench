#!/usr/bin/env bash
# Stage a HF model on THIS node into a non-root cache dir.
# Usage: stage-model.sh <hf-repo-id> <dest-cache-dir>
#
# Two lessons baked in:
#  1. Ubuntu 24.04 sets PEP-668 EXTERNALLY-MANAGED, so `pip install --user`
#     is REFUSED. A repo-local venv is the only reliable path. Do NOT mask
#     the failure with `|| true` -- that hid a broken install and the real
#     error only surfaced as ModuleNotFoundError much later.
#  2. The cache dir must be owned by the login user, NOT created by the
#     root-running vLLM container, or teardown needs sudo.
set -euo pipefail

REPO="${1:?usage: stage-model.sh <repo-id> <dest-dir>}"
DEST="${2:?usage: stage-model.sh <repo-id> <dest-dir>}"
VENV="$HOME/.hfvenv"
LOG="$HOME/stage-$(echo "$REPO" | tr '/' '_').log"

[ -n "${HF_TOKEN:-}" ] || { echo "FAIL: HF_TOKEN not set (check ~/.hf_env)" >&2; exit 1; }

mkdir -p "$DEST"

# --- venv with huggingface_hub (fail loudly) --------------------------------
if [ ! -x "$VENV/bin/python" ]; then
  echo "[$(date +%T)] creating venv $VENV" | tee -a "$LOG"
  python3 -m venv "$VENV" >>"$LOG" 2>&1
fi
if ! "$VENV/bin/python" -c 'import huggingface_hub' 2>/dev/null; then
  echo "[$(date +%T)] installing huggingface_hub[hf_transfer]" | tee -a "$LOG"
  "$VENV/bin/pip" install --quiet --upgrade pip >>"$LOG" 2>&1
  "$VENV/bin/pip" install --quiet "huggingface_hub" hf_xet >>"$LOG" 2>&1
fi
"$VENV/bin/python" -c 'import huggingface_hub as h; print("huggingface_hub", h.__version__)' | tee -a "$LOG"

# huggingface_hub >= 2.x uses Xet, NOT hf_transfer (HF_HUB_ENABLE_HF_TRANSFER
# is deprecated and warns). Enable Xet high-performance mode when available.
if "$VENV/bin/python" -c 'import hf_xet' 2>/dev/null; then
  export HF_XET_HIGH_PERFORMANCE=1
  echo "  hf_xet high-performance: enabled" | tee -a "$LOG"
else
  echo "  hf_xet: NOT available (normal download speed)" | tee -a "$LOG"
fi

echo "[$(date +%T)] staging $REPO -> $DEST" | tee -a "$LOG"
"$VENV/bin/python" - "$REPO" "$DEST" >>"$LOG" 2>&1 <<'PY'
import sys, os
from huggingface_hub import snapshot_download
p = snapshot_download(repo_id=sys.argv[1], cache_dir=sys.argv[2],
                      token=os.environ["HF_TOKEN"], max_workers=8)
print("SNAPSHOT:", p)
PY

echo "[$(date +%T)] DONE $REPO size=$(du -sh "$DEST" | cut -f1)" | tee -a "$LOG"
