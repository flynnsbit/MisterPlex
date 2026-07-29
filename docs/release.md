# MiSTerPlex release notes (Phase 5)

Install, configure, and verify a lab or SD deploy. For packaging from source, see `make package` / [`scripts/package_release.sh`](../scripts/package_release.sh).

## Package contents

Typical tarball `dist/misterplex-<git-desc>.tar.gz` expands to `misterplex-<git-desc>/`:

| Path | Purpose |
|------|---------|
| `bin/misterplexd` | Static ARM companion + media daemon (GDM + HTTP `:3005`) |
| `bin/ffmpeg` | Bundled static ARM FFmpeg 7.0.2; no external ffmpeg install required |
| `bin/push_frame` | Optional SPI frame / bitstream push tool (Phase 3) |
| `bin/set_status` | Lab tool: drive Plex OSD CONF_STR bits (pattern / force-bars / TV / FPS / audio / AR) via SPI |
| `conf/misterplex.conf.example` | Conf template |
| `cores/Plex.rbf` | Verified v0.3.0 Phase A playback-controls core; MD5 `41adb98c7a630b541091c22ce291be68` |
| `licenses/ffmpeg/` | GPLv3 text, build provenance, and source pointers for the bundled FFmpeg |
| `docs/` | INSTALL path notes, display/output resolution, release notes, match-source-Hz, CRT/LCD matrix |

## Install on MiSTer SD

```text
/media/fat/misterplex/bin/misterplexd
/media/fat/misterplex/misterplex.conf          # copy from example; edit keys
/media/fat/linux/_user-startup.sh             # start daemon on boot
/media/fat/_Utility/Plex.rbf                  # lab canonical (deploy_plex_core.sh / HW tests)
# alternate OSD paths: /media/fat/_Arcade/Plex.rbf or games/Plex/Plex.rbf
```

### From a release tarball

```bash
# On dev host
tar -tzf misterplex-*.tar.gz
tar -xzf misterplex-*.tar.gz
cd misterplex-*
ssh root@MiSTer "mkdir -p /media/fat/misterplex /media/fat/_Utility"
scp -r bin scripts docs licenses root@MiSTer:/media/fat/misterplex/
scp conf/misterplex.conf.example root@MiSTer:/media/fat/misterplex/misterplex.conf
# Edit conf on device, then:
scp cores/Plex.rbf root@MiSTer:/media/fat/_Utility/Plex.rbf
```

Set at least `PLEX_BASE=http://YOUR-PLEX-SERVER:32400` in
`/media/fat/misterplex/misterplex.conf`. Cast sessions usually bring a transient
token; set `PLEX_TOKEN=` only if you want the on-device browse/menu scripts to
list libraries without a phone or web app. Load the core from MiSTer's OSD
(**F12** → `_Utility` → `Plex`) after starting the daemon.

### From this monorepo (recommended for lab)

```bash
make arm-plexd
make package                    # rebuilds ARM if needed; copies the MD5-verified release Plex.rbf
MISTER_HOST=<mister-ip> ./scripts/deploy_misterplexd.sh
./scripts/deploy_plex_core.sh   # copy RBF; DEPLOY_LOAD=none|menu|core (default none)
```

### Mandatory live PMS Baseline gate for FPGA-decode promotion

Any RBF promoted for FPGA-decode work must have a current live PMS delivered
stream check, or an explicit recorded skip reason. `make unit` only proves the
offline parser/red paths; it cannot prove the live Plex server is still
delivering the FPGA contract:

```text
profile_idc=66, entropy_cabac=0, max_num_ref_frames=1, b_slices=0
coded=624x480, display=618x480
```

Use the secret-safe wrapper; it prompts for the PMS token with `read -rs`, never
accepts a token on argv, refuses an already-exported `PLEX_TOKEN`, and removes
its temporary curl secret config on exit:

```bash
set +x
PLEX_BASE=http://YOUR-PLEX-SERVER:32400 \
MISTERPLEX_BASELINE_KEY=/library/metadata/N \
make pms-baseline-live
```

A pass writes `build/pms-baseline-live-gate/PASS.stamp` with non-secret
provenance. For decode promotion through the normal deploy script, mark the
purpose explicitly:

```bash
DEPLOY_DECODE_PROMOTION=1 DEPLOY_LOAD=none ./scripts/deploy_plex_core.sh path/to/Plex.rbf
```

`DEPLOY_DECODE_PROMOTION=1` refuses without the pass stamp unless the operator
sets `PMS_BASELINE_LIVE_SKIP_REASON='...'` to consciously record why the live
PMS Baseline gate was skipped. Credential-less environments should skip cleanly;
do not make `make unit` depend on live PMS credentials.

Startup hook (idempotent via deploy script):

```bash
/media/fat/misterplex/bin/misterplexd \
  --name MiSTerPlex --id misterplex-dev --port 3005 \
  --conf /media/fat/misterplex/misterplex.conf \
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
```

Verify:

```bash
curl -s http://MiSTer:3005/resources | grep MiSTerPlex
```

## Conf keys

File: `/media/fat/misterplex/misterplex.conf` (see [`assets/misterplex.conf.example`](../assets/misterplex.conf.example)).
Display output mode is **not** a `misterplex.conf` key; set `[Plex] video_mode` in
`/media/fat/MiSTer.ini` instead. Native content resolution is an OSD setting
(**Content resolution**). See [`display-resolution.md`](display-resolution.md).

| Key | Example | Meaning |
|-----|---------|---------|
| `PLEX_BASE` | `http://YOUR-PLEX-SERVER:32400` | Default PMS URL for resolve; set this to your Plex Media Server |
| `PLEX_HOST` | `YOUR-PLEX-SERVER` | Alternate host; builds `http://HOST:32400` (overrides base host) |
| `PLEX_TOKEN` | *(optional)* | Static token; cast usually supplies transient `X-Plex-Token` |
| `FFMPEG` | `/media/fat/misterplex/bin/ffmpeg` | FFmpeg binary; defaults to the bundled release copy |
| `DECODE` | `320x240` | RGB decode size (`WxH`) |
| `TRANSCODE_PROFILE` | `240p` \| `480p` | PMS universal profile. `240p` = 320x240@1000k; `480p` = coded 624x480@2000k for 640x480 presented scanout. Both request H.264 Baseline Level 3.0. |
| `WEAK_RES` | `320x240` | Legacy PMS universal ladder resolution override |
| `WEAK_BITRATE` | `1000` | Legacy ladder max video kbps override |
| **`PRESENT`** | `fb0` \| `fpga` \| `both` | Where RGB lands |
| **`STREAM`** | `0` \| `1` | Annex-B → host I-recon F1 + F3 |
| `STREAM_SKIP_RGB` | `auto` | `auto`: skip heavy RGB when `PRESENT=fpga` (keep audio); `0` always RGB |
| `MATCH_SOURCE_HZ` | `off` | `on` logs target Hz; cadence-only until switchres |
| `SOURCE_FPS` | `auto` | `auto`\|`12`\|`24`\|`30`\|`60`\|`off` — Content FPS hint from PMS |

Restart after edits: `killall misterplexd` then re-run deploy or the startup line.

### PRESENT / STREAM modes

| PRESENT | STREAM | Behavior |
|---------|--------|----------|
| `fb0` | `0` | **Phase 2 default path:** FFmpeg → `/dev/fb0` + `/dev/MrAudio`. Cast-proven. |
| `fb0` | `1` | FFmpeg A/V + host I-slice recon may blit sparse keyframes to fb0; F3 fed for FPGA status. |
| `fpga` | `0` | RGB565 frames → SPI frame_store (F1); no continuous fb0. Needs `Plex.rbf` loaded. |
| `fpga` | `1` | **STREAM hybrid (3.3k):** host I-slice recon → F1 present (`host_owns_fs`, mae=0 on golden); annex-B → F3 stub. `STREAM_SKIP_RGB=auto` drops heavy RGB (audio kept). |
| `both` | `0`/`1` | FFmpeg owns continuous fb0; recon/DDR-YUV F1 for FPGA path. Lab often uses `both` + `STREAM=1`. |

**STREAM hybrid (current product policy):** dual-A9 **host I-recon owns frame-store present** until FPGA residual/IDCT (Phase 3.3l+) is mae-competitive. F3 is diagnostic/stub status; do not expect full FPGA pixel recon on screen yet. Lab RBF needs Template HSync ~60 Hz + `res_dc` tune for stable HDMI.

**STREAM resolve:** when `STREAM=1`, prefer **direct H.264 Part** from PMS (CAVLC-friendly Baseline/Main) over Chrome universal High/CABAC. Non-H.264 still uses the weak universal ladder. Local `.264` uses elementary demux (no `mp4toannexb`).

**set_status (lab):** after core load, `/media/fat/misterplex/bin/set_status --pattern grid --force-bars 1 --raw` (etc.) RMW-writes OSD status bits without leaving Reset/Flush stuck. Menu matrix: `tests/hw/run_menu_matrix.sh` / `test_fbar_fast.sh`.

**Do not break the Phase 2 cast path:** keep a known-good conf (`PRESENT=fb0`, `STREAM=0`) if STREAM/FPGA work regresses display. Companion HTTP and resolve stay the same for STREAM=0.

## Plex.rbf locations

| Where | Path |
|-------|------|
| Monorepo release copy | `release_artifacts/v0.3.0/Plex.rbf` |
| Explicit override | `RBF_PATH=/path/to/Plex.rbf make package` (must match the pinned MD5) |
| Package | `misterplex-<version>/cores/Plex.rbf` |
| MiSTer SD (lab) | `/media/fat/_Utility/Plex.rbf` (deploy + HW tests) |
| MiSTer SD (alt) | `/media/fat/_Arcade/Plex.rbf` or `/media/fat/games/Plex/Plex.rbf` |

Phase 2 **fb0 / MrAudio** works with MiSTer’s normal video path (ascal/fb) even without Plex core loaded. Phase 3 **FPGA present / STREAM** requires `Plex.rbf` and OSD **Video source = Frame store** where applicable.

Release packages do not silently select local Quartus outputs. `make package`
uses the tracked `release_artifacts/v0.3.0/Plex.rbf` by default, or an explicit
`RBF_PATH`, and refuses to package it unless the MD5 is
`41adb98c7a630b541091c22ce291be68`.

## Lab stable pair (v0.3.0) — 2am card

Ship **core, daemon AND conf together**. A 320×240 core with a 480p-line daemon
(or the reverse) is a silent geometry mismatch: **320×240 bank1 is `0x30040000`**;
**624/640×480 bank1 is `0x30080000`**. Wrong pair → stale/wrong bank reads that
look like “corruption in the background.”

> **It is a triple, not a pair — learned the hard way 2026-07-29.** The core and
> daemon were deployed correctly, but `/media/fat/misterplex/misterplex.conf` was
> left on the 480p experiment line (`DECODE=624x480`, `PRESENT=fpga`, `STREAM=1`).
> **Idle looked perfect, so the mismatch passed inspection**; the fault would only
> have appeared on the first play. `arm/misterplexd/main.cpp` defaults to
> `decodeW=320, decodeH=240` (:89) **but the conf overrides it** (:174-179) and
> `setDecodeSize()` (:285) is called with the conf value — so the daemon would have
> decoded 624×480 into a layout the 320×240 core does not read. **A conf key silently
> overriding a correct default is the same defect class as a check that cannot fail.**

Required conf for this pair (matches `scripts/package_release.sh:98-100`):

```
DECODE=320x240
PRESENT=fb0
STREAM=0
```

Verify from the daemon's own log rather than the file — the daemon prints what it
actually adopted:

```
misterplexd: running name=MiSTerPlex ... decode=320x240 weak=320x240@1000k present=fb0
```

| Piece | Identity |
|-------|----------|
| RBF | `release_artifacts/v0.3.0/Plex.rbf` · MD5 **`41adb98c7a630b541091c22ce291be68`** · hardware-validated Phase A playback-controls core (G-VID1 edge-wrap fixed in `0139f2c`, eyes-on 2026-07-26) |
| Daemon tree | git tag **v0.3.0** = `cacd87176cbc2017c6ef2673eef84717dd673009` |
| Daemon binary | static ARM ELF · MD5 **`06c5735a2f85114688f0ff2ac36e4fd4`** · 320×240 RGB565 · `kDdrFrameBytes=320*240*2` · no 624/640 frame constants |
| Geometry | content **320×240** RGB565; overlay + joystick/keyboard controls |

### Deploy (lab)

```bash
# From a clean v0.3.0 tree (or worktree at cacd8717) so make arm-plexd matches:
git worktree add .worktrees/v3-stable cacd8717   # once
cd .worktrees/v3-stable
make arm-plexd
# md5sum build/arm/misterplexd  →  06c5735a2f85114688f0ff2ac36e4fd4

# Core — prefer menu bounce; if already on MENU and bounce stalls, ONE core load:
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh \
  /path/to/MisterPlex/release_artifacts/v0.3.0/Plex.rbf
# deploy_plex_core.sh archives outgoing SD core as Plex.<md5[0:8]>.bak.rbf first

./scripts/deploy_misterplexd.sh   # from the same v0.3.0 tree
```

### Verify on device (quote hashes; use `pidof`, not `pgrep`)

```bash
md5sum /media/fat/_Utility/Plex.rbf
# expect 41adb98c7a630b541091c22ce291be68
md5sum /media/fat/misterplex/bin/misterplexd
# expect 06c5735a2f85114688f0ff2ac36e4fd4
cat /tmp/CORENAME          # expect Plex
pidof misterplexd          # expect ≥1 PID
wget -qO- http://127.0.0.1:3005/resources | head -c 200
```

### On-device backups (lab 2026-07-29 ship)

| Path | What |
|------|------|
| `/media/fat/_Utility/Plex.226e6a0f.bak.rbf` | Pre-stable overnight core (integ-fit3 / Phase-3; unattributable to fleet until traced) |
| `/media/fat/_Utility/Plex.rbf.bak` | Single-generation bak (same content at ship time) |
| `/media/fat/misterplex/bin/misterplexd.prev-c2` | Daemon displaced by last `deploy_misterplexd.sh` (480p-line at ship) |
| `/media/fat/misterplex/bin/misterplexd.prev-before-v030` | Extra copy of that 480p-line daemon (`ca0b0e9c…`) |

### Rollback (pair — do not mix)

```bash
# Daemon only (restores prev-c2, restarts process — disrupts a live session):
./scripts/restore_misterplexd_prev.sh
# Then restore matching core, or you reintroduce the bank-address mismatch:
scp /media/fat/_Utility/Plex.226e6a0f.bak.rbf ...   # only if you intend that core
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh path/to/chosen.rbf
```

`restore_misterplexd_prev.sh` **does not** touch the RBF. Restoring the old
daemon while leaving the v0.3.0 core loaded is the mismatch this card forbids.

## Smoke tests

```bash
make unit
./scripts/deploy_misterplexd.sh
./tests/hw/test_media_fb.sh
./tests/hw/test_playqueue_bind.sh
./tests/hw/test_single_process.sh
# Multi-title soak (auto-loads conf from MiSTer when PMS token present):
SOAK_HOLD_S=5 SOAK_ROUNDS=1 ./tests/hw/test_soak.sh
# Longer lab soak (multiple keys × rounds; logs net snapshot for Wi-Fi/Ethernet matrix):
SOAK_HOLD_S=15 SOAK_ROUNDS=5 SOAK_PROGRESS=1 SOAK_NET_LABEL=wifi ./tests/hw/test_soak.sh
```

## Wi-Fi vs Ethernet

Not a separate product path — same companion/media code. Document latency/stability deltas in
[crt-lcd-matrix.md](crt-lcd-matrix.md) (Wi-Fi vs Ethernet matrix + `SOAK_NET_LABEL` / `SOAK_LOG_NET`).

| Lab note | Status |
|----------|--------|
| Soak on wlan0 (eth NO-CARRIER) | **PASS** `2 keys × 5 rounds × 12s` (10 plays, ~137s) after SPI + F2 throttle fixes |
| Side-by-side eth vs wifi numbers | **Deferred** until ethernet is available on the lab MiSTer |
| Wi-Fi blips | Whole-host SSH/curl timeouts can fail soak without daemon fault — re-run after AP recover |

## Known limits (Phase 5)

| Area | Limit | Severity |
|------|--------|----------|
| Decode | Dual-A9 FFmpeg transitional; **3.3l-0 done** (host quant/IDCT golden); FPGA IDCT 3.3l-1+ not product-present | product |
| STREAM hybrid | **Host I-recon → F1 owns pixels** (3.3k mae=0); F3 stub/status until 3.3l-5 hybrid gate | product |
| STREAM recon | Baseline CAVLC keyframe-oriented; **CABAC/High → sticky skip** (PPS entropy); `recon_ok` often 0 on weak ladder | product |
| F1 bandwidth | **DDR ~16 ms/frame** when kick+`has_frame` verify works (~60 fps @320×240); RGB/SPI F1 is retired/refused | product |
| DDR product path | F1 product path is DDR YUV420p-only; DDR failures are reported, not hidden by RGB/SPI fallback; ≥30 fps steady in misterplexd still lab-tracking | lab |
| FBAR | Force bars O[9] visual **PASS** (`test_fbar_fast`: grid_off=7.0 force=82.9 bars=94.4) | fixed |
| Safe deploy | `DEPLOY_LOAD=none\|menu\|core` (default **none** = copy only); avoid live RBF overwrite + `load_core` thrash — [`deploy_plex_core.sh`](../scripts/deploy_plex_core.sh) | ops |
| Match source Hz | **Cadence + OSD Content FPS only**; no `CmdSwitchres` yet — [match-source-hz.md](match-source-hz.md) | product |
| CRT 15 kHz | MiSTer video options / fixed modelines; [crt-lcd-matrix.md](crt-lcd-matrix.md) — no automated CRT golden | lab |
| Wi-Fi vs Ethernet | Soak net hooks only; eth comparison not measured (no carrier) | lab |
| Resolution | Output signal modes through 1920×1080@60/50 are supported via MiSTer.ini/ascal; native content defaults to 320×240. OSD 640×480 is for 480p test builds only: fits and closes timing / within modelled bandwidth, not hardware-validated. | product |
| Scrubber | Play-queue bind + seek/step clamp + stop/async race harden (P4-SCRUB E-P4h: playQueued cast invalidate, async seek/step, scrub plant hold, same-pos demux no-op); skipPrevious=Plex-style (restart@0 if >3s else queue prev); live Web eyes-on optional | UX |
| Audio | FFmpeg → MrAudio @ 48 kHz stereo; F2 FIFO best-effort (off if FPGA leaves user mode) | product |
| Auth | Static `PLEX_TOKEN` optional; prefer cast-supplied tokens | ops |
| Stop under STREAM | thr_ joins; stop clears bind before join so late progress cannot re-arm cast UI | fixed |
| SPI under STREAM soak | Concurrent F1/F2/F3 → daemon death; **fixed** recursive mutex, no `system()`, thread-safe `lastError` | fixed |
| F2 under PRESENT=both | F2 only when `PRESENT=fpga` (both uses MrAudio alone) | fixed |
| PMS thin library | Lab may expose one episode + local `test.mp4`; soak uses onDeck/recentlyAdded | lab |
| Package | `make package` **requires** the pinned v0.3.0 `Plex.rbf` MD5; daemon-only packages are disabled for release builds | ops |

## Version stamp

Package version is `git describe --tags --always --dirty` at pack time. Daemon product string is currently `MiSTerPlex` with companion `version` in `/resources` XML (`0.2.0`).
