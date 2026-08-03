# PLAYING parent runbook — one script, fail-closed

**Script:** `scripts/parent_playing_gate.sh`  
**Scores:** `scripts/hdmi_score_pair.sh` + `docs/fab-playing-parent-capture-contract.md`  
**Pair card (daemon):** `docs/evidence/p720-path-20260803/PARENT_DEPLOY_PAIR_540P.md`  
**Delivered geom:** `docs/evidence/p720-path-20260803/PMS_540_DELIVERED_GEOMETRY.md`

## Why this exists

The fabric RBF and the ARM daemon deploy through **different** scripts. The 540p
PMS ladder lives in the **daemon**. Deploying a 960×540 fabric against a daemon
that only knows 240/480 makes PMS send the wrong geometry into a frozen content
window — glass looks like **D2/D3** (scaler bug) when the real fault is **pair**.

This script refuses to emit a fabric taxonomy unless:

1. Device reachable; baseline `Plex_rel.rbf` matches `c5382bee*`; live RBF matches `EXPECT_RBF_MD5`
2. `video_mode=0`
3. `/dev/video0` free (else **UNKNOWN_GRABBER**, not fabric)
4. Live `misterplexd` **binary** contains `540p`/`960x540` (w-path ≥ `8e62f61b`)
5. Conf: `DECODE=960x540` + `OSD_CONTROL=off` (+ bitrate ≥2000 if set)
6. Log: request path `960x540` **and** `MEASURED_DELIVERY 960x540` (not 720×404)

Then: NEG → P1 pair 1 s → optional P2 `kill <PID>` only.

## Exit codes (do not collapse)

| rc | Meaning |
|----|---------|
| **0** | `VERDICT=A_FABRIC_PLAY_OK` |
| **1** | Scored product non-A (B/C/D/CONTROL/…) — **glass** result |
| **2** | Usage |
| **3** | `UNKNOWN_GRABBER` — never fabric |
| **4** | `PRECOND_*` — pair/device/delivery; **never fabric** |
| **5** | P2 nosignal after P1 picture (`B1`) |

## Parent command (device up)

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-osd   # or integ tree with this script

# 1) Deploy PAIR (order flexible; both required before gate)
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh /path/to/fit/Plex.rbf
./scripts/deploy_misterplexd.sh /path/to/w-path/build/arm/misterplexd

# 2) Conf on device (see pair card)
#    DECODE=960x540
#    OSD_CONTROL=off
#    WEAK_BITRATE=2000   # knee: <2000 → measured 720x404
# Cast HD 16:9 motion title; wait until MEASURED_DELIVERY appears in log.

# 3) One shot
EXPECT_RBF_MD5=<live-or-prefix> \
  scripts/parent_playing_gate.sh full
echo "true rc=$?"

# Artifacts: docs/agent-evidence/playing-gate-<ts>/
# Grep: SUMMARY VERDICT=... DELIVERY=960x540
```

Subcommands: `preflight` | `neg` | `p1` | `p2` | `baseline-ab` |
`score-only T0 T1` | `offline-selftest` (no device).

## baseline-ab (known-good then candidate)

Standing rule: always keep `Plex_rel.rbf` (`c5382bee*`) for rollback. **baseline-ab**
goes further — it **scores** the baseline live core, then the candidate, and prints
both verdicts with raw metrics so a non-A candidate answer starts with
“regression vs already-like-that?”

```bash
# Leg 1 — load known-good as LIVE (copy/menu load Plex_rel → Plex.rbf), then:
EXPECT_RBF_MD5=<candidate-prefix> \
  scripts/parent_playing_gate.sh baseline-ab
# Script scores baseline, then requires live md5 == EXPECT (no auto-deploy).
# After baseline leg: deploy candidate RBF (DEPLOY_LOAD=menu), optionally:
#   BASELINE_AB_SWITCH_TIMEOUT_S=300   # poll until live matches EXPECT
```

Fail-closed:

| Failure | rc | Meaning |
|---------|----|---------|
| Baseline not live / missing rel | **4** | `PRECOND_*` — fix load order |
| Baseline grabber fail | **3** | `UNKNOWN_GRABBER` — not fabric |
| Baseline `E_NOSIGNAL` | **4** | `PRECOND_AB_BASELINE_NOSIGNAL` — **not** candidate evidence |
| Candidate pair/delivery | **4** | same as full preflight |
| Candidate scored non-A | **1** | glass; compare `SUMMARY_AB BASELINE=… CANDIDATE=…` |
| Candidate A | **0** | product PASS |

Baseline leg **skips** the 540p daemon/delivery preflight (rel is pre-720p-class).
Candidate leg runs full pair + `MEASURED_DELIVERY 960x540`.

## Offline check (build host)

```bash
scripts/parent_playing_gate.sh offline-selftest; echo "true rc=$?"
tests/unit/test_parent_playing_gate.sh; echo "true rc=$?"
```

## Never

- Bare `ffmpeg -frames:v 1` (false black)
- `killall` / `pkill` misterplexd
- Scoring glass when precond rc=4
- Treating soft-skip 77 as PASS
- Treating a failed **baseline** leg as evidence about the **candidate**
