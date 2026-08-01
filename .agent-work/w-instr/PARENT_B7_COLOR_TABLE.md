# B7 colour close-out + provenance payoff

Branch: `w-instr-provenance`  
OSD note: keep `output=DEFAULT_ASSUMED` until w-osd-hires measures it; then
`source=measured` or `source=ini` only — never silent upgrade of a guess.

## Single-frame colour table (all metrics `[measured]`)

| name | color_fail | kinds | structure | red_bar | spread | rc_hint |
|---|---|---|---|---|---|---|
| le3_c5382bee_broken | True | GREEN+CHROMA | OK | n/a | 115.52 | **2** |
| DDR_PLAYBACK_CORRECT | False | — | OK | **OK** | 5.37 | **0** |
| cap480a f_018 magenta | True | **MAGENTA**+RED_BAR_MISSING | FAIL | MISS | 200.08 | **3** |
| cap480a f_022 green | True | GREEN+CHROMA | FAIL | n/a | 174.33 | **3** |
| cap480b f_049 flash | False | — | OK | **OK** | 4.8 | **0** |
| cap480b f_030 dark | False | — | OK | n/a | 4.87 | **0** |
| cap240fs f_020 | False | — | OK | n/a | 4.81 | **0** |

Thresholds `RED_BAR_DOM_MIN=0.25`, `FLASH_LUMA_MIN=100` are `[DEFAULT_ASSUMED]`.

## Burst scores (`true rc` direct)

```
python3 tools/hdmi_motion_instrument.py /tmp/cap480a --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured; echo "true rc=$?"
→ color=GREEN+MAGENTA+BLUE+GREYSCALE+RED_BAR_MISSING_CAST_FAIL
  structure=VERT_DUP=15+HORIZ_WRAP=8
  VERDICT=STRUCTURE_FAIL rc=3
  magenta_cast_frames=4 red_bar_missing_frames=11 green_cast_frames=27

python3 tools/hdmi_motion_instrument.py /tmp/cap480b ...; echo "true rc=$?"
→ COLOR_OK RED_BAR_MISSING=0 VERDICT=MOTION_OK rc=0

python3 tools/hdmi_motion_instrument.py /tmp/cap240fs ...; echo "true rc=$?"
→ COLOR_OK VERDICT=MOTION_OK rc=0

# stills (×5 copy to meet frame floor)
le3  → COLOR_FAIL rc=2  GREEN+CHROMA
DDR  → COLOR_OK; motion UNSCORED rc=77 (single still, no counter advance — not a colour pass claim)
```

## What closed B7

Not green-only. Fail classes:
1. GREEN cast fingerprint  
2. CHROMA spread (any axis)  
3. **MAGENTA** explicit (high R+B, crushed G) — parent milestone frame  
4. BLUE explicit  
5. GREYSCALE / chroma-constant  
6. UV_SWAP  
7. **RED_BAR_MISSING** on flash/white field (RK fixture red bar must be red-dominant)

## Provenance

Load-bearing colour counters print `N [measured]`. Design thresholds tagged
`DEFAULT_ASSUMED`. Rate still refuses `DEFAULT_ASSUMED` src_fps.

## Self-test

`python3 tools/hdmi_motion_instrument.py --self-test; echo "true rc=$?"` → 0  
Includes magenta-without-green, flash+red OK, flash-without-red FAIL.
