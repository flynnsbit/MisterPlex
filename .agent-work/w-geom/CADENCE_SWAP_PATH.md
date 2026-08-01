# present_cadence vs DDR swap — verify + fabric hold experiment (w-geom)

**Branch:** `w-avsync-hdmi-measure`  
**Gates (true rc direct):**
- `tests/unit/test_cadence_swap_path_source.sh` → **rc=0**
- `build/test_cadence_swap_path` → **rc=0**
- `tools/fabric_frames_done_hold_hist.py --self-test` → **rc=0**

Logs: `.agent-work/w-geom/cadence_swap_source.out`, `cadence_swap_path.out`, `fabric_hold_selftest.out`

Parent HDMI (caller_supplied): plateau mean 2.517, ratio2:3=1.54, frac hold≥4 = 130/1263 ≈ **0.1029**. Loss separate (0.07%) — this is **judder only**.

---

## 1. Claim verification — r-misterfin is **CORRECT**

### What decides a bank swap (product DDR)

```271:286:fpga/Plex_MiSTer/rtl/ddr_frame_store.sv
			if (vsync_pulse && swap_pending && pending_ready_s2) begin
				disp_bank <= pending_bank;
				// ...
				frames_done <= frames_done + 16'd1;
```

No `advance_unique`, no `content_fps`, no `present_cadence`.

### How `vsync_pulse` is driven

```283:287:fpga/Plex_MiSTer/rtl/present_core.sv
		.vsync_pulse(fstart),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		// ...
		.frames_done(ddr_frames_done),
```

`fstart` = `colorbars.frame_start` (display raster), **not** cadence.

### What `present_cadence` actually drives

```116:125:fpga/Plex_MiSTer/rtl/present_core.sv
	present_cadence cadence (
		// ...
		.advance_unique(advance),
		.display_index(disp_i),
		.content_index(cont_i)
	);
```

- `cont_i` → `colorbars.content_index` (bars motion only)  
- `advance` → `stat_advance` only (`present_core.sv:437`)  
- Top-level **ties off** stats: `Plex.sv:1023`  
  `wire _unused = |{disp_i, cont_i, advance, ...`

### Explicit product policy

```230:231:fpga/Plex_MiSTer/Plex.sv
// Legacy cadence input is now fixed; the daemon handles exact content pacing.
wire [7:0] content_fps = 8'd24;
```

### Host twin is test-only on the product path

- `host/libmisterplex/cadence.hpp` — **no** `arm/` includes (grep clean)  
- Referenced from `tests/unit/test_cadence.cpp` (+ this gate)  
- Same defect class as `rawPipeDesynced` unit-only: **green tests, unwired product path**

**Definitive:** DDR display cadence is **async vsync re-latch** when a doorbelled bank is prep-ready. Strict 3:2 exists in RTL/host and is unit-tested, but it does **not** schedule swaps.

---

## 2. Wire `present_cadence` into swap? (a)(b)(c)

| | |
|---|---|
| **(a) Correct?** | Yes for film-style **strict 3:2** display schedule: only promote `pending→disp` on `advance_unique && pending_ready`. |
| **(b) Safe?** | Safe **iff** swap still requires `pending_ready_s2` (never show unprepared bank). Late frames: miss cadence slot → either extend previous hold (still judder) or skip (frame loss — worse). Does **not** fix supply stalls. |
| **(c) Worth it?** | **Only if fabric hist shows device-side hold≥4.** If fabric is pure {2,3} and only HDMI shows 4/5, that is capture/tear bias — **do not fit**. |

Model evidence (host gate, pre-register printed first):

| case | frac_ge4 | ratio2/3 | notes |
|---|---|---|---|
| C2 strict cadence | **0.0000** | **1.00** | cannot make parent 1.54 ratio |
| C3 async healthy free-gated | **0.0000** | ~1.00 | mean 2.50 |
| C4 async + late pub/ready | **0.1034** | 1.25 | **matches parent HDMI ge4 0.1029** |
| C5 cadence-gated + same jitter | **0.0004** | 1.00 | kills almost all ge4 |

So wiring cadence **can** smooth judder **if** the irregularity is real on fabric. It is **not** justified until the fabric experiment runs.

**No RBF authorised** from this report alone.

---

## 3. Fabric measurement (the deciding experiment)

### Constraint (quoted RTL)

`bank_vsync_count` increments on vsync in `ddr_frame_store.sv` but PLXD packs **`frames_done` (swap count)**, deliberately **not** vsync count (comment ~1036–1037: packing vsync faked liveness during freeze).

So “vsyncs between `frames_done`” on device today =

`round(Δmono_ms / T_vsync_ms)` with  
- `frames_done` **measured** from PLXD  
- `T_vsync` **DEFAULT_ASSUMED 1000/60** unless parent measures blanking

### Pre-register (printed before any device binning)

| band | frac hold≥4 | meaning |
|---|---|---|
| healthy | [0.00, 0.03] | fabric regular 2/3 → HDMI 4/5 is instrument |
| hdmi_match | [0.08, 0.13] | fabric matches parent HDMI → device judder real |
| w-geom lean | [0.05, 0.15] | if pfps&lt;24 / prep stalls (prior 480p soak) |

**w-geom prediction before parent runs:** lean **device band** if 480p `pfps≈23.x`; if 240p locked pfps≈24 and prep never stalls, lean **healthy**.

### Parent commands (agent does not run)

```bash
# 1) During steady 480p playback (OCR fixture, FORCE_SCALE=1, product core):
OUT="$PWD/.agent-work/w-geom/fabric_fd_hold_480p.csv" \
DURATION_S=60 PERIOD_MS=2 \
  ./scripts/poll_plxd_frames_done_hold.sh

# 2) Score (host):
python3 tools/fabric_frames_done_hold_hist.py \
  --csv "$PWD/.agent-work/w-geom/fabric_fd_hold_480p.csv"

# Optional if you measure vsync period from HDMI timing:
#   --t-vsync-ms 16.667
```

Requires `devmem2` on MiSTer and live Plex core. CSV columns: `mono_ms,frames_done`.

Self-test already green: healthy → `FABRIC_HEALTHY_2_3`; jitter10% → `FABRIC_MATCHES_HDMI_GE4`.

---

## 4. What not to conflate

| | |
|---|---|
| Frame **loss** | separate (0.07% parent); scanout skip free-gated was KILLED earlier |
| Frame **judder** | hold length variance; this doc |
| `drops` / `publish_misses` | blind to pure hold-length irregularity |

---

## 5. Deliverables

| path | role |
|---|---|
| `tests/unit/test_cadence_swap_path.cpp` | C2–C5 models + pre-register |
| `tests/unit/test_cadence_swap_path_source.sh` | C1 source greps + model |
| `tools/fabric_frames_done_hold_hist.py` | fabric CSV scorer |
| `scripts/poll_plxd_frames_done_hold.sh` | parent PLXD poll → CSV |
| Makefile | `test_cadence_swap_path` in unit-unlocked |
