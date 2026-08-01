# T7 — Full store fetch (ceiling fix) + frames_done_d2 for w-fit-1

**Branch:** (see `git rev-parse --short HEAD` at commit)  
**No Quartus fit by w-geom.** w-fit-1 owns exclusive slot.

## What changed (RTL)

### `fpga/Plex_MiSTer/rtl/present_core.sv` — vertical ceiling fix
| | Pre-T7 (c5382bee class) | T7 product FRAME_H=480 |
|---|---|---|
| `V_STORE` | hard 240 | `FRAME_H` via `NATIVE_V_1TO1` |
| `py` | `scandouble ? (vc>>1) : vc` | **`vc`** when native |
| `STORE_Y_SCALE` | `(FRAME_H*65536)/240` = 2.0 | `(FRAME_H*65536)/V_STORE_I` = **1.0** |
| unique store_y | 240 even rows 0..478 | **480 rows 0..479** |
| `past_last_row` | `py >= 240` | `py >= V_STORE` |

Legacy `FRAME_H<=240` builds keep half-height path.

### Horizontal — NOT fixed (honest)
- `H_DE` remains **529** (Template/FBAR class).
- unique `store_x` remains **529 of 640** (~17.3% never unique).
- **Why not 640 DE:** `clk_sys=20 MHz`, refresh 60 Hz, V_total scandouble 524 → max H_total = `20e6/60/524 = 636` < 640.
- Full width needs **higher clk_sys** and/or new timing class — separate fit risk; not sneaked in here.

### `ddr_frame_store.sv` — already tip-correct
- Packs `frames_done_d2` (real swaps). **Must be in same RBF as T7 present_core.**
- Does **not** pack `bank_vsync_count`.

## Bandwidth (closes)

| Item | Number | Source |
|---|---|---|
| Full I420 frame | 624×480×1.5 = 449280 B | layout params |
| FPGA read @ 60 Hz | **26.957 MB/s** | 449280×60 |
| DDRAM_CLK | 90 MHz (pll outclk_2) | pll_0002.v |
| Peak 64-bit | 720 MB/s | 90×8 |
| 25% safe read budget | 180 MB/s | display-resolution.md model |
| Result | **26.9 ≪ 180** | PASS model |
| Unique Y lines | 240 → 480 (**2×**) | T7 |
| Line fill ESTIMATE | parent 10.0 µs ×2 ≈ 20 µs vs 63.8 µs line | still inside |

No LINE_COUNT change required for model close; silicon underrun remains parent-measured post-fit.

## Timing / STA
- Change is address-map localparams + mux on `py` — no new multiplies beyond existing scale path (scale becomes 1.0 constant-fold likely).
- **No fit run here.** w-fit-1: expect STA close similar to prior present_core; watch M10K line fills under 2× Y traffic.
- DE_LAG=3 **unchanged** (not re-swept; comment in present_core stands).

## O[4]
Still **not** wired to store geometry. Synthesis `FRAME_W/H=640/480` only.

## Gates (w-geom)
```
make define-parity
make quartus-sv-subset
# targeted:
./tests/unit/test_present_store_scale_math   # after build
./tests/unit/test_geom_frame_cost
python3 tests/unit/test_rtl_invariants.py    # or via make unit slice
./tests/unit/test_c5382bee_frames_done_pack.sh
```

## w-fit-1 handoff checklist
1. Fit **this branch tip** (present_core T7 + frames_done_d2 pack together).
2. Post-fit: `make post-fit-hierarchy` + `make post-fit-timing`.
3. NEW_RBF ∉ banned set; one menu deploy.
4. Parent eyes: glyph/period-3 contrast should collapse if 480 rows reach glass.
5. Daemon interval ledger: after RBF, expect `fd_semantics=SWAP_COUNTER` path scorable (p_d1≥0.5) if free-gate holds.
6. Do **not** claim full 640-column unique sample — still 529 until clock/timing work.

## ARM-only? 
**NO — RBF required** for both vertical ceiling and honest frames_done.
