#!/usr/bin/env bash
# Make HF_TOKEN visible to NON-INTERACTIVE shells (ssh 'cmd', scripts, systemd).
#
# WHY: Ubuntu's ~/.bashrc returns early for non-interactive shells (line ~8),
# so an `export HF_TOKEN=` further down (line 119) is never reached by
# `ssh node 'cmd'`. The token is moved to ~/.hf_env, which is sourced from the
# TOP of .bashrc (before the guard) and from .profile. The secret value is
# copied in-place by this script; it is never printed.
set -euo pipefail

BRC="$HOME/.bashrc"; ENVF="$HOME/.hf_env"; PROF="$HOME/.profile"

# 1. Extract the existing token from .bashrc WITHOUT echoing it.
TOK="$(bash -ic 'printf %s "$HF_TOKEN"' 2>/dev/null | tail -c 200 || true)"
if [ -z "$TOK" ]; then
  echo "FAIL: no HF_TOKEN found in interactive shell on $(hostname)" >&2; exit 1
fi

# 2. Write the private env file (0600).
umask 077
printf 'export HF_TOKEN=%s\nexport HUGGING_FACE_HUB_TOKEN=%s\n' "$TOK" "$TOK" > "$ENVF"
chmod 600 "$ENVF"

# 3. Source it from the TOP of .bashrc (above the non-interactive guard).
if ! grep -q 'hf_env' "$BRC" 2>/dev/null; then
  tmp="$(mktemp)"
  { echo '# --- HF token for non-interactive shells (added for sovereign-agent demo) ---'
    echo '[ -f "$HOME/.hf_env" ] && . "$HOME/.hf_env"'
    echo
    cat "$BRC"
  } > "$tmp"
  mv "$tmp" "$BRC"
fi

# 4. And from .profile, for login shells that skip .bashrc entirely.
if ! grep -q 'hf_env' "$PROF" 2>/dev/null; then
  printf '\n[ -f "$HOME/.hf_env" ] && . "$HOME/.hf_env"\n' >> "$PROF"
fi

# 5. Comment out the ORIGINAL late export so there is one source of truth.
sed -i -E 's/^(export HF_TOKEN=.*)$/# superseded by ~\/.hf_env -> \1/' "$BRC"

echo "  configured on $(hostname)"
