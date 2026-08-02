# PARENT — grabber_preflight real-path harden + locus v2 status

branch: w-instr-provenance
SHA: (see git log after commit)

## 1. Parent crash — verified class

Quoted parent traceback:
```
__import__("PIL.Image", fromlist=["Image"]).Image.open(path)
AttributeError: type object 'Image' has no attribute 'open'
```
`__import__(..., fromlist=["Image"])` returns the **module**; trailing `.Image` is the **class** `PIL.Image.Image`, which has no `.open`.

**Coordinate:** w-promote may one-line-fix an older tree. This lane owns the deeper audit + self-test. Production form is now:
```python
from PIL import Image
...
Image.open(path).convert("RGB")   # grabber_preflight.py classify_png_path
```

## 2. Real-path-only call sites (audit — production body only)

| site | risk if broken | harden |
|---|---|---|
| `query_dv_timings` → `v4l2-ctl --query-dv-timings` | missing binary / device | returns unlocked=False with nulls; decide may UNSCORED |
| `fuser_busy` → `fuser -v` | missing fuser | returns None (no busy block) |
| `sample_frame` → `ffmpeg -f v4l2` | busy / no signal / fail | NEVER raises; returns ok=False |
| `classify_png_path` → `PIL.Image.open` + `classify_frame_signal` | **parent crash class** | NEVER raises; try/except → ok=False |
| `run_preflight` outer try | any uncaught | → VERDICT=UNSCORED rc=77 + NOTE do-not-rollback |

**Inject-stats alone is not proof** — parent verified: inject returned 78 while real path crashed. Self-test now exercises:
- inject 7,7,0 → rc=78 + ACTION text
- inject real extrema → rc=0
- `classify_png_path` on uniform pixel-7 PNG (real PIL.open)
- `classify_png_path` on non-uniform PNG
- `sample_frame` on missing device (must not raise)
- `sample_frame` with mocked ffmpeg writing uniform PNGs (full PIL path)
- `decide` DV 0x0 → rc=78 even if frame sample failed
- source audit forbids broken `__import__(...PIL.Image...).Image.open` in production

## 3. Host evidence (this machine, agent-run — parent re-confirm)

```
python3 tools/grabber_preflight.py --self-test; echo "true rc_self=$?"
→ SELF_TEST_OK true rc_self=0

python3 tools/grabber_preflight.py --inject-stats 7,7,0; echo "true rc_inj=$?"
→ VERDICT=CAPTURE_NO_SIGNAL ... ACTION: ... do NOT rollback ... true rc_inj=78

# live dead grabber (agent observed once; YOU re-run):
python3 tools/grabber_preflight.py --device /dev/video0; echo "true rc=$?"
→ dv_timings active=0x0 pixelclock_hz=0.0 locked=False
→ sample_frame signal_class=NO_SIGNAL min=7 max=7 std=0.0 mean=7.0
→ VERDICT=CAPTURE_NO_SIGNAL rc=78 ... ACTION: do NOT rollback ...
```

## 4. Locus480 saturation — ALREADY SHIPPED (v2)

Parent quote still shows v1 refusal reason:
`too_few_degraded_seconds n=1 need>=5`

That string is **v1**. Tip at prior commit `b2e3f886` already has magnitude/dynamics + saturation guard.
**Pull branch and re-run verdict** — do not rebuild v2.

```
python3 tools/locus480_local_vs_supply.py --self-test; echo "true rc=$?"
# expected HEALTHY/LOCAL/SUPPLY/INSUFFICIENT/SESSION_INVALID paths, rc=0
```

MISS_v1 published: binary `recv_q>0` and any-`pipe_write` pinned at 1.0 on healthy paced playback (audio pacer back-pressure). Kept finding: socket never empty → steady-state supply starvation refuted.

residual=1 policy: **exact, not rounded**; classified `near_closed_abs_le_1` when |residual|<=1 on reconstructed split-line pairing — still `reconstructed` provenance, never claimed measured.

## Commands for parent
```bash
cd /path/to/worktree   # w-instr-provenance
python3 tools/grabber_preflight.py --self-test; echo "true rc=$?"
python3 tools/grabber_preflight.py --device /dev/video0; echo "true rc=$?"
python3 tools/locus480_local_vs_supply.py --self-test; echo "true rc=$?"
```
