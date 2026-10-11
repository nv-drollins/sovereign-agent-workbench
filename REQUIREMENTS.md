# Sovereign Agent Workbench — Requirements & Install Inventory

Running record of **everything installed or changed** on each machine, so any
box can be rebuilt clean. Updated as the build proceeds.

**Demo:** local agent reads sensitive-style documents, extracts cited
obligations/deadlines, drafts a response — with enforced egress policy and a
pull-the-cable air-gap beat. Target: NVIDIA GTC Washington, D.C.
(Nov 30 – Dec 3, 2026, Ronald Reagan Building).

---

## 1. Hardware roster

| Role | Hostname | Mgmt IP | CX7 ring IPs | RAM | Disk free |
|---|---|---|---|---|---|
| **Head** (model + app + gateway) | node-a | 192.0.2.159 | 198.51.100.2, .11.2, .14.1, .15.1 | 121 GB | 3.4 TB |
| Worker | node-b | 192.0.2.188 | 198.51.100.1, .11.1, .12.1, .13.1 | 121 GB | 3.5 TB |
| Worker | node-c | 192.0.2.124 | 198.51.100.2, .13.2, .14.2, .15.2 | 121 GB | 3.5 TB |
| Control (Hermes runs here) | control | 192.0.2.164 | — | 121 GB | 3.4 TB |

- All DGX Spark / GB10 Grace Blackwell, 128 GB unified memory (~121 GB visible,
  ~115 GB available).
- CX7 ring: full mesh, all 4 links up per node, subnets 192.168.10–15.0/24.
  Deliberately off the colliding 192.0.2.0/24 management LAN.
- **Addressing rule:** peers are reached by `.local` mDNS names or CX7 IPs.
  No hardcoded management IPs in any committed file.

### Measured link throughput (head → peer, 4 GB)

| Method | Rate |
|---|---|
| ssh, default cipher | 682 MB/s |
| **ssh, `-c aes128-gcm@openssh.com`** | **1024 MB/s** ← used |
| raw TCP (netcat) | 682 MB/s |

Raw TCP matching default ssh means the cap is **peer disk write**, not crypto.
`aes128-gcm` still wins; ~3.5 min per peer for a 196 GB model.

---

## 2. Prerequisites (must exist before install)

| Requirement | Status | Note |
|---|---|---|
| Passwordless SSH, control → all 3 nodes | ✅ | key-based |
| Passwordless SSH, head → peers over CX7 | ✅ | keys already trusted |
| `sudo -n` on nodes | ✅ present | scripts must still degrade gracefully |
| Docker, user in `docker` group | ✅ | no sudo needed for docker |
| `HF_TOKEN` on every node | ✅ fixed — see §3 | user `nv-drollins`, nvidia org |
| Python 3.12.3 | ✅ | PEP-668 externally-managed |
| Internet on head node | ✅ | for model pull only |

---

## 3. Changes made to each node

### 3.1 HF_TOKEN reachable from non-interactive shells — ALL 3 NODES

**Problem:** `HF_TOKEN` was exported at line 119 of `~/.bashrc`, but Ubuntu's
non-interactive early-return sits at line 8. So `ssh node 'cmd'`, scripts and
systemd units all saw an **empty** token while an interactive login looked fine.

**Fix** (`fix-hf-token-env.sh`):
- token moved to `~/.hf_env` (mode 0600), exported as `HF_TOKEN` and
  `HUGGING_FACE_HUB_TOKEN`
- sourced from the **top** of `~/.bashrc` (above the guard) and from `~/.profile`
- original late `export` commented out — one source of truth
- `~/.bashrc` backed up to `~/.bashrc.bak.<epoch>`

Verified: all three return `HF_TOKEN SET (len=37)` from a non-interactive shell.

### 3.2 Python venv for HF downloads — head + node-b

`~/.hfvenv` containing `huggingface_hub` 2.2.0 + `hf_xet`.

**Why a venv:** Ubuntu 24.04 ships `EXTERNALLY-MANAGED`, so `pip install --user`
is refused. The first attempt masked this with `|| true`, and the failure only
surfaced later as `ModuleNotFoundError`. **Never swallow a pip failure.**

**Note:** `huggingface_hub` 2.x dropped the `[cli]` and `[hf_transfer]` extras,
and `HF_HUB_ENABLE_HF_TRANSFER` is deprecated in favour of Xet. Install
`hf_xet` by name and set `HF_XET_HIGH_PERFORMANCE=1`.

### 3.3 Model cache location

Models go to `~/models/` (gpt-oss) and `~/models-nemotron/`, **not**
`~/.cache/huggingface`, and the dir is pre-created by the login user.

**Why:** the vLLM container runs as root and writes the HF cache as root. During
the Earth-2 teardown this made `rm -rf` fail on every file and required `sudo`.
Pre-creating + bind-mounting keeps teardown a plain `rm -rf`.

---

## 4. Teardown of Earth-2 (completed)

`teardown-earth2.sh`, run on all three. Removed: NemoClaw/OpenShell/OpenClaw
CLIs + state + gateway unit, all sandboxes, openshell docker
containers/volumes/networks, `~/earth2-spark-ensemble`, all HF caches, all
container images.

Verified clean on all three: 0 images, 0 containers, ports 8080/4454/8001/8000
free, 0 stray files, no HF cache.

- Earth-2 repo was clean and fully pushed to `nv-drollins/earth2-spark-ensemble`
  before deletion — nothing lost.
- **Gotcha:** `nemoclaw uninstall` exits 0 while leaving the gateway process,
  `~/.config/openshell`, `~/.local/state/nemoclaw`, and a systemd user unit.
  Assert the wipe; don't trust the exit code.

---

## 5. Models

| Model | Repo | Weights | Role |
|---|---|---|---|
| **gpt-oss-120b** | `openai/gpt-oss-120b` | 196 GB | primary — Apache-2.0, non-Chinese vendor |
| **Nemotron-3-Super-120B** | `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | 80 GB | A/B comparison |

**Rejected:**
- `Nemotron-3-Ultra-550B-NVFP4` (352 GB) — leaves ~11 GB across the whole
  cluster for KV cache + activations + OS. Will not serve.
- `Qwen3-235B` (236 GB) — fits, Apache-2.0, but Chinese-vendor provenance
  undercuts the sovereignty pitch for a DC audience.
- `zai-org/GLM-4.6-FP8` (361 GB) — exceeds total cluster memory.

**Distribution strategy:** download **once** on the head, fan out over the CX7
ring (`distribute-model.sh`). Three internet pulls of 196 GB is slow and
venue-hostile.

---

## 6. Still to install

- [ ] vLLM container + Ray cluster across 3 nodes (one sharded endpoint)
- [ ] NemoClaw + OpenShell on head (`v0.0.124` — do NOT upgrade past this)
- [ ] Hermes sandbox (`--agent hermes`), per-agent profile
- [ ] Egress policy preset scoped to the vLLM endpoint
- [ ] Demo app: FastAPI + WS, document viewer, approval gate UI
- [ ] Synthetic document corpus (never real government data)
- [ ] Sovereignty ledger panel (tokens / cost avoided / bytes egressed = 0)

---

## 7. Keys and tokens

| Secret | Status | Note |
|---|---|---|
| `HF_TOKEN` | ✅ on all 3 nodes | validated: `nv-drollins`, nvidia org |
| NGC API key | ⬜ not yet needed | only if we pull an NGC container |
| GitHub token | ⬜ not yet needed | for committing the demo repo |

No secret is ever written into a committed file or echoed into logs.
