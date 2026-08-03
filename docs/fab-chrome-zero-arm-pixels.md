# Player UI — zero ARM pixel writes (w-osd)

**Objective:** fabric paints the player HUD; ARM emits a bounded PLXC command
list only. Matches the user goal to move work into the FPGA.

## Composite path (product)

```
ascal → shadowmask → plex_chrome → osd → pins   (HDMI_OUT 1280×720)
```

ARM never blends HUD pixels into the content bank when `chromePlaneLive()`.

## UI inventory (what glass needs)

| Element | Source today | PLXC ops | Notes |
|---------|--------------|----------|-------|
| State word PLAYING/PAUSED/STOPPED | `buildPlaybackHud` | 6–7 GLYPH | Required |
| Title (≤19 chars) | same | ≤19 GLYPH | Required |
| Elapsed + total time | same | ~6–16 GLYPH | Required |
| Progress track | RECT | 1 | Required |
| Progress fill | RECT_PAL chunks ≤255 | ≤5 @1280 | Required |
| Panel background | RECT | 1 | Required |
| Skip flash (`30s >>`) | ARM `PlaybackOverlay` bake historically | box+glyphs ~8 | Now expressible in PLXC |
| Notice banner | same | box+≤31 glyphs | Now expressible |
| Buffering chip | progress log only | box+9 glyphs | Now expressible |
| Volume | not drawn on HDMI HUD | 0 | N/A |

### Budget vs `MAX_CMDS=48` / `HIT_SCAN=48`

Measured by `countHudBudget()` / `test_plex_chrome_cmds` (uncapped builder):

Measured (`test_plex_chrome_cmds`, true rc=0):

| Scenario | `totalUncapped` | Fits 48? |
|----------|-----------------|----------|
| Core STOPPED + 19-char title + bar | **38** | **yes** |
| PLAYING worst title + full bar | **45** | **yes** |
| Core + skip + notice + buffering **simultaneous** | **79** | **no** — need `MAX_CMDS≥79` |

Per-layer add-on (same run): skip=+7, notice=+24, buffering=+10.

**Policy:** if simultaneous full UI needs N>48, **raise `MAX_CMDS`/`HIT_SCAN` to N**
(list is 2×N×64b BRAM — deep/wide, not many small RAMs). **Do not trim the UI**
to make the gate pass. Product `buildPlaybackHud` still truncates at 48 so RTL is
never overfed; truncation is a **visible residual**, not a silent feature cut.

List M10K cost at N=48 today: ~6 kbit → 1–2 M10K. Doubling N≈96 stays small vs
decode RAMs.

## ARM writes commands, not pixels (evidence)

| Gate | What it proves |
|------|----------------|
| `checkNoPixelBakeWhenLive` | live plane → frame buffer unchanged |
| `checkRedTwinArmPixelBakeCaught` | inverted gate **does** dirty pixels (negative case) |
| `checkZeroPerPixelArmWhenLiveSource` | `media_player.cpp`: bake only under `!chromePlaneLive()`; idle `skip ALL ARM paint`; `Semantic list only — never pixels`; no `writeChromePixels` |
| `checkWriteChromeIsListNotPixels` | `FpgaSpi::writeChromeCommandList` body has no blit/render/frame RGB |
| `checkFlashSkipPublishesPlxc` | R2: `flashPlaybackSkip` calls `publishPlxcHud(..., skipDeltaMs)` under `chromePlaneLive()`; no pixel bake calls |

Quoted product shape (`media_player.cpp`):

```cpp
// plane=1: fabric plex_chrome composites PLXC list — do not bake pixels.
if (!dirty.empty() && !chromePlaneLive()) {
    renderOverlay(cleanFrame);
}
...
// Semantic list only — never pixels.
fpga_.writeChromeCommandList(cmds.data(), cmds.size(), /*enable*/ true, seq);
```

## Counted RTL sim (product list_we → pixels)

Counterpart to w-scaler counted-DE. Drive `plex_chrome` through
`plex_chrome_host_if` (`list_we`/`list_waddr`/`list_wdata`), capture full
1280×720, assert HUD pixels + byte-exact passthrough outside the HUD.

| Case | Build | Proves |
|------|-------|--------|
| `green` | product | ~38-cmd core HUD: panel `14_14_28`, fill `FF_B2_20` (pal2), STOPPED white ink, passthrough exact |
| `wrong_off` | product | list base addr ≥ MAX_CMDS → `list_we=0`; no panel paint |
| `hit_bleed` | `FAULT_HIT_BLEED=1` | +1px right edge is chrome (red twin) |
| `no_bleed` | product | edge x=rect.x+w is pure video |
| `trunc79` | product | 79 writes → 48 `list_we`; cmd50 amber marker absent; no wrap |

```bash
tests/unit/test_plex_chrome_counted_rtl_sim.sh
# expect: EXECUTED <case> + PASS counted-* ; true rc=0
```

## Honest residuals

1. **OPEN — PLXC DDR loader armed but not granted.**  
   `Plex.sv`: `plex_chrome_ddr_loader` may be `ENABLE=1` under `PLEX_CHROME_DDR`,
   but `.m_gnt(1'b0)` until w-mem arbiter gives a master slot.  
   **State: ENABLE can arm; beats stay quiet without grant. Not product-live.**  
   Partial credit only until grant lands.

2. **CLOSED — R2 skip flash PLXC.**  
   `flashPlaybackSkip` now calls `publishPlxcHud(..., deltaMs)` when
   `chromePlaneLive()`. `!chromePlaneLive` still uses ARM `PlaybackOverlay`
   fallback (correct dual-path). Gate: `checkFlashSkipPublishesPlxc`.

3. **OPEN — Volume** is not a glass HUD element in the current design.

4. **OPEN — Simultaneous full UI** needs `MAX_CMDS ≥ 79` (measured 79 vs product
   48). Truncation is **visible and bounded** (`trunc79` sim: cmd50 absent, no
   wrap). Raise list depth (w-nostub/fit) rather than cutting elements.

## Tests

```bash
make …/build/test_plex_chrome_cmds && ./build/test_plex_chrome_cmds
# expect: UI_BUDGET lines + test_plex_chrome_cmds: PASS
tests/unit/test_plex_chrome_counted_rtl_sim.sh
# expect: true rc=0
```
