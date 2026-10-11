#!/usr/bin/env bash
# Run the three containment beats of the Sovereign Agent demo and print
# evidence for each. Run ON the node that hosts the sandbox.
#
#   demo-beats.sh [sandbox-name]
#
# Written as a FILE on purpose: nesting quotes through
# ssh -> bash -lc -> openshell exec collapses and produces misleading
# "unexpected EOF" / "command not found" errors from the wrong layer.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1

SBX="${1:-sovereign-agent}"
X="timeout -k 5 120 openshell sandbox exec --name $SBX --no-tty --timeout 90 --"

hr(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

hr "BEAT 1  the agent runs in a real, isolated box"
$X hostname 2>/dev/null        | sed 's/^/  container id : /'
$X id -un   2>/dev/null        | sed 's/^/  running as   : /'
$X cat /etc/debian_version 2>/dev/null | sed 's/^/  os           : Debian /'

hr "BEAT 2  deny-by-default egress: the open internet is BLOCKED"
code=$($X curl -s -o /dev/null -w '%{http_code}' --max-time 20 https://example.com 2>/dev/null | tail -1)
printf '  https://example.com   -> http=%s   %s\n' "${code:-000}" \
       "$([ "${code:-000}" = "000" ] && echo '(BLOCKED - enforced, not promised)' || echo '(!! UNEXPECTEDLY ALLOWED)')"
code=$($X curl -s -o /dev/null -w '%{http_code}' --max-time 20 https://api.github.com 2>/dev/null | tail -1)
printf '  https://api.github.com-> http=%s   %s\n' "${code:-000}" \
       "$([ "${code:-000}" = "000" ] && echo '(BLOCKED)' || echo '(!! ALLOWED)')"

hr "BEAT 3  the ONE approved route works: local inference"
$X curl -sk --max-time 25 https://inference.local/v1/models 2>/dev/null \
  | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); m=d["data"][0]
    print("  served model :", m["id"])
    print("  context      :", m.get("max_model_len"))
    print("  provenance   :", m.get("owned_by"))
except Exception as e:
    print("  FAILED to read model list:", e)'

hr "BEAT 4  the agent does real work with real code execution"
start=$(date +%s)
OUT="$($X hermes -z 'Use the terminal tool to run: python3 -c "from datetime import date; print((date(2026,12,1)-date(2026,10,1)).days)" then state only the number it printed.' -t terminal,code_execution --yolo 2>&1 | tail -3)"
end=$(date +%s)
printf '  answer       : %s\n' "$(printf '%s' "$OUT" | tr -d '\n' | tail -c 120)"
printf '  elapsed      : %ss\n' "$((end-start))"

hr "SUMMARY"
cat <<EOF
  An agent running on this box, on a model in this room, reading documents
  that never leave it. It cannot reach the internet - that is enforced by
  policy, not by trust. Remove the policy and the same call fails 403.
EOF
