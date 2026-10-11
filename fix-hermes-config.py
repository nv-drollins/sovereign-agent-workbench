#!/usr/bin/env python3
"""Repair + retarget the in-sandbox Hermes config.

Run INSIDE the sandbox (seeded via base64, because inline quoting through
ssh -> bash -lc -> openshell exec collapses).

Fixes a self-inflicted bug worth remembering: appending a second top-level
`providers:` block produces *valid YAML* but Hermes rejects the file
("Invalid YAML configuration syntax") and the later block silently shadows
the real endpoint config. ALWAYS merge into the existing mapping with a YAML
parser; never append a duplicate top-level key by string concatenation.
"""
import sys, pathlib

try:
    import yaml
except ImportError:
    print("FAIL: pyyaml missing in sandbox")
    sys.exit(1)

# NOTE: under `python3 -c "exec(b64)" <blob> <model>` sys.argv[1] is the
# BLOB, not the model. Take the model from the environment instead.
import os
MODEL = os.environ.get("HERMES_TARGET_MODEL", "nemotron-super-120b")
p = pathlib.Path("/sandbox/.hermes/config.yaml")
raw = p.read_text()

# Drop every duplicate top-level `providers:` block except the FIRST, then
# reload. yaml.safe_load already keeps the last, so rebuild from text.
lines = raw.splitlines()
seen_providers = False
out, skipping = [], False
for ln in lines:
    if ln.startswith("providers:"):
        if seen_providers:
            skipping = True
            continue
        seen_providers = True
        skipping = False
    elif skipping and (not ln.strip() or ln.startswith((" ", "\t"))):
        continue
    else:
        skipping = False
    out.append(ln)
raw = "\n".join(out) + "\n"

cfg = yaml.safe_load(raw) or {}

# Merge the reliability settings into the EXISTING provider mapping.
prov = cfg.setdefault("providers", {})
ep = prov.setdefault("compatible-endpoint", {})
ep["default_model"] = MODEL
ep.setdefault("extra_body", {})["chat_template_kwargs"] = {
    "enable_thinking": False,
    "force_nonempty_content": True,
}

for cp in cfg.get("custom_providers", []) or []:
    if isinstance(cp, dict) and cp.get("name") == "compatible-endpoint":
        cp["default_model"] = MODEL

cfg.setdefault("model", {})["default"] = MODEL
cfg.setdefault("tools", {}).setdefault("tool_search", {})["enabled"] = False
cfg.setdefault("auxiliary", {}).setdefault("title_generation", {})["enabled"] = False
mem = cfg.setdefault("memory", {})
mem["memory_enabled"] = False
mem["user_profile_enabled"] = False

p.write_text(yaml.safe_dump(cfg, sort_keys=False, default_flow_style=False))
print("REPAIRED")
print("  providers blocks:", sum(1 for l in p.read_text().splitlines() if l.startswith("providers:")))
print("  default_model   :", cfg["providers"]["compatible-endpoint"].get("default_model"))
print("  model.default   :", cfg["model"]["default"])
print("  yaml reparse    :", "OK" if yaml.safe_load(p.read_text()) else "FAIL")
