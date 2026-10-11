#!/usr/bin/env bash
# Build a self-contained USB bundle for OFFLINE installation.
#
#   make-bundle.sh <output-dir>
#
# Venue internet is usually slow or absent, so everything the installer needs
# must already be on the stick: python wheels, the container image, the model
# weights, and the project itself.
#
# Sizing (measured on this cluster):
#   wheels          ~15 MB
#   vLLM image      ~34 GB  (14 GB after zstd)
#   model weights   ~80 GB  (already-compressed safetensors; zstd gains ~1%)
#   project          <1 MB
#   ---------------------------------------
#   budget a 256 GB stick, exFAT or ext4.
#
# NOTE ON exFAT: it has no symlinks and no unix permissions. HuggingFace caches
# are symlink farms, so weights are copied DEREFERENCED (tar -h). Expect the
# on-stick size to match the real byte size, not the `du` of the cache.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?usage: make-bundle.sh <output-dir>}"
[ -f "$HERE/net.conf" ] && . "$HERE/net.conf"
# use ${VAR-default} (not :-) so BUNDLE_SRC_NODE="" means "skip node steps"
SRC_NODE="${BUNDLE_SRC_NODE-${BOOTH_NODE:-}}"
MODEL_DIR_NAME="${BUNDLE_MODEL_DIR:-models-nemotron}"
IMAGE="${IMAGE:-vllm/vllm-openai:latest}"

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
inf(){ printf '  • %s\n' "$*"; }
hr(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
on(){ ssh -n -o BatchMode=yes "nvidia@$1" "bash -lc $(printf '%q' "$2")"; }

mkdir -p "$OUT"/{wheels,project,images,models}
AVAIL=$(df -BG --output=avail "$OUT" 2>/dev/null | tail -1 | tr -dc '0-9')
inf "target: $OUT  (${AVAIL:-?} GB free)"
[ "${AVAIL:-0}" -lt 140 ] 2>/dev/null && inf "WARNING: <140 GB free; weights alone are ~80 GB"

hr "1/5  project files"
for f in install.sh demo.sh cluster.sh serve-single.sh net-setup.sh model-route.sh \
         setup-agent.sh booth_app.py booth.html retrieval.py verifier.py docservice.py \
         watchdog.py telemetry.py check-booth.py check-access-beat.py prove-doc-block.sh \
         records-policy.yaml net.conf.example cluster.conf.example stage-model.sh \
         verify-model.sh show-telemetry.py; do
  [ -f "$HERE/$f" ] && cp "$HERE/$f" "$OUT/project/" 2>/dev/null
done
cp -r "$HERE/documents" "$OUT/project/" 2>/dev/null
ok "$(ls "$OUT/project" | wc -l) files"

hr "2/5  python wheels"
# The control machine may have no pip module (Hermes-managed interpreters
# often don't). Fall back to downloading the wheels ON a node, then pulling
# them back -- the nodes always have a usable python.
WHEEL_OK=0
if python3 -m pip --version >/dev/null 2>&1; then
  python3 -m pip download --quiet --dest "$OUT/wheels" \
    fastapi "uvicorn[standard]" websockets 2>/dev/null && WHEEL_OK=1
fi
if [ "$WHEEL_OK" = "0" ] && [ -n "$SRC_NODE" ]; then
  inf "no local pip — building wheels on ${SRC_NODE%%.*}"
  on "$SRC_NODE" "rm -rf ~/.wheelcache && mkdir -p ~/.wheelcache && \
     ~/booth/.venv/bin/pip download --quiet --dest ~/.wheelcache \
     fastapi 'uvicorn[standard]' websockets" >/dev/null 2>&1 \
   && scp -q "nvidia@$SRC_NODE:~/.wheelcache/*" "$OUT/wheels/" 2>/dev/null && WHEEL_OK=1
fi
[ "$WHEEL_OK" = "1" ] \
  && ok "$(ls "$OUT/wheels" | wc -l) wheels, $(du -sh "$OUT/wheels" | cut -f1)" \
  || inf "wheels unavailable — offline install will need them"

hr "3/5  container image"
if [ -n "$SRC_NODE" ] && on "$SRC_NODE" "docker image inspect $IMAGE >/dev/null 2>&1"; then
  inf "saving $IMAGE (~34 GB, compresses to ~14 GB) — several minutes"
  on "$SRC_NODE" "docker save $IMAGE | zstd -3 -T0" > "$OUT/images/vllm.tar.zst" 2>/dev/null \
    && ok "$(du -sh "$OUT/images/vllm.tar.zst" | cut -f1)" \
    || inf "image save failed"
else
  inf "image not present on $SRC_NODE — skipping"
fi

hr "4/5  model weights"
if [ -n "$SRC_NODE" ] && [ "${SKIP_WEIGHTS:-0}" != "1" ]; then
  inf "copying $MODEL_DIR_NAME dereferenced (~80 GB) — this is the long pole"
  # -h follows symlinks: a HF cache copied WITHOUT it ships dangling links and
  # arrives as a few hundred KB that looks complete.
  on "$SRC_NODE" "cd ~ && tar -ch -f - $MODEL_DIR_NAME" \
    | tar -C "$OUT/models" -xf - 2>/dev/null \
    && ok "$(du -sh "$OUT/models" | cut -f1)" || inf "weight copy failed"
else
  inf "skipped (no source node, or SKIP_WEIGHTS=1)"
fi

hr "5/5  manifest + installer entry point"
cat > "$OUT/INSTALL.txt" <<'EOF'
SOVEREIGN AGENT WORKBENCH — OFFLINE INSTALL
===========================================

On the control machine (the laptop/Spark you drive the demo from):

  1. Copy this whole directory off the USB to local disk:
         cp -a /media/<usb>/sovereign-bundle ~/sovereign-agent
         cd ~/sovereign-agent/project

  2. Create your site config (NO addresses are baked into the repo):
         cp net.conf.example net.conf
         cp cluster.conf.example cluster.conf
         # edit both: node names, service placement, model path

  3. Put the weights and image on every node:
         bash ../deploy-offline.sh

  4. Restore the fabric config (REQUIRED after every power cycle):
         bash net-setup.sh apply

  5. Install and verify:
         bash install.sh --offline
         bash install.sh --check

  6. Start the demo:
         bash demo.sh start
         bash demo.sh check

TROUBLESHOOTING
  - "booth UI shows nothing"      -> uvicorn installed without [standard];
                                     /ws returns 404. Re-run install.sh.
  - "model endpoint HTTP 000"     -> still loading; allow ~8 minutes.
  - "agent sandbox phase=Error"   -> nemoclaw <sbx> destroy --yes && bash setup-agent.sh
  - "sandbox->model route" fails  -> bash model-route.sh on <model-node-ip>
  - multi-node vLLM hangs         -> bash net-setup.sh check (fabric routes lost)
EOF

cat > "$OUT/deploy-offline.sh" <<'EOF'
#!/usr/bin/env bash
# Push the bundled image + weights to every node. Run from the bundle root.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/project/net.conf" 2>/dev/null || { echo "create project/net.conf first" >&2; exit 1; }
for h in $NODES; do
  echo "=== $h ==="
  if [ -f "$HERE/images/vllm.tar.zst" ]; then
    echo "  loading container image..."
    zstd -dc "$HERE/images/vllm.tar.zst" | ssh -o BatchMode=yes "nvidia@$h" "docker load" >/dev/null
  fi
  if [ -d "$HERE/models" ]; then
    echo "  copying weights (long)..."
    tar -C "$HERE/models" -cf - . | ssh -o BatchMode=yes "nvidia@$h" "mkdir -p ~ && tar -C ~ -xf -"
  fi
  echo "  done"
done
EOF
chmod +x "$OUT/deploy-offline.sh"

{ echo "built: $(date -Iseconds)"
  echo "host:  $(hostname)"
  echo "contents:"; du -sh "$OUT"/* 2>/dev/null | sed 's/^/  /'
  echo "total: $(du -sh "$OUT" | cut -f1)"; } > "$OUT/MANIFEST.txt"
ok "INSTALL.txt, deploy-offline.sh, MANIFEST.txt"

hr "bundle complete"
cat "$OUT/MANIFEST.txt" | sed 's/^/  /'
