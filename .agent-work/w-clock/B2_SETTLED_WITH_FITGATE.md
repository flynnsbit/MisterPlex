# B2_NO_RASTER_GENERATOR — SETTLED with w-fitgate

## Decision (deliberate, both lanes)

| Item | Status |
|------|--------|
| `present_video_timing_960.sv` | **KEEP** as constants/math pack (cargo for oracles/arith tests) |
| Product raster SoT | **`present_beam_content_de.sv` only** |
| `B2_NO_RASTER_GENERATOR` | **RETIRED** as noise (fitgate `fit_release_gate.py` + fit card) |
| Replacement | `B2_NO_PRODUCT_RASTER` if beam missing from qip/hierarchy |

## Evidence (w-fitgate tree, read-only)

- `docs/ascal-true-de-fit-card.md`: *"B2_NO_RASTER_GENERATOR retired as noise"*
- `scripts/fit_release_gate.py:~141, ~1548, ~3805`: retired; timing_960 constants-only intentional

## w-clock action

- File stays in `files.qip` (math pack + TB cargo).
- `present_core` must **not** instantiate `present_video_timing_960` as a generator
  (already gated by elab tests).
- No further blocker noise from this lane.

## Not done here

Deleting the file would break arith/oracle TBs that still parameterize MODE=0/2.
Re-scope is preferred over delete — **done by fitgate**.
