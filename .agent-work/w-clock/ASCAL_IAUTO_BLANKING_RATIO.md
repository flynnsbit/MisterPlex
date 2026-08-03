# Ascal iauto vs extreme H blanking (H_DE=320, H_TOTAL=1182)

## Question
At H_DE=320, blanking = 1182−320 = **862** (ratio blank:active **2.69:1**).
Does ascal `iauto` still measure content correctly?

## Answer (source-backed): **YES — blanking is invisible to iauto**

`ascal.vhd` measures input size from **DE edges only**, not from H_TOTAL:

```
-- ascal.vhd ~1263-1276 (quoted from tree)
IF i_pde='1' AND i_de_pre='0' THEN   -- DE rising
  i_vimax<=i_vcpt;
  i_hcpt<=0;
ELSE
  i_hcpt<=(i_hcpt+1) MOD 4096;
END IF;

IF i_pde='0' AND i_de_pre='1' THEN   -- DE falling
  i_himax<=i_hcpt;
END IF;

IF i_iauto='1' THEN
  i_hmin<=0;
  i_hmax<=i_himax;   -- = clocks while DE was high (active width)
  i_vmin<=0;
  ...
  i_vmax<=i_vimax;   -- from DE/VS path (active height)
END IF;

i_hsize <= (4096+i_hmax-i_hmin+1) MOD 4096;  -- active width class
```

**ih** = duration of `i_de` high per line ≈ **H_DE**, not H_TOTAL.
**iv** = active DE lines between VS events ≈ **V_ACTIVE**.

Horizontal blanking (862 clocks with DE=0) does not contribute to `i_himax`.

| H_DE | H_TOTAL | H_BLANK | blank:active | iauto ih class |
|-----:|--------:|--------:|-------------:|----------------|
| 320 | 1182 | 862 | **2.69:1** | **320** (DE only) |
| 416 | 1182 | 766 | 1.84:1 | 416 |
| 624 | 1182 | 558 | 0.89:1 | 624 |
| 960 | 1182 | 222 | 0.23:1 | 960 |

12-bit counters (`uint12`, MOD 4096): max line 1182 ≪ 4096 — **no wrap hazard**.

## What extreme blanking *does* affect
- Duty cycle / average pixel rate (lower for small DE) — **helps** bandwidth
- Time available for DDR line fetch during blanking — **helps** underrun margin
- Not iauto size detection

## Evidence gate
`tests/unit/test_ascal_iauto_de_only.sh` — quotes the VHDL predicates and
checks arithmetic; fails if iauto is rewritten to use full line length.
