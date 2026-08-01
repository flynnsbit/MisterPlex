# Glass frame-ID contract (writer ↔ reader)

**Source of truth:** `tools/glass_frame_id.py`  
**Writer:** `scripts/gen_glass_ledger_fixture.py`  
**Do not re-derive the bar layout from a capture by guessing.** Import the module.

Labels: values below are `caller_supplied` design constants unless marked `measured`.

## Why this exists

Variable-width `TREK24 n=NNNN` OCR produced a 23× false drop rate (e.g. `2358`→`23538`).
Fixed-width digits on an opaque plate fixed digit OCR. The **bar strip is the
authoritative machine channel** so frames where digits fail (~4% class) stay
resolvable, and digit reads can be cross-checked (disagree → `UNRESOLVED`).

## Canvas (default bank)

| field | value | notes |
|-------|-------|-------|
| coded size | **624×480** | DDR bank geometry |
| origin | top-left | x right, y down |
| opaque plate | y ∈ **[0, 56)** full width | solid black `RGB(0,0,0)` — never alpha |
| text | at (8, 6) | yellow `RGB(255,255,0)`, stroke 3 black |
| text format | `G n=DDDDDD c=C` | **exactly 6** zero-padded digits |
| checksum C | `(d0+d1+d2+d3+d4+d5) mod 10` | of the six decimal digits |
| bar strip | y ∈ **[56, 88)** | height 32 (even) |
| cells | **20** | `cell_w = 624 // 20 = **31**` px |
| right margin | 4 px | `624 - 20*31 = 4` unused |
| cell i x-range | `[i*31, (i+1)*31)` | i = 0..19 left→right |
| even-row paint | plate∪bars | odd row copies even row-1 (`present_core` STORE_Y_SCALE=2) |
| chrome exclusion | y ≥ 100 | player chrome lower band — keep ID at top |

Other coded sizes (320×240, 624×352, 640×480, 720×480) use `geometry_for(w,h)`:
same **bit layout**, plate/bar heights and font scaled by canvas ratio.

## Bar bit layout (MSB-left)

| cell index | name | value |
|-----------:|------|-------|
| 0 | START | **1** (white) |
| 1 | G15 | grey bit 15 (MSB) |
| 2 | G14 | grey bit 14 |
| … | … | … |
| 16 | G0 | grey bit 0 (LSB) |
| 17 | PARITY_EVEN | see below |
| 18 | STOP | **0** (black) |
| 19 | LOCK | **1** (white) |

Colours: white = `RGB(240,240,240)`, black = `RGB(0,0,0)`. No intermediate greys.

### Numeric coding

```text
g = (n & 0xFFFF) ^ ((n & 0xFFFF) >> 1)     # binary-reflected Grey code
parity = popcount(g) & 1                    # even parity bit over the 16 grey bits
n_hat = from_grey(g)                        # standard BRGC inverse (xor >>1,2,4,8)
```

- Grey bits are placed **MSB at cell 1** (next to START), LSB at cell 16.
- Parity is chosen so `popcount(grey_bits) + parity` is **even**
  (equivalently `parity == popcount(g) % 2`).
- `n` is only the low 16 bits in the bar; text carries the full zero-padded value.
  For soaks ≤ 65535 frames this is the full index (600 s × 24 = 14400).

### Worked example — `n = 2358`

```text
text     = "G n=002358 c=8"     # 2+3+5+8 = 18 → c=8
g        = 2358 ^ (2358 >> 1) = 0x0DAD
popcount = 10 (even) → parity bit = 0
bits[20] = [1, 0,0,0,0,1,1,0, 1,1,0,1,0,1,1,0, 1,  0, 0, 1]
            S  -------- grey 0x0DAD MSB→LSB --------  P  S  L
```

## Decoder algorithm (no OCR)

Implemented by `decode_bars_from_rgb()`:

1. Sample mean luma in the **center 50%** of each cell at mid-bar y.
2. Threshold = mid of p20/p80 of the 20 means (fallback 128 if low contrast).
3. Require START=1, STOP=0, LOCK=1 else **UNRESOLVED**.
4. Pack cells 1..16 MSB-first → `g`; check parity cell else **UNRESOLVED**.
5. `n = from_grey(g)`; if `n >= 1_000_000` → **UNRESOLVED**.
6. Optional: if digit OCR present and ≠ `n` → **UNRESOLVED** (never pick a side).

### Capture-space geometry (host model — `caller_supplied`, not HDMI-measured)

Modelled path (matches `simulate_capture_chain`):

1. Keep even store rows only → height/2  
2. Bilinear to **1920×1440** (`video_mode=12`)  
3. Bilinear vertical squash to **1920×1080** grabber  

For default 624×480 bank this predicts:

| param | value | formula |
|-------|------:|---------|
| origin_x | 0 | (no pillar in model) |
| pitch | **95.3846…** | `31 * (1920/624)` |
| bar_y0 | **126** | `(56/2) * (1440/240) * (1080/1440)` |
| bar_y1 | **198** | `(88/2) * …` |

**Live HDMI often differs** (ascal letterbox, overscan). Parent measured ~pitch 91.6
and origin_x≈41 at y≈130..205 — use those as **calibrated** `origin_x`/`pitch`/
`bar_y0`/`bar_y1` arguments to `decode_bars_from_rgb`. Do not invent bit order
to force a match; bit order is fixed above.

Calibrate on a known frame: find leftmost white run (START) left edge → `origin_x`;
distance between successive cell centers or START→LOCK span/19 → `pitch`.

## Authority order

1. **Bars** (primary)  
2. Fixed-width text + checksum (secondary / human / template OCR)  
3. Disagree → `UNRESOLVED` — never guess  

## Unit test

`tests/unit/test_glass_frame_id_roundtrip.py` — generator bits ↔ decoder on native
canvas and after simulated capture chain, including historical fail indices
2352 / 2358 / 2378 on dark and white-flash bodies.

## CLI dump

```bash
python3 tools/glass_frame_id.py    # JSON contract_dict()
```
