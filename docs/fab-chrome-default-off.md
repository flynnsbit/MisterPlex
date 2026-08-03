# Fabric chrome default-OFF (rd-duck integration audit)

## Defect (quoted)

> Even with all `PLEX_FAB_*` macros unset, the unconditional boot FSM writes
> GLYPH `#` at (64,64), then writes PLXC ctrl `{seq=1,count=1,enable=1}`.
> On next VS, `plex_chrome` latches it, so default output is not pass-through.

Also: `PLEX_FAB_IDLE` hardwired `has_frame_chrome=0` (steals video forever);
`plxc_ext_*` assign-0 (ARM PLXC not product-live); PLXG vs PLXC both at +0x130.

## Fix (this tree)

| Item | Behaviour |
|------|-----------|
| Boot PLXC | list_we still toggles (anti-elision); **enable=0** unless `PLEX_FAB_BOOT_PLXC` |
| Default macros | `has_frame_chrome=1` → `idle_en=0`; demo/sig/beacon off |
| `PLEX_FAB_IDLE` | idle capability + phase; `has_frame` from **CDC(`HAS_FRAME`)** |
| `PLEX_FAB_IDLE_FORCE` | ARM-off milestone only — hardwire `has_frame=0` |
| `plxc_ext_*` | emu ports `PLXC_EXT_*` from `plex_chrome_ddr_loader` (ENABLE=0 default) |
| Mailbox | **PLXC +0x130**, list +0x140..+0x2BF, **PLXG +0x2C0** |

## Macros (fit)

| Macro | Effect |
|-------|--------|
| *(none)* | Video pass-through (+1 cycle). Boot enable=0. |
| `PLEX_FAB_BOOT_PLXC` | Boot commits enable=1 + `#` glyph (diagnostic only) |
| `PLEX_FAB_IDLE` | Fabric idle when `!has_frame` + cyan sig + screensaver phase |
| `PLEX_FAB_IDLE_FORCE` | Always idle (ARM-off capture). Requires `PLEX_FAB_IDLE`. |
| `PLEX_FAB_CHROME` | Built-in STOPPED demo HUD + magenta |
| `PLEX_FAB_PLAY_BEACON` | Lime motion marker (off under IDLE) |
| `PLEX_CHROME_DDR` | Loader ENABLE=1 — still needs w-mem arbiter grant |

## Gate

```bash
python3 tests/unit/test_plex_chrome_default_off_static.py; echo "true rc=$?"
python3 tests/unit/test_plex_chrome_write_path_static.py; echo "true rc=$?"
```

## Residual (honest)

- DDR loader `m_gnt=0` until w-mem provides a PLXC master slot — ENABLE can be 1
  but beats stay quiet. Product-live ARM PLXC = loader ENABLE + arbiter grant.
- `HAS_FRAME` is a Plex-local `emu_ports.vh` extension (not upstream MiSTer).
