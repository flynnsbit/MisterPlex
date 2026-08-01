# PRODUCT_NO_STUB / dark-silicon — w-fit scope (no fit requested)

**Date:** session continuation · branch `w-fit-ceiling-fd-min`  
**Baseline fit:** RBF `8fdf440f` · `fpga/Plex_MiSTer/remote_out/fit-t7b-prog480/Plex.fit.rpt`  
**Slot:** NOT requested.

## 0) ≤10-line prior finish

- Next-fit prep: NBA hold + comb dequant already in `8fdf440f` → no fit justified.  
- Fabric H.264 inventory doc + regenerating gate shipped.  
- This task: prove/kill `decode_stub` dark silicon + scope `PRODUCT_NO_STUB` reclaim.

## 1) Fit table verified (quoted from fit.rpt entity rows)

| entity | ALM needed | M10K | DSP | block bits |
|--------|----------:|-----:|----:|-----------:|
| sys_top | 23584.6 | 465 | 44 | 2,997,709 |
| emu:emu | 16784.2 | 406 | 11 | 2,613,184 |
| stream_path:spath | 12268.0 | 303 | 2 | 2,387,904 |
| decode_stub:stub | **9216.9** | **268** | 1 | 2,124,800 |
| └ dpb_mem_rtl_0 | 128.7 | **256** | 0 | 2,097,152 |
| bitstream_fifo | 33.7 | 32 | 0 | 262,144 |
| ddr_bitstream_reader | 541.0 | 0 | 0 | 0 |
| present_core | 3604.4 | 103 | 9 | 225,280 |
| ddr_frame_store | 3501.3 | 96 | 6 | 159,744 |
| ascal | 1936.2 | 43 | 23 | 315,488 |

M10K arithmetic: 2,097,152/256 = **8192** bits/block; 262,144/32 = **8192**. Free M10K = 553−465 = **88**.

## 2) Dark-silicon verdict (product pixels)

### PROVED: cannot affect product HDMI pixels under shipping `DDR_FRAME_STORE=1`

| Check | Evidence |
|-------|----------|
| Product store ignores `fs_wr_*` | `present_core.sv` DDR branch: `assign fs_wr_ready=1'b1`; `ddr_frame_store` port map has **no** `.wr_en(fs_wr_en)` / `.swap_banks(fs_swap)`. Those exist only in `#else` legacy `frame_store`. |
| `ddr_swap` cannot latch host | `Plex.sv`: `assign ddr_swap=1'b0; assign ddr_wr_en=1'b0` under `DDR_FRAME_STORE`. `host_owns_fs` only sees `f1_swap \| ddr_swap`. |
| Parent “first DDR swap latches host_owns_fs” | **Corrected:** false under shipping macro. Product ARM frames use doorbell inside `present_core`, not `ddr_swap`. |
| `stub_allow` still blocked for STREAM product | `product_recon_ok` resets 0; sets only on stub pure I-slice hybrid path. Even if 1, (fs_wr disconnect) still wins. |
| Idle/boot | ARM idle paint → HPS DDR publish → `ddr_frame_store`, not stub. |

### NOT fully dark (soft / resource)

| Effect | Evidence |
|--------|----------|
| Fit cost | 9216.9 ALM + 268 M10K + 1 DSP still in RBF |
| DDR arbiter m1 poll | `stream_ddr_enable=1`; `ddr_bitstream_reader` `want_poll = enable && (poll_div==0)` → `bus_want_comb` in ST_IDLE |
| Telemetry/LED | `has_stream`, `nalu_count`, status pack still live |
| `_keep_hybrid_product` | `(* keep=1 *)` OR of hybrid outs — **synth keep only**, not pixels. Removing stub drives 0; safe. |

**Bottom line:** Parent’s reclaim motivation stands. Pixel-dark is **stronger** than the SPI-era `host_owns_fs` story; soft DDR tax + RAM/ALM cost remain.

## 3) PRODUCT_NO_STUB scope (implemented scaffolding)

| Item | Status |
|------|--------|
| `stream_path.sv` `` `ifndef PRODUCT_NO_STUB `` / else zero-assigns | DONE |
| `Plex.qsf` commented `PRODUCT_NO_STUB=1` (default OFF) | DONE |
| `decode_stub` / QIP / research gates untouched | DONE — no deletes |
| Tier B full `PRODUCT_NO_STREAM_PATH` ifdef | SCOPED in doc only (parsers+fifo still cost under Tier A) |
| Doc `docs/phase3-decode.md` ownership correction + reclaim table | DONE |
| Gate `tests/unit/test_product_no_stub_dark_silicon.sh` + rollcall | DONE |

## 4) Pre-register (before any fit)

Baseline `8fdf440f`: ALM **23585** · M10K **465** · DSP **44** · setup **+0.333** · hold **+0.245** · TNS 0.

| Tier | Pred ALM used | Pred M10K | Pred DSP | Free M10K |
|------|-------------:|----------:|---------:|----------:|
| A `PRODUCT_NO_STUB` | ~14,368 (−9217) | ~197 (−268) | ~43 (−1) | **~356** |
| B whole stream_path | ~11,317 (−12268) | ~162 (−303) | ~42 (−2) | **~391** |

ascal-class scaler need ~43 M10K → **fits Tier A headroom**; does **not** fit today’s 88 free without reclaim.

Setup/hold: **unknown until STA** — predict close remains ≥0 if no new CDC; **no new `set_false_path`**.

**Miss rule:** Tier A M10K Δ ≠ ~268 ⇒ finding (DPB not fully dropped or packing).

## 5) Gates (true rc captured directly)

```
bash tests/unit/test_product_no_stub_dark_silicon.sh; echo "true rc=$?"  → true rc=0
make define-parity; echo "true rc=$?"                                   → true rc=0
make fabric-decode-inventory FIT_RPT=.../fit-t7b-prog480/Plex.fit.rpt   → true rc=0
python3 tests/unit/test_unit_rollcall.py; echo "true rc=$?"             → true rc=0
make quartus-sv-subset; echo "true rc=$?"                               → true rc=0
  (includes VERILATOR_ELAB_PASS; PINNOTFOUND/%Error → rc=2 still enforced)
```

Red-before-green inside dark-silicon test: strip `PRODUCT_NO_STUB` markers in a copy → scaffolding check fails (expected).

## 6) Explicit non-actions

- No Quartus fit / no slot request.  
- No device/ssh/deploy.  
- PRODUCT_NO_STUB **not** enabled in product QSF default.  
- Scaler cargo (w-geom) should share the first reclaim fit.
