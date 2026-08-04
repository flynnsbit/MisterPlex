# w-clock → parent fit candidate on integ/720p-compose

Branch: `w-clock-720p-compose` (merge of `w-clock-clkpix-live` onto `integ/720p-compose`)

## Enabled macros (product-ON, not default-OFF)

| Macro | Value | Role |
|-------|------:|------|
| FRAME_W/H | 1280/720 | canvas |
| FRAME_LINES_16 | 1 | store floor 16 |
| PRESENT_MULTI_PIXEL | 1 | dual-lane |
| PRESENT_PX_PER_CLK | 2 | PPC2 |
| PRESENT_CLK_PIX_PLL | 1 | **29.7 MHz COMPACT** |
| Plex_clk_pix.sdc | active | async groups |
| FABRIC_FRAME_DMA | 1 | publish engine in hierarchy |
| PRODUCT_NO_STUB | 1 | strip |

Refresh honesty: without PLL, COMPACT 1650×750 @20 MHz → **16.16 Hz** (photographs as win).
With PLL: target **24.00 Hz**. COMPACT ≠ CEA VIC60 (59.4/H3300).

## STA PRE-REG (before fit) — not measured

Baseline post-strip (parent): clk_ddr **+0.311**, clk_sys **+1.290**, TNS 0.

| ID | Prediction | Class |
|----|------------|-------|
| P1 | general[3] clk_pix Fmax ≥29.7, slack ≥0 | PRE-REG |
| P2 | clk_ddr worst ≥0 (may lose +0.311 to re-place) | PRE-REG |
| P3 | clk_sys ≥ +0.5 ns | PRE-REG |
| P4 | hold TNS = 0 | PRE-REG |

Doc detail: `docs/clk_pix_29p7_sta_prereg.md`.

## M10K PRE-REG (layout stated)

Shared free: **356 M10K / 27,556 ALM** (post-strip 197/553, 14354 ALM — parent fit).

| Block | Layout | M10K | Class |
|-------|--------|-----:|-------|
| plex_clk_status measure | flops only | **0** | EST (no RAM) |
| line_buf @ LINE16 | 64b SDP; Y 160×64 U/V 80×64; 96 inst × **2 M10K** (measured pack class post-strip 78×64→2) | **192** | **PRED** |
| Δ line_buf vs post-strip 96 | — | **+96** | PRED |
| fabric DMA bounce | `ramstyle=logic` MAX_BURST×64 | **0 M10K** | EST from RTL |
| ascal (unchanged class) | mix incl real **256×40** | **43** | MEASURED post-strip |

Naive 8-bit 1280 line = **2 M10K** (1K×8); packed 256×40 = **1 M10K** + 5px granularity.
Our line_buf is **not** 8-bit — see `docs/m10k-layout-correction-w-clock.md`.

**Whole enabled-720p fit M10K:** UNKNOWN until fit. Settle: entity rows + RAM Summary.
Lower bound bits alone is **not** a plan number (post-strip line_buf 16% eff).

## Device refresh (parent only)

```bash
./scripts/check_clk_pix_refresh.sh
# set_status --raw → fps_x10~240 PASS_24HZ_BAND; ~161 FAIL_16HZ_TRAP
python3 scripts/hdmi_measure_refresh.py --seconds 2   # 23–25.5 PASS; 15.5–17 FAIL
```

## T_copy

+8.962 ms PRE-REG **arithmetic only**; e2e OPEN until fabric DMA measured on device.

## Gates run on this tip (no fit)

- make define-parity rc=0
- make rtl-lint rc=0
- test_clk_pix_720p_recipe rc=0
- test_present_multi_720p_abi_static rc=0
- test_present_multi_e2e_verilator (see commit notes)

