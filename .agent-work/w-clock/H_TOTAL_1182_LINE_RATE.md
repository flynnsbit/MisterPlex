# H_TOTAL=1182 line-rate sanity (w-clock)

**clk_sys = 20.000000 MHz** (`pll_0002.v`). Fixed `H_TOTAL=1182`.

## Horizontal frequency (independent of H_DE)

```
f_h = 20e6 / 1182 ≈ 16920.473 Hz  (~16.920 kHz)
```

| Geometry | H_DE | H_BLANK | duty H_DE/HT | f_h |
|----------|-----:|--------:|-------------:|-----|
| 320×240 | 320 | 862 | 0.2707 | 16.920 kHz |
| 416×234 | 416 | 766 | 0.3519 | 16.920 kHz |
| 624×480 | 624 | 558 | 0.5279 | 16.920 kHz |
| 640×360 | 640 | 542 | 0.5415 | 16.920 kHz |
| 960×540 | 960 | 222 | 0.8122 | 16.920 kHz |

## Vertical (with V_TOTAL)

| V_TOTAL | f_v | Role |
|--------:|----:|------|
| 564 | 20e6/(1182×564) ≈ **30.0008 Hz** | TV / 2:1 vs 60 |
| 705 | 20e6/(1182×705) ≈ **24.0007 Hz** | film companion |

## Why not HT = H_DE+222 for every DE?

If blanking tracked DE (HT=H_DE+222):

| H_DE | HT | f_h |
|-----:|---:|----:|
| 320 | 542 | **36.90 kHz** |
| 624 | 846 | **23.64 kHz** |
| 960 | 1182 | **16.92 kHz** |

That is a **~2.2× line-rate swing** across the library. Fixed HT=1182 keeps **constant f_h and f_v**, and small sources only get **more** blanking (ascal-friendly). Parent asked for generous blanking — this is the extreme of generous on the H axis for SD.

**Verdict:** one H_TOTAL suits the 3× DE span **because** line/frame rate stay locked; duty cycle absorbs the span. Not an unexamined assumption — arithmetic above.

Gate: `tests/unit/test_beam_htotal_line_rate.sh`
