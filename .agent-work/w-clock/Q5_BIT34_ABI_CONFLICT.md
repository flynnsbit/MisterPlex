# PLXG q5 bit34 — three-way ABI conflict (rd-duck 2026-08-03)

**Status: RESOLVED by parent arbitration #4 — bit34 STAYS RESERVED.**
w-path "#2.1" VACATED. `fps_1001` concept provisional for a future freeze only
as a single-window five-site merge. w-clock still has no consumer and must not
add one until that freeze. See `PARENT_ABI_ARBITRATION_4.md`.

## Parent freeze (ABI arbitration #2 — still the only parent-signed wire)

```
q5 @ doorbell+0x828:
  [11:0]  dar_x
  [23:12] dar_y
  [31:24] content_fps
  [32]    dar_valid
  [33]    fps_valid
  [63:34] RESERVED — must be zero; receiver MUST reject non-zero reserved
```

The reserved-must-be-zero rule was an explicit forward-compat trap.

## What each lane ships today

| Lane | Tip (observed) | Bit 34 meaning | Effect on 23.976 record |
|------|----------------|----------------|-------------------------|
| **Parent #2** | freeze text | **RESERVED** | reject if set |
| **w-path** | `f31a6eb9` | **`fps_1001`** (self-named "#2.1"); reserved moves to `[63:35]` | packs bit34=1 for 24000/1001 |
| **w-mem** | latch product | **reserved `[63:34]`** (`\|sh5[63:34]` → `q5_reserved_reject`) | **wholesale reject** of path film q5 |
| **w-clock** | `90d73f3f`+ | **no port / no logic** for bit34 | never sees NTSC flag; integer class only |

Evidence quotes:

- w-mem `present_geom_latch.sv`: `wire q5_reserved_nz = |sh5[63:34];` + `q5_ok = !q5_reserved_nz`
- w-path `plxg_q5_aspect_cadence.hpp`: `[34] fps_1001` … `[63:35] RESERVED`
- w-clock `plex_content_fps_sel.sv`: ports are `fps_valid`, `content_fps_q5` only

## Consequence (do not soft-pedal)

A host that publishes film as `content_fps=24, fps_valid=1, fps_1001=1` under
w-path's packer produces a q5 that **w-mem rejects entirely**. Cadence and DAR
from that commit never promote. This is worse than silent integer bucketing:
the record is dropped, not degraded.

Until one parent-arbitrated ABI is merged across **host pack + 6-qword latch +
top + beam/cadence + tests**, **23.976 is not on the wire in a form fabric can
consume**.

## What bit34 would still NOT fix (even after ABI)

Even if parent awards bit34 to `fps_1001`:

1. Core beam stays integer V_TOTAL: `20e6/(1182*705)=24.000672…` Hz — not
   23.976024. Exact cpf at 20 MHz is non-integer (`834166.66…`).
2. Flag alone does not retune H×V. Options remain parent-owned:
   - **C (preferred ops):** ARM `swap_pending` / availability paced by true
     rational; fabric beam stays 24/30 class; no source-lock claim on glass.
   - **B:** num/den or milli on wire + fabric cadence floor math (still not
     exact beam Hz without V_TOTAL change).
   - **A:** fractional/nearest V_TOTAL (ppm residual; STA + ascal impact).

Wiring a consumer bit without (C) or a real rate path is cargo-cult.

## w-clock contract until parent speaks

1. **Do not** add `fps_1001` ports or treat bit34 as defined.
2. **Do not** claim source-locked / judder-controlled for 23.976/29.97
   (`assets/ntsc_rational_cadence_wall.json` + gate).
3. Keep integer B15: valid fps → class; unspecified → 24 (no invent 30).
4. When parent freezes #2.x, implement **exactly** that freeze end-to-end with
   w-mem/w-path in the same integration window — not a lane-local half.

## Ask of parent

Arbitrate one of:

- **Keep #2:** bit34 stays reserved; w-path must clear bit34; NTSC stays
  host-paced (C) or later ABI growth (q6).
- **Award #2.1:** bit34=`fps_1001`, reserved=`[63:35]`; w-mem mask + reject
  tests move; w-clock gains optional flag port **and** a named rate policy
  (almost certainly C, not beam retune).
- **Larger B:** num/den fields (may need q6) — supersedes bit34 flag.

w-clock will implement the consumer half only after that text lands.
