# Mode-exit beam DE = **624×480** (not 640) — settle before merge

## rd-duck collision

| Lane | Constant | Mode-exit DE |
|------|----------|--------------|
| **w-clock** (this tree) | `LEG_CW=624` | **624×480** |
| w-mem | `LEG_DE_W=640` | 640×480 |

## Source of truth (`host/libmisterplex/ddr_frame_layout.hpp`)

```
kPlex480pCodedWidth     = 624   // H.264 payload + DDR bank layout + true DE columns
kPlex480pDisplayWidth   = 618   // crop window inside coded
kPlex480pPresentedWidth = 640   // VGA scanout after 11+11 pillarbox — NOT beam DE
```

**Source-native rule:** true DE tracks delivered/storage. Store under `geom_enable=0`
is the **legacy coded bank (624-wide)**. Emitting beam DE=640 with a 624-wide store is
the same **island class** as DE=960 over 624 (16 dead columns; ascal sees wrong extent).

640 is the **presented** canvas *after* pillarbox — owned by scaler/ascal path, not
`plex_present_geom_mux` mode-exit content DE.

## Ruling (w-clock owner of beam/content DE)

1. Mode-exit (`disable_legacy`) **must** emit content/beam DE **624×480** (`LEG_CW/CH`).
2. `LEG_DE_W=640` / any disable→640 path is **rejected** by `test_present_b13_mux_e2e.sh`.
3. w-mem must adopt 624 on merge; last-writer 640 will fail the gate.

## Gate

`tests/unit/test_present_b13_mux_e2e.sh` — layout.hpp 624/640 split + LEG_CW=624 +
sim native→legacy exit DE=624×480 exact + RED 960-island twin.
