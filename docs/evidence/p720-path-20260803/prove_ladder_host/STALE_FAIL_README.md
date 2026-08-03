# STALE — do not treat as regression

`run_540.txt`, `run_360.txt`, and `run_540_trap.txt` in this directory were
captured at **04:09** against **`/library/metadata/1`** (320×240 SD) while the
ffmpeg header path still returned `rc=8` / `NO-DATA`.

Authoritative host proof is **`run_all.txt` (04:10)** against
**`/library/metadata/2`** (1080p): `FAILS=0` with

- 540 → 960×540 @24  
- 360 → 640×360  
- 540-trap → 720×404  

Parent re-ran metadata/1 later and got **healthy** `rc=0` delivery **320×240**
(not NO-DATA) — PMS does not upscale; the old rc=8 was a separate transient.

These three FAIL files are **kept only as historical mis-keys**, not as product
verdicts. Prefer `run_all.txt` and
`docs/evidence/p720-path-20260803/pms_clamp_rule/matrix.txt`.
