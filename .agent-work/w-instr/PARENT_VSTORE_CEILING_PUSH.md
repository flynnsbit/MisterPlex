# Parent card — V_STORE even/odd ceiling via product `publishDdrFrame`

**Agent does not touch the device.** You run every step. Capture `true rc=$?` **directly**.

## Why this path

- H.264 destroys 1-row Nyquist stripes → spectral tests INCONCLUSIVE.
- Product DDR path is **I420/YUV420p** coded **624×480** via `FpgaSpi::publishDdrFrame` (playback).
- Tool: `build/arm/push_frame` (built by `make arm-plexd`)
  - `--ddr --pattern …` → built-in I420 → `sendYuv420pFrameDdr` → **same publish path as MediaPlayer**
  - File form: `--ddr --yuv420p 624x480 FILE.i420` (fixtures from `scripts/gen_vstore_evenodd_i420.py`)

## PRE-REGISTER (commit before capture) — current RBF `c5382bee`

| Pattern | Glass prediction |
|---------|------------------|
| `mid_grey` (CONTROL) | uniform **MID_GREY** |
| `even_black` | solid **BLACK** |
| `even_white` | solid **WHITE** |
| `odd_black` | solid **WHITE** (phase invert) |
| `odd_white` | solid **BLACK** |

**Falsifiers**
- Control ≠ mid-grey → **UNSCORED** (path broken; do not score ceiling).
- `even_black` class **identical** to `even_white` → **CEILING_FALSIFIED** (retract 240-row claim).
- After w-geom T7 (480 unique rows): even_black/even_white should **no longer** collapse to opposite solids — bank this “before” now.

## Daily-driver safety

`misterplexd` and `push_frame` both take SPI/Main + DDR banks. **Stop the daemon before push; restore after.**

```bash
# On device (example — use your real service unit if different)
killall misterplexd 2>/dev/null || true
# optional: confirm Main free
# After test:
#   redeploy/restart misterplexd (scripts/deploy_misterplexd.sh from host)
```

Do **not** leave Main stopped. If `push_frame` crashes mid-open, follow stranded-Main recovery in `fpga_spi.hpp` notes / lab checklist.

## Host prep

```bash
cd /path/to/MisterPlex   # repo or worktree root
make arm-plexd           # builds build/arm/push_frame + misterplexd; ~7 min
# true rc must be 0 — capture DIRECTLY:
make arm-plexd
echo "true rc=$?"

python3 scripts/gen_vstore_evenodd_i420.py -o .agent-work/w-instr/vstore-evenodd-i420
# optional file fixtures; patterns below need no scp of .i420

scp build/arm/push_frame root@${MISTER_HOST:-192.168.1.183}:/media/fat/misterplex/push_frame
```

## Device protocol (one pattern at a time)

Warm grabber first (discard ~12–15 junk frames) — never score `ffmpeg -frames:v 1` alone as truth.

```bash
HOST=${MISTER_HOST:-192.168.1.183}
CAP=./.agent-work/w-instr/vstore-ceiling-caps   # host path
mkdir -p "$CAP"

# 0) stop daemon on device
ssh root@$HOST 'killall misterplexd 2>/dev/null; sleep 1; echo stopped'

# 1) CONTROL first
ssh root@$HOST '/media/fat/misterplex/push_frame --ddr --pattern mid_grey --hold-ms 5000'
# while hold (or after push — bank sticks until next publish):
fuser -v /dev/video0 2>&1 | head -5
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 -i /dev/video0 \
  -frames:v 20 -y "$CAP/warm_%03d.png"
cp "$CAP/warm_018.png" "$CAP/mid_grey.png"   # pick late frame after warm-up

# 2) even_black
ssh root@$HOST '/media/fat/misterplex/push_frame --ddr --pattern even_black --hold-ms 5000'
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 -i /dev/video0 \
  -frames:v 20 -y "$CAP/eb_%03d.png"
cp "$CAP/eb_018.png" "$CAP/even_black.png"

# 3) even_white
ssh root@$HOST '/media/fat/misterplex/push_frame --ddr --pattern even_white --hold-ms 5000'
ffmpeg ... -frames:v 20 -y "$CAP/ew_%03d.png"
cp "$CAP/ew_018.png" "$CAP/even_white.png"

# 4) optional phase invert
ssh root@$HOST '/media/fat/misterplex/push_frame --ddr --pattern odd_black --hold-ms 5000'
# → odd_black.png ; odd_white similarly

# 5) RESTORE daemon
# scripts/deploy_misterplexd.sh   or systemctl/start your unit
ssh root@$HOST '...'   # your restore
```

720p60 OK if preferred: `-video_size 1280x720` (grabber 1080p caps 30 fps).

## Score (host)

```bash
python3 tools/hdmi_vstore_discriminate.py --flat-suite "$CAP"
echo "true rc=$?"
# expect on c5382bee: VERDICT=CEILING_240_HOLD rc=0
# control fail: rc=77 UNSCORED
# identical phases: rc=2 CEILING_FALSIFIED

python3 tools/hdmi_vstore_discriminate.py --self-test
echo "true rc=$?"
```

## File-based publish (optional)

```bash
scp .agent-work/w-instr/vstore-evenodd-i420/*.i420 root@$HOST:/tmp/
ssh root@$HOST '/media/fat/misterplex/push_frame --ddr --yuv420p 624x480 /tmp/even_black.i420 --hold-ms 5000'
```

## After w-geom ceiling fix

Re-run **identical** card. “Before” bank lives under `.agent-work/w-instr/vstore-ceiling-caps`.  
After fix, solid BLACK/WHITE collapse should **break** (stripes or grey average) — that is the glass proof.


---

## ESTABLISHED BEFORE (parent 2026-08-01, c5382bee) — do not re-litigate

Parent-run, pre-registered, 5/5 hit, **std=0.00** all fields:

| pattern | mean | std | class |
|---------|------|-----|-------|
| mid_grey | 137.0 | 0.00 | MID_GREY CONTROL |
| even_black | 7.0 | 0.00 | BLACK |
| even_white | 255.0 | 0.00 | WHITE |
| odd_black | 255.0 | 0.00 | WHITE invert |
| odd_white | 7.0 | 0.00 | BLACK invert |

Bank: `.agent-work/w-instr/VSTORE_CEILING_BEFORE_c5382bee.json`  
**Vertical 240 ceiling is fact.** H 529/640 not proven here.

## AFTER w-geom T7 (unique rows 240→480)

Identical capture protocol. Score with:

```bash
python3 tools/hdmi_vstore_discriminate.py --flat-suite "$CAP" --expect-after-fix
echo "true rc=$?"
# want: VERDICT=AFTER_FIX_OK rc=0  (collapse BROKE)
# bad:  VERDICT=AFTER_FIX_STILL_240 rc=2  (still opposite solids — fix not on glass)
# bad:  rc=77 UNSCORED (control failed)
```

BEFORE mode (reconfirm current core only):

```bash
python3 tools/hdmi_vstore_discriminate.py --flat-suite "$CAP"
# want CEILING_240_HOLD on c5382bee
```

## STALE / freeze (related safety defect)

On c5382bee, `frames_done` advances every vsync → ARM `[STALE]` cannot see a frozen picture.
**Do not use PLXD frames_done for freeze.** Use glass:

```bash
python3 tools/glass_hold_skip.py CAP_DIR --templates T.pkl --pts pts.csv \
  --source-fps 24 --capture-fps 60 --refresh-hz 60 --force-mode 720
echo "true rc=$?"
```

