# PLXG q5 — aspect + cadence publish (w-path, ABI arbitration #2)

## Ownership
- **w-path**: select + pack + daemon publish of DAR/fps values (this note).
- **w-mem**: q5 in `plxg_record` / mailbox / RTL latch + B16 frame-boundary atomicity (**unmerged until their lane lands**).
- **w-scaler**: consume `dar_*` only.
- **w-clock**: consume `content_fps` only.

## Wire (parent freeze)
```
q5 @ doorbell+0x828 LE:
  [11:0] dar_x  [23:12] dar_y  [31:24] content_fps
  [32] dar_valid  [33] fps_valid
  [63:34] RESERVED must be 0 (receiver reject)
```
Record grows 5→6 qwords (40→48 B). Path header: `host/libmisterplex/plxg_q5_aspect_cadence.hpp`.

## Selection rules (never invent)
- DAR: `Stream@pixelAspectRatio` × **measured coded** WxH, else `Media@aspectRatio`. **No** coded_w/coded_h storage fallback (720×480 red twin).
- fps: integer or broadcast family from measured rational (`24000/1001→24`, `30000/1001→30`). Unknown → `fps_valid=0` (not default 24).
- Lab note: `624×350 × SAR 160:117` → **256:105** (coded×SAR). ebec8ab3's 16:9 used height **480**, not coded 350 — do not re-introduce that.

## Daemon surface
- `MediaPlayer::setContentAspectMeta` + `refreshPlxgAspectCadence` after resolve fps and on `MEASURED_DELIVERY`.
- Logs: `media: PLXG_Q5 dar=…` and `misterplexd: PLXG_Q5_SRC …`.
- `lastPlxgQ5()` holds packed qword for w-mem write path (not wired on path until PLXG store merges).

## Tests
```
./build/test_plxg_q5_aspect_cadence   # red: reserved≠0 reject; unknown no 16:9/24; 720×480 no storage AR
```
true rc=0 on host.

## Coordinate
- Atomic promote of q5 with geom: **w-mem B16** (not path).
- Path does **not** edit `present_geom_latch.sv` or mailbox ownership headers in wt-mem.
