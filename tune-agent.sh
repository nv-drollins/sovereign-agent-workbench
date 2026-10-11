#!/usr/bin/env bash
# Apply the Hermes-in-sandbox reliability fixes to a NemoClaw Hermes sandbox.
#
#   tune-agent.sh <sandbox-name>
#
# Fixes (each one earned):
#  1. extra_body.chat_template_kwargs.enable_thinking=false +
#     force_nonempty_content=true  -> gpt-oss/Nemotron otherwise burn the whole
#     budget on internal reasoning and return NO final answer
#     ("model produced only internal reasoning ... despite retries").
#  2. tools.tool_search.enabled=false -> the search/describe/call indirection
#     makes mid-size local models loop until the run budget expires.
#  3. auxiliary.title_generation.enabled=false -> saves a whole extra model
#     call per turn (and a spurious 403 when routes are policy-denied).
#  4. memory/curator off -> clean, reproducible booth turns.
set -uo pipefail

NODE="${AGENT_NODE:?set AGENT_NODE}"
SBX="${1:?need sandbox name}"

on() { ssh -o BatchMode=yes -o ConnectTimeout=10 "nvidia@$NODE" "bash -lc $(printf '%q' "$*")"; }

# Build the patch script locally, base64 it in: inline quoting through
# ssh -> bash -lc -> openshell exec -> python collapses otherwise.
read -r -d '' PATCH <<'PYEOF' || true
import re, sys, pathlib
p = pathlib.Path("/sandbox/.hermes/config.yaml")
s = p.read_text()

def set_block(src, block):
    name = block.split(":")[0]
    pat = re.compile(rf"^{re.escape(name)}:.*?(?=^\S|\Z)", re.M | re.S)
    return pat.sub(block, src) if pat.search(src) else src.rstrip() + "\n" + block

# 1. tool search off
s = re.sub(r"(tools:\s*\n\s+tool_search:\s*\n\s+enabled:\s*)on", r"\1false", s)

# 2. memory + curator off (clean booth turns)
s = re.sub(r"(memory:\s*\n\s+memory_enabled:\s*)true", r"\1false", s)
s = re.sub(r"(\n\s+user_profile_enabled:\s*)true", r"\1false", s)

# 3. auxiliary: no title-generation model call
if "auxiliary:" not in s:
    s += "\nauxiliary:\n  title_generation:\n    enabled: false\n"
else:
    s = set_block(s, "auxiliary:\n  title_generation:\n    enabled: false\n")

# 4. THE important one: stop the model emitting reasoning-only turns.
#    OpenShell rewrites base_url at request time, so we only add extra_body.
if "extra_body" not in s:
    s += (
        "\nproviders:\n"
        "  compatible-endpoint:\n"
        "    extra_body:\n"
        "      chat_template_kwargs:\n"
        "        enable_thinking: false\n"
        "        force_nonempty_content: true\n"
    )
p.write_text(s)
print("PATCHED")
for k in ("enable_thinking", "force_nonempty_content", "tool_search", "title_generation"):
    for line in s.splitlines():
        if k in line:
            print("  ", line.strip())
PYEOF

B64="$(printf '%s' "$PATCH" | base64 -w0)"
echo "=== patching $SBX hermes config ==="
on "timeout -k 5 90 openshell sandbox exec --name $SBX --no-tty --timeout 60 -- \
    python3 -c 'import base64,sys;exec(base64.b64decode(sys.argv[1]).decode())' $B64" 2>&1 | tail -12

echo "=== restarting sandbox so the config is picked up ==="
on "nemoclaw $SBX restart --yes 2>/dev/null || nemoclaw $SBX stop --yes 2>/dev/null; nemoclaw $SBX start --yes 2>/dev/null" | tail -3
sleep 10
on "openshell sandbox list | grep '^$SBX '"
