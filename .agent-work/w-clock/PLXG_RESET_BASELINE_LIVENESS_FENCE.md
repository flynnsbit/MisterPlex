# PLXG reset baseline — liveness/ownership fence (rd-duck)

**Status:** OPEN gap · **not** stale-live closure · **not** B20_CLOSED  
**w-clock role:** consume `geom_live_*` honestly; do **not** invent boot nonce ABI  
**Owners to close:** w-mem (poller) + w-path (host epoch/nonce/ACK protocol)

## MEASURE_REF (poller source — sibling, read-only)

| Field | Value |
|-------|--------|
| Worktree | `/home/flynnsbit/Projects/MisterPlex-wt-mem` |
| HEAD_BRANCH | `w-mem-720p-abi` |
| HEAD_SHA | `5f3f0885` (at measurement; re-pin if drifted) |
| File | `fpga/Plex_MiSTer/rtl/plxg_ddr_poller.sv` |

This branch (`w-clock-bump`) does **not** carry `plxg_ddr_poller.sv` (L0 elsewhere).

## Verdict (rd-duck — verified against source header + S_WAIT_V)

### What retained DDR does **not** do (product path)

Header + `S_WAIT_V` / `S_BASELINE` (MEASURED quote intent):

- First *valid coherent* snapshot after reset → **BASELINE** `last_*` **without** `commit`
- Latch resets `live_valid=0` on FPGA reset (`present_geom_latch.sv` ~171)
- Therefore retained DDR does **not** directly assert `plxg_live` / `live_valid` on the product path
- `FAULT_PLXG_NO_BASELINE` is the RED twin that would promote retained immediately

### Explicit race still OPEN (source admits it)

`plxg_ddr_poller.sv` header lines 20–22 (MEASURED on wt-mem@5f3f0885):

> LIMITATION: passive baseline cannot distinguish a fresh host record written  
> just before the first poll from retained DDR (reset/publication race). A  
> true host↔FPGA boot nonce/ACK would close that; not claimed here.

Mechanism (INFERRED from measured states, arithmetic of protocol only):

1. FPGA reset: `boot_baseline_done=0`, `last=(0,0)`, latch `live_valid=0`
2. Host writes fresh PLXG `(epoch=1, seq=K)` before first poll completes
3. First coherent poll → `S_BASELINE` swallows `(1,K)` as baseline, **no commit**
4. That single post-reset publish/disable **never goes live**
5. Coupled bank / B20 swap waits until **another** distinct `(epoch,seq)`

Empty-first path is improved (empty completes baseline so first valid *commits*) — that is a different defect class (`FAULT_PLXG_EMPTY_NO_BASELINE`). The race above is **valid-first-before-poll**.

### Daemon restart **without** FPGA reset (separate gap)

- Latch keeps prior `live_valid` / geometry (no fabric reset)
- Seq seeding can make next publish distinct → may promote
- Host **epoch defaults to constant 1** (header: epoch≠0 does not prove fresh-this-boot)
- **No boot/session nonce** in PLXG record for fabric ownership
- Treat as **liveness/ownership** gap, **not** “stale-live closed”

## What would prove closure (do not claim until implemented)

Any one of:

1. **Boot nonce / session epoch** in PLXG (host stamps unique per daemon or per FPGA-observed boot) + poller baselines only matching retained-without-nonce class, **or**
2. **Explicit ACK** from fabric after baseline (“baseline done, republish”) so host always second-publishes, **or**
3. Documented **mandatory second-publish** protocol after every FPGA reset with E2E TB using real poller (not PlxgPollerSim first-valid)

Hierarchy TB must cover:

- Retained DDR present + no host write → baseline, `live_valid=0`
- Fresh write before first poll → today FAIL liveness (swallowed); after fix COMMIT or forced republish
- Daemon restart no FPGA reset → ownership story explicit

## Impact on w-clock B20 (this lane)

| Situation | present_core effect |
|-----------|---------------------|
| `live_valid=0` after swallowed first publish | `b20_visual_hold` off (no live); `beam_de_idle` may free-run app if `!swap_pending` — **idle geometry**, not stale live paint |
| Bank doorbell waiting on never-live PLXG | swap never arms on geom epoch — **stall**, not wrong DE island |
| Daemon-only restart | live may stay prior session geometry until new seq — **ownership**, not NBA lag |

NBA lag fix (`8736e9e3`) is orthogonal. **B20_CLOSED stays false.**

## Honesty gates

- `assets/b20_visual_two_phase_wall.json` → `plxg_reset_baseline_liveness_closed: false`
- `tests/unit/test_plxg_reset_baseline_open.sh` — fails if someone claims closed without nonce/ACK evidence
- Do **not** treat PlxgPollerSim “first valid commits” as product reset proof (prior atomic contract)

## w-clock will NOT unilaterally

- Edit `plxg_ddr_poller.sv` (w-mem)
- Invent doorbell/PLXG high-word nonce bits (w-path ABI)
- Claim stale-live or reset liveness CLOSED on baseline-without-commit alone
