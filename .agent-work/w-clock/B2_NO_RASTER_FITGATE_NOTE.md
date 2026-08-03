# B2_NO_RASTER_GENERATOR — coordinate w-fitgate

**Decision (B2b, parent-verified):** `present_video_timing_960.sv` is a **math/constant pack only**.
Sole raster generator SoT: `present_beam_content_de.sv` (hc/vc/DE/HS/VS).

A fit-gate that requires timing_960 to be a raster generator **describes a deliberate non-goal**.
Please **retire** `B2_NO_RASTER_GENERATOR` or invert to:
- timing_960 must remain math-only (no hc/vc counters)
- present_core must not dual-instantiate timing_960 as a beam

w-clock will not re-promote timing_960 to a generator.
