# MiSTerPlex release notes (Phase 5)

Install, configure, and verify a lab or SD deploy. For packaging from source, see `make package` / [`scripts/package_release.sh`](../scripts/package_release.sh).

## Package contents

Typical tarball `dist/misterplex-<git-desc>.tar.gz` expands to `stage-misterplex/`:

| Path | Purpose |
|------|---------|
| `bin/misterplexd` | Static ARM companion + media daemon (GDM + HTTP `:3005`) |
| `bin/push_frame` | Optional SPI frame / bitstream push tool (Phase 3) |
| `conf/misterplex.conf.example` | Conf template |
| `cores/Plex.rbf` | Present/decode core (included when built in tree) |
| `docs/` | INSTALL path notes, match-source-Hz, CRT/LCD matrix |

## Install on MiSTer SD

```text
/media/fat/misterplex/bin/misterplexd
/media/fat/misterplex/misterplex.conf          # copy from example; edit keys
/media/fat/linux/_user-startup.sh             # start daemon on boot
/media/fat/_Arcade/Plex.rbf                   # or games/Plex/Plex.rbf
```

### From a release tarball

```bash
# On dev host
tar -tzf misterplex-*.tar.gz
scp -r stage-misterplex/bin root@MiSTer:/media/fat/misterplex/
scp stage-misterplex/conf/misterplex.conf.example root@MiSTer:/media/fat/misterplex/misterplex.conf
# Edit conf on device, then:
scp stage-misterplex/cores/Plex.rbf root@MiSTer:/media/fat/_Arcade/Plex.rbf   # if present
```

### From this monorepo (recommended for lab)

```bash
make arm-plexd
make package                    # rebuilds ARM if needed; copies Plex.rbf when present
./scripts/deploy_misterplexd.sh # HOST default 192.168.1.183, pass 1
./scripts/deploy_plex_core.sh   # optional: load/copy RBF
```

Startup hook (idempotent via deploy script):

```bash
/media/fat/misterplex/bin/misterplexd \
  --name MiSTerPlex --id misterplex-183 --port 3005 \
  --conf /media/fat/misterplex/misterplex.conf \
  --pms http://192.168.1.41:32400 \
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
```

Verify:

```bash
curl -s http://MiSTer:3005/resources | grep MiSTerPlex
```

## Conf keys

File: `/media/fat/misterplex/misterplex.conf` (see [`assets/misterplex.conf.example`](../assets/misterplex.conf.example)).

| Key | Example | Meaning |
|-----|---------|---------|
| `PLEX_BASE` | `http://192.168.1.41:32400` | Default PMS URL for resolve |
| `PLEX_HOST` | `192.168.1.41` | Alternate host; builds `http://HOST:32400` (overrides base host) |
| `PLEX_TOKEN` | *(optional)* | Static token; cast usually supplies transient `X-Plex-Token` |
| `FFMPEG` | `/media/fat/mistercast/bin/ffmpeg` | FFmpeg binary (Phase 2 path) |
| `DECODE` | `320x240` | RGB decode size (`WxH`) |
| `WEAK_RES` | `320x240` | PMS universal weak ladder resolution |
| `WEAK_BITRATE` | `1000` | Weak ladder max video kbps |
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
| `fpga` | `1` | Host I-recon → F1 + annex-B → F3; product STREAM path. `STREAM_SKIP_RGB=auto` drops heavy RGB (audio kept). |
| `both` | `0`/`1` | FFmpeg owns continuous fb0; recon/SPI F1 for FPGA path. Lab often uses `both` + `STREAM=1`. |

**STREAM resolve:** when `STREAM=1`, prefer **direct H.264 Part** from PMS (CAVLC-friendly Baseline/Main) over Chrome universal High/CABAC. Non-H.264 still uses the weak universal ladder. Local `.h264` uses elementary demux (no `mp4toannexb`).

**Do not break the Phase 2 cast path:** keep a known-good conf (`PRESENT=fb0`, `STREAM=0`) if STREAM/FPGA work regresses display. Companion HTTP and resolve stay the same for STREAM=0.

## Plex.rbf locations

| Where | Path |
|-------|------|
| Monorepo release copy | `fpga/Plex_MiSTer/releases/Plex.rbf` |
| Quartus output | `fpga/Plex_MiSTer/output_files/Plex.rbf` |
| mister-dev out | `misterfpga-dev/out/Plex_MiSTer/Plex.rbf` |
| Package | `stage-misterplex/cores/Plex.rbf` (if any of the above existed at pack time) |
| MiSTer SD | `/media/fat/_Arcade/Plex.rbf` or `/media/fat/games/Plex/Plex.rbf` |

Phase 2 **fb0 / MrAudio** works with MiSTer’s normal video path (ascal/fb) even without Plex core loaded. Phase 3 **FPGA present / STREAM** requires `Plex.rbf` and OSD **Video source = Frame store** where applicable.

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
| Side-by-side eth vs wifi numbers | **Deferred** until eth cable present on 192.168.1.183 |
| Wi-Fi blips | Whole-host SSH/curl timeouts can fail soak without daemon fault — re-run after AP recover |

## Known limits (Phase 5) — remaining issues

| Area | Limit | Severity |
|------|--------|----------|
| Decode | Dual-A9 FFmpeg is transitional; full FPGA residual decode is Phase 3.3j+ | product |
| STREAM recon | Host I-slice recon is Baseline CAVLC keyframe-oriented; **CABAC/High → skip** (`recon skip CABAC/High`) so `recon_ok` often 0 on PMS weak ladder | product |
| Match source Hz | **Cadence + OSD Content FPS only**; no HPS `CmdSwitchres` / modeline swap yet — [match-source-hz.md](match-source-hz.md) | product |
| CRT 15 kHz | Use MiSTer video options / fixed modelines; matrix checklist in [crt-lcd-matrix.md](crt-lcd-matrix.md) — no automated CRT golden | lab |
| Wi-Fi vs Ethernet | Checklist + soak net hooks only; eth comparison not measured this lab (no carrier) | lab |
| Resolution | Lab default 320×240; 480×360 HW-verified on weak ladder; higher sizes stress ARM | product |
| Scrubber | Play-queue bind fields implemented; edge cases vs Plex Web versions may still need tuning | UX |
| Audio | Single-process FFmpeg → MrAudio @ 48 kHz stereo; F2 FIFO best-effort (disabled for session if FPGA leaves user mode) | product |
| Auth | Static `PLEX_TOKEN` optional; prefer cast-supplied tokens for multi-user | ops |
| Stop under STREAM | Media thr_ owns audio/stream joins; stop clears bind before join so late progress cannot re-arm cast UI | fixed |
| SPI under STREAM soak | Concurrent F1/F2/F3 used `system(killall)` + unlocked `err_`/`MainPause` → **daemon death** mid multi-round soak; **fixed** recursive mutex, no `system()`, thread-safe `lastError` | fixed |
| F2 under PRESENT=both | F2 SPI ~20×/s plus F1/F3 thrashed Main; **now F2 only when PRESENT=fpga** (both uses MrAudio alone) | fixed |
| PMS thin library | Lab PMS may only expose one playable episode + local `test.mp4`; soak discovers onDeck/recentlyAdded | lab |
| Package | `make package` **requires** `cores/Plex.rbf` unless `PACKAGE_ALLOW_NO_RBF=1` | ops |

## Version stamp

Package version is `git describe --tags --always --dirty` at pack time. Daemon product string is currently `MiSTerPlex` with companion `version` in `/resources` XML (`0.2.0`).
