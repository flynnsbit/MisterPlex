# Settled: elision guard + stub_busy (no fit)

**Branch tip:** `b436452b` · **Date:** 2026-08-02  
**Quartus hold:** ON · **Device:** not touched

---

## 1. Elision guard — red-before-green PROVEN

Gate: `scripts/check_plex_chrome_elision.py`  
Make: `make post-fit-chrome-elision FIT_RPT=… [MAP_RPT=…]`  
Unit: `tests/unit/test_plex_chrome_elision_guard.sh`

### Against c74c6863 live reports (the fit that elided RAM)

```
python3 scripts/check_plex_chrome_elision.py \
  --fit-rpt fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.fit.rpt \
  --map-rpt fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.map.rpt
# → CHROME_ELISION_REJECTED
# → plex_chrome present ALMs=5.3 regs=54 block_bits=0 M10Ks=0
# → map.rpt: 1026 stuck list_a/list_b bit(s)
true rc=1
```

| Case | true rc |
|------|--------:|
| LIVE c74c6863 fit+map | **1** RED |
| Fixture excerpt c74c6863 | **1** RED |
| Synthetic green 2 M10K / 8192 bits | **0** GREEN |
| Mutate green → 0/0 | **1** RED |
| Unit suite (all of above) | **0** |

**Wording discipline:** P1 on c74c6863 is **unmeasured** (NO-DATA), not “zero user-visible benefit.”  
P2 playback PASS on PRODUCT_NO_STUB is separate and stands on viewed pixels.

---

## 2. stub_busy — **TIED TO `1'b0`, NOT DELETED**

### Source (cargo of c74c6863 / tip)

`stream_path.sv` under `PRODUCT_NO_STUB` (`Plex.qsf` has `VERILOG_MACRO "PRODUCT_NO_STUB=1"`):

```systemverilog
// stream_path.sv:366-384 (`else of `ifndef PRODUCT_NO_STUB)
assign fs_swap = 1'b0;
assign stub_busy = 1'b0;   // ← TIE, not omit
assign stub_frames = 16'd0;
```

`Plex.sv:890-893` — pack **still includes** the bit (MSB-first, width 8):

```systemverilog
wire [7:0] telem_flags = {
	pps_valid, sps_valid, stub_busy, has_idr,
	audio_underrun, has_stream, has_audio, has_frame
};
// bit7=pps … bit5=stub_busy … bit0=has_frame
```

`Plex.sv:947`: `status_telem_r[23:16] <= telem_flags;`  
⇒ `stub_busy` lives at **`status_telem_r[21]`** (= flags bit5).

### ARM (unchanged masks)

`fpga_spi.cpp:2023`: `s.stub_busy = (flags & 32) != 0;`  // bit5  
`status_telemetry.hpp:52`: `kTelemFlagStubBusyBit = 5;  // PRODUCT_NO_STUB: tie 0, never delete`

### Post-fit report (c74c6863 / fit-nostub-chrome)

| Check | Evidence |
|-------|----------|
| `decode_stub` entity rows | **0** (instance removed) |
| Named net `stub_busy` in fit/map | **0 lines** (constant folded — expected for `assign = 1'b0`) |
| `status_telem_r[16]`…`[23]` | **present**, `PRESERVE_REGISTER on` for each including **`status_telem_r[21]`** |
| Telem ABI unit gate | `python3 tests/unit/test_telem_flags_abi.py` → **true rc=0** (order still `…,stub_busy,…` width 8) |

**Conclusion:** Bit position **kept**. Value is constant **0**.  
Had it been **deleted** from the concat, width would be 7 and `pps_valid`/`sps_valid` would shift — gate would fail; ARM would misread both. That did **not** happen.

---

## 3. Next-fit pre-registration (FROZEN baseline = c74c6863)

| Metric | c74c6863 baseline | Next-fit prediction (PLXC-live chrome RAM) | Notes |
|--------|------------------:|---------------------------------------------|-------|
| ALM | **14,354** | **16.0k ±1.5k** (Δ +1.5k…+3.5k) | Restore real list-scan comb; was 5.3 ALM folded |
| M10K | **197** | **199…209** (Δ **+2…+12**) | Dual `list_a`/`list_b` 64×64b; elision gate requires ≥1 M10K and ≥4096 bits |
| DSP | **43** | **43** (Δ 0) | Chrome is +0 DSP |
| clk_sys Fmax | **32.59 MHz** | **≥ 30 MHz** (must not collapse to stub-era 23.46) | Stub stays out |
| clk_ddr setup | **+0.559 ns** | **≥ +0.25 ns** | Half-cycle CDC still binds; do not raise clk_ddr |
| pll_hdmi setup | **+0.587 ns** | **≥ +0.20 ns** | Chrome stays on `clk_hdmi` post-ascal |
| PRESENT_PROFILE ledger | FLAT | **FLAT** (movement = bug) | Not a throughput fit |
| Elision gate on NEW fit.rpt | n/a (red on c74c) | **must rc=0** | Hard slot condition |
| P1 score | **unmeasured** | Parent glass: `#` bbox 32×32±1 @1080p | Viewed pixels only |

### Explicit non-justifications (struck)

- Do **not** cite historical “av-lock sustained” — `media_player.cpp:4245` emits `" clock=av-lock"` unconditionally (ERROR 20).
- Do **not** justify fabric decode as 480p CPU relief — ARM decode ~5.8% of ffmpeg bill; 9.57× headroom measured; honest case is **direct-play / higher tiers**.
- Do **not** treat raising `clk_ddr` as free headroom — binding path is half-cycle `clk_sys→clk_ddr` CDC (5.555 ns); more MHz **tightens** it.
- P1 c74c6863 = **unmeasured**, not null benefit.

### Slot still blocked until

1. Elision guard green on **new** reports (already red on c74c6863) — **done as precondition tooling**  
2. **`list_we` driven by product PLXC** (w-osd-hires ARM) — not `1'b0` / BOOT_DEMO-only  
3. Parent releases exclusive Quartus hold  

No fit requested from this note.
