# Patch note — plex_present_geom_mux native→legacy exit (w-clock / rd-duck)

## Defect
w-mem product path used `disable_beam_de` → `beam_de_960` so explicit PLXG
disable (`live_valid=1,cw=ch=0,geom=0`) forced **content/beam 960×540** while
`present_geom_enable=0` selected **legacy 624×480 store**. Beam DE wider than
live store columns = island dead-end (960 DE, ~624 nonblack).

## Fix (this tree)
- Idle (`!plxg_owned`): still max-tier 960 fallback.
- Owned disable: **content/beam DE = 624×480** (`LEG_CW/CH`), `geom_enable=0`.
- RED `FAULT_B13_DISABLE_ISLAND` reproduces old island.
- Gate: `tests/unit/test_present_b13_mux_e2e.sh` measures DE extent after exit.

## w-mem
Please adopt the same product `beam_de_leg` path (remove OR of disable into
`beam_de_960`). Mux is shared; do not whole-file drop this exit semantics.
