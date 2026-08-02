# Colour patch contract (fixture ↔ w-instr detector)

**Status:** caller_supplied design for promo “scoreable” fixtures.  
**Purpose:** replace crude green-dominance guesses with **known-hue patches at known coded coordinates**.  
**Encoder path:** patches are drawn in **RGB full-swing** then encoded H.264 yuv420p (Expect chroma bleed at edges — sample **inner 50%** of each patch).

## Coordinate system

- Origin: top-left of the **coded** frame (not capture).
- `W`, `H` = coded width/height.
- ID band occupies `y ∈ [0, id_bottom)` where `id_bottom = geometry_for(W,H).bar_y1`  
  (624×480 → 88; scales with height — see `tools/glass_frame_id.py`).
- **Active body** = `y ∈ [id_bottom, H)`.
- Patch rectangles are defined as **fractions of the active body**, then converted to integer pixels.

```
body_h = H - id_bottom
x0 = floor(fx0 * W)
x1 = ceil(fx1 * W)
y0 = id_bottom + floor(fy0 * body_h)
y1 = id_bottom + ceil(fy1 * body_h)
# then force even x0,y0 and odd-exclusive x1,y1 for 4:2:0 friendliness
```

## Patch table (six primaries + greys)

Left → right row in the **lower third** of the body. All present on **every frame** (no `enable=`).

| id | name | RGB (8-bit full) | fx0 | fx1 | fy0 | fy1 | assert (coded, inner ROI) |
|----|------|------------------|-----|-----|-----|-----|---------------------------|
| R | red | (255, 0, 0) | 0.04 | 0.18 | 0.72 | 0.94 | R − max(G,B) ≥ 80 |
| G | green | (0, 255, 0) | 0.20 | 0.34 | 0.72 | 0.94 | G − max(R,B) ≥ 80 |
| B | blue | (0, 0, 255) | 0.36 | 0.50 | 0.72 | 0.94 | B − max(R,G) ≥ 80 |
| Y | yellow | (255, 255, 0) | 0.52 | 0.66 | 0.72 | 0.94 | min(R,G) − B ≥ 80 |
| C | cyan | (0, 255, 255) | 0.68 | 0.82 | 0.72 | 0.94 | min(G,B) − R ≥ 80 |
| M | magenta | (255, 0, 255) | 0.84 | 0.98 | 0.72 | 0.94 | min(R,B) − G ≥ 80 |

### Neutrals (upper body, for range/matrix)

| id | name | RGB | fx0 | fx1 | fy0 | fy1 | assert |
|----|------|-----|-----|-----|-----|-----|--------|
| W | white | (240, 240, 240) | 0.04 | 0.18 | 0.08 | 0.28 | mean ≥ 200; max−min channel ≤ 25 |
| K | near-black structure | (32, 32, 32) | 0.20 | 0.34 | 0.08 | 0.28 | mean ∈ [16, 64]; **not** used for freeze |
| N18 | 18% grey | (46, 46, 46) | 0.36 | 0.50 | 0.08 | 0.28 | mean ∈ [30, 70] |

**Do not** use K/near-black for freeze detection — that is ERROR 13 class. Freeze = glass ID `n` monotonicity only.

## Capture-space note (1080p grabber)

If the device letterboxes/pillarboxes, map coded → capture with the measured content rect, then apply the **same fractions inside the content rect**. w-instr should:

1. Locate content rect (non-pad), or use glass ID plate top edge as `y=0` coded proxy.  
2. Compute `id_bottom_cap` from bar decode or fraction `bar_y1/H * content_h`.  
3. Sample **inner 50%** of each patch AABB in capture pixels.  
4. Assert the table above on **mean RGB** (or YUV→RGB with documented matrix).

## Worked example — 624×480

`id_bottom=88`, `body_h=392`

| id | x0:x1 | y0:y1 (coded) |
|----|-------|---------------|
| R | 24:112 | 88+282=370 : 88+368=456 |
| G | 124:212 | 370:456 |
| B | 224:312 | 370:456 |
| Y | 324:412 | 370:456 |
| C | 424:511 | 370:456 |
| M | 524:611 | 370:456 |

(Exact integers come from the generator; this table is illustrative — **trust `*.meta.json` `colour_patches_px`.**)

## Generator

`scripts/gen_promo_scoreable_fixture.py` draws these patches every frame after content composite and before/with glass ID (ID band wins on overlap — patches stay in body).

## Version

`colour_patch_contract_version = 1` — bump if coordinates change; w-instr must pin the version from fixture meta.
