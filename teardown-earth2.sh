#!/usr/bin/env bash
# Full Earth-2 + NemoClaw teardown on one node. Run ON the node.
# Usage: teardown-earth2.sh
set -u

say() { printf '  %-52s %s\n' "$1" "$2"; }
echo "===== TEARDOWN on $(hostname) ====="

# --- 1. NemoClaw / OpenShell -------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1

if command -v nemoclaw >/dev/null 2>&1 || [ -x "$HOME/.local/bin/nemoclaw" ]; then
  NC="$(command -v nemoclaw || echo "$HOME/.local/bin/nemoclaw")"
  # destroy any sandboxes first
  "$HOME/.local/bin/openshell" sandbox list 2>/dev/null | awk 'NR>1 && $1!="" {print $1}' | while read -r s; do
    [ -n "$s" ] && { echo "  destroying sandbox $s"; "$NC" "$s" destroy --yes >/dev/null 2>&1; }
  done
  echo "  running nemoclaw uninstall (may take a minute)..."
  "$NC" uninstall --yes --destroy-user-data --all-gateway-ports >/dev/null 2>&1
fi

# gateway commonly survives uninstall as a bare process with no systemd unit
systemctl --user disable --now nemoclaw-openshell-gateway >/dev/null 2>&1
pgrep -af 'openshell-gateway' | awk '{print $1}' | while read -r p; do
  echo "  killing surviving gateway pid $p"; kill "$p" 2>/dev/null; sleep 1; kill -9 "$p" 2>/dev/null
done

# openshell docker leftovers
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^openshell-default--|^nemoclaw-' | while read -r c; do
  echo "  rm container $c"; docker rm -f "$c" >/dev/null 2>&1
done
docker volume ls -q 2>/dev/null | grep -E 'openshell|nemoclaw' | xargs -r docker volume rm -f >/dev/null 2>&1
docker network ls --format '{{.Name}}' 2>/dev/null | grep -E 'openshell' | xargs -r docker network rm >/dev/null 2>&1

rm -rf "$HOME/.nemoclaw" "$HOME/.openshell" "$HOME/.openclaw" "$HOME/.local/state/nemoclaw-"* 2>/dev/null
rm -f "$HOME/.local/bin/nemoclaw" "$HOME/.local/bin/openshell" "$HOME/.local/bin/openshell-gateway" 2>/dev/null

# --- 2. Earth-2 repo + artifacts --------------------------------------------
rm -rf "$HOME/earth2-spark-ensemble" "$HOME/e2cache" "$HOME/e2-render" "$HOME/earth2" 2>/dev/null

# --- 3. Model weights (full wipe, user-requested clean slate) ----------------
rm -rf "$HOME/.cache/huggingface" 2>/dev/null

# --- 4. Container images -----------------------------------------------------
for img in $(docker images --format '{{.Repository}}:{{.Tag}}@{{.ID}}' 2>/dev/null); do
  repo="${img%@*}"; id="${img##*@}"
  case "$repo" in
    *earth2*|*physicsnemo*|*vllm*|*nemoclaw*|curlimages/curl*|busybox*|ubuntu*)
      echo "  rmi $repo"; docker rmi -f "$id" >/dev/null 2>&1 ;;
  esac
done
docker system prune -f >/dev/null 2>&1

# --- 5. VERIFY ---------------------------------------------------------------
echo "--- verification (every line must read none/free/0) ---"
say "nemoclaw/openshell/openclaw CLIs:" "$(command -v nemoclaw openshell openclaw 2>/dev/null | tr '\n' ' ' || true)${_:+}$( [ -z "$(command -v nemoclaw openshell openclaw 2>/dev/null)" ] && echo none)"
say "port 8080 / 4454 / 8001 / 8000:" "$(ss -ltn 2>/dev/null | grep -cE ':8080|:4454|:8001|:8000' | sed 's/^0$/free/')"
say "openshell containers:" "$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -cE 'openshell|nemoclaw')"
say "openshell networks:" "$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -cE 'openshell')"
say "docker images remaining:" "$(docker images -q 2>/dev/null | wc -l)"
say "HF cache:" "$( [ -d "$HOME/.cache/huggingface" ] && du -sh "$HOME/.cache/huggingface" | cut -f1 || echo none )"
say "earth2 dir:" "$( [ -d "$HOME/earth2-spark-ensemble" ] && echo PRESENT || echo none )"
say "stray nemoclaw/openshell files:" "$(find "$HOME" -maxdepth 4 \( -name 'nemoclaw*' -o -name 'openshell*' -o -name 'openclaw*' \) -not -path '*/.cache/*' -not -path '*/sovereign-agent/*' 2>/dev/null | wc -l)"
say "disk free on /:" "$(df -h / | awk 'NR==2{print $4}')"
say "RAM available:" "$(free -g | awk '/Mem/{print $7"G"}')"
echo "===== done on $(hostname) ====="
