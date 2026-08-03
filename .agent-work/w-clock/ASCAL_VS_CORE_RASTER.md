# Does the core raster need to be CEA-legal on the wire?

**Answer: No — ascal sits between the core and HDMI.** Quoted framework code below.
29.7 MHz (1650×750×24) is the correct **core input** pixel rate for a 1280×720@24
content raster into ascal. HDMI output timing comes from HPS `video_mode`, not from
the core PLL.

## Path (quoted)

### 1) Core exports `CLK_VIDEO` / `CE_PIXEL`

`Plex.sv` (emu):
```systemverilog
// default OFF:
assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
// PRESENT_CLK_PIX_PLL:
assign CLK_VIDEO = clk_pix;  // 29.7 MHz
assign CE_PIXEL  = 1'b1;
```

### 2) `sys_top` maps emu video into ascal **input**

`fpga/Plex_MiSTer/sys/sys_top.v`:

```systemverilog
// emu port map ~L1819
.CLK_VIDEO(clk_vid),
.CE_PIXEL(ce_pix),

// bridge to ascal input ~L1747–1754
assign clk_ihdmi= clk_vid;
assign ce_hpix  = vga_ce_sl;
assign hr_out   = vga_data_sl[23:16];
...
assign hde_emu  = vga_de_sl;
```

### 3) ascal: separate input clock vs HDMI output clock

`sys_top.v` ascal instance ~L714–775:

```systemverilog
.i_clk    (clk_ihdmi),   // = core CLK_VIDEO
.i_ce     (ce_hpix),     // = core CE_PIXEL (via scanlines)
.i_r/g/b/hs/vs/de (...),

.o_clk    (clk_hdmi),    // = hdmi_clk_out  ← HDMI PLL, NOT core
.o_ce     (scaler_out),
.htotal   (WIDTH + HFP + HBP + HS[11:0]),  // from HPS video_mode
.hdisp    (WIDTH),
.vtotal   (HEIGHT + VFP + VBP + VS[11:0]),
.vdisp    (HEIGHT),
```

`wire clk_hdmi = hdmi_clk_out` (~L712). HDMI TX is driven from the **ascal
output** path (`HDMI_TX_*` assigns later in the same file), not from `clk_vid`.

### 4) Parent lab config

Device `video_mode=0` → 1280×720@**60** on the HDMI side (parent control arm).
Core may emit a slower/faster content raster; ascal frame-rate-converts into that
fixed HDMI mode.

## Implications for 29.7 vs VIC 60

| Concern | Verdict |
|---------|---------|
| CEA VIC 60 is 3300×750 @ 59.4 MHz for **HDMI 720p24** | True for that **output** mode — **not** our path |
| Our HDMI out at `video_mode=0` | **720p60** via ascal + HDMI PLL |
| Core 1650×750 @ 29.7 MHz | Legal **ascal input** content timing; need not be a CEA VIC |
| Display rejects non-standard 24 Hz HDMI | N/A if ascal owns HDMI at 60 Hz |
| Still need 29.7 on core? | **Yes** for ~24 Hz **content** refresh into ascal (else ≤16.16 Hz at 20 MHz) |

## What to watch on glass (not a CEA legality fail)

- ascal low-latency / frame-repeat behaviour at 24→60
- Tear if core VS is unstable or underruns mid-line (CDC), not “TV rejected VIC”
- Capture ACTIVE/geometry discriminators still apply

## Bottom line

**ascal decouples core raster from HDMI CEA mode.** Keep PIX24 = **29.700000 MHz**
`clk_pix` for core content. Do not switch to 59.4 MHz VIC-60 wire timing unless
we change product to drive HDMI without ascal (we do not).
