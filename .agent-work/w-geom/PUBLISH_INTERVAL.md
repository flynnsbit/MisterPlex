# Publish-interval instrumentation + frames_done correction (w-geom)

**Branch:** `w-avsync-hdmi-measure`  
**Gates:** `build/test_publish_interval_ledger` **true rc=0**  
**Log:** `.agent-work/w-geom/publish_interval_gate.out`

---

## 1. RTL: `frames_done` is SWAP count (verified)

```271:287:fpga/Plex_MiSTer/rtl/ddr_frame_store.sv
			if (vsync_pulse && swap_pending && pending_ready_s2) begin
				// ...
				frames_done <= frames_done + 16'd1;
				vsync_toggle <= ~vsync_toggle;
			end else if (vsync_pulse) begin
				vsync_toggle <= ~vsync_toggle;
			end
```

- `frames_done++` **only** on successful swap.  
- `vsync_toggle` flips on **every** vsync.  
- PLXD packs `frames_done_d2`, **not** `bank_vsync_count` (pack comment ~1036–1043).

**Therefore:** Δ`frames_done` between consecutive publishes is typically **1** and carries **zero** hold-length information.  
Parent brief point-3 fabric hist via `frames_done` edges is **INVALID**.  
Tools `scripts/poll_plxd_frames_done_hold.sh` and CSV mode of `tools/fabric_frames_done_hold_hist.py` now **exit 2** with `INVALIDATED_HOLD`.

### Stale comment fixed

`host/libmisterplex/ddr_bank_release_select.hpp` no longer claims product  
`frames_done` *is* `bank_vsync_count`. Documents historical fault pack + product truth.  
`input_mailbox.hpp:107` / `mailbox_abi_spec.hpp:97` already correct (“monotonic swap count”).

### Other readers audited

| location | reading | action |
|---|---|---|
| `input_mailbox.hpp` | swap count | OK |
| `mailbox_abi_spec.hpp` | swap count | OK |
| `media_player.cpp` handoff | “frames_done is swap count” | OK |
| `test_ddr_playback_bank_select.cpp` | packs vsync as fd | **comment only** — LEGACY FAULT MODEL for stale-free ARM gate |
| prior w-geom fabric hold tool | treated fd edges as holds | **INVALIDATED** |

### Is `vsync_toggle` ARM-readable?

**No, not without RBF.**  
- Internal `reg vsync_toggle` → CDC → `bank_vsync_count++`  
- PLXD reserved `[47:36] = 12'd0` — vsync count not exported  
- `debug_state` = format/line/state_ddr, not vsync  

To expose fabric holds: pack `bank_vsync_count` into PLXD reserved (fit required — **not authorised**).  
Judder root-cause experiment is **publish-interval** on ARM (below).

---

## 2. Decisive experiment: publish intervals

Reasoning accepted: async latch is deterministic given inputs; pixel-clock vsync does not jitter.  
Hold irregularity ⇒ **when daemon doorbelled**.

### Instrumentation (ARM-only, no fit)

- `host/libmisterplex/publish_interval_ledger.hpp` — fixed 4096-deep ring, `steady_clock` µs  
- `MediaPlayer::publishDdrFrame` on **success**: `pubInterval_.note(us)` (VDSO-class clock)  
- Session end always logs:
  - `media: publish_interval notes=… mean_ms=… sigma_ms=… p_ge50=… verdict=… tag=measured phase=session_end`
  - `media: publish_interval_corr short_lt25_n=…` (hold=1 / pending overwrite class)
- Optional mid-session every 240 pubs if `MISTERPLEX_PUBLISH_INTERVAL_LOG=1`

### Pre-register (committed before device measure)

| result | verdict |
|---|---|
| σ&lt;4 ms, ≥99% in 41.67±8 ms, **p_ge50 &lt; 0.03** | **ARM_CLEAN** — late-publish FALSIFIED; look vsync domain (needs RBF for vsync count) |
| **p_ge50 ∈ [0.09, 0.11]** | **ARM_LATE_MATCH_HOLD45** — matches ~9–11% hold 4/5; fix scheduling/CPU **not** RTL |
| p_ge50 &gt; 0.11 or p_ge83 &gt; 0.02 | **ARM_LATE_OR_BIMODAL** — late + catch-up; check corr shorts |
| p_ge50 ∈ (0.03, 0.09) | **ARM_LATE_MILD** |

Ideal period uses **frameRate=24.000** → 41.666… ms (not 23.976).

Host gate synthetic: clean → `ARM_CLEAN`; 10% late → `p_ge50=0.0982` → `ARM_LATE_MATCH_HOLD45`.

### Correlation (hold=1 class)

`pending_bank <= pending_bank_s2` on new doorbell while pending can overwrite.  
Short publish interval (&lt;25 ms) should neighbor catch-up; ledger emits `publish_interval_corr`.

---

## 3. Roadmap (do not guess — measure)

| verdict | FPGA H.264 decode helps? |
|---|---|
| ARM_LATE_* | **Yes candidate** — frees CPU so publish stays on 41.67 ms |
| ARM_CLEAN | **No for judder** — irregularity not in publish schedule; need vsync-domain observability (RBF) or other |

---

## 4. Parent commands (agent does not touch device)

```bash
# Deploy daemon with this SHA (parent path). Then 60s 480p soak.
# Session end log must contain:
grep -E 'publish_interval' /path/to/misterplexd.log

# Optional denser mid samples:
MISTERPLEX_PUBLISH_INTERVAL_LOG=1   # in conf/env before start

# Expect one of:
#   verdict=ARM_CLEAN
#   verdict=ARM_LATE_MATCH_HOLD45
#   verdict=ARM_LATE_MILD | ARM_LATE_OR_BIMODAL | ARM_OTHER
```

**Do not** run `poll_plxd_frames_done_hold.sh` for holds (rc=2 by design).

---

## 5. Files

| path | role |
|---|---|
| `host/libmisterplex/publish_interval_ledger.hpp` | ring + verdict |
| `arm/misterplexd/media_player.{hpp,cpp}` | note on success; dump session end |
| `host/libmisterplex/ddr_bank_release_select.hpp` | stale comment fixed |
| `tests/unit/test_publish_interval_ledger.cpp` | red/green + pre-register |
| fabric poll/hist tools | INVALIDATED exit 2 |
