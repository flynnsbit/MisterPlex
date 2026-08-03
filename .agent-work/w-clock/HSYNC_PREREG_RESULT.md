# PRE-REGISTER results (post-measure)

| Item | PREDICT | RESULT |
|------|---------|--------|
| L4 HSync asserted_cycles | 0 (CONFIRMED bug) | **HIT** — model+RED sim width=0 |
| VSync L4 6 lines @728 | ASSERTS OK | **HIT** — even pre-fix; post-fix exact 6@728 |
| PLL 29.70 wrong for L4 | need ~24.0 | **HIT** — retargeted default to 24.000000 MHz |
| PPC=2 product unlock | aspirational (force PPC==1) | **HIT** — present_core gate still forces PPC==1 |

No MISS published on this batch.
