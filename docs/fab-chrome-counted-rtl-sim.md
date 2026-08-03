# Counted plex_chrome RTL sim

**Why:** host-side layout math + static RTL analysis do not prove that a command
list written through the product mailbox path becomes the right pixels on the
HDMI_OUT canvas. This is the chrome counterpart of w-scaler’s counted-DE sim.

## Path under test

```
TB host_we/addr/wdata
  → plex_chrome_host_if  (list_we only if addr < MAX_CMDS; ctrl @0xFF)
  → plex_chrome          (double-buffer list; latch on vs+seq)
  → dout @ 1280×720      (post-ascal paint domain HDMI_OUT)
```

Do **not** poke internal list RAMs — only the host_if ports the ARM path uses.

## Cases (`COUNTED_CASE=`)

| Case | Expect |
|------|--------|
| green | Core HUD (~38–39 cmds): panel/track/fill/glyphs located; video byte-exact outside HUD band |
| wrong_off | base addr 80 → zero `list_we`; mid-panel is pure `videoAt` (host layout can still “pass”) |
| hit_bleed | `FAULT_HIT_BLEED=1`: rect right edge +1 is chrome |
| no_bleed | product: first pixel outside rect is video |
| trunc79 | 79 cmds → 48 accepts; cfg_count clamped; cmd50 amber zone empty; no wrap corruption |

Markers: `EXECUTED <case>`, `PASS counted-*`. Soft-skip ≠ pass.

## Colours (fabric)

- RECT / panel: `24'h14_14_28`
- RECT_PAL pal2 (host `Pal::Amber`): `24'hFF_B2_20` (not idle chevron `E5_A0_0D` / pal6)
- Glyph ink: `24'hFF_FF_FF`

## Run

```bash
tests/unit/test_plex_chrome_counted_rtl_sim.sh ; echo "true rc=$?"
```

Wired into `Makefile` `rtl-sim` / `rtl-sim-unlocked` next to idle720.
