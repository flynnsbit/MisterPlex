# Bresenham V_TOTAL implementation — pre-register + results

## Pre-registered (before sim)

| ID | Prediction | Evidence needed |
|----|------------|-----------------|
| P1 | Duty fraction 0.72476 is at **V=706**, not 705 | mean = 705 + 1285/1773 |
| P2 | DEN=1773 ticks → n_hi film=1285, tv=1028 | TB count |
| P3 | hz film = 24000/1001 exact; tv = 30000/1001 exact | double compare |
| P4 | FAULT_FIXED_VTOTAL → hz≈24.000672 / 30.000840 ≠ NTSC | RED twin |
| P5 | FAULT_BRES_EXACT_INT → n_hi 35/28; hz=24/30 exact | TB |
| P6 | Jitter one line = 1182/20e6 = 59.1 µs | arith |
| P7 | bit34 not consumed | structural grep |
| P8 | B15 still not closed (swap≠advance) | core note + wall |

## Results (measured)

| ID | Result |
|----|--------|
| P1 | **HIT** parent miss published: wrong mean@705=705.275; right@706=705.725 |
| P2 | **HIT** green TB n_hi=1285/1028 |
| P3 | **HIT** hz=23.976023976023978 and 29.970029970029969 (err 0) |
| P4 | **HIT** fixed 24.000672018817 / 30.000840023521 |
| P5 | **HIT** n_hi=35/28; hz=24.0 / 30.0 |
| P6 | **HIT** 59.1 µs (prior arith) |
| P7 | **HIT** comments only mention RESERVED |
| P8 | **HIT** wall b15_closed=false; swap_pending not advance |

Gate: `tests/unit/test_bresenham_vtotal_impl.sh` **true rc=0**
