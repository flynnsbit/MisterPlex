# T7 play-file OSD 240p vs L4 PLXJ (host design)

**Worker:** W-osd-720p. **HOST_DESIGN_OK.** Soft-skip ≠ PASS.
**`--decode` ≠ OSD 720p ≠ raster PASS.** ACK ≠ unique pfps.
**P3-720P24** stays **IN_PROGRESS / pfps FAIL**. **P4-DISPLAY / P4-720P-MIX** stay **TODO**.
**FIT_GO=NO.** Next T7 retry is **PARENT-owned only**. This worker: ZERO Quartus,
ZERO menu, ZERO play, did **not** kill misterplexd **24016**.

Cite: `/tmp/misterplex-agent-W-t7-j.txt` + lab `/tmp/misterplexd.t7j.log` +
`/tmp/misterplex-agent-W-lab-plxd.txt` + `J_480P_PLAY_REJECT.md`.

Product-tree copy: `/home/shawn/Projects/MisterPlex-wt-480p-lessons/Memory/lab/status/T7_PLAYFILE_OSD_720P.md`.

---

## What T7-j actually logged

Play instance **did not run frames** (`PLAY_RC=1`, ~1 s wall).

```
media: OSD word=0x6000 ... content_res=240p display_res=240p decode=320x240
media: idle screen painted (mode=0)
ERROR media: source aspect publish failed: sendSourceAspect: PLXJ ACK timeout
      want=16:9 token=1 last=4:3 token=0
misterplexd: play-file failed: source display aspect unavailable
```

`--decode 1280x720` was on the argv. OSD still 240p/320x240. Soft-skip ≠ PASS.

---

## 1. Why last=4:3 token=0 and OSD 240p at play start

### OSD word `0x6000` is 240p/240p (Main-owned)

`decodeOsdWord` (`host/libmisterplex/osd_menu.hpp`):

| Bits | `0x6000` | Meaning |
|------|----------|---------|
| `O[5:4]` | `0` | **content = 240p** (320×240) |
| `O[15:14]` | `1` | **display = force 240p** (not Follow) |
| `O[13]` | `1` | reserved HPS DDR kick/bank (ignored by decode) |
| rest | `0` | resync on, A/V offset 0 |

Main_MiSTer owns the word (`Plex_v7.CFG`). The daemon **never** writes those bits
(`kOsdOwnedMask` comment). A play-file start cannot publish 720p into F12 without
fighting Main or a **menu / CFG+reload** (forbidden on this ticket).

`OSD_CONTROL=1` → `startOsdPoll` → first mailbox sample applies `0x6000` **before**
`probeSourceAspect` / `setSourceAspect` (ffmpeg probe gives the poll thread time).
That is the `content=240p display=240p decode=320x240` line.

### `--decode 1280x720` did not own `outW_`/`outH_`

Two independent host losses (either is enough to miss L4):

1. **Conf overwrites CLI.** `main.cpp` parses `--decode` first, then
   `loadConf(DECODE)` **unconditionally replaces** `decodeW/H`. W-t7-j wrote
   “DECODE=640x480 (overridden by `--decode` 1280x720)” — **that is inverted**.
   Default `decodeW/H` is **320×240**. A 240p persist (`persistOsdResToConf`
   writes `DECODE=`**display**) also lands 320×240. Logged `decode=320x240`
   matches default / 240p DECODE, not a winning CLI 1280×720.
2. **`osdRetargetDecodeSizeFromPresented` only grows to L4.** Display 240p
   returns false: it will **not** raise 320×240 → 1280×720, and it will **not**
   shrink a live L4 canvas. Play-file never re-`setDecodeSize` after OSD seed.
   GDM does `setDecodeSize(displayRes)` before ACK — with `0x6000` that is
   **also** 320×240.

`--decode` flag ≠ live decode size ≠ OSD 720p.

### `last=4:3 token=0` is the **default ACK struct**, not fabric 4:3

`SourceAspectAck` defaults to `x=4 y=3 token=0`.
`sendSourceAspect` (250 ms):

- token = `sourceAspectToken_+1` (**1**) unless `readSourceAspectAck(baseline)`
  succeeds;
- T7-j used **token=1** → **baseline read failed**.

`readSourceAspectAck` maps **`ddrLayout_.doorbell_phys + 0x130`**.
Layout follows `outW_`/`outH_`:

| Canvas | doorbell | host PLXJ poll |
|--------|----------|----------------|
| 320×240 | `0x3007F000` | **`0x3007F130`** |
| 640×480 / true480 | `0x300FF000` | `0x300FF130` |
| **1280×720 L4** | **`0x3047F000`** | **`0x3047F130`** |

`968b828a` is compile-locked L4. RTL `ASPECT_MAILBOX_PHYS = DOORBELL_PHYS+0x130`
→ fabric publishes PLXJ at **`0x3047F130`**.

W-lab-plxd **21:25:59Z** (CORE=Plex, **before** T7-j play) already had live L4 PLXJ:

- `0x3047F130` lo=`0x504c584a` (**PLXJ** magic)
- hi=`0x2301402f` → **47:20 token=35** (same class as `J_480P_PLAY_REJECT`)

If T7-j had polled L4, baseline token would have been **35**, next token **36**,
not 1. `last=4:3 token=0` means the play instance was reading the **240p window**
(empty / not magic) and printed the default struct. It is **not** proof the
scaler was latched 4:3. `Plex.sv` defaults `VIDEO_ARX/ARY` to 4:3 only while
`source_aspect_valid=0`; ioctl 4 (`PLXA`) is independent of doorbell and may
already have committed 16:9 to the ingest even though play aborted.

ioctl 4 path: `encodeSourceAspectPacket` + `sendFileTx(..., index=4)` →
`source_aspect_ingest` (16:9 passes the 4× ratio clamp) → `ddr_frame_store`
writes PLXJ at the **compile-locked** L4 address. Host 250 ms wait never sees it
if `doorbell_phys` is `0x3007F000`.

`J_480P_PLAY_REJECT.md`: same RBF **did ACK** (tokens 34/35) while decode stayed
**1280×720** (osdRetarget refused to shrink L4). OSD 480p ≠ ACK fail. **Wrong
doorbell ≠ missing PLXJ RTL.**

Even the claimed conf `DECODE=640x480` would still poll `0x300FF130` and miss
L4. Only **1280×720** hits `0x3047F130`.

---

## 2. Named host-only sequence (parent T7 only)

**Do not** second-menu. **Do not** write `Plex_v7.CFG` / fight Main OSD.
**Do not** kill **24016** except inside the parent play window (one soft-stop).
**Do not** Quartus. Soft-skip ≠ PASS.

OSD 720p bits are **not required** for a PLXJ ACK on this RBF (J_480P).
P4-DISPLAY (HDMI still 640×480@59.9 under 1280×720@24) is a **different gate**.

### Sequence **T7_SIDECAR_L4_CONF** (no new binary)

Use a **sidecar conf**, do **not** upsert live `/media/fat/misterplex/misterplex.conf`
(idle `persistOsdResToConf` / next 24016 restart).

1. Parent-only: confirm CORE=Plex, RBF **`968b828a`**, port 3005 owner **24016**.
   Optional RO peek (no write): `0x3047F130` magic `PLXJ` vs `0x3007F130` absent.
2. Write `/tmp/t7-l4.conf` with the play keys only:
   `PRESENT=fpga`, `DECODE=1280x720`, **`OSD_CONTROL=0`**, `AV_RESYNC_DROP_MS=0`,
   `IDLE_SCREEN=logo`, plus the usual `AUDIO_*` / `FFMPEG_*` the lab already uses.
   `OSD_CONTROL=0` skips `startOsdPoll` so `0x6000` cannot log a 240p canvas
   (and does not park v3 A/V bits — play-file does not need the menu).
3. Soft-stop supervise + TERM misterplexd (**no -9**). One instance.
4. `MPX_FABRIC_DIRECT=1 AV_RESYNC_DROP_MS=0` \
   `misterplexd --conf /tmp/t7-l4.conf --decode 1280x720` \
   `--play-file /tmp/real720p_1500k_dar.mp4 --play-seconds 15`
5. Expect **no** `decode=320x240` line. Expect
   `source aspect=16:9 owner=MiSTer_native_scaler ack=matched`
   (baseline token from L4, **not** token=1 against last=4:3/0).
6. Then and only then score `media: frames= … pfps= … drops=`.
   ACK ≠ ≥23.9. Chevron ≠ unique-24. 24 Hz beam ≠ 24 unique fps.
7. Restore supervise. Do **not** second play from a worker.

`--decode` stays on argv as documentation; **sidecar `DECODE=1280x720` is what
survives today’s conf-over-CLI load order**.

### Sequence **T7_PLAYFILE_L4_THEN_PLXJ** (future host patch; not this ticket)

When a parent host-deploy is allowed:

1. **CLI_DECODE_WINS** — apply `--decode` **after** conf `DECODE`, or ignore conf
   `DECODE` when `--decode` is present.
2. **PLAYFILE_RESTORE_L4** — after OSD first sample, if CLI/clip is 1280×720,
   `setDecodeSize(1280,720)` again (OSD 240p/480p must not keep a 240p doorbell
   on a compile-locked 720p24 RBF).
3. **L4_LAYOUT_BEFORE_ACK** — `setDdrFrameLayout` 1280×720 so
   `readSourceAspectAck` is `0x3047F130`, then `sendSourceAspect`.
4. **ACK_WAIT** — keep the token+ratio match. **Do not** skip ACK. **Do not**
   lengthen 250 ms as the first fix (wrong window still fails; J_480P already
   ACKed in-window on L4). Optional 1 s only after L4 is proven, if a later
   token starves (J_480P `token=35` class).
5. Still no second menu. Still `--decode` ≠ OSD 720p ≠ raster PASS.

### What not to do

| Knob | Verdict |
|------|---------|
| F12 Content/Display → 720p + save | Needs menu / CFG reload. **Forbidden** here. |
| Upsert live `DECODE=1280x720` | Works on next process, fights idle persist. Prefer sidecar. |
| Longer ACK only | **NO** while poll is `0x3007F130`. |
| Skip ACK / “force aspect” | Ungates play without proving `VIDEO_ARX`. Not a hard gate. |
| Second play / second menu / Quartus | **NO.** Parent owns retry. **FIT_GO=NO.** |

---

## Honesty

- T7 unique pfps is still **FAIL / not measured** (0 frames).
- **HOST_DESIGN_OK ≠ T7 PASS.**
- **DEPLOY_OK ≠ pfps PASS.** **IDLE_SWAP ≠ T7.**
- HDMI overlay **640×480@59.9** under requested 1280×720@24 remains **P4-DISPLAY**.
