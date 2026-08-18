// plex_15k_bw_contract.svh — ONE CRT 15 kHz FPGA-present beam contract (w-clock).
// clk_sys = 20_000_000 (pll_0002.v outclk_0 / Plex.qsf). Do not raise it. No new PLL:
// 20 MHz hits both rasters with integer ce_pix (1/3 bob, 2/3 weave).
// ascal 15 kHz video_mode is RED (PLXD down). This is the fabric raster, not ascal.
// Store stays 640x480 I420 @ 0x3000_0000 / doorbell 0x300F_F000. No 320x240 doorbell.
// Not in files.qip until a fit is awarded — constants/docs only (like plex_720p_bw_contract).
//
// Product true480 (NOT this file): CE/2, H=672, V=496
//   10e6 / (672*496) = 10e6 / 333312 = 30.00192012 Hz.
//
// NTSC reference (not claimed as this beam):
//   H = 4.5e6/286 = 15734.26573427 Hz
//   field = 60e3/1001 = 59.9400599401 Hz
//   frame = 30e3/1001 = 29.9700299700 Hz
//   BT.601: Fpix=13.5e6, H=858, V_field=262.5.

localparam int P15K_CLK_SYS_HZ = 20_000_000;

// ---------------------------------------------------------------------------
// 240p bob — Fpix = clk_sys/3, H=424, V=262
//   Fpix  = 20e6 / 3                 = 6_666_666 + 2/3 Hz
//   Hfreq = 20e6 / (3*424)           = 20e6 / 1272 = 2_500_000/159
//         = 15723.2704402516 Hz      (NTSC-H -10.995 Hz, -699 ppm)
//   Vfreq = 20e6 / (3*424*262)       = 20e6 / 333264 = 1_250_000/20829
//         = 60.01248259698 Hz        (NTSC-V +0.07242 Hz, +1208 ppm)
// H_DE=320: H_TOTAL=424 cannot hold 640. CE/2=10 MHz max H @15.734 kHz is 635.56
// so 640 DE + blank is impossible at /2. Identity-X 640 DE needs CE 2/3 (weave Fpix).
// ---------------------------------------------------------------------------
localparam int P15K_BOB_CE_NUM     = 1;
localparam int P15K_BOB_CE_DEN     = 3;          // fire 1 of every 3 clk_sys (pattern 1,0,0)
localparam int P15K_BOB_FPIX_NUM   = 20_000_000;
localparam int P15K_BOB_FPIX_DEN   = 3;
localparam int P15K_BOB_H_TOTAL    = 424;
localparam int P15K_BOB_V_TOTAL    = 262;
localparam int P15K_BOB_H_DE       = 320;
localparam int P15K_BOB_V_ACTIVE   = 240;
localparam int P15K_BOB_H_FP       = 16;
localparam int P15K_BOB_H_SW       = 32;         // ~4.80 us @ 20e6/3 (NTSC ~4.7 us)
localparam int P15K_BOB_H_BP       = 56;         // 16+32+56=104; 320+104=424
localparam int P15K_BOB_H_SYNC_S   = 336;        // H_DE+H_FP
localparam int P15K_BOB_H_SYNC_E   = 368;        // +H_SW
localparam int P15K_BOB_V_FP       = 10;
localparam int P15K_BOB_V_SW       = 3;
localparam int P15K_BOB_V_BP       = 9;          // 10+3+9=22; 240+22=262
localparam int P15K_BOB_V_SYNC_S   = 250;
localparam int P15K_BOB_V_SYNC_E   = 253;
localparam int P15K_BOB_HFREQ_MILLI = 15_723_270; // floor(1000*20e6/1272)
localparam int P15K_BOB_VFREQ_MICRO = 60_012_482; // floor(1e6*20e6/333264)
localparam bit P15K_BOB_HS_N       = 1'b1;
localparam bit P15K_BOB_VS_N       = 1'b1;

// Store map — bob (DROP default). Average is optional later (needs a line pair).
//   store_x = (hc << 1) | P15K_BOB_X_PARITY     // 320 DE samples even columns of 640
//   store_y = (vc << 1) | P15K_BOB_Y_PARITY     // 240 lines = even (or odd) store rows
localparam bit P15K_BOB_AVG        = 1'b0;       // 0=DROP (locked); 1=average not in this cut
localparam bit P15K_BOB_X_PARITY   = 1'b0;       // 0=even columns 0,2,..638
localparam bit P15K_BOB_Y_PARITY   = 1'b0;       // 0=even rows    0,2,..478

// ---------------------------------------------------------------------------
// 480i weave — Fpix = clk_sys*2/3, H=849, V_field=262
//   Fpix        = 40e6 / 3                    = 13_333_333 + 1/3 Hz
//   Hfreq       = 40e6 / (3*849)              = 40e6 / 2547
//               = 15704.7506870828 Hz         (NTSC-H -29.515 Hz, -1876 ppm)
//   Vfreq_field = 40e6 / (3*849*262)          = 40e6 / 667314 = 20e6 / 333657
//               = 59.94179651558 Hz           (NTSC-V +0.001737 Hz, +29 ppm)
//   Vfreq_frame = Vfreq_field / 2             = 10e6 / 333657
//               = 29.97089825779 Hz
// H=849 is the integer that puts field Hz on 59.94 at 2/3. H=858 is BT.601 at
// 13.5 MHz, not at 13.333 MHz — see P15K_I858_* (computed, not locked).
// ---------------------------------------------------------------------------
localparam int P15K_I_CE_NUM       = 2;
localparam int P15K_I_CE_DEN       = 3;          // fire 2 of every 3 clk_sys (pattern 1,1,0)
localparam int P15K_I_FPIX_NUM     = 40_000_000;
localparam int P15K_I_FPIX_DEN     = 3;
localparam int P15K_I_H_TOTAL      = 849;
localparam int P15K_I_V_TOTAL      = 262;        // per FIELD
localparam int P15K_I_V_TOTAL_EVEN = 262;
localparam int P15K_I_V_TOTAL_ODD  = 262;        // equal fields; no 262/263 dither
localparam int P15K_I_FRAME_LINES  = 524;        // 2*262; not 525 (half-line off)
localparam int P15K_I_H_DE         = 640;
localparam int P15K_I_V_ACTIVE     = 240;        // active lines per field
localparam int P15K_I_H_FP         = 20;         // 1.50 us @ 40e6/3
localparam int P15K_I_H_SW         = 63;         // 4.725 us @ 40e6/3 (NTSC ~4.7 us)
localparam int P15K_I_H_BP         = 126;        // 20+63+126=209; 640+209=849
localparam int P15K_I_H_SYNC_S     = 660;
localparam int P15K_I_H_SYNC_E     = 723;
localparam int P15K_I_V_FP         = 3;
localparam int P15K_I_V_SW         = 3;
localparam int P15K_I_V_BP         = 16;         // 3+3+16=22; 240+22=262
localparam int P15K_I_V_SYNC_S     = 243;
localparam int P15K_I_V_SYNC_E     = 246;
localparam int P15K_I_HFREQ_MILLI  = 15_704_750; // floor(1000*40e6/2547)
localparam int P15K_I_VFREQ_MICRO  = 59_941_796; // field; floor(1e6*20e6/333657)
localparam int P15K_I_FRAME_MICRO  = 29_970_898; // frame = field/2
localparam bit P15K_I_HS_N         = 1'b1;
localparam bit P15K_I_VS_N         = 1'b1;
localparam bit P15K_I_HALFLINE     = 1'b0;       // v1 integer beam; no mid-line vsync
localparam bit P15K_I_FIRST_ODD    = 1'b1;       // NTSC: first field after vsync is odd

// Field flag (0-based store y):
//   field_odd=0 (even / top)    store_y = {vc, 1'b0} = 2*vc       // 0,2,..478
//   field_odd=1 (odd  / bottom) store_y = {vc, 1'b1} = 2*vc+1     // 1,3,..479
//   store_x = hc  (identity 640; ddr_frame_store still applies 11+618+11)
// Frame = even field + odd field. Cadence unique-advance is still present_cadence
// (content 24/30 on this ~59.94 field / ~29.97 frame glass).
localparam bit P15K_I_FIELD_EVEN   = 1'b0;
localparam bit P15K_I_FIELD_ODD    = 1'b1;

// ---------------------------------------------------------------------------
// BT.601 858 trial at 2/3 — evaluated, NOT locked.
//   Hfreq = 40e6 / (3*858)        = 20e6 / 1287 = 15540.0155400155 Hz  (-194.25 Hz)
//   Vfreq = 40e6 / (3*858*262)    = 20e6 / 337194 = 59.31303641227 Hz  (-0.627 Hz)
// Exact 13.5 MHz * 858 is CE 27/40 from the same 20 MHz (Bresenham, still no PLL)
// and is a later cut if a set will not lock 15.705 kHz. Not this contract.
// ---------------------------------------------------------------------------
localparam int P15K_I858_H_TOTAL     = 858;
localparam int P15K_I858_V_TOTAL     = 262;
localparam int P15K_I858_HFREQ_MILLI = 15_540_015;
localparam int P15K_I858_VFREQ_MICRO = 59_313_036;
localparam bit P15K_I858_LOCKED      = 1'b0;

// Shared-Hfreq sibling (not locked): 848x262 @ 2/3 == 424x262 @ 1/3
// (same 15723.270440 Hz / 60.01248260 Hz). Use if a set must keep H while
// switching bob↔weave. Locked weave prefers 849 for V=59.94180 Hz.
localparam int P15K_I848_H_TOTAL = 848;

// ---------------------------------------------------------------------------
// Store / doorbell — same true480 bank. Do not add a 320x240 doorbell.
// Coded 624 / display 618 / presented 640 / pillars 11+11 (L44).
// ---------------------------------------------------------------------------
localparam int P15K_STORE_W            = 640;
localparam int P15K_STORE_H            = 480;
localparam int P15K_CODED_W            = 624;
localparam int P15K_CODED_H            = 480;
localparam int P15K_DISPLAY_W          = 618;
localparam int P15K_PILLAR_L           = 11;
localparam int P15K_PILLAR_R           = 11;
localparam int P15K_I420_BYTES         = 449_280;        // 624*480*3/2
localparam int P15K_BANK_STRIDE        = 32'h0008_0000;
localparam [31:0] P15K_PHYS_BASE       = 32'h3000_0000;
localparam [31:0] P15K_DOORBELL_PHYS   = 32'h300F_F000;  // DDR_FRAME_YUV420P_DOORBELL_PHYS
localparam bit    P15K_NEW_DOORBELL    = 1'b0;
