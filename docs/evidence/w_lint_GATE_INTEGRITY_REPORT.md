# w-lint GATE INTEGRITY AUDIT (promotion blocker)

- **branch:** `w-lint-gate-integrity`
- **tip:** `3b11cf7af56ac59f9ec9483c385815e2a8eed547`
- **date:** 2026-07-31
- **scope:** host/source only — no SSH to 192.168.1.183, no Quartus
- **Rule 0:** every rc below captured as `cmd; echo "true rc=$?"` (never through a pipe)

## 1. Headline — running bitstream identity

### What the gate can and cannot see

| Signal | Object inspected | Identifies running RBF content? | Blind-green how? |
|---|---|---|---|
| On-disk `md5sum …/Plex*.rbf` | file on SD | **NO** | disk ≠ fabric |
| `/tmp/CORENAME` | string | **NO** — always `Plex` | every build identical |
| `/tmp/RBFNAME` | string | **NO** — always `Plex` | every build identical |
| `/tmp/RBFNAME` mtime | reload event | reload only, not which file | claim couples mtime |
| Claim `.running_core_claim` | last plexctl load record | interim only | wrong if load bypassed claim writer |
| Live daemon `/proc/PID/exe` | running binary | daemon only | correct for ETXTBSY/dead |
| HTTP `/resources` | live process | liveness only | 200 on mixed black screen |
| Pair table (core family × daemon family) | claim core + live daemon | **mixed family** | catches SPI core claim + DDR daemon |
| PLXC @ `0x300FF130` | fabric register | **YES** when RTL present | **absent on c5382bee** (fit-gated) |
| Bank1 peeks `0x30040000`/`0x30080000` | DDR contents via devmem | forensic tier only | residue/not content hash |
| HDMI fingerprint | pixels (parent grabber) | can catch mixed visually | **parent-only** |

**Honest deliverable (landed):** without PLXC (or parent `VIDREG_CORE_ID=` inject from a live PLXC read), `scripts/video_regression.sh verify` **refuses FULL_PASS**:

| Outcome | `true rc` | Meaning |
|---|---|---|
| FULL_PASS + VERIFIED_PLXC | **0** | fabric path proven + pair/liveness OK |
| CORE_IDENTITY_UNVERIFIED | **2** | pair/liveness OK; **fabric content hash unproven** — not promote-alone |
| FAIL | **1** | dead daemon, mixed pair, stale claim, HTTP dead, … |
| NO-DATA | **4** | empty SSH/hash (not a mismatch) |

**What still needs hardware/RTL (cannot fake on host):**
- **PLXC build-ID register** at doorbell+0x130 (`0x504C5843` + stamp) — design in `docs/core-running-bitstream-identity.md`. Rides next exclusive fit; do not open a slot for this alone.
- Until then, **parent HDMI** is the only content-level mixed-state detector for same-family wrong bitstream.

### Host RBG (measured this lane)

```
bash tests/unit/test_video_regression_liveness.sh; echo "true rc=$?"
```

| Case | true rc |
|---|---|
| OLD disk-only while daemon DEAD (defect repro) | 0 |
| NEW: dead daemon | **1** |
| NEW: SPI claim + DDR daemon (mixed) | **1** |
| NEW: DDR claim + SPI daemon (mixed) | **1** |
| NEW: coherent pair, no PLXC | **2** REFUSE FULL_PASS |
| NEW: VIDREG_CORE_ID=ddr + DDR pair | **0** FULL_PASS |
| NEW: empty daemon-disk SSH | **4** NO-DATA |

## 2. `fix/gate-liveness` (`323c14f1` / tip `478e7dbf`)

**CLOSE — do not merge as-is.** Content (live `/proc` + HTTP, not disk alone) is **superseded and extended** on `w-lint-gate-integrity` (deleted-tolerant exe, pair table, UNVERIFIED→rc=2, pin track, NO-DATA). Merging would **clobber** `expected_commands` (branch 99 vs protected 124) and drop identity work. Evidence: `git diff w-lint-gate-integrity fix/gate-liveness -- scripts/video_regression.sh` is ours ≫ theirs.

## 3. Daemon pin track (no hand-edit per deploy)

- `artifacts/validated-pair/CURRENT` + `ACCEPTED_DAEMONS`
- `scripts/pair_pin_update.sh --from-live` (shape-safe SSH join; empty→4)
- `pair_ship_policy.sh` PRIMARY row resolves CURRENT prefix (`865d4c8a`)
- Unknown daemon → pair-unknown **FAIL** (not accept-anything)

## 4. Soft-skip / CRITICAL gap

| Gate | Object | Can look green while broken? | true process contract |
|---|---|---|---|
| `live-pms-baseline-profile` | live PMS stream (needs KEY) | was: make-unit **rc=0** + PASS_INCOMPLETE label | **now process_rc=78** PASS_INCOMPLETE |
| `core_conf_geometry` unknown md5 | map TSV | no — **rc=77 SKIP-NOT-PASS** (kept) | never scored as pass |
| motion UNSCORED | pixels | promotion treats 77 as HARD FAIL | promote path |

`scripts/run_with_skip_summary.py`: CRITICAL inventory gap ⇒ **exit 78**, never 0.

Host-only without PMS key: `make unit-unlocked` (documented).

## 5. Compile-fail must be RED

| Guard | Status | Evidence |
|---|---|---|
| `scripts/run_verilator.sh` PINNOTFOUND/%Error → rc=2 | enforced | static + **RBG fake verilator** in `test_gate_false_green_guard.py` |
| `lib_rtl_sim_gate.sh` missing VL → 3 or 77 (never 0) | enforced | false-green guard scan |
| bare `verilator` after wrapper | banned | false-green guard |
| scanout freeze TB | uses wrapper | freeze script sources RUN_VERILATOR |

## 6. Other gates — blind-while-green class (summary)

| Check | Inspects | Blind-green residual? |
|---|---|---|
| video_regression verify | claim+live daemon+pair+optional PLXC | **rc=2** without PLXC (not full green); mixed family **rc=1** |
| promotion_gate_check | S99 LIVE hook, pair, visual/motion | conf-keys FAIL; motion not elif-dead; glue shape |
| deploy_misterplexd | LIVE hook from S99, v2 root | fixed on this branch (main still decoy until merge) |
| boot_hook_policy | S99 USER_SCRIPT | decoy underscore never LIVE |
| pair_visual_gate | pixels | menu_color_bars reject; no orange_cy pose bound |
| build_rbf_remote STA | STA file | missing STA **HARD FAIL** (not 0 neg slack) |
| plexctl supervise TERM | signal | exit 143/130 not 0 |
| measure_c2 counts | log greps | three-way NO_DATA (not `\|\| echo 0`) |

## 7. Rollcall

Never hand-edit count. `python3 tests/unit/test_unit_rollcall.py --write-expected` after adding tests. Unregistered command → RED `UNREGISTERED_COMMAND`.

## 8. Parent device commands (agent does not run)

```bash
bash scripts/video_regression.sh verify; echo "true rc=$?"
# pre-PLXC: expect true rc=2 CORE_IDENTITY_UNVERIFIED (not FULL_PASS)
# mixed SPI core + DDR daemon: expect true rc=1 FAIL pair-mismatch

# optional after identity RBF / live PLXC peek:
VIDREG_CORE_ID=ddr bash scripts/video_regression.sh verify; echo "true rc=$?"

MISTER_HOST=192.168.1.183 bash scripts/pair_pin_update.sh --from-live
```

## 9. Needs next fit (not this lane)

PLXC @ 0x300FF130 — only durable running-bitstream content id without HDMI.
