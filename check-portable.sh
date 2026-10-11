#!/usr/bin/env bash
# CI-style guard: refuse to commit anything carrying this site's identity.
#
#   check-portable.sh [dir]
#
# This repo gets handed to other people and installed in other labs, so a
# baked-in address, hostname or username is a DEFECT, not a convenience.
# "There's a config file" is not compliance -- the check is that a fresh
# clone contains nothing from here.
#
# Allowed: 0.0.0.0, 127.0.0.1, netmasks, docker bridge ranges, and the RFC
# 5737 documentation blocks (192.0.2.x, 198.51.100.x, 203.0.113.x).
set -uo pipefail
DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
FAIL=0

say_bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=1; }
say_ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }

# Files that legitimately hold site config are gitignored; skip them.
SKIP='(^|/)(\.git/|net\.conf:|cluster\.conf:|node-macs\.txt:|cold-boot-[0-9-]*\.log:|bundle/|check-portable\.sh:)'

scan(){ # $1 = regex, $2 = label
  local hits
  hits=$(grep -rnE "$1" "$DIR" 2>/dev/null \
         | grep -vE "$SKIP" \
         | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.' \
         | grep -vE '0\.0\.0\.0|127\.0\.0\.1|255\.255\.255|172\.1[78]\.0\.1|10\.200\.0\.1|192\.168\.0\.0/16' \
         | head -8)
  if [ -n "$hits" ]; then
    say_bad "$2"
    printf '      %s\n' "$hits"
  else
    say_ok "$2"
  fi
}

echo "=== portability audit: $DIR ==="
scan '(^|[^0-9.])(192\.168|10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+' "no private IPv4 literals"
scan 'spark-[0-9a-f]{4}' "no site hostnames"
scan '/home/[a-z][a-z0-9_-]+/' "no absolute home paths"

# secrets must never appear
if grep -rniE 'hf_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|BEGIN (RSA|OPENSSH) PRIVATE' "$DIR" 2>/dev/null \
   | grep -vE "$SKIP" | head -3 | grep -q .; then
  say_bad "SECRET MATERIAL PRESENT"
else
  say_ok "no secrets"
fi

echo
[ "$FAIL" = "0" ] && echo "  PORTABLE — safe to publish" || echo "  NOT PORTABLE — fix the above before committing" >&2
exit $FAIL
