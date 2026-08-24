# Phase 1a pickup — 2026-08-24

Next-session source of truth for the FPGA H.264 on-ramp. Do not invent BUILD_OK,
glass PASS, or 23.9. Soft-skip ≠ PASS. Tokens stay in
`Memory/lab/local/secrets.env` (gitignored).

Standing law: [`PHASE1A_320_FIT_LESSONS.md`](PHASE1A_320_FIT_LESSONS.md).
Fleet: [`AGENT_ORCHESTRATION.md`](AGENT_ORCHESTRATION.md) ·
[`agent-fleet-playbook.md`](agent-fleet-playbook.md).
Living gates: [`PHASE_BACKLOG.md`](PHASE_BACKLOG.md).

## Product

MisterCast’s end state is FPGA H.265 plus Plex A/V on MiSTer. **H.264 Phase 1a
is the on-ramp**, not a second product. Stay on `Plex_MiSTer` / `stream_path`.
Do not start a second core. HEVC stays parked.

Branch: `wip/phase1a-320-fit13-lessons`.
`origin/main` is v0.4.1 (`14924c49`) — do not merge this decode line onto it.
720p24 unique24 stays **PARKED**. Do not thrash true480 `07f54d9f`.

## History (how we got here)

1. Host goldens locked CAVLC / sat9 / IQ+IDCT / intra / P16+Skip (`residual_csum=0x14`,
   `recon_sig=0x3b`). GOP12 Verilator: F0–F11 `MAE_Y=0` `MAE_I420=0` vs
   `tests/fixtures/h264_phase1a_p16skip/`.
2. Walker + DPB wrap landed in `h264_mb_ctrl.sv`. Picture store is
   `stream_path` `dpb_pic[0:230399]` (2×115200 I420). No `cur_pic` / `ref_pic`.
3. Quartus 17.0.2 Cyclone V 5CSEBA6 (41910 ALM / 112 DSP):
   fit7–10 combo qpel exploded; fit11 sequential 6-tap luma hit the target;
   fit12 LAB-short; **fit13 map+fit SUCCESS** (36561 ALM, 87%).
4. fit13 RBF sha256 `6faba2acec31f1f6bf26f5bb14c4f335b6bf473fb447bd094e83eb3d224083ce`
   parsed GOP12 on hardware (`has_stream` `has_idr` `sps=320x240` `nalu=15`).
5. Glass stayed **black**. HDMI/ascal does not read `dpb_pic`. Present is
   `present_core` `frame_store`. `product_recon_ok` is TB `clip_gold_match`
   and is **0 on silicon**. Never assign `1'b1`.
6. Present-gate split is on disk (`decode_frame_valid` from `frames_out` /
   `st_recon_seen`). First “fit14” **assembled a copy of fit13** (same sha256).
   **A real rematch is still required.**

## What is left (ordered)

1. **Rematch** present-gate tree. New RBF sha256 **must differ** from `6faba2ac`.
2. **ONE** `DEPLOY_LOAD=menu` via node-worker1 → `root@192.168.2.2`.
3. Prove CORE=Plex + mailbox/status (not SD md5 alone).
4. GOP12 SPI still green, then **HDMI JPEG** on node-worker1 `/dev/video0`.
   Black / false-black (`e74e3559`) / menu wallpaper = FAIL.
   `nalu=15` ≠ glass PASS.
5. Only then name the next exclusive (FPGA recon → `frame_store` without host F1
   owning the bank). Later: HEVC, 720p24 (parked).

## Lab map (pinned 2026-08-24 18:21 CDT)

| Role | Living value |
|------|----------------|
| Quartus exclusive | Docker on **node-worker1** (`192.168.1.24` / SSH `node-worker1`). FREE at pin. At most one fit. |
| Farm Ethernet | node-worker1 `enp90s0` = **192.168.2.1/24** |
| MiSTer SSH | **192.168.2.2** (only via node-worker1). Studio has no route. |
| MiSTer WiFi `192.168.1.183` | **DOWN** — `wlan0` unassociated. Do not use as default. |
| HDMI eyes | node-worker1 MacroSilicon `534d:2109` **`/dev/video0`** MJPEG 1280×720. Not YUYV. Discard first-frame `e74e3559`. L58: grab yourself. |
| PMS | `http://192.168.1.24:32400` (docker `plex` healthy). Never `127.0.0.1` for the portal. |
| Power cycle | Enbrighten plug **192.168.1.91** (`scripts/enbrighten_mister_power_cycle.sh`). Keys in `~/.config/misterplex/enbrighten-mister.env`. Lockup only. After cycle, wait SSH on **192.168.2.2**. |
| Living FPGA | `/tmp/CORENAME=Plex`. Product `/media/fat/Plex.rbf` **absent**. Utility `_Utility/Plex.rbf` md5 **`fa7a29d7`**. |
| Fixture | `tests/fixtures/h264_phase1a_p16skip/plex_phase1a_p16skip_320x240_12f.264` |

## Roles

| Role | Owns | Must not |
|------|------|----------|
| Chief of Staff (parent) | `FIT_GO`, cut order, MiSTer token, harvest, backlog | Invent BUILD_OK; second exclusive |
| MisterFPGA Developer | RTL / `/sys` (`h264_mb_ctrl.sv`, `stream_path.sv`, `Plex.sv`) | Quartus; mid-fit edit of the live compile |
| FPGA Developer | Quartus 17.0.2 rematch on node-worker1 after `FIT_GO` | Assemble-copy of an old DB; freelance ALM cuts |
| H264 Expert | Spec, CAVLC, Phase 1a vectors, gold MAE | Deploy; fit |
| Lab / eyes | HDMI grab, optional PMS cast, ONE menu | kill-9 / `load_core` storms |

## Standing bans (do not repeat)

- No `cur_pic` / `ref_pic`. No `(* keep *)`. No combo 2D `qpel_at`.
- sat9, not sat8. `apply_itu_fix=false`. Do not widen dequant in Phase 1.
- `product_recon_ok` never forced high.
- Address walls: ascal `0x20000000`, rotate `0x24000000`, present
  `0x30000000`–`0x306FFFFF`.
- One exclusive rematch after CoS `FIT_GO`. No mid-fit RTL.
- Soft-skip ≠ PASS. DIAG ≠ product PASS. USB JPEG ≠ CRT.

## First commands

```bash
# Exclusive detect
ssh node-worker1 'pgrep -af quartus_ || true; docker ps --format "{{.Names}} {{.Image}}"'

# MiSTer (from farm)
ssh node-worker1 'sshpass -p 1 ssh -o StrictHostKeyChecking=no root@192.168.2.2 "cat /tmp/CORENAME; ip -4 -br addr"'

# Eyes
ssh node-worker1 'v4l2-ctl --list-devices; ffmpeg -y -f v4l2 -input_format mjpeg -video_size 1280x720 -i /dev/video0 -frames:v 2 /tmp/misterplex-eyes/probe.jpg'

# Rematch (CoS FIT_GO=YES only; one slot)
MISTER_REMOTE_HOST=node-worker1 ./scripts/build_rbf_remote.sh phase1a-fit14

# ONE menu after BUILD_OK + new sha256 ≠ 6faba2ac
MISTER_HOST=192.168.2.2 DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh
# If this studio has no route to 192.168.2.2, run deploy from node-worker1.

# Lockup only
./scripts/enbrighten_mister_power_cycle.sh
```
