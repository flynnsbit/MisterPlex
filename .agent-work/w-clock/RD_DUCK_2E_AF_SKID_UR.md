# rd-duck 2e — AF/skid drop + UR CDC (w-clock)

## Confirmed bugs
1. **Skid/registered wr_en race** (real): `wr_en<=1` + `skid_rp++` same cycle;
   FIFO samples registered `wr_en` next cycle and can drop at full under +1000 ppm lead.
   **Fix:** combo `fifo_wr_fire = !skid_empty && !fifo_full`; pop skid only on fire.
2. **AF single-count** (prior): fixed to occupancy band; 2e still needed FWFT +1 bias
   (`OCC_AF = DEPTH - AF_HEADROOM - 1`) so free∈{4,3,2,1} stays AF.
3. **UR toggle undercount**: replaced with pix sticky level-sync + Gray count → sys.
4. **Host ABI**: `FrameStoreStatus::pixUnderrunSticky()` / `underrunEventCount()` decode bit15.

## Tests
- `present_npx_af_conserve`: freeze `clk_pix`, push 48 groups, exact rd_px=wr*PPC + id match.
- `present_npx_longhaul`: `act == H_DE*V_ACTIVE*FRAMES` (not half), ur_mid=0, coord match.

## Still open
- Real `ddr_frame_store` LAT cosim (mock LAT-true TB only).
- Fit HELD; no glass claim.
