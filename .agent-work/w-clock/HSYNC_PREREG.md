# PRE-REGISTER — L4 HSync / raster clock (w-clock) — BEFORE measure

branch: w-clock-hsync-fix
base: 8609fd78

## Finding #1 HSync
PREDICT: CONFIRMED. use_rt_geom=1 uses H_FP=32/H_SW=64 defaults; hs_s=1312 >= htot 1312; asserted_cycles=0.
present_core passes H_SYNC_S/E (1288/1296) but beam IGNORES them in rt mode (present_beam_content_de.sv hs_s/hs_e lines).

## VSync V_TOTAL=762
PREDICT: ASSERTS correctly with defaults V_FP=8 V_SW=6 → vs 728..733 (6 lines), v_last=761.

## Pixel clock reconcile
PREDICT: L4 drives 1312×762 (NOT CEA 1650×750). Required f_pix @24fps = 1312*762*24 = 23_993_856 Hz ≈ 23.994 MHz; @24.0 MHz pix → fps≈24.006 Hz.
PLL landed 29.70 is CEA pack — WRONG for L4. Must add/retarget 24.000000 MHz option.

## PPC=2
PREDICT: present_npx_path group-write path is real (Peak F_sys*PPC). present_core FORCES PRESENT_PPC==1 until ddr_frame_store N-wide — comment unlock is aspirational at product land.
