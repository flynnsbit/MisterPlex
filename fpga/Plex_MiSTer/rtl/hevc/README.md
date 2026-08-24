# rtl/hevc — HEVC Phase 0 bank

Banked RBF only. **Do not** instantiate `hevc_decode_top` from `Plex.sv` or add this dir to `files.qip`.

First cut (H264 Expert):
- `hevc_nalu.sv` — Annex-B NAL ports (`clk_sys`)
- `hevc_slice_hdr.sv` — slice header ports + reject list
- `hevc_cabac.sv` — CABAC on **clk_ddr 90 MHz**, 1 bin/cycle, 3.00 Mbin 720p30 budget
- `BIN_BUDGET.md` — 720p I-frame bin math

Locks: CTB 16/32, Main 8-bit I/P, no tiles/WPP, SAO+deblock after recon, DPB/SAO/CTU off-chip, F2 PCM only. H.264 `apply_itu_fix` stays false.
