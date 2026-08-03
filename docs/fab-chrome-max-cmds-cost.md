# MAX_CMDS / HIT_SCAN cost (w-osd)

## Why 112 (not 48, not “79”)

| Scenario (HDMI_OUT 1280×720) | `totalUncapped` |
|-----------------------------|-----------------|
| Core STOPPED + 19-char title + bar | 38 |
| Prior “simultaneous short” (skip+notice+buf) | **79** |
| **True worst under current API caps** (title19 + notice31 + H:MM:SS times + huge skip + buffering + full bar) | **102** |
| Same worst @ 1080p canvas | **104** |

**79 was not the true worst case** — it used short times/notice. Product
`kMaxCmds` / RTL `MAX_CMDS` / `HIT_SCAN` are **112** (102 + headroom for one
small element without another ABI move).

Growth that **can** raise the figure again:

- Raising title/notice string caps
- Adding volume / multi-line notices / extra chips
- New HUD elements on glass

Growth that does **not** (today): content/core geometry — chrome is HDMI_OUT only.

`kMaxCmds` is the hard gate: `buildPlaybackHud` truncates; uncapped inventory
must stay ≤112 or we raise again (and move PLXG again).

## Mailbox map (parent ABI freeze)

```
PLXC  +0x130
list  +0x140 .. +0x4BF   (112 × 8B = 0x380; may grow)
PLXG  +0x800 FIXED       (NOT kPlxl + MAX_CMDS*8)
```

Bound only: `kPlxlOffset + kPlxcListMaxCmds*8 <= kPlxgOffset`.
UI budget changes must **not** relocate PLXG. w-mem/w-scaler must use **+0x800**.
Gate: `./build/test_ddr_720p_abi` (builds in this lane).

## Yosys generic cell counts (not Quartus ALM / not Fmax)

Method: `read_verilog -sv plex_chrome.sv` → `chparam MAX_CMDS=HIT_SCAN=N` →
`proc; opt_clean; memory -nomap; stat`. Logs:
`.agent-work/chrome-area/stat_n{48,80,104,112,128}.txt`.

| N | cells | $eq | $mux | $mem_v2 | list bits (2×N×64) |
|---|------:|----:|-----:|--------:|-------------------:|
| 48 | 35509 | 15659 | 13597 | 50 | 6144 |
| 80 | 56629 | 24779 | 21981 | 82 | 10240 |
| 104 | 72469 | 31619 | 28269 | 106 | 13312 |
| **112** | **77749** | **33899** | **30365** | **114** | **14336** |
| 128 | 88309 | 38459 | 34557 | 130 | 16384 |

**Δ 48 → 112:** cells +42240 (**+119%**). Combo depth of `chrome_at` scales with
`HIT_SCAN` (per-pixel on **`clk_hdmi`**, not clk_sys).

### M10K (analytic, not fit)

Dual list 2×112×64 = 14336 bits ≈ 1.4× M10K (10 kbit). Expect **2 M10K** if
consolidated; do **not** infer M10K count from yosys `$mem_v2` (114 is
pre-map fragments).

### Fmax

**UNKNOWN without Quartus.** Chrome sits on `clk_hdmi` (~74.25 MHz @720p60).
Parent’s 23.46 MHz clk_sys margin does **not** bound this path. If fit Fmax
fails, fallback design (not implemented here):

- Keep `MAX_CMDS=112` storage
- Build a **per-scanline active list** in HBLANK (worst band ~32 cmds for
  notice31) and set `HIT_SCAN`≈40 for DE — services 112 logical cmds without
  112 parallel comparators.

## Decision for parent

Ship **112** with measured yosys Δ; **Quartus Fmax is the open fit question**.
Do not trim UI. Do not assume 79 was the ceiling.
