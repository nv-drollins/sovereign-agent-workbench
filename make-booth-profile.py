#!/usr/bin/env python3
"""Create a LEAN Hermes profile for booth use.

Problem measured on real hardware: the default sandbox profile ships 82
bundled skills, so a turn that only needs to say "PING" sends **16,181
prompt tokens** and generates 542 tokens of preamble-driven chatter. A
163-second booth run was ~85% this overhead (the model itself answers the
same prompt in 26s).

Fix: a profile with NO skills, NO tool search, NO memory, a tight system
prompt, and a capped answer length. Booth answers must fit on a screen
anyway.

Run INSIDE the sandbox (seed via base64 + --env, never inline quoting).
"""
import os, pathlib, shutil, sys

try:
    import yaml
except ImportError:
    print("FAIL: pyyaml missing")
    sys.exit(1)

PROFILE = os.environ.get("BOOTH_PROFILE", "booth")
MODEL = os.environ.get("HERMES_TARGET_MODEL", "nemotron-super-120b")

home = pathlib.Path("/sandbox/.hermes")
base = yaml.safe_load((home / "config.yaml").read_text()) or {}
pdir = home / "profiles" / PROFILE
(pdir / "skills").mkdir(parents=True, exist_ok=True)

cfg = dict(base)

# Keep ONLY the provider wiring from the managed config; drop everything that
# inflates the prompt.
cfg["tools"] = {"tool_search": {"enabled": False}}
cfg["memory"] = {"memory_enabled": False, "user_profile_enabled": False}
cfg["auxiliary"] = {"title_generation": {"enabled": False}}
cfg["skills"] = {"enabled": False}
cfg["agent"] = {"max_turns": 8, "verify_on_stop": False}
cfg["display"] = {"compact": True, "tool_progress": "all",
                  "interim_assistant_messages": True, "show_reasoning": False}

prov = cfg.setdefault("providers", {})
ep = prov.setdefault("compatible-endpoint", {})
ep["default_model"] = MODEL
# reasoning_effort=low measurably halves reasoning on this model; enable_thinking
# is a NO-OP here (verified) but harmless and correct for Nemotron siblings.
ep.setdefault("extra_body", {}).update({
    "reasoning_effort": "low",
    "chat_template_kwargs": {"enable_thinking": False,
                             "force_nonempty_content": True},
})
cfg.setdefault("model", {})["default"] = MODEL

(pdir / "config.yaml").write_text(
    yaml.safe_dump(cfg, sort_keys=False, default_flow_style=False))

print("PROFILE", PROFILE, "written")
print("  skills dir entries :", len(list((pdir / 'skills').iterdir())))
print("  default_model      :", ep["default_model"])
print("  extra_body         :", ep["extra_body"])
