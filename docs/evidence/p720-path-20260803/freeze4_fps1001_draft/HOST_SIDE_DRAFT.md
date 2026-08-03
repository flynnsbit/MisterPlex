# Freeze #4 host-side draft — `fps_1001` on q5 bit34

**STATUS: DRAFT ONLY — DO NOT LAND ALONE**

Parent arbitration #4 (2026-08-03):
- Concept **provisionally awarded** (single `fps_1001` flag covers 23.976/29.97/59.94).
- Mechanism (unilateral bit34) **VACATED** until freeze #4 single-window merge.
- Sites that must move atomically: host pack → 6-qword latch → top → beam/cadence → tests.
- Never enable `kPlxgQ5Fps1001OnWire` in isolation.

## Host delta (when parent signs)

1. `host/libmisterplex/plxg_q5_aspect_cadence.hpp`
   - Set `kPlxgQ5Fps1001OnWire = true` (and restore `kPlxgQ5Fps1001Bit = 1ull << 34`).
   - In `packPlxgQ5`: if `in.fps_1001 && kPlxgQ5Fps1001OnWire`, OR bit34.
   - In `unpackPlxgQ5`: read bit34 into `fps_1001` when freeze live; reserved check becomes `[63:35]`.
   - Update comments: reserved starts at 35 under freeze #4.

2. `tests/unit/test_plxg_q5_aspect_cadence.cpp`
   - Invert red twins that currently forbid bit34.
   - Assert film 24000/1001 packs bit34=1 and receiver accepts under new latch contract.
   - Keep negative: bits [63:35] still reject.

3. `arm/misterplexd/fpga_spi.cpp` `writePlxgQ5`
   - No API change if it already uses `plxgQ5ToMailboxWords` / reserved helper.
   - Re-run unit + misterplexd host build.

## Must NOT change until w-mem publishes byte-exact layout

- w-mem `present_geom_latch.sv` reserved mask
- w-clock consumer ports
- Plex.sv `plxg_*` nets
- Any partial main merge of host-only bit34

## Residual under ABI #2 (current live wire)

```
beam24 = 20e6/(1182*705) = 24.000672  vs  24000/1001 = 23.976024
  -> slip 0.024648 fps ≈ 1 repeat / 40.57 s
beam30 = 20e6/(1182*564) = 30.000840  vs  30000/1001 = 29.970030
  -> slip 0.030810 fps ≈ 1 repeat / 32.46 s
```

Host retains `fps_num`/`fps_den`/`fps_1001` for ARM pacing/logs under ABI #2.

## Coordination

w-path ready with this draft. Wait for parent freeze signature + w-mem layout byte dump before flipping the constant.
