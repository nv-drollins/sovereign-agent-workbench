#!/usr/bin/env bash
# Show HOW the egress deny is actually enforced, with evidence.
# Run ON the sandbox host.  Usage: explain-deny.sh [sandbox]
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
SBX="${1:-sovereign-agent}"
X="timeout -k 5 90 openshell sandbox exec --name $SBX --no-tty --timeout 60 --"

echo "=== 1. proxy environment inside the sandbox ==="
$X env 2>/dev/null | grep -iE 'proxy|ca_bundle|ssl_cert|REQUESTS_CA' | sed 's/^/  /' || echo "  (none)"

echo
echo "=== 2. what happens on a DENIED host (verbose) ==="
$X curl -sv --max-time 15 https://example.com 2>&1 \
  | grep -iE 'proxy|CONNECT|407|403|denied|tunnel|refused|Could not resolve' | head -6 | sed 's/^/  /'

echo
echo "=== 3. what happens on the ALLOWED host ==="
$X curl -sv --max-time 20 https://inference.local/v1/models 2>&1 \
  | grep -iE 'proxy|CONNECT|200|tunnel|subject|issuer' | head -6 | sed 's/^/  /'

echo
echo "=== 4. can the sandbox reach the outside WITHOUT the proxy? (raw IP) ==="
$X curl -s -o /dev/null -w '  direct 1.1.1.1:443 -> http=%{http_code}\n' --max-time 10 https://1.1.1.1 2>&1 | tail -1

echo
echo "=== 5. DNS: can it even resolve a blocked name? ==="
$X getent hosts example.com 2>/dev/null | sed 's/^/  /' || echo "  no resolution"

echo
echo "=== 6. the policy the gateway is enforcing ==="
nemoclaw "$SBX" policy-list 2>/dev/null | grep -E '●' | sed 's/^/  /'

echo
echo "=== 7. container network placement ==="
cid=$(docker ps --format '{{.Names}}' | grep -i "$SBX" | head -1)
[ -n "$cid" ] && docker inspect "$cid" \
  -f '  networks: {{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' 2>/dev/null
[ -n "$cid" ] && docker inspect "$cid" -f '  dns: {{.HostConfig.Dns}}' 2>/dev/null
