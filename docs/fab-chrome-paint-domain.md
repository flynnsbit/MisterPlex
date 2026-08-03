# Fabric chrome paint domain (ascal pivot)

**Lane:** w-osd · **No Quartus · No device**  
**Status:** product chrome stays on **HDMI_OUT** (post-ascal). Layout basis is the
paint beam, not STORAGE and not “HDMI constants while beam is CORE_DE”.

## Three domains (never conflate)

| Domain | Size (product path) | Owner | Chrome? |
|--------|---------------------|-------|---------|
| **STORAGE** | 960×540 I420, 777 600 B | w-mem bank / ARM decode | **Never** PLXC canvas |
| **CORE_DE** | 960×540 DE @ 24/30 Hz | core → ascal | Only if chrome moves **pre**-ascal |
| **HDMI_OUT** | 1280×720@60 post-ascal | HPS `video_mode` + ascal | **Product paint** |

Same numbers can appear in two domains (960×540 is STORAGE *and* CORE_DE). The
**name** is the contract — size alone is not enough.

## Where chrome sits today (quoted)

`fpga/Plex_MiSTer/sys/sys_top.v`:

```
// plex_chrome: post-ascal / post-shadowmask player chrome (HDMI output res).
// Composite: ascal → shadowmask → plex_chrome → osd → pins.
```

So:

1. Core emits CORE_DE (near-term **960×540**).
2. **ascal** upscales to HPS-configured **1280×720**.
3. **plex_chrome** paints on that post-ascal beam (**HDMI_OUT** pixels).
4. Capture / `hdmi_score_pair` / PASS-A `ACTIVE` are **glass-side** (HDMI).

## Architectural choice: keep post-ascal

| Option | Chrome sharpness | Layout basis | Risk |
|--------|------------------|--------------|------|
| **A. Post-ascal (product)** | Native glass pixels | HDMI_OUT 1280×720 | None for ascal pivot |
| B. Pre-ascal | Soft ~1.333× upscale by ascal | CORE_DE 960×540 | Softer HUD; must re-layout |

**Recommendation: A.** Soft upscale of text/glyphs is a real cost of B and is
exactly the “overlay looked low-res” class. Move pre-ascal **only** if a measured
fit forces chrome off the HDMI path. Document the cost; do not discover it on glass.

Host API:

- Product: `chromeLayoutFromActiveHdmi()` / `PaintDomain::HdmiOut`
- Experiment only: `chromeLayoutFromPaintDomain(PaintDomain::CoreDe, 960, 540, …)`
- `PaintDomain::Storage` always refuses

## Red-twins (must stay red)

| Fault | Beam | Layout math | Catch |
|-------|------|-------------|-------|
| `FAULT_LEGACY_480P_LAYOUT` | 1280×720 | 624×480 | amber at (232,160) not (520,240) |
| `FAULT_HDMI_LAYOUT_ON_CORE_DE` | **960×540** | **1280×720** | amber at (520,240) not CORE_DE (390,180) |

**Parent retraction (sweep 38):** product chrome is post-ascal; there is no
product overflow from HDMI layout on a 960 DE. Keep this fault anyway — it
**pins the paint domain** so a future lane cannot silently move chrome
*pre*-ascal and soften every glyph ~1.333× without a red-twin trip. It defends
sharpness / domain honesty, not a nonexistent overflow.

Green optional: `CORE_DE_BEAM=1` + product layout tracks beam → chevron at (390,180).

## Glass gates vs core DE

`scripts/parent_playing_gate.sh` / `hdmi_score_pair.sh` measure **HDMI capture**.

| Gate | Basis after ascal pivot |
|------|-------------------------|
| PASS-A `ACTIVE ≥ 1100×680` | Glass 1280-class — **unchanged** by core DE 960×540 |
| Control `ACTIVE≈923×717` | Glass letterbox control — **unchanged** |
| `DIFF_PX` / 1 s pair | May change character under 24 vs 30 Hz core (5:2 vs 2:1 vs 60 Hz HDMI); geometry basis stays glass |

baseline-ab scores glass on both legs. Unscorable baseline → `PRECOND` rc=4, never
candidate fabric.

## RTL hooks

- `layout_w/h` track paint beam unless a FAULT forces wrong-domain math
- `mon_*` / `glass_scale` always true beam (anti-elision keep-sink)
- Default-OFF: boot PLXC `enable=0` unless `PLEX_FAB_BOOT_PLXC`

## Tests

- `tests/unit/test_plex_chrome_idle720_rtl_sim.sh` — red / legacy / **hdmi_on_de** / corede / green
- `tests/unit/test_plex_chrome_cmds` — `checkPaintDomains`, HDMI refuse of 960×540
- `tests/unit/test_plex_chrome_default_off_static.py` — default-OFF honesty
