# ONE-fit coordination — plex_chrome + PRODUCT_NO_STUB (+ w-geom)

**Hold:** Quartus exclusive ON — do not request fit from w-osd-hires.  
**Tip chrome:** see `git rev-parse --short HEAD` on `w-osd-hires`.

## Cargo (single RBF)

| Order | Lane | Change |
|------:|------|--------|
| 1 | w-fit-1 | `PRODUCT_NO_STUB=1` in QSF; `stream_path` else `stub_busy=0`; **no telem_flags shorten** |
| 2 | w-osd-hires | `rtl/plex_chrome.sv` in `files.qip`; **GOOD** `sys_top` wire (see below); expose `chrome_hw` |
| 3 | w-geom | content window / fabric scaler if ready same slot |

## HARD — c74c6863 NO-DATA must not repeat

Parent scored fit `c74c6863`: playback PASS, chrome **NO-DATA** (HUD stroke histogram byte-identical). Causes:

1. `sys_top`: `.list_we(1'b0)` + `.list_wdata(64'd0)` → Quartus elides list RAM  
2. BOOT_DEMO wrote `list_b[0]` while `live_bank=0` reads `list_a` → invisible glyph  

**Product wiring (copy fixture):** `tests/unit/fixtures/plex_chrome_sys_top_GOOD.sv.inc`  
**Forbidden:** `tests/unit/fixtures/plex_chrome_sys_top_BAD.sv.inc` (= c74c pattern)

- `list_we` / `list_wdata` / `list_waddr` = **real nets**, never `1'b0` / `64'd0`  
- BOOT_DEMO preload **`list_a[0]=BOOT_DEMO_CMD`** (RTL on this branch already does)  
- Prefer `BOOT_DEMO=1` only until ARM PLXC lands; keep write path live either way  
- `(* noprune *) (* preserve *)` on list RAMs (already in RTL)

### Host gate (red-before-green) — parent runs before granting slot

```bash
cd .worktrees/w-osd-hires
# RED — c74c pattern (expect true rc=1)
python3 tests/unit/test_plex_chrome_write_path_static.py \
  --subject tests/unit/fixtures/plex_chrome_sys_top_BAD.sv.inc
echo "true rc=$?"   # must be 1

# GREEN — required product wire (expect true rc=0)
python3 tests/unit/test_plex_chrome_write_path_static.py \
  --subject tests/unit/fixtures/plex_chrome_sys_top_GOOD.sv.inc
echo "true rc=$?"   # must be 0

# Live integ tree still RED until w-fit-1 rewires (expect 1 today)
python3 tests/unit/test_plex_chrome_write_path_static.py \
  --subject ../w-fit-integ/fpga/Plex_MiSTer/sys/sys_top.v
echo "true rc=$?"   # 1 until GOOD wire lands

# Full suite + sim
python3 tests/unit/test_plex_chrome_write_path_static.py; echo "true rc=$?"
make "$PWD/build/test_plex_chrome_sim" && ./build/test_plex_chrome_sim; echo "true rc=$?"
```

## Baseline (BINDING — parent locked)

Deployed **`8fdf440f`** = `w-fit-integ/.../remote_out/fit-t7b-prog480/` only.  
**ALM 23585 · M10K 465 · DSP 44** · `pll_hdmi` slack **+0.669 ns**  
`output_files` / `2890baac` = **BANNED**

Post-stub intent: **ALM ~14368 · M10K ~197 · free M10K ~356**  
Chrome Δ: **M10K +12±4 (cap24) · ALM +2.5k±1k · DSP 0 · HDMI slack stay >0 (target ≥+0.20 ns)**  

**telem_flags:** keep `stub_busy` bit — **tie to 0**, never delete/shift.

**PRESENT_PROFILE=1:** overlay wall/CPU **FLAT or down** when plane=1.

## HALF A (daemon, no fit) — shipped this tip

`loadMisterVideoModeFromIni`: `[Plex]` then `[MiSTer]` fallback.  
Log: `source=ini:plex|ini:mister|none` — **never** `measured` from ini.  
Parent deploy daemon → expect (if device ini is MiSTer-only mode 8):
`output=1920x1080 mode=8 source=ini:mister authoring=624x480`

## Glass after deploy

`docs/plex-chrome-glass-criterion.md` — AFTER stroke histogram **single** width; runs multiple of scale.  
BEFORE: `files/device-evidence/hud_1080p_BEFORE_8fdf440f.png` multi `{7,8,9,10}`.
