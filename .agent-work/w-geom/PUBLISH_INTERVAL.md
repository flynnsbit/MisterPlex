# Part 2 — Publish-interval experiment (judder root-cause)

**Branch:** `w-avsync-hdmi-measure` @ `024ae42f`  
**Gates:**  
- `build/test_publish_interval_ledger` true rc=0  
- `build/test_present_store_scale_math` true rc=0  
- `scripts/score_publish_interval_log.sh` smoke true rc=0  

## frames_done correction (verified)

RTL (`ddr_frame_store.sv`):
- `frames_done++` **only** inside `if (vsync_pulse && swap_pending && pending_ready_s2)`
- `vsync_toggle` flips on **every** vsync (swap arm + else-if)

⇒ Δ`frames_done` between publishes ≈ 1, **zero hold info**.  
Stale comment in `ddr_bank_release_select.hpp` **fixed** (no longer claims fd==bank_vsync_count).  
`vsync_toggle` / `bank_vsync_count` **not** packed to ARM PLXD without RBF.

## Why publish timing (not latch)

Swap only on `vsync_pulse`. Async latch is deterministic given inputs; pixel-clock vsync does not jitter.  
Irregular 2/3 holds with adjacent-equal excess ⇒ **when ARM doorbelled**.

## Instrumentation (ARM-only)

On **successful** `publishDdrFrame` (after doorbell/swap_req path returns ok):

- `steady_clock` µs into 4096 ring (`publish_interval_ledger.hpp`)
- Session end logs:
  - `media: publish_interval … p_ge50=… verdict=… phase=session_end`
  - `media: publish_interval_hist …`
  - `media: publish_interval_acf lag1=…`
  - `media: publish_interval_corr …`
- Optional:
  - `MISTERPLEX_PUBLISH_INTERVAL_LOG=1` → mid sample every 240 pubs
  - `MISTERPLEX_PUBLISH_INTERVAL_DUMP=/path/mono_us.txt` → raw timestamps

## Pre-register (committed before device measure)

| result | verdict |
|---|---|
| **P(iv>50ms) ∈ [0.09, 0.11]** | **ARM_LATE_MATCH_HOLD45** — late publish CONFIRMED; fix CPU/schedule **not** RTL |
| **P(iv>50ms) < 0.03** | **ARM_CLEAN** — late-publish **DEAD**; next is vsync domain (RBF for vsync count) |
| else | ARM_LATE_MILD / ARM_LATE_OR_BIMODAL / ARM_OTHER — inspect hist+acf |

Ideal period: **1000/24 = 41.666… ms** (`frameRate=24.000`, not 23.976).

### Autocorr pre-register (before measure)

| shape | lag1 acf |
|---|---|
| clean metronome | ≈ 0 |
| late + catch-up short (synthetic gate) | **negative** (long then short) |
| bursty clustered lates | **positive** (long then long) — would explain (2,2) adjacent-equal excess if both intervals long enough to force hold=2 twice |

Parent’s bands accepted; not disputed.

## Parent commands (agent does not touch device)

```bash
# 1) Build+deploy misterplexd from tip 024ae42f (or later).
# 2) Optional denser mid logs / raw dump:
#    export MISTERPLEX_PUBLISH_INTERVAL_LOG=1
#    export MISTERPLEX_PUBLISH_INTERVAL_DUMP=/media/fat/misterplex/pub_iv_mono_us.txt
# 3) >=60 s 480p playback (frameRate=24.000 fixture), then stop stream so session_end fires.
# 4) Score:
scripts/score_publish_interval_log.sh /path/to/misterplexd.log

# Or manual:
grep -E 'publish_interval' /path/to/misterplexd.log | tail -20
```

**Do not** use `poll_plxd_frames_done_hold.sh` (INVALIDATED, rc=2).

## Roadmap implication

| verdict | Does FPGA H.264 decode help **judder**? |
|---|---|
| ARM_LATE_* | **Candidate yes** — frees CPU so publish stays on 41.67 ms |
| ARM_CLEAN | **No for judder** — publish schedule clean; need vsync-domain observability |

Note: Part 1 (240-line store fetch) is **orthogonal** to judder. Even if ARM_CLEAN, glass still lacks odd store rows until RBF.
