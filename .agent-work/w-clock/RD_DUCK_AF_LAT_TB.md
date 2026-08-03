# rd-duck bd55+ audit — fixes

## (1) Integrated TB no longer LAT tautology
- `TAG_LAT` fixed at product 4; `RED_BAD_LAT` delays **store only** (`FS_LAT=TAG+2`)
- RGB oracle: R=x+lane, G=y, B=A5; GREEN requires xy_fail=0, black_de=0, lat_mismatch=0
- RED_BAD_LAT requires black_de>0 or lat_mismatch>0
- RED_DUAL_OR retained
- Shell rejects nonzero rc even if PASS marker present

## (2) async_fifo almost_full band
- Was: `(wr_bin+4) gray == full` → true only at **exactly** 4 free
- Now: `occ = wr_bin - gray2bin(rd_sync); af = full || occ >= DEPTH-AF_HEADROOM`
- Conservation TB: fill with pix held in reset; release; rd_px == wr_g*PPC

## (3) PLL RGB / reset
- Removed clk_pix RGB gate on unsync `has_frame`/`use_frame_store` (npx already blacks)
- Hold regs reset with `mp_reset_pix` not raw `reset`
- UR sticky/count already in `stat_frame_underruns` (prior)

## (4) Harness + CEA
- integrated + cea shells: `rc!=0` → FAIL
- CEA: H_TOTAL slots/line + HS width (prior harden); multi-frame window

Still **not** a fit claim; real ddr_frame_store cosim remains open.
