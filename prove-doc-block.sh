#!/usr/bin/env bash
# Prove the REAL containment beat: revoke the agent's access to the DOCUMENT
# REPOSITORY (not the model) and show it genuinely cannot read the case file.
#
# Run ON the sandbox host.  Usage: prove-doc-block.sh [sandbox] [records-ip]
#
# This is the version that tells the right story:
#   * the agent keeps its model -- it can still think and answer
#   * it loses its permission to reach the records system
#   * so it reports that it cannot retrieve the document, in its own words
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1

SBX="${1:-sovereign-agent}"
RIP="${2:?need the records-repository IP as arg 2}"
PORT="${3:-8900}"
POLICY="${POLICY:-/tmp/records-policy.yaml}"
X="timeout -k 5 90 openshell sandbox exec --name $SBX --no-tty --timeout 60 --"

probe() { $X curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
          "http://$RIP:$PORT/api/docs/grant-award" 2>/dev/null | tail -1; }

echo "=== 1. WITH permission: agent fetches the case file ==="
before=$(probe)
echo "    GET /api/docs/grant-award  -> http=$before"

echo
echo "=== 2. revoke the records-repository policy ==="
nemoclaw "$SBX" policy-remove records-repository --yes >/dev/null 2>&1
echo "    nemoclaw $SBX policy-remove records-repository"

echo
echo "=== 3. SAME request, nothing else changed ==="
denied=$(probe)
echo "    GET /api/docs/grant-award  -> http=$denied"

echo
echo "=== 4. but the agent is NOT broken -- it can still reach its model ==="
mdl=$($X curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
      https://inference.local/v1/models 2>/dev/null | tail -1)
echo "    model endpoint             -> http=$mdl"

echo
echo "=== 5. restore ==="
nemoclaw "$SBX" policy-add --from-file "$POLICY" --trusted-private-host "$RIP" --yes >/dev/null 2>&1
after=$(probe)
echo "    GET /api/docs/grant-award  -> http=$after"

echo
if [ "$before" = "200" ] && [ "$denied" = "403" ] && [ "$after" = "200" ]; then
  echo "  PROVED: 200 -> 403 -> 200   (document access revoked and restored)"
  [ "$mdl" = "200" ] && echo "  AND the agent kept its model throughout -- it was contained, not broken."
  exit 0
fi
echo "  NOT PROVED: before=$before denied=$denied after=$after" >&2
exit 1
