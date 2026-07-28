# MiSTerPlex phase backlog (living)

Update this file when work finishes. Loop agents claim items and mark `DONE` / `IN_PROGRESS` / `BLOCKED`.

## ACTIVE — W-OSD reconstructed-neighbour context (**REACHABLE UNDER REAL-INTRA, no product-decode PASS** 2026-07-28)

Raw findings / scope first:

- Added `h264_intra_nb_ctx` as a full-width PRE-deblock reconstructed-neighbour store for the
  measured coded frame (`624x480`, `39x30` MBs, no partial MBs). It stores luma above row
  (`39*16`), chroma U/V above rows (`39*8` each), luma/chroma left columns, above-left
  corners, and luma above-right; picture/slice edges report unavailable so DC `128` remains
  the correct fallback only at real edges.
- W-DECODE seam adapter added after coordination: the producer now also exposes the exact luma
  port shape already consumed by `h264_decode_top` (`mb_avail_left/top/topright/topleft`,
  `nb_top[0:15]`, `nb_left[0:15]`, `nb_topleft`, `nb_topright[0:3]`). MB0 external neighbours
  correctly report unavailable, so MB0 mismatches are not explained by this external line buffer.
- `stream_path.sv` now instantiates `h264_intra_nb_ctx` in the `DECODE_REAL_INTRA=1` branch and
  drives `h264_decode_top`'s luma neighbour ports from that producer instead of hardcoded
  unavailable/`128` placeholders. The context commits the decoder's reconstructed luma one cycle
  after `mb_recon_valid`, preserving the PRE-deblock tap; chroma is still tied neutral until the
  consumer grows chroma neighbour ports.
- Seam statement for W-DEBLOCK: intra prediction reads this module's **PRE-deblock** reconstructed
  samples. The DPB/reference path must consume **POST-deblock** samples from the deblock commit path;
  these taps are intentionally separate.
- Gate: `python3 tests/unit/test_h264_intra_nb_ctx_verilator.py` prints `Scope:` first and compares
  exact block-level and `h264_decode_top` MB-level luma/chroma neighbour bytes while walking all
  `1170` MBs (`39x30`), including interior, left edge, top edge, right-edge above-right unavailable,
  last MB, and a slice-boundary case where storage-valid samples must be semantically unavailable.
  It does not cover entropy parsing, residual math, deblock filtering, DPB post-deblock storage,
  inter prediction, or HDMI.
- Red checks: `H264_INTRA_NB_CTX_FAULT_STUB_NEIGHBORS` fails by forcing neighbour bytes back to 128;
  `H264_INTRA_NB_CTX_FAULT_SWAP_CHROMA_UV` fails the chroma scoreboard; and
  `H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE` fails the edge/slice availability scoreboard. All are
  registered in the expected-red manifest and define-parity allowlist.
- Reachability: W-GATE's `scripts/check_rtl_module_instantiations.py` reports
  `DEFAULT_OFF_DEFINE_REACHABLE_MODULE h264_intra_nb_ctx defines=DECODE_REAL_INTRA=1`; with
  `--define DECODE_REAL_INTRA=1 --list-reachable`, `h264_intra_nb_ctx`, `h264_decode_top`,
  `h264_intra4x4_pred`, and `h264_intra16x16_pred` are reachable together. This is honest:
  default `DECODE_REAL_INTRA=0` still ships the stub path.
- Validation: neighbour RTL gate `rc=0`; stream-path real-intra gate `rc=0`; reachability gate
  `rc=0` with mutation red `rc=1` / restore green `rc=0`; `make define-parity rc=0`;
  `make quartus-sv-subset rc=0`; `make unit rc=0`.

Conclusion: reconstructed-neighbour storage now exists and is non-vacuously gated, but this is not a
claim that the product decoder works. Live PMS is still mostly P-slices (`343 P / 7 IDR`), so intra
green alone cannot be read as decode-off-ARM.

## ACTIVE — W-OSD idle Plex-logo split (**UNSCORED, non-visual only** 2026-07-28)

Raw findings, no HDMI/capture PASS claimed:

- Device conf restored after the probe: `PRESENT=fpga STREAM=0 DECODE=624x480 OSD_CONTROL=0`.
- `PRESENT=fb0` readback from `/dev/fb0` after daemon restart matched the idle-logo renderer:
  background pixel `26_23_1f_ff` at `(240,180)` and foreground pixel `0d_a0_e5_ff` at `(360,260)`.
- Restored `PRESENT=fpga` immediately reported PLXD `free_bank_mask=0 swap_pending=1`
  (`hi=0x94FB0008`, `frames_done=38139`) and daemon logs contained
  `[STALL] sendDdrFrame: PLXD bank-release timeout ... swap_pending=1`.
- The new card `tests/hw/test_idle_present_split.sh` encodes this split and exits `77`:
  `FB0_PROXY=PASS scope=framebuffer-readback-not-hdmi`,
  `FPGA_PROXY=BLOCKED_BY_BANK_RELEASE_LIVELOCK scope=mailbox-not-hdmi`,
  `IDLE_SPLIT_RESULT=UNSCORED reason=no-hdmi-capture-or-human-eyes`.
- Mutation evidence: `FB0_EXPECT_FG=00_00_00_00 tests/hw/test_idle_present_split.sh`
  failed with `rc=1` / `fb0-logo-foreground-mismatch`; restoring the operand returned to the
  normal UNSCORED card with the fb0 proxy passing.

Conclusion from the measured split: the logo asset/idle renderer/fb0 presentation path are not the
black-screen root cause. The current `PRESENT=fpga` symptom is not separate from the W-SWAP-owned
bank-release livelock until a post-fix RBF proves otherwise. User-visible picture still needs eyes or
capture after W-SWAP lands.

## PRODUCT MILESTONE — VSync present / product A/V cast (**DONE** 2026-07-25)

| | |
|--|--|
| **Status** | **DONE** — user eyes-on: *looks good on video and vsync* (2026-07-25) |
| **Git** | **`588e528`** `milestone(vsync-present): tear-free DDR present + product A/V cast` |
| **RBF** | **`1441d409ad3f8ccc5dcb0033c32ff7c8`** — `releases/Plex_vsync_tear_1441d409.rbf` + lab `/media/fat/_Utility/Plex.rbf` |
| **Conf** | `PRESENT=fpga` `STREAM=0` `DECODE=320x240` |
| **Notes** | Full write-up: [`docs/MILESTONE_VSYNC_PRESENT.md`](MILESTONE_VSYNC_PRESENT.md) · resume: [`docs/SESSION_RESUME.md`](SESSION_RESUME.md) |

**What fixed half-frame / multi-panel tears**

1. **`frame_store`**: dual-bank writes to non-display bank; `swap_pending`; **flip display bank only on `vsync_pulse`**; **hold writes while pending** (no mid-scan flip, no multi-panel overwrite).
2. **`ddram_frame_rd`**: **hold DDR→BRAM DMA while `swap_pending`**; queue one latest doorbell/SPI kick; mmap doorbell `0x3007F000` (`PLXK`).
3. **Host (`misterplexd`)**: product cast = **STREAM=0 every-frame DDR F1** (not STREAM recon); **wall-48 kHz MrAudio**; doorbell-preferred present; **heal Main on stop**.

**Evidence**

- holdoff2: half/mid/multi tear rates **0.00/s** — `captures/e2e/tc_glitch/holdoff2/REPORT.txt`
- Blip 24 fps Web cast: median flash↔beep **~−13 ms** — `captures/e2e/blip24/avsync_report.txt` (+ suite notes in `captures/e2e/REPORT*.md`)
- Do **not** thrash this RBF while product path is green unless a new present gate fails.
- Residual csum / WIDE / 3l2 below are **separate** serial tracks (historical RBF ids do not supersede product **`1441d409`** present path).

---

## ACTIVE — Hardware visual decode regression harness (**HW RED/GREEN PROVEN** 2026-07-27)

User directive: after simulation, build realtime, push to MiSTer, and validate on real DE10-Nano hardware with
visual unit tests/debug output instead of stopping at Verilator.

| | |
|--|--|
| **Branch** | `feat/c1-hw-visual` |
| **Harness** | `tests/hw/test_f3_visual_golden.sh` |
| **Comparator** | `scripts/hw_visual_compare.py` |
| **Goldens** | no silent default; `VISUAL_GOLDEN` must name a hardware-captured PNG with `.provenance.json` |
| **Docs** | [`hw-visual-regression.md`](hw-visual-regression.md) |
| **Status** | **EVIDENCE-BACKED for the legacy rollback instrument only:** real HDMI capture achieved; `57674f2e` grades GREEN and characterized bad `fe7673bc` grades RED. **UNSUBSTANTIATED for current product decode:** the `57674f2e` golden is RGB565/320×240 rollback evidence and must not grade the current YUV420/624×480 path. |

**Design:** push a known Baseline/CAVLC F3 vector, capture HDMI, derive thresholds from five repeated static
captures, compare the stable decoded ROI (default `VISUAL_COMPARE_BOX=11,0,160,120`, containing MB0), and emit
`golden | captured | amplified-diff` PNG plus JSON metrics. The comparator can still use the shared host/RTL DDR
layout active region for future 624×480 gates.

**Promotion gate:** before any RBF is promoted for FPGA-decode evidence, run the
secret-safe live PMS Baseline gate:
`PLEX_BASE=... MISTERPLEX_BASELINE_KEY=/library/metadata/N make pms-baseline-live`.
The token is entered only at the hidden prompt. The gate must prove the live PMS
still delivers Baseline/CAVLC/ref=1/no-B (`profile_idc=66`, `entropy_cabac=0`,
`max_num_ref_frames=1`, `b_slices=0`, coded `624x480`, display `618x480`) or the
worker must record an explicit skip reason. Decode-promotion deploys should set
`DEPLOY_DECODE_PROMOTION=1`, which requires the live pass stamp or
`PMS_BASELINE_LIVE_SKIP_REASON`.

**Dry-run evidence:** `make unit` exit 0. Synthetic/checked-in noise floor is zero
(`max_pair_mae_rgb=[0,0,0]`, `max_abs_noise=0`, thresholds `[1,1,1]` / `2`), and the comparator's red-path unit
corrupts one active pixel and fails with exact worst coordinate + diff artifact.

**Capture/freshness/artifact integrity:** compare exit codes are distinct: `1` = real visual mismatch, `3` =
stale frame, `4` = V4L2/FFmpeg corrupted buffer/data, `5` = absent device, `6` = busy device, `7` = no fresh
frame delivery proven from status counters/token, `8` = loaded/golden RBF md5 does not match the declared
artifact, `9` = missing/mismatched golden provenance. Capture-rig, delivery, wrong-core, or unscoped-golden
failure is never accepted as either green or known-red core evidence.

**Hardware evidence (W-C1 token window):**

- Differential test: the exact W-CAP YUYV pipelines also report full-frame corrupt buffers on the MiSTer menu
  (`1843200` bytes at 1280×720@10 and `614400` bytes at 640×480@10), so this is a raw-YUYV capture-pipeline
  problem rather than evidence that Plex alone emits bad HDMI timing.
- Repaired capture path: `/dev/video4` MJPEG `1280x720@60`; menu capture was clean, YUYV 640×480@5 with
  120-frame warm-up still reported full-frame corruption. `v4l2-ctl` advertises MJPEG 720p60/1080p30 and YUYV
  720p only at 10 fps; dongle is on a shared 480M USB bus.
- W-CAP's real `fe7673bc959f37fd7da44e8a865f7db3` YUYV failure logs (`Dequeued v4l2 buffer contains corrupted
  data`, `/dev/video4`, 10 fps, 1280×720 corrupt bytes `1843200`, 640×480 corrupt bytes `614400`) are now checked
  in as capture-log fixtures and force `compare --capture-log ...` to return `rc=4` before pixel grading.
- Measured static capture noise floor on `57674f2e` default ROI: `max_pair_mae_rgb=[0,0,0]`, `max_abs_noise=0`;
  thresholds `[1,1,1]` / `2`.
- Green rollback `57674f2e`: exact ROI pixels `19200/19200`, MAE `[0,0,0]`, max_abs `0`, `rc=0`.
- Red specimen `fe7673bc`: telemetry has `res_csum=20`/`raw[13]=0x14` class signal while reconstruction is known
  bad; visual compare exact ROI pixels `0/19200`, MAE RGB `[112.7730,59.8615,61.0523]`, max_abs `242`,
  `rc=1`, diff artifact emitted.
- Tooling no longer has a proven default pair. The former
  `plex_real_baseline_320x240_57674f2e_mjpeg720_golden.png` is quarantined as
  legacy rollback evidence only; its sidecar declares `57674f2e`, 320×240,
  RGB565, BT.601/full, and ROI `11,0,160,120`. The 624×480 reference is
  retained only as a future target and is marked `generated_reference`, so the
  hardware harness refuses to grade it as a captured golden.
- Stale-screen follow-up: Plex reload+push captures can exact-match a golden while status reports `bytes_in=4`.
  Source audit proved this is a status-telemetry alias (`bytes_in == nalu == 4`, four NALs, not four bytes)
  after stream byte telemetry was reclaimed for residual/recon RCA. The comparator now names the
  `STATUS_TELEMETRY_LAYER` and refuses that phantom-green path before pixel grading (`rc=7`) using the natural
  captured fixture; unit coverage also proves a fresh legacy-style `bytes_in=6227` plus changed
  `{bank,format,seq}` token green path.
- Wrong-core follow-up: rollback `57674f2e` predates the current YUV420/624×480 frame-store contract, so it cannot
  validate the current ARM I420 delivery path. The hardware script now requires `VISUAL_RBF` or
  `VISUAL_EXPECTED_RBF_MD5`, verifies device `/media/fat/_Utility/Plex.rbf`, requires `VISUAL_GOLDEN`, and the
  comparator refuses loaded-vs-golden source mismatches before pixel grading (`rc=8`) with both core md5s in the
  error. Unit coverage proves wrong/undeclared RBF red, golden-source mismatch red, and matching md5 green.

**Hardware TODO:**

- [x] Get W-CAP's actual corrupted V4L2 command/log/device/artifacts and add the logs as rc=4 harness specimens.
- [x] Record real HDMI capture noise floor from `build/hw_visual_accept/noise_good_57674f2e.json`.
- [x] Prove green visual compare against rollback `57674f2e`.
- [x] Prove red path on hardware with known-bad `fe7673bc`.
- [x] Quarantine the former 320×240 `57674f2e` golden; no silent default golden remains.
- [x] Refuse full-frame `VISUAL_FULL_FRAME=1` coverage by default. Hardware investigation of the 618×480 active
  region false-reded on known-good `57674f2e` despite zero within-run noise: exact `281458/296640`,
  Y/U/V MAE `[5.1175,3.3041,1.9793]` vs checked golden, and `281249/296640`, Y/U/V MAE
  `[5.1944,3.3532,2.0109]` after rerun against a same-window full golden. Bad `fe7673bc` was red
  (`0/296640`, Y/U/V MAE `[63.9724,24.5320,26.1278]`), but a full-frame gate cannot ship until good is green.
- [x] Add a freshness/delivery guard so a stale frozen screen cannot grade as PASS. `compare --status-log`
  refuses the `bytes_in=4`/`nalu=4` status-telemetry alias before pixel grading (`rc=7`) and supports the shared DDR frame token
  `{bank,format,seq}` for w-a3/w-cap alignment.
- [x] Add loaded-artifact identity gating. The hardware script records and verifies `md5sum
  /media/fat/_Utility/Plex.rbf`; compare refuses wrong or undeclared RBF identity (`rc=8`) before grading pixels.
  Status `frame_debug=0xe1` is surfaced as a named non-YUV doorbell/debug refusal.
- [ ] Promote a checked-in host/good 624×480 golden only after that vector is live and green on rollback hardware.

---

## Decode evidence reconciliation (2026-07-27)

Status labels below distinguish measured evidence from retired instrumentation:

| Claim area | Evidence status | Measurement / instrument |
|------------|-----------------|--------------------------|
| MB0 first-pixel/root-cause localization | **EVIDENCE-BACKED** | Native-I420 full-frame scoreboard (`tools/score_h264_native_frames.cpp`, `tests/unit/test_stream_path_full_frame_compare.sh`) reports the old phantom first-pixel divergence as clean: `got=73 ref=73 abs=0`. The retired RGB565/presentation scoreboard had reported `got=142 ref=65`, so that older failure was an instrument artifact, not decoder evidence. |
| Full-frame intra prediction exactness | **EVIDENCE-BACKED NATIVE-I420 GREEN** | The former "300/300 exact"/`maeY=0` frame-wide green was measured through the RGB565 diagnostic/presentation path with border masking, then the first native-I420 ratchet still mismatched loop-filter state. Corrected no-deblock native-I420 ratchets now declare/refuse H.264 loop-filter state and compare against FFmpeg `-skip_loop_filter all`: 624×480 intra `1170/1170`, 320×240 intra `300/300`, and `wcap_residual14` intra `300/300`, all Y/U/V MAE 0. |
| P-slice / motion compensation full-frame output | **MEASURED RED / OWNER W-REL** | Product `stream_path` parser now drives DPB/MC liveness through the product deblock writeback commit barrier (`recon_sig_3b_cycles=39780`, forced-`recon_sig=0` red). Full-frame RGB565 diagnostic output remains a non-native expected-red (`0/3300` P MB exact, Y MAE `76.468417`). A new native-I420 inter candidate exported from the RTL DPB/MC predictions is scored by `score_i420_candidate.py` with colorspace/loop-filter refusal: 320×240 reports `intra=0/300`, `inter=0/3300`, first_bad_inter frame 1 MB0 Y `got=32 ref=80 abs=48`, `mb_type=P_L0_16x16`, `mv_l0=(0,0)`; 624×480 scorer self-check reports `intra=0/1170`, `inter=0/12870`, first_bad_inter `got=32 ref=77 abs=45`. Metadata declares `candidate.h264_loop_filter=disabled`, `reconstruction_stage=mc_prediction_only_pre_deblock_no_residual_add`, and `reference_picture_state=diagnostic_filtered_reference_via_deblock_writeback_ctrl`; this measures MC arithmetic/plumbing only, not end-to-end P conformance. |
| Visual hardware golden `plex_real_baseline_320x240_57674f2e_mjpeg720_golden.png` | **EVIDENCE-BACKED only for rollback `57674f2e`; contaminated for current-product claims** | Sidecar declares rollback RBF `57674f2e`, 320×240 RGB565, BT.601/full, ROI `11,0,160,120`. It is quarantined as legacy evidence and must not grade current YUV420/624×480 delivery or decode status. |
| `bytes_in` status freshness | **EVIDENCE-BACKED alias, not byte count** | ARM/status parser currently maps `bytes_in` to `nalu_count`; `bytes_in=4` means four NALs (SPS/PPS/SEI/IDR), not four bytes. Visual gates must use status/token freshness and reject the stale-screen phantom (`rc=7`) before pixel grading. |
| DDR present / frame-store mailbox on current silicon | **UNSUBSTANTIATED / HARDWARE BLOCKED** | W-CAP silicon evidence on loaded `eeff4eee` (proven source `b5c50c6`): valid `PLXK` doorbell (`lo=0x504c584b`, `hi=0xa0000068`, bank=1, format=YUV420P, seq=0x68) but `PLXF` frame mailbox stayed all-zero (`lo=0x00000000 hi=0x00000000`) for 40 samples over 12.3 s and `has_frame=0`. Simulation of the same mailbox path reads `MAGIC_F=0x504c5846`; a later line-read hang simulation is a distinct **stale** fault (`PLXF` magic remains `0x504c5846`, e.g. `plxf=0x8001504c5846`, while `has_frame=0`). Pre-deploy discriminator: `PLXF lo=0x00000000` means the first frame-mailbox write never reached/read back at `0x3007F118` (reset/clock/DDR grant/write-address/netlist class); `PLXF lo=0x504c5846` with static high word means the mailbox published and a later frame-fill/present path stalled. Until a provenance-correct post-`d803e4c`/`86558c4`/`97beb1d` RBF is fitted and observed, claims that the DDR frame-store/present path works on device are not current evidence. |
| Current localized intra defect | **RESOLVED / HOST REFERENCE FIXED** | The apparent MB 182 DC-collapse was a host-side QP_Y clamp where H.264 requires modulo-52 wrap. After the reference fix, no-deblock native-I420 intra is bit-exact on all checked fixtures; localize future decode reds to the first divergence in raster order before naming a mechanism. |

Any future green decode claim must name the exact evidence file, fixture, and instrument. A claim that cannot state whether it came from native I420 planes, RGB565 presentation diagnostics, hardware HDMI capture, or host-only reference code stays **UNSUBSTANTIATED**.

---

## ACTIVE — A/V lipsync + Plex Web seek/resume (**IN_PROGRESS** 2026-07-25)

| | |
|--|--|
| **Title SoT** | TNG show `/library/metadata/40710` · **S1E1 episode `/library/metadata/40868`** (Encounter at Farpoint) on server `1cdd1b7f718cb9f111a2a92abcdd50c7733d14fe` @ `http://203.0.113.10:32400` (~3:54 = seek 234000); probe **REACHABLE** 2026-07-25 (`/tmp/misterplex-agent-AV-trek-probe.txt`) — **≠ G-AV4 PASS** |
| **RBF** | Keep **`1441d409`** (tear-free); ARM/conf only unless present regresses |
| **Conf** | `PRESENT=fpga` `STREAM=0` `DECODE=320x240` · **`AUDIO_DELAY_MS=0`** (safe default; adelay via conf when eyes-on tunes) |
| **Plan** | session plan A/V + seek · multi-agent fill · no Quartus sole |

| ID | Item | Status | Notes |
|----|------|--------|-------|
| P3-AVSYNC | Fresh lipsync + Trek-matched blip + measure | **PARTIAL** | G-AV0/1/2 PASS; G-AV3 **FAIL open** baseline HDMI **−54…−60 ms**; PCM-drop “−36 PASS” **revoked** (wrong polarity); FFmpeg **adelay** conf ready |
| P4-SEEK | Plex Web seek/resume: re-resolve universal on seek | **DONE** (lab blip) | G-SEEK1/2/3 **PASS**; see `MILESTONE_AVSYNC_SEEK.md` |
| P3-PRESENT | VSync tear-free present | **DONE** | do not thrash RBF **`1441d409`** |

**Gates**

- [x] G-AV0 zero intentional lag (`AUDIO_DELAY_MS=0`) — lab conf default; no hardcoded lag
- [x] G-AV1 Trek-matched blip fixture — `assets/avsync/sync_trekmatch_*` PMS keys **9/10**
- [x] G-AV2 measure harness flash↔beep — **PASS** HDMI trekmatch RK10 n=12; `captures/e2e/avsync_trekmatch/`
- [ ] G-AV3 blip \|median\| ≤ 1 frame @24p (≤42 ms) — **superseded by G-AV7**; the old absolute number was unmeasurable while the A/V origin race added ±35 ms per play
- [x] G-AV8 video paces off audible position — **PASS**: `/dev/MrAudio` has a 512 KB DMA ring with **no backpressure** (10 s of PCM accepted in 116 ms), so the old submitted-byte clock ran ahead of what was heard. The driver's `open()`+`read()` exposes `len:` = bytes queued-but-unplayed; the pump now samples it (EMA-smoothed) and the present loop paces off `(written - queued)`. Measured steady-state depth **~35,000 B ≈ 185 ms** — sampled *mid-playback*; the 19 ms/4 B first readings were startup and end-of-clip artifacts. The depth is **session-dependent** (it is FFmpeg's startup latency, dumped into the ring by the pump's catch-up burst and then held there because feed and drain are both 48 kHz), which is the likely source of this project's run-to-run lipsync variance. Ring overwrite is now logged instead of silently corrupting lipsync.
- [x] G-AV10 ring depth bounded and self-correcting — **PASS**: the first sustained measurement showed the ring growing **+255 B/s (~80 ms/min)**, which overruns the 512 KB ring ~31 min in and silently shreds unplayed audio. Cause: `AUDIO_CLOCK_PPM=+685` had the **wrong sign** (true error ~**-638 ppm**) because it was calibrated under the submitted-byte clock, where a filling ring and a fast playback clock look identical. Replaced the open-loop constant with a proportional servo on the measured depth (`feedRateBytesPerSec`, target ~100 ms, tau 8 s, ±1 % clamp); also anchored the pump clock on the first chunk (kills the session-dependent FFmpeg warm-up burst) and fixed `decodeOsdWord` returning a hardcoded 685 that clobbered `AUDIO_CLOCK_PPM` on every OSD poll. Hardware, TNG 40868 @3:54 120 s: depth **97-101 ms flat** (19198-19231 B vs 19200 B target), `audio_s == wall_s`, **drops 0** (was 1), 0 overrun warnings, Main pid stable.
- [x] G-AV4 Trek eyes-on — **PASS** (S1E1 **40868**): user eyes-on settled on **video delay +80 ms**. Root cause of the reported "half a second" was the knob turned the wrong way: the menu read `A/V offset` and never said which stream moved, so `-160 ms` pushed video *further* ahead (−160 → +80 is a 240 ms swing). Menu is now `Video delay` (positive = video later). **The +80 is not transferable to the new clock** — it was tuned while video paced off submitted bytes, so it silently absorbed that session's ring depth (see G-AV8). The default is therefore reset to **0 ms** and needs one fresh eyes-on pass; tracked as G-AV9.
- [x] G-AV9 retune `Video delay` under the audible clock — **PASS at 0 ms, no constant needed.** User eyes-on, real TNG S1E1 `40868` @ 3:54 (23.976 → `fps=24000/1001`, HEVC transcode), `osd lo=0x0000` / `av_offset_ms=0`: "audio looks in sync right now". The old +80 ms was **entirely** the MrAudio ring depth the submitted-byte clock was silently carrying; with the audible clock and the feed servo there is nothing left to trim. This is the answer to the original question — Plex Web needs no constant because it schedules against the hardware playback position, and now so do we.
- [x] G-AV11 HDMI grabber calibration — the flash/beep harness read **-215 ms** at the same setting the user's eyes call in-sync, so **the USB grabber's own A/V skew is about -215 ms** (video and audio arrive as independent USB streams). `tests/hw/avsync_measure.py` is therefore a **relative/drift instrument only**; add **+215 ms** to treat a reading as absolute, and never bake a constant from it without eyes-on confirmation.
- [x] G-VID1 VGA/HDMI 1 px edge wrap — **RESOLVED (build `dfebf2bf`).** Symptom: the column falling
  off the right edge reappeared as a vertical bar on the far LEFT ("like word wrap"), plus a
  duplicated bottom line.
  **Two independent defects, both in `present_core.sv`:**
  1. *Horizontal.* `hc → fr` costs ~4 clk (`store_x` on `ce_pix` = 2, `frame_store`
     `rd_addr_r → rd_q → rd_r` = 3) while `hc → hb` costs 1, so pixel data lagged its own DE.
     Fix: delay `hb`/`hs` by `DE_LAG` — **not** `vb`/`vs`. Advancing `read_hc` can never fix this
     and burned many cycles. `DE_LAG = 3` was *measured*, not guessed (sweep 3/4/5/6 built in
     parallel: 3 → col0 w=6px, col319 w=4px ✅; 4 → 4/7; 5 → col0 missing/11; 6 → missing/14).
  2. *The blank-time reset was the actual wrap.* `store_x <= in_content ? store_x_clamped : 0`
     handed **column 0** to any pixel addressed outside `in_content` — which, with DE delayed, is
     the tail of every line. It also *masked* left-edge errors. Fix: drive `store_x` unconditionally
     from the clamped counter.
  3. *Vertical.* `colorbars.sv` moves the V blank edges at `hc == H_SYNC_S` (544), i.e. **after**
     each line's active region, so `VBlank` releases a line early and line 240 is displayed;
     `de_out` never checked `py < 240`, so that row fetched `store_y = 240` — one past the store.
     Fix: `past_last_row = (py >= 240)` folded into `vb_d`, plus a clamped `store_y`.
     Proven by stripe pitch: 1035/1044/1053/1062/1071 = 1080/**241**; after the fix
     1038/1047/1056/1065/1074 and top at 2/9/18/27/36 = 1080/**240**.
  **Verification is now automated and self-checking** — `scripts/gen_edge_markers.py` pushes a
  synthetic marker frame and `scripts/check_edges.py` captures HDMI and grades all four edges on
  both position and run width (exit 0 = pass). Reports `PASS: all four edges correct`, and live
  TNG shows col0↔col319 r=0.33 / row0↔row239 r=0.13 (no wrap). **User confirmed all four edges
  eyes-on on VGA (2026-07-26)** — left/right after the horizontal fix, bottom after the 241st-row
  fix. Closed.
  *Measurement traps worth remembering:* MJPEG 4:2:0 **fabricates** colours at 1 px saturated
  boundaries (use `-input_format yuyv422` and luma-coded markers); `/dev/video4` needs ~60 warm-up
  frames; captures right after a DDR push can be torn — validate with solid white/black first.
- [ ] G-LIB1 missing PMS item silently plays the test pattern — a deleted/renumbered ratingKey 404s, but PMS returns an HTML error *body*, so the old `!xml.empty()` check passed and resolve fell through to `testsrc2`. Cost a full session of measurements attributed to Star Trek that were actually the test pattern. Now detected via `<MediaContainer` and reported as "no such item on PMS". **TNG is no longer in the library** (section 2 holds only ThunderCats; 40868/40710 both 404) — G-AV9 eyes-on needs it re-added.
- [x] G-AV5 exact content rate — log `content fps exact=24000/1001` (Trek/RK11) vs `24/1` (RK12) from identical `videoFrameRate="24p"` metadata; `test_avclock` in `make unit`
- [x] G-AV6 drift slope ≤ 10 ms/min — **+0.79 / −0.67 / +1.79** ms/min (RK11) and **−2.21** (RK12), 240 s single-capture fits; before **−53.3**; `tests/hw/avsync_rate.py`
- [x] G-AV7 constant offset ≤ 42 ms — **PASS via G-AV4**: the residual was a real, constant video lead, not grabber skew. Instrumented capture said +60 ms (|median| 36 ms, `avsync_trekmatch_d60`) and eyes-on said +80 ms — two independent measures one step apart, so the default is evidence-backed, not guessed.
- [x] G-SEEK1 mid-play seekTo ±1 s — blip key=6 seek 12s → playing ~15.5s
- [x] G-SEEK2 resume/continue-watching ≠0 — playMedia offset=15s → playing ~19s
- [x] G-SEEK3 unit regression — `make unit` PASS + `universalOffsetSeconds(234000)==234`
- [x] G-REG tear RBF unchanged unless proven needed — leave **`1441d409`** alone

---

## ACTIVE — OSD menu v3 + idle screen (**DONE** 2026-07-26)

User ask: *"add the different audio delay settings and any other controls in the config directly to the RBF
menu items so the user can change them there without having to edit a config"* and *"the last frame of the
last video is staying on screen and should go back to a default state, black screen or even better a Plex
logo screensaver option in the menu"*.

| | |
|--|--|
| **RBF** | **`91777ac1`** (`91777ac11bc63e7bb4ab20331a26540d`) — supersedes `1441d409` on the lab path. Fit 427 s, **0 errors / 40 warnings**. Not in the banned set. |
| **Deploy** | ONE `DEPLOY_LOAD=menu` bounce; lab `md5sum /media/fat/_Utility/Plex.rbf` = `91777ac1…` |
| **Conf** | `OSD_CONTROL=1` is now the shipped default (requires v3+); `AV_OFFSET_MS` / `IDLE_SCREEN` are power-on defaults only |

### v3 CONF_STR bit layout (`host/libmisterplex/osd_menu.hpp` is the SoT)

| Bits | Menu item | Notes |
|------|-----------|-------|
| `[0]` | Reset | core-owned |
| `[1]` | A/V auto resync | 0 = On (drift corrector) |
| `[2]` | TV Mode | core-owned |
| `[3]` | Audio clock trim | 0 = On (685 ppm); takes effect next session |
| `[5:4]` | *(dead)* | old Content FPS — removed from the menu, still inert in RTL |
| `[9:6]` | **A/V offset** | **4-bit signed** × 20 ms = −160…+140 ms; index 0 **must** be 0 ms because Main cannot express a non-zero CONF_STR default |
| `[10]`/`[11]` | flush triggers | core-owned |
| `[13:12]` | HPS DDR kick/bank | **never reuse** |
| `[15:14]` | **Idle screen** | Logo / Black / Screensaver / LastFrame |

`kOsdOwnedMask = 0xC3CA`. Removed from the menu: Content FPS, Pattern, Audio tone, Force bars —
`pattern`, `audio_en` and `use_frame_store` are hardwired to `0` in `Plex.sv`, preserving the prior defaults.

### Hard rule (non-obvious trap)

**The daemon must NEVER write user OSD bits.** Main_MiSTer owns the OSD word and persists it to
`/media/fat/config/Plex_v3.CFG`. Any daemon-side `setStatusBits()` on those bits fights Main's shadow copy —
observed flapping `0x01c0 ↔ 0x0000` every poll. Removing all daemon writes made it rock-stable for 30 s+.
This is why `pushContentFpsBits()` / `restoreOsd()` / `osd_state.txt` were reverted. Polling is read-only.

**Gates**

- [x] G-OSD1 live core carries the v3 menu — `set_status --confstr` dumps the exact expected CONF_STR from the running core
- [x] G-OSD2 OSD renders with live values — `/tmp/osd5.png` via `tests/hw/osd_keys.py` (uinput F12), labels + values correct
- [x] G-OSD3 all four controls decode and apply live — `0x00c0`→+60 ms, `0x40c0`→idle=1, `0x40ca`→trim+resync off, `0x020a`→−160 ms; verified **mid-playback**
- [x] G-OSD4 A/V offset measurably moves lipsync — OSD +140 ms → median **−62.15 ms** vs baseline **+94.0 ms** = **−156 ms** delta
- [x] G-IDLE idle screen replaces the stuck last frame — `/tmp/idle3.png`, `/tmp/idle_afterstop.png`; amber chevron on near-black after stop
- [x] G-IDLE2a **`Black` idle mode PROVEN (2026-07-28)** — `black_poststop_bank0_Y.pgm` has **exactly one unique Y value (16)** across all
  299,520 pixels: uniform video-black, entered only after setting `lo=0x4000`. Distinguished from the original black-screen
  **bug** by the fact that the other modes render correctly on the same build.
- [x] G-IDLE2b **`Screensaver` idle mode PROVEN (2026-07-28)** — two time-separated captures differ by **7,656 / 299,520 pixels**;
  rendering shows the chevron **centred** in the logo baseline and **shifted hard left** in the screensaver captures. It is a
  bouncing-logo screensaver and genuinely animates (position change, not noise).
- [ ] G-EOF1 **Natural end-of-file leaves the local timeline wedged (2026-07-28)** — W-CAST soak, 21.5 min / **32171 frames** of real media (ThunderCats) played to natural EOF. The media session ends and PMS correctly receives `stopped`, **but the local timeline stays `fullScreenVideo`/`buffering` until an explicit stop arrives.** User-visible: watching an episode to the end leaves the device in a fake playing state reporting a stale timeline to anything that polls it. The explicit-stop path works correctly, so the divergence between "explicit stop" and "natural EOF" *is* the bug. Fix should **converge** the two paths, not add a parallel one. Must not depend on `LastFrame` idle mode, which is independently broken (G-IDLE2c). **Survived because every existing test issues an explicit stop; nothing tests natural EOF.** Regression test must be proven to go red against current code first.

- [x] G-SOAK1 **Long-run playback stability PROVEN (2026-07-28)** — same 21.5 min / 32171 frame soak, sampled throughout rather than only at the end:
  - `vfps/pfps` = **24.9 / 24.9** held for the whole run
  - `av_drift_ms` bounded **-23..-35**, **non-monotonic** -> **disproves the clock-domain / timebase-leak hypothesis**
  - drops crept **5 -> 9** = ~0.012% of 32171 frames
  - RSS **4300 -> 4308 KiB**, PID stable (32159) -> no leak, no respawn
  This replaces the previous 91-second basis for scoring cast playback. **Note the frame rate here is 24.9 fps vs 24.75 fps in the 91 s run** -- a real difference, relevant to the `kDdrBankReuseMinUs` question, since a rate pinned this tightly for 21.5 minutes is consistent with a hard-coded sleep (not proof; a well-behaved source looks similar).

- [ ] G-IDLE2c **`Last frame` idle mode is BROKEN — holds a TORN COMPOSITE, not a decoded frame (2026-07-28)**
  `lastframe_poststop == lastframe_paused_reference` (md5 `26cc25a728f1…`, diff `0`) — but that only proves **stability**, not
  **correctness**: both sides share the same defect, so the equality can never expose it. Per-band luma analysis of
  `lastframe_poststop_bank0_Y.pgm`:

  | Rows | Unique Y values | Range | Reading |
  |---|---|---|---|
  | 0–185 (top) | **189** | 15–203 | real decoded video |
  | 190–380 (**middle**) | **2** (45, 157) | — | **synthetic logo graphics, not video** |
  | 390–480 (bottom) | **134** | 15–203 | real decoded video |

  The middle band is **93.1%** pixel-identical to `screensaver_poststop` and **92.2%** identical to the logo baseline, i.e. the
  middle third of the frame buffer was **never overwritten** and retains stale content from the preceding mode. A user selecting
  "Last frame" sees a torn image.
  **Open questions:** compare bank0 vs bank1 — if only one bank tears this is a **bank-swap/`swap_pending` defect in the present
  path**, not an idle-mode bug, and is considerably more serious. Also re-run from a clean state to confirm the stale content
  really originates from the previous test rather than a fresh-boot tear.
  **Method note worth keeping:** comparing two artifacts that share a defect always reports agreement. Validating "does X hold the
  right content" requires comparison against **known-good** content, not against another instance of X.
- [ ] G-IDLE2 **the other three idle modes were UNPROVEN on hardware (2026-07-28)** — `Plex.sv:73` declares four modes
  (`"O[15:14],Idle screen,Plex logo,Black,Screensaver,Last frame;"`) but every eyes-on capture to date exercises only
  **`Plex logo`** (`[15:14]=00`): idle = Plex chevron, playback counter advanced 46→154, post-stop byte-identical to idle.
  **`Black`, `Screensaver` and `Last frame` have never been exercised on device**, and the merged idle fix (`0fd39d9`)
  changed *dispatch* for all four, so three of the four paths it touches are untested. Specific risks: `Black` is
  visually indistinguishable from the original black-screen **bug** unless you know it was requested; `Last frame` is
  the most likely to be silently broken; a `Screensaver` that does not animate is a bug and needs two time-separated
  frames diffed to detect. **This goal was scored 100% on the strength of one mode and has been corrected to 65%.**
- [x] G-OSD-UNIT bit layout pinned — `tests/unit/test_osd_menu.cpp` in `make unit` (12 suites green)
- [ ] G-OSD5 arrow-key menu navigation eyes-on — **PENDING user**: `/dev/uinput` F12 works, **arrows do not register**, so lab automation cannot drive the menu end-to-end
- [x] G-OSD6 **F12/OSD invisible (2026-07-26)** — **RESOLVED. Root cause: a wedged MiSTer `Main`.**
  F12 came back by itself after a reboot, with zero RTL changes. `Main` had spun forever in the
  GPO/SPI ACK handshake; while wedged it stops servicing the HPS<->FPGA link, so it never writes
  `io_osd_vga`/`io_strobe`/`io_din` and the OSD simply has nothing to draw. Same wedge also made it
  silently drop `/dev/MiSTer_cmd`, so `load_core` was a no-op (see G-VID1).
  **Two earlier diagnoses were WRONG — recorded so they are not repeated:**
  1. "SPI sharing in `d9941de` starves Main's OSD writes." Disproven: F12 stayed dead with
     `misterplexd` fully stopped.
  2. "`sys/video_mixer.sv` / `sys/osd.v` are never instantiated." Disproven: `video_mixer.sv`
     contains **no OSD at all**, and `sys/sys_top.v` **is** the top-level entity
     (`Plex.qsf:11: TOP_LEVEL_ENTITY sys_top`), instantiating `osd hdmi_osd` (line 1183) and
     `osd vga_osd` (line 1403) via `sys/sys.qip`. The framework composites the OSD regardless of
     whether the core uses `video_mixer`; routing through `video_mixer` would NOT have fixed F12.
  **Follow-up (open, tracked as G-STAB2):** find what wedges `Main` in the first place.
  **Liveness test — the only valid one:** `load_core /media/fat/menu.rbf`, then confirm
  `/tmp/CORENAME` actually becomes `MENU`. A `DEPLOY_LOAD=menu` bounce printing `CORENAME=Plex`
  proves **nothing** (it loads Menu then Plex, ending at `Plex` either way).
  **First diagnosis was WRONG — recorded so it is not repeated:** Main pid 30664 sits in `state=R`
  at ~48 % CPU with `utime` climbing, which looks exactly like the documented GPO-mid-handshake
  spin. It is not — the same Main serviced `/dev/MiSTer_cmd` during a `DEPLOY_LOAD=menu` bounce
  (`CORENAME=Plex`). **A busy-looking Main is normal while a core is loaded; only a dead
  `MiSTer_cmd` proves the wedge.** Keyboard is enumerated fine (`SIGMACHIP USB Keyboard` →
  `event0`; Main's `MiSTer virtual input` → `event4`).
- [x] G-STAB1 **`misterplexd` exits during session handoff** — **RESOLVED. Root cause: unhandled
  `SIGPIPE`.** Reproduced deterministically with a `seekTo` on live TNG: the new `PLAY`, the old
  session's `audio pump end` / `session end`, the session-start banner (`FPGA frame path OK`), then
  **nothing** — process gone, port 3005 refusing.
  The silence was the clue. All logging is `fprintf(stderr, …)` and stderr is unbuffered, so no
  message was lost; the process was dying from a signal that prints nothing. `SIGPIPE`'s default
  action terminates silently and leaves **no dmesg record**, which is exactly what we saw.
  Two defects, both fixed:
  1. `SIGPIPE` was never ignored — `main.cpp` installed handlers for SIGINT/SIGTERM/SIGCHLD only.
  2. `companion.cpp`'s `sendHttp()` called `::send(fd, …, 0)` without `MSG_NOSIGNAL`, so any client
     that hung up before the response flushed (Plex's long-poll timeline, a timed-out request)
     raised SIGPIPE on the HTTP thread.
  **This one defect also explains G-OSD6.** `SIGPIPE` is not in `installCrashGuard()`'s list
  (SIGSEGV/ABRT/BUS/ILL/FPE/QUIT), so the guard never ran, `Main` was left SIGSTOPped mid-SPI, and
  F12/OSD/`/dev/MiSTer_cmd` all died with the daemon — the "wedged Main" of G-STAB2.
  Verified: seek on live TNG now survives (same pid, new session plays, audio `av-lock`), and
  `Main` stays `state=R` with `CORENAME=Plex`.

- [ ] G-STAB2 **What wedges MiSTer `Main`?** (highest-value stability item) — during this session
  `Main` entered the GPO/SPI ACK spin (`state=R`, `utime` climbing, `wchan=0`) and stayed there.
  Consequences are severe and **silent**: F12/OSD dies (G-OSD6) *and* `/dev/MiSTer_cmd` stops being
  serviced, so `load_core` is accepted then dropped — the RBF on the SD card updates and its md5
  verifies, but **the FPGA keeps running whatever bitstream was loaded when Main wedged**. Four
  consecutive build/deploy/test cycles were invalidated this way before it was noticed.
  Notes: `resumeStrandedMain()` only rescues state **T**, never this spin; Main's handshake loop has
  no timeout. Only recovery found is a reboot (~75 s to SSH; the startup hook re-launches
  `misterplexd`).
  **Next:** determine whether `misterplexd` provokes it (it wedged while the daemon was running),
  and add an automatic detector — probe `load_core menu.rbf` + `/tmp/CORENAME` before trusting any
  deploy, and consider having `deploy_plex_core.sh` fail loudly instead of reporting success.
  **UPDATE — likely answered by G-STAB1.** The daemon was dying from an unhandled `SIGPIPE`, which
  is *not* in `installCrashGuard()`'s signal list. So the guard never ran and `Main` was left
  SIGSTOPped inside an SPI critical section — precisely this wedge. With SIGPIPE ignored and
  `MSG_NOSIGNAL` on the HTTP sends, the daemon no longer dies on that path. Keep this item open
  only to confirm no *other* silent-death path exists: any signal outside
  {SEGV,ABRT,BUS,ILL,FPE,QUIT} strands Main the same way, so consider widening the guard (or
  restoring GPO from an `atexit`/RAII owner) rather than enumerating signals.
  The automatic detector is **done**: `deploy_plex_core.sh` now verifies `CORENAME` actually
  becomes `MENU` and hard-fails (exit 3 wedged / exit 4 never returned to Plex) instead of
  reporting a false success. It fired correctly and caught a real wedge during the edge work.

### misterplexd no longer touches Main (**DONE** 2026-07-26)

**Root cause of "the Plex core keeps crashing Main / F12 is dead".** The HPS<->FPGA "SPI"
is a single GPO register (`0xFF706010`) plus a strobe/ACK handshake, owned by Main. Main's
`fpga_spi()` spins on that handshake with **no timeout**, so rewriting GPO while Main sits
between `strobe=1` and `saw ACK` makes the core drop ACK and Main spin **forever** — no
F12, no OSD, no `/dev/MiSTer_cmd`. `healMainReloadPlex()` then "fixed" that by killing and
re-exec'ing Main after every play; since `/etc/inittab` uses `sysinit` (not `respawn`), any
interruption of that left the board with **no Main at all** until a power cycle.

- [x] G-MAIN1 verified-safe SPI window — stop Main, wait for **every task** in
      `/proc/<pid>/task` to reach state `T`, require Main's enable bits
      (FPGA_EN/OSD_EN/IO_EN) + strobe all clear, restore GPO byte-for-byte, then SIGCONT.
      Retry on busy; fail the call cleanly rather than corrupt the handshake.
- [x] G-MAIN2 DDR OSD mailbox — core publishes `status[15:0]` at **`0x3007F100`**
      (`"PLXS"` + seq) from `ddram_frame_rd`; host reads it with a plain load. Live on
      hardware: `media: OSD via DDR mailbox (no SPI)`. Frame path was already SPI-free,
      so a normal session now touches SPI **zero** times.
- [x] G-MAIN3 bandaid removed — `healMainReloadPlex()` and `ensureMainAlive()` deleted.
      misterplexd never starts, stops, kills or reloads Main. Only `resumeStrandedMain()`
      remains, and it sends **SIGCONT only**.
- [x] G-MAIN4 hardware proof — 4 play/stop cycles, Main pid **28219 unchanged throughout**;
      `screenshot` via `/dev/MiSTer_cmd` produced a new file *after* playback (the exact
      thing that used to need a Main restart); final state `R`, core `Plex`.
- [x] G-MAIN5 unit regression — `tests/unit/test_main_guard.cpp` also asserts no guard
      ever terminates Main.

RBF `06b3cb4836436ba2a60a237dc604eb7a` — 0 errors, timing MET (worst setup slack
0.051 ns, pll_hdmi), ALM 23%, RAM blocks 74%.

**`scripts/deploy_misterplexd.sh` was shipping stale binaries** — it only cross-compiled
`if [[ ! -f "$BIN" ]]`, so once `build/arm/misterplexd` existed no later deploy rebuilt it.
It now always runs `make arm-plexd`. Check this first whenever a fix appears to have no
effect on hardware.

### Fallout / follow-ups

- `tests/hw/test_fbar_fast.sh` and `tests/hw/test_menu_osd.sh` are **OBSOLETE on v3** (they drive the removed
  debug menu; on v3 they would write a bogus A/V offset). Headers now say so.
- Two thread-lifecycle bugs fixed in `media_player.cpp`: `startIdle()`/`stopIdle()` raced the same
  `std::thread` (→ `std::terminate`), and `stop()`'s `fpga_.close()` + `healMainReloadPlex()` ran while the
  OSD poller / idle painter were mid-ioctl (→ crash). Guarded by `idleMu_` / `osdMu_` and an ordered
  retire-then-restart in `stop()`.
- A **third**, intermittent abort was found by stress-running `test_plex_browse.sh` (3/6 repro) and read
  out of a core dump: `~MediaPlayer()` destroyed a still-joinable `std::thread`. Only `stop()`/`play()`
  ever joined `thr_`, so a session that ended on its own left it finished-but-joinable, and SIGTERM →
  `main()` return → destructor → `std::terminate`. Fixed with `MediaPlayer::shutdown()`, which joins
  `thr_`/`audioThr_`/`streamThr_` **before** retiring the idle/OSD threads — the reverse order still
  aborted 1/10, because `threadMain` calls `startIdle()` at session end and would spawn a fresh painter
  after the old one was joined. A `shuttingDown_` latch makes `startIdle()`/`startOsdPoll()` refuse to
  start once teardown begins. **0/15 after the fix.**
- Both `test_plex_browse.sh` and `test_companion_http.sh` now `assert_clean_exit` (daemon must exit 0 or
  143). They previously only asserted HTTP responses, so the abort printed `terminate called without an
  active exception` and the script still exited 0 — that is why this shipped.
- `paintIdle()` must use the same DDR-bulk-then-SPI ladder as the present loop; SPI-only F1 does not land.
- HDMI grabber emits ~20 black warmup frames — single-frame captures must `select=gte(n\,40)`.

---

Evidence sources (2026-07-24; **J-backlog66** evidence-only stamp; **exclusive FREE**; lock **`R-csum6 DONE BUILD_OK 2026-07-24T14:10:26-05:00 NEW_RBF=94bbfe433feb562fabe0798e16b378c5 wall=438s LOCK_OK`**): `/tmp/misterplex-*-agent*.txt`. **R-csum6 BUILD_OK DONE** — log `/tmp/plex_quartus_rcsum6.log` Full Comp **0e/40w** wall **438s** exit **0**; NEW_RBF **`94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5`; **LOCK_OK** claim **`c7a847f7`/`ca62d02b`/`904e9b2e`** DIAG=ABSENT Rank1+2+3. **H-deploy-rcsum6 ONE menu DEPLOY_OK** lab **LOADED `94bbfe43`** (`/tmp/misterplex-agent-H-deploy-rcsum6.txt` + user log + lab txt). **H-gate-rcsum6 hard residual IN_PROGRESS / PENDING** — **do NOT invent hard residual PASS**. **WIDE still FAIL open Fix-2** historical **`ec21e133`** span=**0.605**. **3l2 BLOCKED** until sticky **0x14**. **C-unit28/27 PASS** host green. Soft-skip ≠ hard PASS. **BUILD_OK + DEPLOY ≠ residual PASS ≠ WIDE PASS.** **J-backlog66 REFRESH_DONE**.

**W-wide-gate-fix2b — WIDE FAIL reconfirm on lab `ec21e133` (J-backlog61 primary wide cite):** report **`/tmp/misterplex-agent-W-wide-gate-fix2b.txt`**. Lab LOADED full `ec21e1330ddd75ad7f39099e5abfad49` pre+post; ZERO reload. **WIDE FAIL** span=**0.605** (60.5%) live **2..485** R5%=**0.0** L5=**201.6** class **PILLAR_320_of_529**; multi-format 0.605–0.608. **FBAR PASS** 7.0/82.9/94.4 EXIT=0. Fingerprint **IDENTICAL** **H-gate-sf2** / **W-wide-gate-sf2**. Captures `fix2b_*` + `fix2b_wide_analysis.json`. **P3-WIDE remains FAIL open** — do **not** invent WIDE PASS / Fix-3 PASS. Fix-3 hold FIT_GO=NO until residual serial / exclusive free.

**W-wide-gate-sf2 — WIDE FAIL on lab `ec21e133` (companion wide cite):** report **`/tmp/misterplex-agent-W-wide-gate-sf2.txt`**. Lab LOADED full `ec21e1330ddd75ad7f39099e5abfad49`. **WIDE FAIL** span=**0.605** (60.5%) class **PILLAR_320_of_529** (same as pre-Fix-2 / W-wide7); R5%=0.0; captures `wq2_*`. **FBAR soft PASS** 7.0/82.9/94.4 EXIT=0 — **≠ WIDE product PASS ≠ residual PASS**. **P3-WIDE remains FAIL open** — do **not** invent WIDE PASS / Fix-3 PASS.

**H-gate-sf2 — WIDE Fix-2 companion gate on lab `ec21e133`:** report **`/tmp/misterplex-agent-H-gate-sf2.txt`**. RBF full `ec21e1330ddd75ad7f39099e5abfad49`; colorbars SRC **`f1d9666a…`**. **FBAR PASS** 7.0/82.9/94.4 EXIT=0. **WIDTH FAIL** span=**0.605** x0=2 x1=485 class **PILLAR_320_of_529**; captures `captures/menu/sf2w_10.jpg`..`sf2w_12.jpg`. **BUILD_OK + DEPLOY + FBAR ≠ WIDE product PASS.** Next: RCA / Fix-3 plan only after residual exclusive frees — **do not invent Fix-3 PASS**.

**H-gate-ec21 — residual HARD_FAIL on LOADED wide `ec21e133` (residual still FAIL open on lab ec21e133; J-backlog65):** report **`/tmp/misterplex-agent-H-gate-ec21.txt`**; probes `/tmp/misterplex-H-gate-ec21-probes.txt`; reconfirm **`/tmp/misterplex-agent-H-res-ec21.txt`**. Lab md5 match full `ec21e1330ddd75ad7f39099e5abfad49`; ZERO redeploy. **res_csum HARD_FAIL**: sticky0x14=**0/3** (never raw[13]==**0x14**). Canonical +0x53 seq **08/5b/ae/01** (PRE→P1→P2→P3 all +0x53). Class **MULTI_DRIVE_OR_STILL_FAIL**. **res_dc PASS** (−24 / 0xe8) 3/3. FBAR soft EXIT=0 ≠ hard residual PASS. **H-res-ec21**: sticky0x14=**0/7** +0x53 6/6 raw13 **54 a7 fa 4d a0 f3 46** — **SAME CLASS** as historical **`8832824e`**. Wide Fix-2 bitfile does **not** carry residual sticky pack fix. **BUILD_OK + DEPLOY + FBAR + PACKAGE ≠ residual PASS.** Soft-skip ≠ PASS. **3l2 BLOCKED.** Thrash residual banned set **FORBIDDEN**; do not thrash-redeploy **ec21e133** for residual luck either. R-csum6 **BUILD_OK** host **`94bbfe43`** is the intentional multi-drive path — **not** luck redeploy of **ec21e133**; **ONE H-deploy-rcsum6** next.

**H-fbar-ec21b — FBAR soft PASS reconfirm lab `ec21e133` (J-backlog64 cite):** report **`/tmp/misterplex-agent-H-fbar-ec21b.txt`**. Lab LOADED full `ec21e1330ddd75ad7f39099e5abfad49`; ZERO redeploy/Quartus. **FBAR soft PASS** EXIT=0 **7.0/82.9/94.4**. **≠ WIDE product PASS ≠ residual hard PASS ≠ 3l2 UNBLOCK.**

**C-unit28 / C-unit27 — host unit PASS (J-backlog64 cite):** **C-unit28** report **`/tmp/misterplex-agent-C-unit28.txt`** — `make unit` **EXIT=0 PASS**; host goldens res_csum=**0x14** res_dc=**-24**; test_idct_quant + parse self-test OK. Prior **C-unit27** **`/tmp/misterplex-agent-C-unit27.txt`** / log `/tmp/misterplex-unit-C-unit27.log` same goldens. **HOST GREEN ≠ lab residual PASS.**

**B-ddr7 — optional DDR F1 reconfirm PASS on LOADED `ec21e133` (J-backlog63 cite):** report **`/tmp/misterplex-agent-B-ddr7.txt`**. Lab md5 full `ec21e1330ddd75ad7f39099e5abfad49`; ZERO deploy/menu/Quartus; mean **16.5 ms** 5/5 OK (~60.6 fps) ≥30 fps; has_frame 0→1 after pulse0. **DDR ≠ residual PASS ≠ WIDE PASS.** Prior **B-ddr6** dabdaeb0 same class.

**A-csum-host28 — HOST_GOLDEN_OK (J-backlog64 cite):** report **`/tmp/misterplex-agent-A-csum-host28.txt`**. Host residual goldens locked for post–R-csum6 H-gate compare: res_dc=**−24** (0xe8), res_csum=**XOR 0x14**, ideal raw class **`e8 14 xx`**; helper SELF-TEST OK; cite **C-unit28/C-unit27** PASS. **HOST_GOLDEN_OK ≠ lab residual PASS ≠ R-csum6 BUILD_OK ≠ 3l2 UNBLOCK.**

**W-wide-rca-sf2 — FIX2_INEFFECTIVE + W-sf3-plan READY / FIT_GO_WIDE=NO (J-backlog64 cite):** loop SoT `/tmp/misterplex-loop-status.txt` harvest: **W-wide-rca-sf2: FIX2_INEFFECTIVE** pillar **0.605** paint still **content320/DE529**; **W-sf3-plan: Fix-3 READY; FIT_GO_WIDE=NO** while residual LIVE. Plan/hold reports (when present) `/tmp/misterplex-agent-W-sf3-plan.txt` **FIT_GO Q-SF3=NO**; `/tmp/misterplex-agent-W-sf3-hold.txt` **HOLD_OK**. Measure still **W-wide-gate-sf2b / W-wide-gate-sf2 / H-gate-sf2** span=**0.605** **PILLAR_320_of_529**. **≠ WIDE product PASS.** **Q-SF3 sole only after R-csum6 exclusive frees** — do **not** invent WIDE PASS / Fix-3 BUILD_OK.

**H-gate-rcsum5d — DEFINITIVE HARD_FAIL historical lab `8832824e` (residual serial CLOSED FAIL; J-backlog64 cite):** report **`/tmp/misterplex-agent-H-gate-rcsum5d.txt`** consolidates **H-gate-rcsum5** + **5b** + **5c**. Primary `/tmp/misterplex-agent-H-gate-rcsum5.txt` + **`…5b.txt`**; probes `/tmp/misterplex-H-gate-rcsum5-probes.txt` + summary `/tmp/misterplex-H-gate-rcsum5-summary.txt`. Residual gate was on LOADED **`8832824e`** full `8832824e483cf6613f82ee3ba3e592b3` CORENAME=Plex. **res_csum HARD_FAIL**: sticky0x14=**0/12** (never raw[13]==**0x14**). Canonical +0x53/push seq **16/69/bc/0f/62/b5/08** (6/6 adjacent +0x53). Class **NOT PACK_PROVEN** / **MULTI_DRIVE_OR_STILL_FAIL**. **res_dc PASS** (−24 / 0xe8). FBAR soft EXIT=0 (≠ hard residual PASS). Soft residual EXIT=0 ≠ hard PASS. **3l2 BLOCKED.** **BUILD_OK + DEPLOY_OK + PACKAGE_OK ≠ hard residual PASS.** Thrash **`8832824e` forbidden.** Lab path **now** LOADED **`ec21e133`** (wide track) — residual **also HARD_FAIL on `ec21e133`** (**H-gate-ec21** / **H-res-ec21**); residual class **CLOSED FAIL historical + still FAIL open on current lab**.

**H-gate-rcsum4 — HARD_FAIL lab `75da8bb1` (historical; path superseded by 8832824e then ec21e133):** report `/tmp/misterplex-agent-H-gate-rcsum4.txt` + **`/tmp/misterplex-agent-H-gate-rcsum4b.txt`**. Lab md5 **`75da8bb10e36b3e068d66a9ed053cd2c`** match; CORENAME=Plex. **FBAR PASS** (7.0/82.9/94.4). **res_dc PASS** (−24 / **0xe8** sticky). **res_csum HARD_FAIL**: never raw[13]==**0x14**. Series A **64/147/230** (**0x40→0x93→0xe6**, +0x53); 4b reconfirm **0x85→0xd8→0x2b** (+0x53/wrap). Class **NOT PACK_PROVEN** / **MULTI_DRIVE_OR_STILL_FAIL**. Soft residual EXIT=0 ≠ hard PASS. Thrash **75da8bb1 forbidden**.

**R-csum6 sole — residual multi-drive Rank1+2+3 product sticky BUILD_OK DONE + ONE menu DEPLOY + exclusive FREE — J-backlog66:**
- Lock **DONE BUILD_OK**: **`R-csum6 DONE BUILD_OK 2026-07-24T14:10:26-05:00 NEW_RBF=94bbfe433feb562fabe0798e16b378c5 wall=438s LOCK_OK`** (`/tmp/plex_quartus.lock` verbatim).
- **Exclusive FREE** — no `quartus_fit`/docker sole.
- Log **`/tmp/plex_quartus_rcsum6.log`**: BUILD START **14:02:51**; Full Comp **0e/40w** successful; BUILD END **14:10:09** exit **0** wall **438s** (`/tmp/plex_quartus_rcsum6.exit`=`0`; `/tmp/plex_quartus_rcsum6.wall`=`438`).
- NEW_RBF **`94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5` size **3506356** — host `fpga/Plex_MiSTer/output_files/Plex.rbf` md5 MATCH; **banned_hit=NO**.
- Claim **`/tmp/plex_quartus_rcsum6.claim/`**: owner **R-csum6-sole**; **FIT_GO=YES** Rank1+2+3; **DIAG=ABSENT**; freeze **Plex `c7a847f7`** / **slice `ca62d02b`** / **stream `904e9b2e`** fulls MATCH live **LOCK_OK**; build_result/done **VERDICT=BUILD_OK**.
- Sole **`/tmp/misterplex-agent-R-csum6-sole.txt` VERDICT=BUILD_OK**; mon **M-fitmon-rcsum6 BUILD_OK YES** SRC_DRIFT **NO** idle=YES.
- **H-deploy-rcsum6 ONE menu DEPLOY_OK**: `/tmp/misterplex-agent-H-deploy-rcsum6.txt` **PROMOTE_OK|DEPLOY_OK**; `/tmp/misterplex-H-deploy-rcsum6-user.log` Soft reload Menu→Plex; lab `/tmp/misterplex-H-deploy-rcsum6-lab.txt` **LOADED `94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5` CORENAME=Plex.
- **H-gate-rcsum6 hard residual IN_PROGRESS / PENDING** — **do not invent hard PASS / PACK_PROVEN**. Expect sticky0x14 ≥2; reject +0x53; res_dc=-24.
- **WIDE still FAIL open Fix-2** (historical **`ec21e133`** span=0.605). **3l2 BLOCKED** until hard product sticky **0x14**. Soft-skip ≠ PASS. **BUILD_OK + DEPLOY ≠ residual PASS ≠ WIDE PASS.**
- Evidence: `/tmp/plex_quartus.lock`; `/tmp/plex_quartus_rcsum6.log`; claim dir; `/tmp/misterplex-agent-R-csum6-sole.txt`; `/tmp/misterplex-agent-M-fitmon-rcsum6.txt`; `/tmp/misterplex-agent-H-deploy-rcsum6.txt`; `/tmp/misterplex-H-deploy-rcsum6-user.log`; `/tmp/misterplex-H-deploy-rcsum6-lab.txt`.

**R-csum5 sole — residual serial CLOSED FAIL on `8832824e` (BUILD_OK+DEPLOY_OK+PACKAGE_OK; H-gate HARD_FAIL) — historical; J-backlog62:**
- Build lock (historical): **`R-csum5 DONE BUILD_OK 2026-07-24T13:40:35-05:00`** — then exclusive FREE until Q-SF2 then R-csum6.
- Log residual build: **`/tmp/plex_quartus_rcsum5.log`** — Full Compilation **0e/37w**; wall **441s** exit **0**.
- Build report: `/tmp/misterplex-agent-R-csum5-build.txt` **VERDICT=BUILD_OK**.
- Residual NEW_RBF **`8832824e`** full `8832824e483cf6613f82ee3ba3e592b3` size **3510568**; ∉ banned at build.
- Claim@launch product sticky **`6422fb9a`/`8e6af3bb`** DIAG=ABSENT; mid-fit thrash **`6a5dcaaa`/`7d4a1d8b`** DIAG PRESENT → **PROVENANCE_UNTRUSTED** (map product sticky class midfit-rcsum5b).
- **H-deploy-rcsum5 DEPLOY_OK** ONE menu; lab was **LOADED `8832824e`** (now superseded on lab path by **`ec21e133`**).
- **PACKAGE_OK** (rcsum5 era) embeds **`8832824e`** (superseded by F-prep-qsf2 **`ec21e133`**).
- **H-gate-rcsum5d HARD_FAIL** (definitive; sources 5/5b/5c) MULTI_DRIVE sticky0x14=**0/12** +0x53 seq **16/69/bc/0f/62/b5/08**; **res_dc PASS**; FBAR soft; **NOT PACK_PROVEN**.
- **BUILD_OK + DEPLOY_OK + PACKAGE_OK ≠ hard residual PASS**. Soft-skip ≠ PASS. **3l2 BLOCKED.** Thrash **`8832824e` forbidden.**
- Evidence: **`/tmp/misterplex-agent-H-gate-rcsum5d.txt`**; H-gate 5/5b/5c; probes `/tmp/misterplex-H-gate-rcsum5-probes.txt` + summary; build/deploy/package reports; midfit-rcsum5*.

**Q-SF2 sole — wide Fix-2 TERMINAL BUILD_OK + DEPLOY + PACKAGE + WIDE FAIL open + residual HARD_FAIL on same RBF — historical; J-backlog62 cite:**
- Lock start historical **`Q-SF2 2026-07-24T13:45:49-05:00`**; log END **13:52:56** Full Comp **0e/38w** wall **415s** exit **0**; NEW_RBF **`ec21e133`** full `ec21e1330ddd75ad7f39099e5abfad49` size **3436288**.
- Mon **`M-fitmon-qsf2d` / `M-fitmon-qsf2b` BUILD_OK** — exclusive idle post-exit0 (pre–R-csum6).
- Lock was **`Q-SF2 DONE BUILD_OK 2026-07-24T13:52:56-05:00 NEW_RBF=ec21e133…`** (H-deploy-qsf2 harvest) — **superseded** by **`R-csum6 DONE BUILD_OK`** NEW **`94bbfe43`**.
- **H-deploy-qsf2: PROMOTE_OK | ALREADY_DEPLOYED** lab was **`ec21e133`** (ZERO second menu by H-deploy). Lab path **now LOADED `94bbfe43`** post H-deploy-rcsum6.
- **F-prep-qsf2 / F-prep-sf2: PACKAGE_OK** embeds **`ec21e133`** tarball `dist/misterplex-3c43a66-dirty.tar.gz`.
- **W-wide-gate-sf2: WIDE FAIL** span=**0.605** **PILLAR_320_of_529**; FBAR soft PASS — **WIDE still open**.
- **H-gate-sf2: FBAR PASS**; **WIDTH FAIL** span=**0.605** pillar.
- **H-gate-ec21 / H-res-ec21: residual HARD_FAIL** on LOADED **`ec21e133`** sticky0x14=0 +0x53 **08/5b/ae/01**; res_dc PASS — residual **FAIL open on current lab RBF**.
- **Wide track + residual measure** — ≠ residual product PASS; ≠ WIDE product PASS; ≠ 3l2 unblock; soft-skip ≠ PASS.
- Evidence: `/tmp/plex_quartus_sf2.log`; `/tmp/misterplex-agent-M-fitmon-qsf2d.txt`; `/tmp/misterplex-agent-M-fitmon-qsf2b.txt`; `/tmp/misterplex-agent-H-deploy-qsf2.txt`; `/tmp/misterplex-agent-F-prep-qsf2.txt`; `/tmp/misterplex-agent-F-prep-sf2.txt`; `/tmp/misterplex-agent-W-wide-gate-sf2.txt`; `/tmp/misterplex-agent-H-gate-sf2.txt`; `/tmp/misterplex-agent-H-gate-ec21.txt`; `/tmp/misterplex-agent-H-res-ec21.txt`.

**R-csum4 sole — BUILD_OK NEW_RBF `75da8bb1` + DRIFT caveat (historical path):** log `/tmp/plex_quartus_rcsum4.log`; Full Compilation **0e/35w**; wall **421s** exit **0**; NEW_RBF **`75da8bb1`** full `75da8bb10e36b3e068d66a9ed053cd2c`. Claim freeze DIAG **`94db41b7`/`9a2d10c5`**. Mid-fit **DRIFT_CRITICAL** → **RBF_PROVENANCE_UNTRUSTED**. **H-deploy-rcsum4 PROMOTE_OK | DEPLOY_OK**. **F-prep-rcsum4 PACKAGE_OK** embeds **75da8bb1**. **H-gate HARD_FAIL** (not PACK_PROVEN). **Thrash-redeploy forbidden.**

**R-csum-rtl5 FIT_GO (product sticky pack @ stamp; historical pre-rcsum5):** report `/tmp/misterplex-agent-R-csum-rtl5.txt` **VERDICT=FIT_GO**. Sticky pack PRESENT (`st_res_word_sticky` / `res_pair_sticky` family); status residual half from sticky ONLY; stream only [127:112]. **DIAG=ABSENT** product `residual_csum <= csum_acc` at stamp. Claim md5s **Plex `6422fb9a…` / slice `8e6af3bb…`**. No Quartus by rtl5. **FIT_GO ≠ BUILD_OK.**

**Lab LOADED `94bbfe43` after ONE menu (J-backlog66):** **H-deploy-rcsum6 PROMOTE_OK | DEPLOY_OK** — report `/tmp/misterplex-agent-H-deploy-rcsum6.txt`; user log `/tmp/misterplex-H-deploy-rcsum6-user.log` Soft reload Menu→Plex; lab `/tmp/misterplex-H-deploy-rcsum6-lab.txt` full `94bbfe433feb562fabe0798e16b378c5` CORENAME=Plex size **3506356**. Prior **`ec21e133`** WIDE FAIL span=0.605 + residual HARD_FAIL (**H-gate-ec21**); historical **`8832824e` HARD_FAIL** (**H-gate-rcsum5d**). **H-gate-rcsum6 hard residual IN_PROGRESS / PENDING** — **do not invent hard residual PASS / PACK_PROVEN / 3l2 UNBLOCK**. Soft-skip ≠ PASS. **3l2 BLOCKED** until hard product sticky **0x14**. Thrash **`8832824e`/`75da8bb1`/`4d6ee356` FORBIDDEN**. **BUILD_OK + DEPLOY ≠ residual PASS ≠ WIDE PASS.** **WIDE still FAIL open Fix-2.**

**Prior product hard class (H-gate-rcsum3b / 3b2 / 3b3 — historical on `4d6ee356`):** **never sticky 0x14**. +0x53/push family. Soft residual ≠ hard PASS. **Thrash 4d6ee356 forbidden.**

**A-csum-probe7 HOST_PROBE_OK** / **A-csum-map1/map2 MAP_OK:** host map matches FPGA packing; blame residual_csum value / multi-drive pack. Ideal **`e8 14 53 1a` HARD_PASS** offline only.

**R-csum-postfail8 RCA (docs):** MULTI_DRIVE / PACK_FAIL on 75da8bb1; annex-len lo +0x53; sticky latch / multi-drive of status[111:104]; provenance co-cause. Report `/tmp/misterplex-agent-R-csum-postfail8.txt`. **H-gate-rcsum5d** reconfirms same class on **`8832824e`** (seq **16/69/bc/0f/62/b5/08**; sticky0x14=0/12).

**Next serial (R-csum6 TERMINAL BUILD_OK; exclusive FREE; J-backlog66):**
1. ~~**R-csum-rtl5** sticky pack FIT_GO~~ — **DONE**
2. ~~**R-csum5 sole**~~ — **DONE BUILD_OK** NEW_RBF **`8832824e`** wall **441s**; **PROVENANCE_UNTRUSTED**; residual gate **CLOSED FAIL**
3. ~~**Trust + H-deploy-rcsum5**~~ — **DONE DEPLOY_OK** ONE menu **`8832824e`** (lab path since superseded)
4. ~~**PACKAGE_OK embed `8832824e`**~~ — **DONE** (superseded by F-prep-qsf2 / F-prep-sf2)
5. ~~**H-gate-rcsum5 / 5b / 5c / 5d**~~ — **DONE HARD_FAIL** residual serial **CLOSED FAIL** MULTI_DRIVE sticky0x14=0 +0x53 **16/69/bc/0f/62/b5/08**; res_dc PASS; **NOT PACK_PROVEN** (**H-gate-rcsum5d** definitive)
6. ~~**Q-SF2 sole wide Fix-2**~~ — **DONE BUILD_OK** END **13:52:56**; Full Comp **0e/38w** wall **415s** exit **0**; NEW_RBF **`ec21e133`**; mon **M-fitmon-qsf2d/qsf2b BUILD_OK**
7. ~~**H-deploy-qsf2 promote + lab LOADED**~~ — **DONE PROMOTE_OK | ALREADY_DEPLOYED** lab was **`ec21e133`** (path superseded by **`94bbfe43`**)
8. ~~**F-prep-qsf2 / F-prep-sf2 PACKAGE_OK embed `ec21e133`**~~ — **DONE** ≠ product/WIDE PASS
9. ~~**W-wide-gate-sf2 / fix2b + H-gate-sf2 FBAR + WIDTH**~~ — **DONE FBAR soft PASS; WIDE/WIDTH FAIL** span=**0.605** **PILLAR_320_of_529** — **WIDE open; Fix-2 CLOSED ineffective**
10. ~~**H-gate-ec21 / H-res-ec21 residual hard on `ec21e133`**~~ — **DONE HARD_FAIL** sticky0x14=0 +0x53 **08/5b/ae/01** — historical FAIL on prior lab path (superseded by **`94bbfe43`**)
11. ~~**C-unit-sf2 / C-unit26 / C-unit27 / C-unit28 host unit**~~ — **DONE PASS** host (**C-unit28** `/tmp/misterplex-agent-C-unit28.txt`) ≠ lab residual PASS
12. ~~**H-fbar-ec21b FBAR soft reconfirm**~~ — **DONE PASS** 7.0/82.9/94.4 on lab **`ec21e133`**
13. ~~**R-multidrive-rca14 + H-proto-rcsum6 + L-csum-note37**~~ — **DONE** RCA_OK / PROTO_OK / DOCS_OK; parent **FIT_GO=YES**
14. ~~**R-csum6 sole**~~ — **DONE TERMINAL BUILD_OK** lock **14:10:26** wall **438s** exit **0** Full Comp **0e/40w**; NEW_RBF **`94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5`; **LOCK_OK** claim **MATCH** Rank1+2+3 DIAG=ABSENT md5s **`c7a847f7`/`ca62d02b`/`904e9b2e`**; mon **M-fitmon-rcsum6c BUILD_OK**; mid-fit **SRC_DRIFT: NO** — **BUILD_OK ≠ residual hard PASS**
15. ~~**W-fix3-hold / W-fix3-hold2**~~ — **DONE HOLD_OK** **FIT_GO Q-SF3=NO** (hold during exclusive; still hold until residual gate serial / parent free pick)
16. ~~**ONE H-deploy-rcsum6**~~ — **DONE PROMOTE_OK|DEPLOY_OK** ONE menu lab **LOADED `94bbfe43`** (`/tmp/misterplex-agent-H-deploy-rcsum6.txt`)
17. **H-gate-rcsum6** hard residual on **`94bbfe43`** expect sticky0x14 ≥2; reject +0x53; res_dc=-24 — **IN_PROGRESS / PENDING** (do **not** invent hard PASS)
18. ~~**F-prep-rcsum6**~~ — **DONE PACKAGE_OK** embeds **`94bbfe43`** (`/tmp/misterplex-agent-F-prep-rcsum6.txt`)
19. **Wide Fix-3 / Q-SF3** — **WIDE FAIL open** historical **`ec21e133`** 0.605; exclusive FREE — **do not invent WIDE PASS / Fix-3 BUILD_OK**
20. Soft-skip ≠ PASS. **3l2 BLOCKED** until hard product sticky **0x14** on non-DIAG product residual RBF. **WIDE still FAIL open Fix-2.** **BUILD_OK+DEPLOY ≠ residual PASS ≠ WIDE product PASS.**

git **docs HEAD `3c43a66`**; **FPGA committed `7bee0a6`**; R-csum6 claim freeze **MATCH** **`c7a847f7`/`ca62d02b`/`904e9b2e`** DIAG=ABSENT Rank1+2+3 LOCK_OK; NEW_RBF **`94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5`; Fix-2 colorbars **`f1d9666a`**. Host/lab RBF **`94bbfe43`**. Lab **LOADED `94bbfe43`** after ONE menu; exclusive **FREE**. **H-gate-rcsum6 IN_PROGRESS / PENDING** — **do not invent hard residual PASS**. **WIDE still FAIL open Fix-2** historical **`ec21e133`** span=**0.605**. **A-csum-host28 HOST_GOLDEN_OK** + **C-unit28/C-unit27 PASS** host ≠ lab residual PASS; **3l2 BLOCKED**. Soft-skip ≠ PASS. **BUILD_OK + DEPLOY ≠ residual PASS ≠ WIDE PASS.** **Do not invent hard-csum PASS / WIDE PASS / Fix-3 PASS / 3l2 UNBLOCK.** **J-backlog66**. Lab `192.168.1.183`.


### CURRENT LAB STATE — 2026-07-27 (supersedes the `94bbfe43` stamps above)

Everything above this line is the **2026-07-24 R-csum6 campaign record** and is retained as history. It is **no longer the live lab state**. Current truth:

- Lab **LOADED `8eb01b79`** full `8eb01b7965e25154eb4093bea16f1fc7` at `/media/fat/_Utility/Plex.rbf`, `CORENAME=Plex`, md5 verified local↔device. Supersedes **`94bbfe43`**. Banned-set hit: **NO**.
- Companion `misterplexd` **`215b01fb13d349d6f67f4665bc0a0041`** deployed and running (1 pid, HTTP :3005, GDM UDP 32412). `deploy_plex_core.sh` **stops plexd and does not restart it** — restart manually after any RBF deploy.
- Build fixes in **`6b5878e`** on `feat/disp-fix`. **HEAD was previously unsynthesizable**: `decode_stub.sv` used `dpb_mem_rd_q` without declaring it (Quartus `Error (10161)`, A&S dead in 8 s). `make rtl-lint` was **already RED on HEAD** — the merge landed without it. Fixed to the one-cycle contract `dpb_mem_rvalid <= dpb_mem_rd;` proven by the authoritative C++ model in `tests/rtl/h264_dpb_mc_tb.cpp`.
- New guard **`scripts/check_verilator_elab.py`** (merged `572e483`) now runs in `make quartus-sv-subset`, `make pre-synth-gates`, and `build_rbf_remote.sh` **before** the Quartus slot is taken. Parent-reproduced red/green: planted fault → exit 1 `VERILATOR_ELAB_REJECTED` at `decode_stub.sv:542`; clean tree → exit 0 `VERILATOR_ELAB_PASS`; ~2 s.

**Corrections to gate rows below — do not read them as green:**
- ~~`make unit` is **RED**~~ — **NOW GREEN as of 2026-07-28 00:30**, `FINAL_UNIT_RC=0`, 80 OK checks on the fully merged tree, including `OK real RTL sim: h264_dpb_mc product RTL nals=15 luma_window=441 chroma_windows=81/81 mc_pixels=256/64/64`. The failure was **the testbench, not the DPB**: the C++ model in `tests/rtl/h264_dpb_mc_tb.cpp` presented `mem_rvalid`/`mem_rdata` **one** edge after `mem_rd`, but the real memory (`decode_stub`) takes **two** — the DPB registers `mem_rd`/`mem_raddr`, `decode_stub` then registers `rvalid`/`raddr_q`, and `rdata` is combinational off `raddr_q`. Deleting the `_d1` stage would have turned the test green **while breaking real hardware**. The model now delays two edges and `_d1` is retained. Product RTL unchanged by this fix.
- **`make post-fit-timing` still FAILS**, but the dominant violation is **closed by design, not by exclusion** (`make timing-exclusion` PASS, no SDC exclusions added). `async_fifo` exposed a combinational `rd_data = mem[rd_bin]`, fanning 90 MHz FIFO RAM straight into 20 MHz `clk_sys` logic (dominant instance `ddr_bus_arbiter.m1_rsp_fifo`, ~187 failing endpoints). Converted to a registered FWFT read port. Fit `wtime1`, Quartus exit 0, wall 680 s, RBF `6ae8abb7adaf41b309f38e0ae9dbe6ae`:
  - `clk_sys` setup **−2.483 / TNS −462.216 → +0.320 / 0.000** — **CLOSED**
  - `clk_ddr` setup −1.197 / −1.278 → **−1.094 / −2.258** — still FAIL
  - `clk_ddr` hold → **−0.130 / −0.130** — new FAIL
  RBF `6ae8abb7` is **deliberately NOT deployed**; the lab still runs `8eb01b79`. Owner: W-TIME.
- Passing gates: `rtl-lint`, `quartus-sv-subset`, `define-parity`, `verilator-elab`, `post-fit-hierarchy`, `timing-exclusion`, `make unit`.

**Product bugs fixed and verified on hardware this session:**
- **Cast playback works.** Was: advertised as a cast target but never played, controller stuck at 0:00. Cause: PMS timeline/status sent a hard-coded Plex Web/Chrome identity, so PMS associated playback with the wrong player. Device evidence: `frames=134 vfps=21.9 audio=on clock=av-lock drops=0`, `fpga frame_tx ok via DDR presents=96`, timeline `0→2378→5528`. Pixel-verified as **real changing video**: bank0 frames differ by 2610/449280 bytes, Y unique 253/254, range 0–255. Scope: this is **ARM decode + PMS transcode at 320×240 presenting via FPGA** — it does **not** advance FPGA decode.
- **Black idle screen explained and fixed.** Cause: `OSD_CONTROL` let the saved OSD word `0x4000` (bits `[15:14]=01`) override `IDLE_SCREEN=logo` and select `IdleMode::Black`. Renderer histograms: `Black → Y 0x10 ×299520, U/V 0x80` (exactly matching the device capture); `Logo → Y 0x2d ×294400, 0x9d ×5120`. **The user's reported "dark grey 0x2D2D2D2D" was the logo's dark field** (`Y=0x2d`), not a bug. With `OSD_CONTROL=0` the active DDR bank shows the visible logo. Device conf set to `OSD_CONTROL=0` (backup `misterplex.conf.bak-orch`). **Still open:** the daemon should not let a default OSD word silently override `IDLE_SCREEN` — `OSD_CONTROL=1` still forces black.

**FINAL EYES-ON CONFIRMATION — 2026-07-28 00:26, daemon `215b01fb13d349d6f67f4665bc0a0041`, RBF `8eb01b79` unchanged, `OSD_CONTROL=0`.**
Captured from the live DDR frame store and **visually inspected** (PNGs preserved outside the repo; `captures/` is gitignored):
1. **Idle = logo, confirmed by eye.** Plex chevron (amber `>`) on the dark field. Both banks identical, md5 `f454b8f8…`; `count(0x2d)=294400` (98.29%), `count(0x9d)=5120` (1.71%), **`count(0x10)=0`, `count(0x00)=0`**. The black frame is gone.
2. **Playback = real moving video, confirmed by eye.** Played `/library/metadata/6` (30.0 s clip). The on-screen frame counter advanced **46 → 154** between the two captures while the timeline moved `2655 → 7040 ms` — consistent with 24 fps. Frames differ by 259619/449280 bytes. Counters alone could not have proven this; the incrementing on-screen number does.
3. **Post-stop returns to the logo — the latched-last-frame bug is gone.** After-stop banks are byte-identical to the initial idle logo.
**Honest scope limit:** the clip used is a **24 fps sync test pattern** from the library, not feature-length media, and the path is **ARM decode + PMS transcode presenting via FPGA** — it does **not** advance FPGA decode.

**REAL-MEDIA CONFIRMATION — 2026-07-28 00:39, same daemon/RBF.** The earlier confirmation used a 24 fps *sync test pattern*; this one uses genuine library content, ThunderCats S1E9 `/library/metadata/3`, 640×480, PMS `transcode=1`, ~91 s.

- **Sustains full frame rate on real content:** `2249 frames / 90.87 s = 24.75 fps` (**40.40 ms/frame**), `vfps=24.7`, `pfps=24.6`, `av_drift_ms` steady at **−21**.
- **`drops` are startup-only:** reach **6** by `wall_s=2.162` and stay **flat at 6** through `wall_s=90.87`. Not accumulating.
- **Real content, not a pattern:** frame at ~45 s has **203 unique luma values** (`Y 6..214`, mean 122.2); adjacent samples differ by **98–99%** of luma pixels. Visually confirmed as full-colour animation.
- **Transport controls work:** pause holds position (`time=5897` across two polls 3 s apart), resume advances, and absolute seek to `120000` lands at `125086` showing a completely different scene.
- Idle logo returns after the long run.

**Correction to an earlier figure in this file:** a `vfps=21.3` reading was quoted as a 480p shortfall. That came from a **7-second** run dominated by startup and was **not representative**; sustained rate is **24.75 fps**. `Direct-play` re-scored 60→68 on the strength of the present path being proven at 480p24. **Scope limit unchanged:** this is PMS transcode + ARM rawvideo presenting via FPGA — it validates the **present/DDR path**, *not* direct-play, and it does **not** advance FPGA decode.

**RETRACTION — 2026-07-28, the "20.6 ms doorbell" figure.** A `20.6 ms/frame` doorbell cost was quoted repeatedly as "~49% of the 41.67 ms budget" and used to argue direct-play was borderline. **It no longer describes the shipping path and must not be reused.** Source evidence (`arm/misterplexd/fpga_spi.cpp`): the steady present path is *not* a hard per-frame hardware handshake — it is `usleep(1500)` prep, `memcpy`, mmap doorbell stores, `usleep(500)` post = **2.0 ms** of explicit sleep. First-kick status polling is **one-time/amortised**. The old PLXD `50 × 1 ms` timeout poll that most plausibly produced the 20.6 ms figure was **removed in `6b5878e`**, i.e. the number was measured on a pre-`6b5878e` build.

**Bank-floor theory: SETTLED AND DEAD — measured on hardware (2026-07-28).** `PRESENT_PROFILE=1` on the device, `8eb01b79`, real media. **`ddr_bank_reuse_wait_us_p` = `32, 32, 0, 0, 0, 0` us per present.** Not 40,000. The `kDdrBankReuseMinUs = 40000` floor **does not fire** and is **not** setting the frame rate. The orchestrator raised this theory three times -- on arithmetic coincidence, then revived it on W-OSD's bank pixels, then again after eliminating the wrong-address explanation. **All three were wrong.** W-FEED's original source-based disproof reached the right conclusion first. Recorded as a standing caution: an arithmetic near-coincidence (40.00 vs 40.40) is not evidence, and it cost two lanes several hours of attention.

**BANK1 "DEFECT" RESOLVED -- IT DID NOT EXIST. Banks alternate correctly (2026-07-28, W-OSD address-agnostic scan).** The 64 KiB block-hash scan of `0x30000000-0x30100000` at 5 Hz shows changed blocks **`[0,1,4,5,7]`** on every one of 49 samples -- i.e. **two disjoint ranges alternating** (`0x30000000` and `0x30040000`), plus block 7 = mailbox/doorbell. A supplemental 640p run showed the doorbell seq advancing `61581 -> 62223` with **`hi[31]` toggling**. **Presents alternate banks; the selector reaches the consumer. There is no bank defect and no 25 fps cap.**

**Mechanism of the false finding:** the idle-mode capture run was at **320x240** (`content resolution=320x240 source=OSD`), not 480p. Bank stride is `alignUp(frame_bytes, 0x40000)`, so at 320p the frame is 115200 bytes and **bank1 sits at `0x30040000`** -- while the capture read `0x30080000`, which is 480p's bank1. Playback never wrote there because playback was not at 480p; the stale-looking logo/black at `0x30080000` was residue from *idle* painting, which had run at the larger geometry. Both observations were real; they were of two different geometries.

**ORCHESTRATOR ERROR -- recorded deliberately, because it is the most instructive mistake of the session.** I declared the wrong-address explanation "DEAD" on the strength of two "independent" confirmations: (a) arithmetic, `alignUpU32(449280, 0x40000) = 0x80000`, cross-checked against the `0x300FF000` doorbell; and (b) empirical, idle writes provably landing at `0x30080000`. **Both were correct. Neither was independent.** They shared the assumption that the run was 480p. **Two methods that share an assumption do not corroborate each other -- they repeat each other.** This is precisely the defect I had diagnosed in W-OSD's `post-stop == paused` check three hours earlier (comparing two artifacts that share a defect always reports agreement), and I committed the same error while citing my own detection of it as authority. Cross-checks must vary the assumption under test, not just the method.

**Corollary: the "stale docs" were not stale.** `docs/phase3-decode.md:422` and `tests/hw/README.md:68` document bank1 at `0x30040000` with a 256 KiB stride, which is **correct for 320x240**. My argument that a 0x40000 stride is "physically impossible" was correct *only* for 480p. Any doc correction must state the stride as **geometry-derived** (`alignUp(frame_bytes, 0x40000)`) and must **not** hard-code 480p addresses, or it will be wrong for the 320p path that the OSD/idle renderer actually uses.

_Superseded, retained for audit:_ **CRITICAL SUBTLETY -- this does NOT clear the bank1 question, and the counter cannot.** If presents never alternate, the same-bank reuse interval equals the frame interval = **~41 ms**, which is *just above* the 40 ms floor -- so the wait would read ~0 **either way**. The measurement is therefore silent on whether banks alternate. **It only proves the floor is not limiting us at 24 fps.** We clear it by ~1 ms, by luck of the source frame rate.

**Consequence, and this is the part that matters going forward:** at any higher frame rate a non-alternating bank **would** hit the floor hard -- 30 fps = 33.3 ms and 60 fps = 16.7 ms are both *below* the 40 ms floor. So if bank1 genuinely never receives video, **the present path is hard-capped just under 25 fps** and every higher-rate ambition (direct-play at source rate, 60 fps) is blocked by it. The bank1 investigation is therefore **more** important after this measurement, not less. W-OSD's address-agnostic block-hash scan remains the deciding evidence.

**What the profile DID establish (all measured, `8eb01b79`, real media):**
- `ddr_total_us_p` = **9858-10805 us** -> the whole DDR present costs **~10.5 ms wall**, not the ~2.0 ms the sleep-arithmetic implied and not the 40 ms of a frame interval
- `ddr_cpu_us_p` = **4862-5057 us** -> **~5 ms CPU**, i.e. roughly half the present is real work (consistent with a 449280-byte memcpy) and half is waiting
- `ddr_unaccounted_us_p` = **17-40 us** -> negligible; **the existing buckets fully explain the frame**, so the instrumentation can be trusted
- Frame tail `~24.3 pfps`, drops 6, drift -25/-26 ms

**Revised direct-play budget (measured, replaces all earlier estimates):** 41.67 ms/frame total - **10.5 ms** measured present = **~31.2 ms/frame available for decode**. Against W-FEED's ARM decode predictions of 20/25/30 ms/f this is a fit, with margin ranging from comfortable to ~1 ms. **Still requires the actual `scripts/run_arm_decode_profile.sh` measurement to resolve** -- the predictions remain unmeasured.

_Superseded, retained for audit:_ **Bank-floor theory: DISPROOF ITSELF INVALIDATED — REOPENED, verdict pending a counter read (2026-07-28).** The source disproof recorded below was correct reasoning from a false premise. W-OSD's dual-bank captures show **`bank1` never contains video in any mode, including mid-playback**: every `*_bank1_Y.pgm` has <=2 unique luma values (synthetic/flat) while the paired `*_bank0_Y.pgm` has 182-216. If presents never alternate, same-bank reuse collapses from ~80 ms to the **frame interval**, the 40 ms floor becomes reachable, and measured **40.40 ms/frame vs a 40.00 ms floor** stops being a coincidence.

**Cheap explanation eliminated (orchestrator-verified, not worker-reported).** The hypothesis that the capture simply read the wrong address is **DEAD**. Stale docs do list bank1 at `0x30040000` (`docs/phase3-decode.md:422`, `tests/hw/README.md:68`) -- a real defect, since a 0x40000 stride is *physically impossible* for a 449280-byte 480p frame -- **but the capture tool did not use them**: `captures/wosd-idle-modes/remote_probe.sh:59` sets `STRIDE=0x80000`. Confirmed correct against the runtime: `fpga_spi.cpp:682` uses `alignUp(frameLen, kDdrFrameStrideAlign)`, and `alignUpU32(449280, 0x40000) = 0x80000`, so bank1 = **`0x30080000`**; cross-checked via `doorbell = base + stride*2 - 0x1000 = 0x300FF000`, which matches the shipping doorbell contract. **The captures read the correct bank1 and found no video there.**

Remaining candidates: (2) hardware/core ignores the bank selector (see `bank = status[13]`, `tests/hw/README.md:68`); (3) selector dropped between `fpga_spi.cpp:1365` (`bankOff = bank * ddrLayout_.bank_stride`) and the doorbell. Software alternation is confirmed **intact** -- both `ddrBank_ = 0` sites (`media_player.cpp:625`, `:761`) are guarded by `fpga_.open()`, i.e. one-time init, not per-frame.

**DECIDING EVIDENCE, not yet gathered:** `prof.ddrBankReuseWaitUs` (`media_player.cpp:2530-2545`) is a dedicated counter for time blocked on the floor, already instrumented and **never once read**. `~0` -> floor never fires, theory dead for good. `~40,000 us/frame` -> the floor is *setting* the frame rate and the present path's real capability is unknown. Requires only `PRESENT_PROFILE=1`. Also unread: `ddrCpuUs` (separates *waiting* from *working*) and `ddrUnaccountedUs`. **No verdict will be recorded in this document until that counter is read.**

**Method note:** this theory has now been raised, disproved on source, revived on pixels, and had its revival's cheapest counter-explanation eliminated -- each move on new evidence. It is the clearest example in this log of why source review cannot substitute for on-device counters.

_Superseded original entry, retained for audit:_ **Bank-floor theory raised and DISPROVED (same date).** `kDdrBankReuseMinUs = 40000` (40 ms) is suspiciously close to the measured 40.40 ms/frame, raising the possibility that a hard-coded sleep was *setting* the frame rate rather than measuring capability. **Excluded by source:** `arm/misterplexd/media_player.cpp` toggles `ddrBank_ ^= 1` after every successful present, so same-bank reuse interval is **~80–83 ms**, comfortably above the 40 ms floor; drops only widen it. The floor cannot fire at 24 fps. Conclusion: **40.40 ms/frame is source cadence and A/V pacing idle, not work time.** Transport is *not* the direct-play blocker.

**Direct-play 480p — UNRESOLVED, and the blocker is ARM decode, not transport.** Transport budget: `41.67 − 2.0 sleeps − ~5.0 copy ≈ **34.7 ms/f** available for read+decode. The only decode data point is **`13.245 ms/f`, measured on the x86-64 host**, *not* on the DE10-Nano's dual-core **ARM Cortex-A9 @ 800 MHz**. H.264 decode is SIMD- and memory-bandwidth-bound, where the A9 (NEON, small cache, low bandwidth) is plausibly **5–10× slower** than a modern x86 core — at 5× the figure becomes **~66 ms/f, which blows the 34.7 ms budget outright**. **Do not quote a "~21 ms/f margin" without this qualification**; it may be wrong by more than the entire budget. A single *measured ARM* number would settle this and is worth more than any scaling argument. If direct-play proves unachievable on the ARM, that is clean supporting evidence for moving decode into the FPGA.

**Library limitation:** the PMS library contains only sync/blip test clips plus this one animated series — no live-action/film-grain title, so the hardest luma case is still untested.

**Verification gap to keep visible:** `test_pms_baseline_profile`'s **live** PMS check is `SKIP-NOT-PASS` in `make unit` (needs `PLEX_BASE`/`PLEX_TOKEN`/`MISTERPLEX_BASELINE_KEY`); only the synthetic green+red proofs run. Since FPGA decode requires **Baseline/CAVLC/ref=1/no-B**, the real delivered profile is **unverified here**. Do not read `make unit` exit 0 as proof PMS is delivering a Baseline stream.

**Lab note:** the `docker` "remote build farm" SSH alias resolves to **localhost** (`~/.ssh/config` → `HostName localhost`; `ssh docker hostname` = `node-worker1` = local host). The farm is this machine. Consequence: `test_resource_preflight.sh` sees the fit's own `quartus_fit` processes and refuses `make unit`. **Fits and unit tests must be serialized** — do not defeat the preflight; Verilator under memory pressure returns *wrong answers* that impersonate real decode bugs.

## Gate: all green before “complete”
- [x] **Product present / tear-free HDMI+VGA** — **DONE** git **`588e528`** RBF **`1441d409`**; vsync page-flip + DMA hold-off; holdoff2 half/mid/multi **0.00/s**; user eyes-on OK 2026-07-25. Docs: `MILESTONE_VSYNC_PRESENT.md`. **≠ residual hard PASS ≠ WIDE PASS.**
- [x] **Product A/V cast (Plex Web → MiSTerPlex)** — **DONE** `PRESENT=fpga` `STREAM=0` wall-48k; blip24 median **~−13 ms**; pfps≈vfps. Evidence `captures/e2e/REPORT*.md` + blip24.
- [x] `make unit` — **GREEN** (**C-unit28 PASS** + **C-unit27 PASS** + **C-unit-sf2 PASS** + **C-unit26 PASS** reconfirm + **C-unit25/24/23/22/21/20/19/18/17** + **C-unit16/15/14**): EXIT=0; host golden res_csum=**0x14**; res_dc=-24; y00=73 mean=62; companion OK; parse self-test OK. **HOST GREEN ≠ lab hard residual PASS.** Soft-skip ≠ PASS. Reports `/tmp/misterplex-agent-C-unit28.txt`, `/tmp/misterplex-agent-C-unit27.txt`, `/tmp/misterplex-agent-C-unit-sf2.txt`, `/tmp/misterplex-agent-C-unit26.txt` … `/tmp/misterplex-agent-C-unit14.txt`
- [~] HW residual hard gate — **IN_PROGRESS / PENDING H-gate-rcsum6** on lab LOADED **`94bbfe43`** (BUILD_OK+DEPLOY done; **do not invent hard PASS**). Historical FAIL **`ec21e133`** + **`8832824e`**. Soft-skip ≠ hard PASS. **3l2 BLOCKED** until product sticky 0x14. **BUILD_OK + DEPLOY ≠ product hard residual PASS.** (Product present path uses **`1441d409`** separately.)
- [x] FBAR visual PASS — **DONE** on lab **`ec21e133`** (**H-fbar-ec21b** / **W-wide-gate-sf2** / **H-gate-sf2** / **H-gate-ec21** 7.0/82.9/94.4) and prior residual **`8832824e`** / **`75da8bb1`** / **`4d6ee356`**. **FBAR soft ≠ hard residual PASS ≠ WIDE product PASS.**
- [ ] Full-width VGA verified (HBlank@320) — **FAIL open** historical **`ec21e133`** (**W-wide-gate-sf2b** span=**0.605** **PILLAR_320_of_529**; **W-wide-gate-sf2** / **H-gate-sf2** same). Fix-2 BUILD_OK+DEPLOY+FBAR but **WIDTH FAIL** — **WIDE still FAIL open Fix-2**. **do not invent WIDE PASS / Fix-3 PASS**. **W-fix3-hold2 FIT_GO=NO**; exclusive FREE.
- [~] DDR F1 ≥30 fps — **HISTORICAL PASS / CURRENT SILICON UNSUBSTANTIATED**: B-ddr7 on LOADED **`ec21e133`** measured mean **16.5 ms** (~60.6 fps) (`/tmp/misterplex-agent-B-ddr7.txt`); prior B-ddr6 dabdaeb0 same class. Current live evidence on `eeff4eee` shows valid YUV420P `PLXK` but all-zero `PLXF` and `has_frame=0`; do not cite historical DDR PASS as proof that the current DDR frame-store/present path runs on-device.
- [x] `make package` — **PACKAGE_OK** embeds **`94bbfe43`** (**F-prep-rcsum6** `/tmp/misterplex-agent-F-prep-rcsum6.txt`). Prior **ec21e133** / **8832824e** packages historical. Product tear RBF also in `releases/Plex_vsync_tear_1441d409.rbf`. Package ≠ WIDE PASS.
- [x] misterplexd soak — **D-soak3/4/5 PASS** ok=6 (re-soak optional after next RBF)
- [x] Safe deploy only — **H-deploy-rcsum6 PROMOTE_OK|DEPLOY_OK** lab **LOADED `94bbfe43`** ONE menu (`/tmp/misterplex-agent-H-deploy-rcsum6.txt`). Prior **H-deploy-qsf2** **`ec21e133`** / **H-deploy-rcsum5** **`8832824e`**. Product present deploy **`1441d409`**. **Do not thrash-redeploy `8832824e`/`75da8bb1`/`4d6ee356` or second-menu `94bbfe43`.** Residual hard **PASS** via **H-gate-rcsum6** (separate).

## Phase 3 (decode / present)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P3-PRESENT | VSync page-flip + DMA hold-off (tear-free present) | **DONE** | git **`588e528`** RBF **`1441d409`**; holdoff2 0.00/s tears; user eyes-on OK. See `MILESTONE_VSYNC_PRESENT.md`. |
| P3-AVCAST | Product cast STREAM=0 + wall-48k A/V | **DONE** | blip24 ~−13 ms; Plex Web → MiSTerPlex HDMI/VGA. |
| P3-FBAR | Force bars O[9] visual = bars when pattern=grid | **DONE** (on ec21e133 + 8832824e + 75da8bb1 + 4d6ee356 + 4deaf6cc + dabdaeb0) | **H-fbar-ec21b / W-wide-gate-sf2 / H-gate-sf2 / H-gate-ec21 FBAR soft PASS** on **`ec21e133`**. Parked force bars. **FBAR ≠ hard residual PASS ≠ WIDE product PASS.** |
| P3-WIDE | Full-width DE HBlank@320 | **PARTIAL / FAIL open; WIDE still FAIL open Fix-2; Fix-3 HOLD FIT_GO=NO** | **W-wide-gate-sf2b WIDE FAIL** span=**0.605** **PILLAR_320_of_529** historical **`ec21e133`**; Fix-2 still WIDTH FAIL. **W-fix3-hold2 HOLD_OK FIT_GO=NO**. Exclusive FREE. **do not invent WIDE PASS / Fix-3 BUILD_OK**. |
| P3-DDR | DDR F1 kick reliable in product path | **HISTORICAL PASS / CURRENT UNSUBSTANTIATED** | Historical product **`1441d409`** / **B-ddr7** on **`ec21e133`** reported every-frame F1 / mean **16.5 ms**. Current silicon (`eeff4eee`, source-proven `b5c50c6`) accepts a YUV420P `PLXK` but leaves `PLXF=0/0` and `has_frame=0`; simulation reads `MAGIC_F=0x504c5846`. Reconfirm after fitting current post-`d803e4c`/`86558c4`/`97beb1d` source before marking current DDR present on-device green. |
| P3-3l0 | Host quant/IDCT golden | DONE | `2e2c2dc` |
| P3-3l1 | FPGA full 16 coeffs | **PARTIAL — R-csum6 BUILD_OK+DEPLOY lab `94bbfe43`; H-gate-rcsum6 IN_PROGRESS/PENDING (do not invent hard PASS); historical HARD_FAIL `ec21e133`+`8832824e`** | Host goldens 0x14 (**C-unit28 / C-unit27**). Lab **LOADED `94bbfe43`**. Soft-skip ≠ PASS. **3l2 BLOCKED** until sticky 0x14. Claim **c7a847f7/ca62d02b/904e9b2e** LOCK_OK. **BUILD_OK+DEPLOY ≠ residual PASS**. |
| P3-3l2 | Inv quant + IDCT first 4×4 | **EVIDENCE-BACKED MB0 + NATIVE INTRA GREEN** | W-REL: `h264_iq_idct_4x4.sv` + `test_p3_idct_reference_model`; MB0/block0 handoff is evidence-backed (`y00=73`, mean=62, coeff_csum=0x14; native-I420 scoreboard confirms `got=73 ref=73 abs=0`). W-CABAC native scorer now proves no-deblock intra frame exactness with loop-filter provenance: 624×480 `1170/1170`, 320×240 `300/300`, wcap fixture `300/300`, all MAE 0. |
| P3-3l3 | First full MB recon | **EVIDENCE-BACKED HOST FIXTURE / FPGA BLOCKED** | W-REL: checked-in `tests/fixtures/p3_host_recon/mb0_luma_v1.json` gives MB0 luma pred/dequant/post-IDCT/recon for RTL; source vector is fixed 6739 B. This supports MB0/first-MB handoff only; it is not a frame-wide product pass. |
| P3-3l4 | All MBs / frame mae | **NATIVE-I420 INTRA GREEN / INTER RED** | Retired claim 1: `tests/fixtures/p3_host_recon/frame_mae_v1.csv` / `test_p3_host_recon_vectors` reported `vector_bytes=6739 mb=300/300 frame=320x240 maeY=0.000000`, but that path was RGB565/presentation-contaminated. Retired claim 2: native-I420 ratchets reporting 624×480 `510/1170`, 320×240 `155/300`, and wcap `207/300` used a deblocked reference while RTL output was no-deblock. Current no-deblock native-I420 scorer is green for intra (`1170/1170`, `300/300`, `300/300`, MAE 0) and still expected-red for P frames until full inter reconstruction is wired. |
| P3-3l5 | Hybrid gate product | TODO | |
| P3-3m | Inter prediction scope + host goldens | **BASELINE MODEL DONE / PMS BASELINE FAILS** | W-REL: `docs/phase3-inter-prediction.md`; checked-in P16×16-only Baseline vector `plex_inter_p16_baseline_320x240_12f.264` (27653 B, md5 `fe5ba815…`), `pframe1_mb_v1.json`, `frame_mae_v1.csv`, and `test_p3_inter_pred_vectors` in `make unit`. Baseline Level 3.0 would make scope tractable: P/CAVLC only, no B/CABAC/weighted/interlace; Level 3.0 DPB max at 640x480 is 6 refs = 2.76 MB YUV420. **But W-A4 delivered-stream probe says PMS ignored Baseline request:** branch `feat/a4-sps-baseline` @ `b28e863` requested Baseline/L3.0 (`640x480`, 2500 kbps) but delivered High `profile_idc=100`, CABAC PPS, B-slices (`i=22 p=165 b=115` in 12s), 618×480, ~1344.3 kbps; mpegts target works, final mp4 target returned empty. Product must fail closed/fallback on B/CABAC/non-Baseline; unit now includes a generated High/CABAC/B unsupported probe. DDR3/YUV420 reference store required for any FPGA inter path; BRAM/SDRAM not viable. |
| P3-3n | Real PMS High/CABAC/B decoder sizing | **SCOPE DONE / A NOT SANE NEAR-TERM** | W-REL: `docs/phase3-high-cabac-scope.md` and `test_p3_high_cabac_scope.py` in `make unit`. Final W-A4 sweep says client-only Baseline forcing is impossible: delivered coded 624×480/display 618×480, 1170 macroblocks, 25 fps, High/CABAC/B, 4 refs. CABAC planning demand **8.775 Mbin/s** (300 bins/macroblock), stress **17.550 Mbin/s**. Current `clk_sys`/DDRAM path is 20 MHz, so 1 bin/cycle barely covers stress, 2 cycles/bin fails stress, 3 cycles/bin fails planning. 4 refs + current YUV420 = 2.25 MB; +present/reorder = 2.70 MB; DDR3 required, SDRAM/BRAM not viable. Existing 4×4 IQ/IDCT/recon survives below entropy, but CAVLC walker does not; High may require 8×8 transform detection/support. Verdict: decoding PMS as sent is a full High-profile decoder project; server-side Baseline XML or ARM/FFmpeg fallback is a hard requirement for a sane FPGA-offload path. |
| P3-3p | P-slice inter prediction / motion compensation | **PRODUCT DPB/MC + DEBLOCK SEAM LIVENESS GREEN / NATIVE INTER QUALITY RED** | W-REL: `docs/phase3-inter-rtl.md`; product RTL `h264_inter_pred.sv`, `h264_p_slice_modes.sv`, `h264_dpb.sv`, and `h264_deblock_writeback_ctrl` are in the stream-path liveness build. DPB budget closes at 987 B/MB = 1,154,790 B/frame = 28.87 MB/s at 25fps; DDR first, SDRAM escape hatch. `test_p3_dpb_mc_rtl_sim.sh` proves filtered I420 writeback, frame-boundary promotion, IDR invalidation, clamped 21x21/9x9 fetch, 16x16 MC, and partition masks for 16x8/8x16/8x8/8x4/4x8/4x4; red-checks clamp, MC arithmetic, early ref publication, and partition mask. `test_p3_inter_rtl_sim.sh` compares real RTL against `inter_mc_v1.json` (`mv_cases=6`, `partition_cases=10`, `frame_mv_cases=9090`) and red-checks bad interpolation rounding plus bad partition MV. `test_h264_p_slice_modes_rtl_sim.sh` covers P_Skip, P_L0_16x16, P_L0_16x8, P_L0_8x16, P_8x8/P_8x8ref0, sub-MB 8x8/8x4/4x4, intra-in-P and unsupported mode classification; red-check swaps 16x8 and fails. `slice_hdr_parser.sv` handles non-IDR ref-marking/ref-idx bits before QP and parses P `mb_skip_run` + first P MB type; shared multi-NAL raw `nalu=15 slice=11 idle_between_vcl=1 recon_sig_3b_cycles=39780 p_first_mb_seen=11 p_first_modes=8/2/1 p_first_bad=0`, with forced-`recon_sig=0` red-check. `decode_stub` routes IDR invalidation and reference promotion through product `h264_deblock_writeback_ctrl` (`filtered_sample_valid` before `filtered_mb_valid`, terminal commit then `frame_boundary`, `ref_ready_pulse` → DPB `frame_done`). `test_stream_path_full_frame_compare.sh` now emits both the old refused RGB565 diagnostic candidate and a native-I420 DPB/MC candidate with inter MB metadata; current 320×240 score is `intra=0/300 inter=0/3300`, first_bad_inter frame 1 MB0 Y `got=32 ref=80 abs=48`, `mb_type=P_L0_16x16`, `mv_l0=(0,0)`; 624×480 scorer self-check is `intra=0/1170 inter=0/12870`, first_bad_inter `got=32 ref=77 abs=45`; both use a declared diagnostic filtered reference state. Full native-I420 inter reconstruction, real decoded/deblocked reference pictures, parsed MV deltas, residual add, and all-P-MB traversal remain open. |
| P3-3q | In-loop deblocking | **NORMATIVE EDGE BLOCKS + MULTI-NAL GATE DONE / FRAME SCHEDULER PENDING** | W-A3: `h264_deblock.sv` covers bS derivation (intra, residual, ref/MV, idc=1/2 controls), alpha/beta/tC0 indexing with slice offsets/clipping, luma/chroma edge rules, and a registered edge pipe. `test_p3_deblock_rtl_sim.sh` now sources the ≥2-VCL `wcap_residual14_idr_plus_p` fixture rather than a single-NAL stream and red-checks edge order drift. `test_stream_path_deblock_integration.sh` proves multi-NAL parser handoff, stream QP/deblock controls, chroma bS4 short filtering, picture-boundary preservation, and that filtered samples feed the next reference value; red-checks trip for bS, threshold offsets, chroma-vs-luma behavior, picture boundaries, in-loop reference use, and slice controls. Full frame deblock scheduling/writeback to the DPB/reference store remains the consumer integration step with W-A4/W-REL. |


| P3-SPI | SPI F1 only ~9fps — retired; product F1 is DDR YUV420p-only | DONE | |

## Phase 4 (UX)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P4-SCRUB | Scrubber/playqueue edge cases | **DONE** | G-p4-dirty `ade6915`; C-unit14..21 reconfirm |
| P4-HZ | Match-source-Hz modeline (docs only OK) | DEFER | |
| P4-SUB | Subtitles burn-in plan | DEFER | |

## Phase 5 (release / lab)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P5-PKG | Package release tarball | **DONE for 94bbfe43 embed** | **F-prep-rcsum6 PACKAGE_OK** embeds **`94bbfe43`** (`/tmp/misterplex-agent-F-prep-rcsum6.txt`). Prior **ec21e133**/**8832824e** historical. Ship still blocked on **WIDE**. Package ≠ WIDE PASS. |
| P5-SOAK | WiFi soak multi-round | **DONE** | D-soak3/4/5 ok=6; optional re-soak after next RBF |
| P5-ETH | Eth vs wifi numbers | BLOCKED | no eth lab path |
| P5-CRT | CRT matrix checklist | **PARTIAL** | Physical CRT PENDING |

## RBF inventory (agent-J-backlog66: no Quartus; no deploy; no RTL thrash; evidence-only; R-csum6 BUILD_OK harvest)
| Path | md5 (prefix) | Notes |
|------|--------------|-------|
| `fpga/Plex_MiSTer/output_files/Plex.rbf` | **`94bbfe43`** | **R-csum6 NEW_RBF** full `94bbfe433feb562fabe0798e16b378c5` size **3506356**; BUILD_OK wall **438s** exit **0**; claim **c7a847f7/ca62d02b/904e9b2e** DIAG=ABSENT Rank1+2+3; ∉ ban |
| `misterfpga-dev/out/Plex_MiSTer/Plex.rbf` | **`94bbfe43`** | R-csum6 collect match output |
| `fpga/Plex_MiSTer/releases/Plex.rbf` | **`94bbfe43`** | R-csum6 promote MATCH full `94bbfe433feb562fabe0798e16b378c5` |
| `releases/Plex.rbf` (repo root) | **`94bbfe43`** | **PROMOTE_OK** H-deploy-rcsum6; MATCH lab LOADED |
| `releases/Plex_qsf2_ec21e133.rbf` | **`ec21e133`** | H-deploy sidecar copy-only |
| `releases/Plex_sf2_wide_ec21e133.rbf` | **`ec21e133`** | F-prep named snapshot |
| `dist/stage-misterplex/cores/Plex.rbf` | **`ec21e133`** | F-prep-qsf2 PACKAGE_OK stage embed |
| `dist/misterplex-3c43a66-dirty.tar.gz` (F-prep-qsf2) | embeds **`ec21e133`** | **PACKAGE_OK** ≠ product/WIDE PASS |
| Lab `/media/fat/_Utility/Plex.rbf` | **`94bbfe43`** | **LOADED** after **H-deploy-rcsum6 ONE menu** full `94bbfe433feb562fabe0798e16b378c5` CORENAME=Plex; cite user log + lab txt + `/tmp/misterplex-agent-H-deploy-rcsum6.txt`; **H-gate-rcsum6 IN_PROGRESS/PENDING** — do not invent hard PASS; prior **`ec21e133`** WIDE FAIL 0.605 historical open |
| Prior residual host/lab RBF (R-csum5; path superseded on lab) | **`8832824e`** | **BUILD_OK** + **DEPLOY_OK** + **H-gate-rcsum5d HARD_FAIL** MULTI_DRIVE; thrash **forbidden**; residual CLOSED FAIL historical |
| `releases/Plex_rcsum5_8832824e.rbf` | **`8832824e`** | local archive copy-only (R-csum5-build) |
| Prior host/lab RBF (R-csum4; path superseded) | **`75da8bb1`** | **BUILD_OK** + **DEPLOY_OK** + **H-gate HARD_FAIL**; thrash forbidden |
| Prior host/lab RBF (R-csum3b; path superseded) | **`4d6ee356`** | historical **HARD_FAIL** +0x53; **thrash forbidden** |
| Prior host/lab RBF (R-csum2) | **`4deaf6cc`** | superseded; PACK_FAIL stream24 |
| R-csum2 fit-start claim SRC | Plex **`9b97b792`** + slice **`eec44561`** | DIAG force-0x14 + multi-cycle |
| **R-csum3 claim @ fit start (historical; dead)** | Plex **`eb6b8541`** + slice **`6ce28d6e`** | **FIT_DEAD_MID**; not BUILD_OK |
| **R-csum3b freeze @ fit start (BUILD_OK product; HARD_FAIL lab; path superseded)** | Plex **`ce1ef26c`** + slice **`e45f98c4`** | **LOCK_OK**; DIAG ABSENT; failed product hard csum |
| **R-csum4 freeze @ claim (BUILD_OK; gate HARD_FAIL; DRIFT caveat)** | Plex **`94db41b7`** + slice **`9a2d10c5`** | DIAG PRESENT at claim; mid-fit **DRIFT_CRITICAL**; **PROVENANCE_UNTRUSTED**; silicon never sticky 0x14 |
| **R-csum5 claim@launch (BUILD_OK sole; product sticky map-era)** | Plex **`6422fb9a`** + slice **`8e6af3bb`** | sticky_pack PRESENT; **DIAG=ABSENT** product csum_acc; lock **13:31:58**; map-era class per midfit-rcsum5b; **PROVENANCE_UNTRUSTED** vs thrash |
| **R-csum5 live WT + claim overwrite mid-fit (DRIFT_CRITICAL)** | Plex **`6a5dcaaa`** + slice **`7d4a1d8b`** | DIAG PRESENT `residual_csum<=8'h14`; claim rewrite ~13:33:19 SUPERSEDES launch product; live matches overwrite; **PROVENANCE_UNTRUSTED**; map netlist ≠ this class |
| **Q-SF2 claim SRC_colorbars (wide Fix-2 BUILD_OK)** | colorbars **`f1d9666a`** full `f1d9666ada5347dbde7e7246bad345c8` | W-sf2-midfit **DRIFT: NO**; Fix-2 paint-full-DE; silicon still WIDTH FAIL 0.605 |
| **R-csum6 claim@fit (BUILD_OK+LOCK_OK wall 438s)** | Plex **`c7a847f7`** + slice **`ca62d02b`** + stream **`904e9b2e`** fulls `c7a847f743bace1e0df48f2d0571f513` / `ca62d02b7188f4dd9be5109dc4f2dd64` / `904e9b2ea3bc6f560cb10c65796f9fbc` | **FIT_GO=YES** Rank1+2+3 **DIAG=ABSENT**; live==claim **MATCH** **SRC_DRIFT: NO** **LOCK_OK**; lock **DONE BUILD_OK** NEW_RBF **`94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5` wall **438s**; mon **BUILD_OK**; **H-deploy ONE menu lab LOADED `94bbfe43`**; exclusive **FREE**; **H-gate-rcsum6 PENDING** — **BUILD_OK+DEPLOY ≠ residual PASS** |
| Prior lab FAIL baseline | **`dabdaeb0`** | Superseded |
| Prior tarballs | `820484a6` / `aa146c17` / `6db3a4d8` / F-prep-rcsum2/3b/4/5 era | Superseded by **ec21e133** package (F-prep-qsf2) |

### Quartus status (2026-07-24; **R-csum6 BUILD_OK DONE** NEW **`94bbfe43`** wall **438s** LOCK_OK; lab LOADED **`94bbfe43`**; exclusive **FREE**; H-gate PENDING; WIDE FAIL open Fix-2 — **J-backlog66**)
| Build | Log | Result |
|-------|-----|--------|
| Clean FBAR | `/tmp/plex_quartus_fbar_clean.log` | **BUILD_OK**; RBF `6db3a4d8` |
| **Q-3l1** | `/tmp/plex_quartus_3l1.log` | **BUILD_OK** → `aa146c17` (superseded) |
| Q-3l1b | (not started) | **ABORT** busy |
| **Q-SF1** | `/tmp/plex_quartus_sf1.log` | **BUILD_OK** → `820484a6` (superseded) |
| **R-csum1** | `/tmp/plex_quartus_rcsum1.log` | **BUILD_OK** → **`dabdaeb0`**; superseded |
| **R-csum2** | `/tmp/plex_quartus_rcsum2.log` | **BUILD_OK** → **`4deaf6cc`**; hard csum FAIL. Superseded. |
| **R-csum3** | **`/tmp/plex_quartus_rcsum3.log`** | **FIT_DEAD_MID** — **NOT BUILD_OK.** |
| **R-csum3b** | **`/tmp/plex_quartus_rcsum3b.log`** | **BUILD_OK** → **`4d6ee356`**. H-gate hard **HARD_FAIL**. Thrash forbidden. |
| **R-csum4** | **`/tmp/plex_quartus_rcsum4.log`** | **BUILD_OK ~13:22** → **`75da8bb1`** wall **421s**. **H-gate HARD_FAIL** MULTI_DRIVE; thrash forbidden. |
| **R-csum5** (residual serial **CLOSED FAIL** historical) | **`/tmp/plex_quartus_rcsum5.log`** | **BUILD_OK** wall **441s** → **`8832824e`**; **DEPLOY_OK**+**PACKAGE_OK**; **H-gate-rcsum5d HARD_FAIL** sticky0x14=0 +0x53 **16/69/bc/0f/62/b5/08**; res_dc PASS; **PROVENANCE_UNTRUSTED**; thrash **`8832824e` FORBIDDEN**. |
| **Q-SF2** (wide Fix-2 sole — **DONE**) | **`/tmp/plex_quartus_sf2.log`** | **BUILD_OK DONE** END **13:52:56**; Full Comp **0e/38w** wall **415s** exit **0**; NEW_RBF **`ec21e133`** full `ec21e1330ddd75ad7f39099e5abfad49`; mon **M-fitmon-qsf2d/qsf2b BUILD_OK**; lock was **DONE BUILD_OK** (H-deploy harvest) — **superseded by R-csum6 DONE BUILD_OK**. **H-deploy PROMOTE_OK \| ALREADY_DEPLOYED**; **F-prep-qsf2/sf2 PACKAGE_OK**; **W-wide-gate-sf2 WIDE FAIL** span=0.605 pillar; **H-gate-ec21 residual HARD_FAIL** on same RBF. **≠ residual PASS ≠ WIDE product PASS.** |
| **R-csum6** (residual multi-drive Rank1+2+3 product sticky — **DONE BUILD_OK + DEPLOY**) | **`/tmp/plex_quartus_rcsum6.log`** | **BUILD_OK DONE** END **14:10:09**; Full Comp **0e/40w** wall **438s** exit **0**; NEW_RBF **`94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5` size **3506356**; claim Rank1+2+3 **DIAG=ABSENT** **`c7a847f7`/`ca62d02b`/`904e9b2e`** **LOCK_OK** SRC_DRIFT **NO**; mon **M-fitmon-rcsum6 BUILD_OK**; lock **DONE BUILD_OK 14:10:26**; exclusive **FREE**. **H-deploy-rcsum6 ONE menu** lab **LOADED `94bbfe43`**; **H-gate-rcsum6 IN_PROGRESS/PENDING** — do **not** invent hard residual PASS. |

- Action this agent (**J-backlog66**): **refresh backlog only** (no Quartus; no lab thrash; no RTL) — **REFRESH_DONE**; cite **R-csum6 BUILD_OK** Full Comp **0e/40w** wall **438s** NEW_RBF **`94bbfe43`** LOCK_OK + **H-deploy ONE menu lab LOADED `94bbfe43`** (`/tmp/misterplex-H-deploy-rcsum6-user.log` + lab txt + agent report) + exclusive **FREE** + **H-gate-rcsum6 IN_PROGRESS/PENDING** (do not invent hard PASS) + **WIDE still FAIL open Fix-2** + **C-unit28/27 PASS** host + **3l2 BLOCKED** until sticky 0x14
- Sequence:
  1. ~~R-csum1 BUILD_OK + collect dabdaeb0~~ — **DONE**
  2. ~~Sole menu deploy dabdaeb0 + FBAR~~ — **DONE** H-deploy; hard csum **FAIL**
  3. ~~Postfail + rtl2 multi-cycle + diagrtl~~ — **DONE dirty**
  4. ~~**R-csum2 sole fit BUILD_OK**~~ — **DONE** → **`4deaf6cc`**
  5. ~~**Promote `4deaf6cc`**~~ — **DONE**
  6. ~~**One sole menu deploy `4deaf6cc` + FBAR + hard csum**~~ — **DONE deploy/FBAR PASS**; **hard csum FAIL**
  7. ~~**F-prep-rcsum2 package embeds 4deaf6cc`**~~ — **DONE PASS** (superseded)
  8. ~~**C-unit16..19 unit green**~~ — **DONE PASS**
  9. ~~**Pack-path RCA + R-csum-rtl3 dirty fix + LOCK_OK @ claim**~~ — **DONE**
  10. ~~**R-csum3 sole**~~ — **FIT_DEAD_MID** — **NOT BUILD_OK**
  10b. ~~**Mid-fit WT drift audit (R-csum3)**~~ — **DONE** → R-csum3b freeze
  11. ~~**R-csum3b sole fit BUILD_OK**~~ — **DONE** → **`4d6ee356`**
  11b. ~~**Promote + ONE menu (H-deploy-rcsum3b)**~~ — **DONE**
  11c. ~~**F-prep-rcsum3b package embeds 4d6ee356**~~ — **DONE** (superseded)
  11d..11d3. ~~**H-gate-rcsum3b / 3b2 / 3b3**~~ — **DONE HARD_FAIL** +0x53; thrash forbidden
  11e. ~~**C-unit21..27 unit green**~~ — **DONE PASS** (**C-unit27** host; ≠ lab PASS)
  11f. ~~**A-csum-probe7**~~ — **DONE HOST_PROBE_OK**
  11g. ~~**A-csum-map1 / map2**~~ — **DONE MAP_OK**
  11h. ~~Stale **R-csum-rtl4.txt @12:34**~~ — **ignore for FIT_GO**
  11i. ~~**L-csum-note21 DIAG pack bisect docs**~~ — **DONE**
  12. ~~**`R-csum-rtl4c` FIT_GO**~~ — **DONE** DIAG sticky 0x14; freeze **`94db41b7`/`9a2d10c5`**
  12b. ~~**`R-csum4` sole DIAG compile**~~ — **BUILD_OK ~13:22** → **`75da8bb1`** — **DRIFT / PROVENANCE_UNTRUSTED**
  12c. ~~**H-deploy-rcsum4 promote + ONE menu**~~ — **DONE** lab was LOADED (now superseded)
  12d. ~~**F-prep-rcsum4 package embeds 75da8bb1**~~ — **DONE PACKAGE_OK** (historical)
  12e. ~~**H-gate-rcsum4**~~ — **DONE HARD_FAIL** NOT PACK_PROVEN MULTI_DRIVE
  12e2. ~~**H-gate-rcsum4b reconfirm (no redeploy)**~~ — **DONE HARD_FAIL** +0x53 0x85→0xd8→0x2b
  12f. ~~**R-csum-rtl5** sticky pack product FIT_GO~~ — **DONE** claim **`6422fb9a`/`8e6af3bb`** DIAG=ABSENT
  12g. ~~**R-csum5 sole**~~ — **DONE BUILD_OK** lock **13:40:35** CDT; Full Comp **0e/37w** wall **441s** exit **0**; NEW_RBF **`8832824e`**; mid-fit **DRIFT_CRITICAL** launch **`6422fb9a`/`8e6af3bb`** → live/claim **`6a5dcaaa`/`7d4a1d8b`** DIAG PRESENT; map-era product sticky (**midfit-rcsum5b**); **PROVENANCE_UNTRUSTED**
  12h. ~~**H-deploy-rcsum5 ONE menu**~~ — **DONE DEPLOY_OK** lab was **LOADED `8832824e`** (path superseded)
  12i. ~~**PACKAGE_OK embed `8832824e`**~~ — **DONE** (superseded by F-prep-qsf2)
  12j. ~~**H-gate-rcsum5 / 5b / 5c / 5d**~~ — **DONE HARD_FAIL** residual serial **CLOSED FAIL** MULTI_DRIVE sticky0x14=0 +0x53 **16/69/bc/0f/62/b5/08**; res_dc PASS; FBAR soft; **NOT PACK_PROVEN**; thrash **`8832824e` forbidden** (**H-gate-rcsum5d** definitive)
  12k. ~~**Q-SF2 sole wide Fix-2 BUILD_OK**~~ — **DONE** END **13:52:56**; Full Comp **0e/38w** wall **415s** exit **0**; NEW_RBF **`ec21e133`**; mon M-fitmon-qsf2d/b **BUILD_OK**; lock was **DONE BUILD_OK** (superseded by R-csum6 DONE BUILD_OK)
  12l. ~~**H-deploy-qsf2 PROMOTE_OK | ALREADY_DEPLOYED**~~ — **DONE** lab was **`ec21e133`** (superseded by **`94bbfe43`**)
  12m. ~~**F-prep-qsf2 / F-prep-sf2 PACKAGE_OK embed `ec21e133`**~~ — **DONE** ≠ product/WIDE PASS
  12n. ~~**W-wide-gate-sf2 + H-gate-sf2 FBAR + WIDTH**~~ — **DONE FBAR soft PASS; WIDE/WIDTH FAIL** span=**0.605** pillar — **WIDE open**
  12o. ~~**H-gate-ec21 / H-res-ec21 residual hard on `ec21e133`**~~ — **DONE HARD_FAIL** sticky0x14=0 +0x53 **08/5b/ae/01**; res_dc PASS — residual **FAIL open on current lab**
  12p. ~~**C-unit-sf2 / C-unit27 / C-unit28 host unit**~~ — **DONE PASS** host ≠ lab residual PASS (**C-unit28** `/tmp/misterplex-agent-C-unit28.txt`)
  12p2. ~~**A-csum-host28 HOST_GOLDEN_OK**~~ — **DONE** host 0x14/−24 ≠ lab PASS
  12q. ~~**H-fbar-ec21b FBAR soft reconfirm**~~ — **DONE PASS** 7.0/82.9/94.4
  12r. ~~**W-wide-rca-sf2 + W-sf3-plan**~~ — **DONE** FIX2_INEFFECTIVE 0.605; Fix-3 READY; **FIT_GO_WIDE=NO** until residual hard path / parent Q-SF3 pick (exclusive FREE post BUILD_OK)
  13. ~~**R-csum6 sole**~~ — **DONE TERMINAL BUILD_OK** lock **14:10:26** wall **438s** exit **0** Full Comp **0e/40w**; NEW_RBF **`94bbfe43`**; mon **M-fitmon-rcsum6c BUILD_OK**; claim **MATCH** Rank1+2+3 DIAG=ABSENT **c7a847f7/ca62d02b/904e9b2e** — **BUILD_OK ≠ residual hard PASS**
  14. ~~**ONE H-deploy-rcsum6**~~ — **DONE PROMOTE_OK|DEPLOY_OK** lab **`94bbfe43`** (`/tmp/misterplex-agent-H-deploy-rcsum6.txt`) ≠ hard residual PASS
  14b. **H-gate-rcsum6 hard residual on `94bbfe43`** — **IN_PROGRESS / PENDING** sticky0x14 ≥2 reject +0x53 res_dc=-24 — **do not invent hard PASS**
  15. **Wide Q-SF3 after residual serial / free** — WIDTH FAIL open on **`ec21e133`**; **W-fix3-hold2 FIT_GO=NO** — **do not invent WIDE PASS / Fix-3 BUILD_OK**
  16. Soft-skip ≠ PASS; G-fpga WAIT; thrash banned residual FORBIDDEN; **3l2 BLOCKED**
- Do **not** invent hard-csum PASS / WIDE PASS / Fix-3 PASS / 3l2 UNBLOCK; soft-skip ≠ PASS; **DIAG ≠ product PASS**; **BUILD_OK+DEPLOY+PKG+FBAR ≠ residual PASS ≠ WIDE product PASS**; **3l2 BLOCKED** until sticky 0x14; thrash **`8832824e`/`75da8bb1`/`4d6ee356` FORBIDDEN**; exclusive **FREE**; **H-gate-rcsum6 PENDING**; **WIDE still FAIL open Fix-2**

## Open (priority next workers)
1. ~~**R-csum6 sole LIVE**~~ — **DONE TERMINAL BUILD_OK** lock **`R-csum6 DONE BUILD_OK 2026-07-24T14:10:26-05:00 NEW_RBF=94bbfe433feb562fabe0798e16b378c5 wall=438s LOCK_OK`**; Full Comp **0e/40w** wall **438s** exit **0**; mon **M-fitmon-rcsum6c BUILD_OK**; claim **MATCH** Rank1+2+3 DIAG=ABSENT md5s **`c7a847f7`/`ca62d02b`/`904e9b2e`**; **SRC_DRIFT: NO**; exclusive **FREE** post-build — **BUILD_OK ≠ residual hard PASS**
2. ~~**ONE H-deploy-rcsum6**~~ — **DONE PROMOTE_OK|DEPLOY_OK** ONE menu lab **LOADED `94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5` (`/tmp/misterplex-agent-H-deploy-rcsum6.txt`) — **DEPLOY_OK ≠ hard residual PASS** — do **not** invent hard sticky0x14 PASS
3. **H-gate-rcsum6** hard residual on lab **`94bbfe43`** (sticky0x14 ≥2; reject +0x53; res_dc=-24) — **IN_PROGRESS / PENDING** — **do not invent hard PASS / PACK_PROVEN**. Prior **ec21e133** **H-gate-ec21 HARD_FAIL** MULTI_DRIVE; historical **CLOSED FAIL** **`8832824e`**
4. **P3-WIDE / Q-SF3 Fix-3** — **WIDE still FAIL open Fix-2** historical **`ec21e133`** span=**0.605** pillar (**W-wide-gate-fix2b**); Fix-2 **CLOSED ineffective**. **W-fix3-hold2 HOLD_OK FIT_GO=NO** — **do not invent WIDE PASS / Fix-3 BUILD_OK**
5. **3l2 BLOCKED** — until hard product sticky **0x14** on non-DIAG product RBF (**H-gate-rcsum6 PENDING** on **`94bbfe43`**); historical FAIL **`ec21e133`** + **`8832824e`**; soft-skip ≠ PASS; thrash residual banned set FORBIDDEN
6. ~~**Q-SF2 sole**~~ — **DONE BUILD_OK** NEW_RBF **`ec21e133`** (superseded on lab path by residual **`94bbfe43`** post H-deploy-rcsum6)
7. ~~**H-deploy-qsf2**~~ — **DONE PROMOTE_OK | ALREADY_DEPLOYED** lab **LOADED `ec21e133`**
8. ~~**F-prep-qsf2 / F-prep-sf2**~~ — **DONE PACKAGE_OK** embeds **`ec21e133`**
9. ~~**W-wide-gate-fix2b / sf2 / H-gate-sf2**~~ — **DONE FBAR soft PASS; WIDE FAIL** 0.605 open (Fix-2 ineffective)
10. ~~**H-gate-ec21 / H-res-ec21**~~ — **DONE residual HARD_FAIL** on **`ec21e133`** sticky0x14=0 +0x53 MULTI_DRIVE; res_dc PASS
11. ~~**R-multidrive-rca14 + H-proto-rcsum6 + L-csum-note37**~~ — **DONE**
12. ~~**H-fbar-ec21b**~~ — **DONE FBAR soft PASS** 7.0/82.9/94.4
13. ~~**C-unit28 / C-unit27**~~ — **DONE PASS** host ≠ lab residual PASS
14. ~~**W-fix3-hold / W-fix3-hold2**~~ — **DONE HOLD_OK** FIT_GO Q-SF3=**NO**
15. ~~**H-gate-rcsum5d**~~ — residual serial **CLOSED FAIL** historical on **`8832824e`**
16. **P3-3l1 HW residual hard** — **H-gate-rcsum6 IN_PROGRESS / PENDING** on lab **`94bbfe43`**; historical FAIL **`ec21e133`** — **do not invent hard PASS**
17. **P3-3l2..3l5** — **3l2 BLOCKED** until hard csum sticky **0x14** on non-DIAG product; soft-skip ≠ PASS; **BUILD_OK+DEPLOY ≠ hard PASS**
18. **P5-CRT** — PARTIAL physical open
19. ~~**P5-PKG**~~ — **DONE** embeds **`94bbfe43`** (F-prep-rcsum6); prior ec21e133 historical
20. ~~**make unit C-unit14..28 + C-unit-sf2**~~ — DONE PASS host ≠ lab residual PASS
21. ~~**J-backlog16..65**~~ — DONE prior; this is **J-backlog66 REFRESH_DONE**
22. **G-fpga** — **WAIT** (no FPGA commit of thrash/DIAG; after hard green + intentional product SRC@fit match LOCK_OK)
23. ~~**R-csum6-midfit***~~ — **DONE** mid-fit DRIFT_OK / SRC_DRIFT NO through terminal

## Non-RBF always available
- (done **C-unit14..28 + C-unit-sf2**) unit GREEN host 0x14 — **C-unit28 PASS** (`/tmp/misterplex-agent-C-unit28.txt`) + **C-unit27 PASS** + **C-unit-sf2 PASS** + **C-unit26 PASS**; **host GREEN ≠ lab hard residual PASS**; soft-skip ≠ PASS
- (done **B-ddr7 optional**) DDR F1 on LOADED **`ec21e133`** mean **16.5 ms** PASS (`/tmp/misterplex-agent-B-ddr7.txt`) — DDR ≠ residual/WIDE PASS
- (done **Q-SF2 BUILD_OK**) Full Comp 0e/38w wall 415s exit 0; NEW_RBF **`ec21e133`**; mon M-fitmon-qsf2d/b; lock was DONE — then R-csum6 **TERMINAL BUILD_OK** NEW **`94bbfe43`**; exclusive FREE post-build
- (done **H-deploy-qsf2**) **PROMOTE_OK | ALREADY_DEPLOYED** lab was **`ec21e133`** (superseded by **`94bbfe43`**)
- (done **H-deploy-rcsum6 ONE menu**) **PROMOTE_OK | DEPLOY_OK** lab **LOADED `94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5` (`/tmp/misterplex-agent-H-deploy-rcsum6.txt` + user log + lab txt) — **DEPLOY ≠ hard residual PASS**
- (in progress **H-gate-rcsum6**) hard residual on **`94bbfe43`** — **do not invent hard PASS**
- (done **F-prep-qsf2 / F-prep-sf2 PACKAGE_OK**) embeds **`ec21e133`** ≠ product/WIDE PASS; prior residual package **`8832824e`** / F-prep-rcsum4 **75da8bb1** historical
- (done **W-wide-gate-sf2**) **WIDE FAIL** span=0.605 **PILLAR_320_of_529**; FBAR soft PASS — WIDE open; ≠ residual PASS (`/tmp/misterplex-agent-W-wide-gate-sf2.txt`)
- (done **H-gate-sf2**) FBAR PASS; **WIDTH FAIL** span=0.605 pillar — WIDE open; ≠ residual PASS
- (done **H-fbar-ec21b**) FBAR soft PASS 7.0/82.9/94.4 on lab **`ec21e133`** — ≠ WIDE/residual PASS (`/tmp/misterplex-agent-H-fbar-ec21b.txt`)
- (done **H-gate-ec21 / H-res-ec21**) residual **HARD_FAIL** on LOADED **`ec21e133`**: sticky0x14=0 +0x53 **08/5b/ae/01**; res_dc PASS; MULTI_DRIVE; **3l2 BLOCKED** (`/tmp/misterplex-agent-H-gate-ec21.txt`, `/tmp/misterplex-agent-H-res-ec21.txt`)
- (done **H-deploy-rcsum5**) promote + one menu **DEPLOY_OK** lab was **`8832824e`** (path superseded)
- (done **H-gate-rcsum5 / 5b / 5c / 5d**) residual serial **CLOSED FAIL** historical **`8832824e`**: FBAR soft; res_dc PASS; sticky0x14=0 +0x53 **16/69/bc/0f/62/b5/08**; **MULTI_DRIVE**; **NOT PACK_PROVEN**; thrash **`8832824e` forbidden**; definitive **`H-gate-rcsum5d`**
- (done **H-deploy-rcsum4**) promote + one menu **DEPLOY_OK** lab was **75da8bb1** (path superseded)
- (done **H-gate-rcsum4 / 4b**) **HARD_FAIL** lab **75da8bb1**: FBAR PASS soft; res_dc PASS; res_csum +0x53 never 0x14; **MULTI_DRIVE/PACK_FAIL**; **NOT PACK_PROVEN**
- (done **H-gate-rcsum3b / 3b2 / 3b3**) hard residual **HARD_FAIL** on prior **4d6ee356** (path superseded; thrash forbidden)
- (done **A-csum-probe7**) HOST_PROBE_OK; ideal **`e8 14 53 1a` HARD_PASS** offline only
- (done **A-csum-map1 / map2**) **MAP_OK** — blame residual_csum value path / multi-drive
- (done **A-csum-host28**) **HOST_GOLDEN_OK** res_dc=−24/0xe8 res_csum=XOR **0x14** ideal **e8 14 xx** (`/tmp/misterplex-agent-A-csum-host28.txt`) — HOST GREEN ≠ lab residual PASS
- (done **L-csum-note2..38** + **H-proto-rcsum*** + **R-csum-rtl3/6-plan** + **R-csum-fold-audit2** + **R-csum-postfail8** + **R-multidrive-rca14**) docs + pack RCA + R-csum6 protocol
- (done **R-csum-midfit-rcsum4 / midfit-rcsum4b**) **DRIFT_CRITICAL** documented; STOP mid-fit RTL
- (done **R-csum-midfit-rcsum5 / midfit-rcsum5b / midfit-rcsum5c**) **DRIFT_CRITICAL** launch **`6422fb9a`/`8e6af3bb`** → **`6a5dcaaa`/`7d4a1d8b`** claim overwrite; map=`st_res_word_sticky` product-class **PROVENANCE_UNTRUSTED**
- (done **W-sf2-d2/d3** / **W-wide7/7b**) design READY; Fix-2 silicon still WIDTH FAIL 0.605 on **`ec21e133`**
- (done **R-csum6 sole TERMINAL BUILD_OK**) lock **DONE BUILD_OK 14:10:26** wall **438s** exit **0** Full Comp **0e/40w**; NEW_RBF **`94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5`; claim freeze **MATCH** **`c7a847f7`/`ca62d02b`/`904e9b2e`** FIT_GO=YES DIAG=ABSENT Rank1+2+3; mon **M-fitmon-rcsum6c BUILD_OK**; mid-fit **SRC_DRIFT: NO**; exclusive **FREE**; lab **LOADED `94bbfe43`** after ONE menu
- soft-skip ≠ PASS; **3l2 BLOCKED** until hard product sticky **0x14**; **BUILD_OK / DEPLOY_OK / FBAR / PACKAGE ≠ hard residual PASS ≠ WIDE product PASS**; **DIAG ≠ product PASS**
- thrash **`8832824e`/`75da8bb1`/`4d6ee356` FORBIDDEN**; exclusive **FREE**; **H-deploy-rcsum6 DONE** lab **LOADED `94bbfe43`**; **H-gate-rcsum6 IN_PROGRESS/PENDING** — do not invent hard PASS; **WIDE still FAIL open Fix-2**; **W-sf3-hold2 FIT_GO=NO**
- git docs **`3c43a66`**; FPGA committed **`7bee0a6`**; R-csum6 claim **MATCH** **`c7a847f7`/`ca62d02b`/`904e9b2e`** NEW host **`94bbfe43`**; prior thrash residual **`6a5dcaaa`/`7d4a1d8b`**; colorbars Fix-2 **`f1d9666a`**; lab LOADED **`94bbfe43`**; residual CLOSED FAIL historical **`8832824e`**; **WIDE FAIL 0.605** open; **C-unit28 PASS** host; G-fpga **WAIT**; stamp **J-backlog66**; **do not invent hard-csum PASS / WIDE PASS / Fix-3 PASS / 3l2 UNBLOCK**

## Hour-21 — wtime4 LIVE, product sticky 0x14, FBAR blocked on missing capture hardware

- (done **W-TIME wtime4 DEPLOY_OK**) lab **LOADED `00eebd5e`** full `00eebd5e685e6cc821b13bfdcff41d0b`; device read-back by parent over own SSH: `CORENAME=Plex`, uptime 0:03. Prior lab `8eb01b79` superseded. **DEPLOY ≠ hard product PASS.**
- (done **W-TIME drift proof, parent-verified**) **DRIFT_CRITICAL=NO / LOCK_OK=YES**. Parent independently hashed both trees: `find rtl -name '*.sv' | sort | xargs md5sum | md5sum` → **39/39 `.sv`, manifest `3bc467e1d1e9f712651c59b8e811ab5f` identical** in fit tree and integration tip; `files.qip` **33/33 QIP_MANIFEST_MATCH**. `00eebd5e` **not** in banned set.
- (done **W-TIME wtime4 STA**) all five sections positive, **every TNS 0.000**: Setup `clk_ddr` **+0.284**, Hold `clk_sys` **+0.244** (`clk_ddr` hold **−0.179 → +0.347**), Recovery **+0.595**, Removal **+0.923**, MPW **+1.122**. Setup cost **−0.079** = the pre-registered +1 `clk_ddr` response-stage cycle. First fully timing-closed fit of the session.
- (**FINDING — deploy wedge**) ONE menu bounce did **not** take: `DEPLOY_FAIL: Main never switched to MENU — it is WEDGED`. Recovered by the deploy script's own `DEPLOY_RECOVER=reboot` path (not agent thrash), then `RECOVER_OK: Plex live after reboot`. One occurrence — record so a second becomes a pattern.
- (done **H-residual on `00eebd5e`**) **HARD PASS, product path, non-DIAG**, rc 0. Sticky **`e8 14 3b f9`**, stable across two pushes and repeated raw reads, **no `+0x53`**; `res_dc=-24 res_csum=20 recon_sig=59`. **First non-DIAG product sticky `0x14` of the session.**
- (**BLOCKER — FBAR NO_CAPTURE, hardware**) FBAR did **not** execute. Harness returned literal `no capture` into a Python expression → `SyntaxError`, reported as `FBAR_EXIT=1`. Root cause is **absent capture hardware on the HOST**, parent-verified: `/dev/video*` **No such file or directory**, `lsusb` shows **no video-class USB device**, **`uvcvideo` not loaded**. `captures/` contains only DDR dumps — no HDMI capture exists this session. FBAR = **UNSCOREABLE/NO_CAPTURE**, not FAIL. **Requires the user to physically attach an HDMI capture device.**
- (done **W-TIME `2ccd827` FBAR harness fix**) up-front missing-grabber preflight + distinct capture-failure diagnostic with dedicated exit **20**: `NO_CAPTURE_DEVICE ... reason=absent`; runtime no-frame remains `CAPTURE_FAILED ... reason=no_frame` / `FBAR_CAPTURE_FAILED ... exit=20`; forced-failure proof `FBAR_FORCED_PREFLIGHT_EXIT=20`. An instrument that could not distinguish "failed to measure" from "measured wrong" now can.
- **DDR dump ≠ picture PASS.** `wcap_dump_ddr` proves what the ARM wrote into the frame store; FBAR proves what the FPGA scans out to HDMI. A scanout-side defect (pillar/stride/`PRESENT_END_X`) is invisible to a DDR dump. **Do not substitute one for the other while FBAR is unavailable.**
- (done **W-MCFIX mutation audit, 10 rows**) **Row 10 pre-registered VACUOUS and confirmed**: with `uPattern == vPattern`, mutating U to carry V's formula left `chroma_windows=81/81` **GREEN**. Rows 1,3,4,5,6,7,8 LOAD-BEARING with distinguishable diagnostics; **Row 2 PARTIAL** (caught only via `decode_stub did not consume multiple VCL pulses` — no local DPB-latency diagnostic, i.e. diagnostic misattribution); **Row 9 over-tight** (encodes `luma→U→V` order as contract).
- (done **W-TIME `0f8e32e` filelist guard, parent mutation-verified**) replaced guard-evasion `50c045c` (which split `ddr_bus_arbiter.sv` into `"${stem}.sv"` to hide the literal from a text scan). Parent tested three ways: baseline green (83 benches / 67 modules); dropping a genuinely-compiled file → **RED**; dropping it **and** adding it to the `$QIP` grep loop (the evasion vector) → **RED anyway**. **No blind spot introduced.**
- (**REJECTED — W-GATE DDR publish centralisation**) `make unit` **rc=2** at integration; isolated by merging in two batches (infra batch rc=0, centralisation batch rc=2). Cause: `tests/unit/test_rtl_invariants.py:1205` text-matches the literal `ok=fpga_.sendYuv420pFrameDdr(txFrame,txBytes,ddrGeometry,ddrBank_)`, which the refactor removed. Integration reset to last green tip. **Fix must teach the invariant, not restore the literal or delete the check.**
- (**W-GATE geometry mutation — keep**) `DDR publish geometry failed: 320x240 and 624x480 bank1 both resolved to 0x30080000` — under a hardcoded stride two geometries collapse to the same bank1 address. This is the bug class behind the parent's retracted wrong-address conclusion.
- **17. P3-3l2 — remains BLOCKED.** The non-DIAG product sticky `0x14` precondition is now **MET** (`e8 14 3b f9`). 3l2 is now blocked solely on **picture verification**, which is unavailable until HDMI capture hardware is attached. **Do not unblock on the sticky alone; BUILD_OK + DEPLOY_OK + residual PASS ≠ product picture PASS.**

## Hour-22 — six worker chains merged; false-PASS instrument class found and fixed

- (done **W-INTER `c6e3900` real-P recon scoreboard**) rebased to a single commit, merged, parent-verified `make unit` **rc=0**, OK **83 → 87**. Scoreboard is an **independent C++ seeded DPB/reference**, not RTL-derived. Three mutations remain **distinguishable** (localising, not merely detecting): drop pred → `got=19 want=92 pred=73 residual=19`; drop residual → `got=73 want=92`; perturb MV → `read_ordinal 0 got_addr=0x400d want_addr=0x400c`. Green: `384 exact clipped pred+residual reads=21248 cycles=42884`. Worker pre-registered 4 genuinely-absent stages and predicted narrow-scoreboard pass / integrated-product fail — **matched**.
- (done **W-OSD `301d975`+`cb42eae`+`51bbe28` LastFrame latch**) merged; caches frame+geometry+layout **inseparably** and republishes both banks. Red-checks fire on the **relationship**, not a constant: `RED OK: LastFrame latch uses playback geometry`, `RED OK: LastFrame latch computes bank base from captured geometry stride` — geometry fault trips stride *and* doorbell, bank-base fault trips `bank_phys` alone. `remote_probe.sh` no longer hardcodes `STRIDE=0x80000`; derives `alignUp(frame_bytes,0x40000)` and reports `geom=UNKNOWN` rather than guessing.
- (**W-OSD root cause NOT yet confirmed — discriminator registered**) geometry mismatch is *not* declared the whole cause of the torn composite. Discriminator: if post-stop banks hash-match the paused last frame at captured geometry → geometry was the whole cause; if layout is correct but pixels remain torn → an **additional stop/lifetime race** exists. To be settled on hardware, not asserted.
- (done **W-MCFIX `050196f` audit closures**) **Row 10 no longer vacuous**: `FAIL h264_dpb_mc RTL: chroma fixture degeneracy: U and V patterns alias across 8x8 probe`; row 5 stays RED (`plane=1 idx=0 got=191 want=83`). **Row 2 given a local diagnostic**: `FAIL decode_stub DPB read latency contract: dpb_mem_rvalid did not follow dpb_mem_rd` — the defect now names itself instead of surfacing three layers away as a stream-path error. Row 9 reframed as implementation-order snapshot, behaviour unchanged.
- (done **W-GATE `2477118`+`11fe930`+`451de4e` DDR publish centralisation — now GREEN**) previously rejected at rc=2; worker took the **teach-the-invariant** route (not restoring the literal, not deleting the check). Parent-verified `make unit` **rc=0**, OK **88**, `present geometry/stride contract` failures **0**. Invariant proven non-vacuous by mutation: `wrong_geometry_mutation_rc=1` → `FAIL: ... must carry the same declared geometry that selected FFmpeg's coded stride into centralized publishDdrFrame`. Inverse bank-base and bank-alternation guards added.
- (**parent conflict resolutions, disclosed**) two conflicts resolved by the parent, both **unions of independent changes**, both verified by compiler + both authors' own tests: (a) `Makefile` — W-CAST `test_companion_plant_seek` ∪ W-OSD `test_last_frame_latch`; (b) `media_player.cpp:2572` — W-GATE's `ddrErr` message ∪ W-OSD's `else if (idleMode()==IdleMode::LastFrame) lastFrameLatch.remember(...)`. W-INTER's semantic RTL conflict was **not** parent-resolved; it was handed back and the worker rebased it.
- (**DEFECT CLASS — instruments that manufacture PASS from absence of evidence**) W-TIME audit of `tests/hw/`: `run_menu_matrix.sh:49-72,105-115,205-210`, `avsync_measure.py:82-119,248-258`, `avsync_rate.py:83-89,108-128` could all turn a **missing capture into `0.0` and report PASS**; `test_menu_osd.sh:26-47,84-92` weak. **Strictly worse than FBAR**, which at least crashed loudly. Clean: `test_f3_visual_golden.sh` via `hw_visual_compare.py`.
- (done **W-TIME `3822b91` capture-failure fixes**) all four sites now speak one vocabulary with dedicated exit **20**, each proven by forcing the condition: `run_menu_matrix / test_menu_osd / avsync_measure / avsync_rate: NO_CAPTURE_DEVICE ... reason=absent; EXIT=20`.
- (**G-AV2 / G-AV6 / G-AV7 / G-AV11 / G-OSD4 — reclassified UNVERIFIABLE-IN-REPO, not fabricated**) worker flagged these SUSPECT; **parent narrowed the claim after checking**. The cited artifacts (`captures/e2e/avsync_trekmatch/`) are absent **and were never committed** — `git log --diff-filter=D -- 'captures/e2e/*'` is empty, so they were local-only from an earlier session, not deleted. **Crucially, the recorded values are specific and non-zero** — `-215 ms` (G-AV11), `+0.79/−0.67/+1.79/−2.21 ms/min` (G-AV6), `−62.15 vs +94.0 ms` (G-OSD4) — which is **affirmative evidence against the `0.0` fabrication mode**, since that bug substitutes zero. These greens are therefore **not shown false**; they are **not re-derivable from the repo**. Action: **re-validate when capture hardware is attached**; do not cite as reproducible evidence until then; do **not** strike them as false passes.
- (done **W-CAST EOF reconfirm on `wtime4` — DDR path PASS, explicitly NOT a picture PASS**) `rbf_md5=00eebd5e...`, rebuilt `daemon_md5=98ee258d...`, `IDLE_SCREEN=black`. `EOF_NAVIGATION_AT_REALDUMP_POLL=5`, `location="navigation"`. Both banks: `md5=fa9d8b16..., Y unique=1, count_0x10=299520`, `bank0==bank1, bytes_differ=0` — uniform true black in both banks. Worker stated the limit itself: *"the daemon wrote black idle to both DDR banks after EOF. No HDMI/product-picture PASS."*
- (**FINDING — synthetic clip `/metadata/6` never returns to navigation**) reached duration and did not return within 240s; W-CAST fell back to real media `/metadata/3`. **This is the EOF failure mode surfacing on the very run that certified EOF.** Under investigation: degenerate fixture vs real EOF race. If it is a product bug, the "EOF works on `wtime4`" record **must be narrowed** to name the conditions under which it does not.
- **17. P3-3l2 — still BLOCKED.** Unchanged from Hour-21: sticky precondition met, blocked solely on picture verification, which remains impossible with **no HDMI capture device attached to the host**. No software change can lift this.

### Hour-22 addendum — roll-call guard, row-10 genuinely closed, and a codec/content blocker

- (done **W-TIME `00c5f81` unit roll-call guard, parent mutation-verified**) `make unit` now runs `unit-rollcall` before `unit-unlocked`. Steady state `UNIT_ROLLCALL_OK prereqs=30 commands=82`. **Parent independently reproduced the mutation** (not merely accepted the worker's proof) by dropping `test_last_frame_latch` from `unit-unlocked` in the integration tree: `UNIT_ROLLCALL_FAIL / MISSING_PREREQ $(ROOT)/build/test_last_frame_latch`, exit **2**; Makefile restored clean. **The silent-drop hole is closed**: previously removing a test left `rc=0` and was invisible.
- (done **W-OSD `986a1a3` announce + coverage census**) `test_last_frame_latch: OK checks=29`. Silent direct `build/*` invocations: **1 / 29** (`test_pixel_format` only, now assigned). Confirms the per-test OK series is a real coverage signal with one named blind spot.
- (**PARENT ERROR — self-caught, metric mislabelled**) the "OK count" quoted in hourly reports since Hour-1 was `grep -c '^OK'`, which counts **assertion lines beginning with `OK `**, not per-test passes (those are `: OK`). Discovered when a merge that added a passing test failed to move the number. Both series are real and both are now tracked: assertions **83 → 88**, per-test passes **63 → 65** across this hour. No prior conclusion is invalidated, but the label was wrong.
- (done **W-MCFIX product-side audit — row 10 GENUINELY CLOSED**) the earlier fixture-degeneracy detector was not sufficient proof; parent required a **product-side** mutation with healthy fixtures. Result: `i420_addr` V-reads-U (`2'd2` → `2'd1`) → **RED**, `chroma window clamp mismatch plane=2 idx=0 got=83 want=191` — **names the plane**. Extended to this hour's other merges: W-INTER scoreboard U/V seed mutation → RED `read_ordinal 20992 got_addr=0x4808 want_addr=0x4a08`; pred/residual drops still localise; LastFrame latch red-checks fire on both named relationships. **No new vacuous checks found among Hour-22 merges.**
- (**BLOCKER — no real H.264 content at target geometry**) W-FEED refused to run the ARM decode profile after verifying the reference clip is the wrong codec: `/library/metadata/3` is **MP4 HEVC Main, 696x540** (PMS metadata and device `ffmpeg` agree: `Video: hevc (Main), 696x540, 25 fps`). Not Baseline/CAVLC, not H.264, and **above the ≤480p budget**. Library scan: the **only** H.264 ≤480p candidates are 320×240 synthetic blips (`metadata 6,7,8,10,11,12`) — **and `/metadata/6` is the clip W-CAST found hangs at EOF**. So the FPGA H.264 decode programme currently has **no real H.264 content at target geometry to validate against**, and its only in-budget corpus is synthetic with at least one defective member. Open questions raised to W-FEED: (a) which prior decode/present numbers were taken on HEVC or >480p and therefore measure a different workload; (b) whether the ≤480p H.264 scope is still the right target if the library is predominantly HEVC; (c) whether to generate a well-formed Baseline/CAVLC ≤480p sample ourselves. **Profile deliberately held rather than run against the wrong workload.**
- (**PROVISIONAL — not a claim**) `ddr_bank_reuse_wait_us_p` **6.4 → 0.8 µs** steady-state on `wtime4` (buckets 2–6, warm-up bucket correctly excluded by the worker). This is the one metric that moved >1% and it is the one a `clk_ddr` hold fix should touch — but it is **~6 µs of ~10 400 µs (0.05% of present time)** and may be a single noisy bucket. **Held out of the hour report as anything more than provisional pending the old raw per-bucket series.** Present itself is unchanged: `ddr_total_us_p` 10333 → 10411, `ddr_cpu_us_p` 4973 → 4916 (both <1%, opposite directions). Worker's "no material move" prediction **CONFIRMED**.

### Hour-22 close-out — syntax handoff wired, coverage signal complete, bank-reuse claim RETRACTED

- (done **W-INTER `e30ed3a` P syntax handoff wired**) `h264_decode_core` now launches P16 recon from parsed `mb_type_valid`, tracks slice MB address, and asserts `rbsp_request_offset`. **This closes the `rbsp_request_valid=0` gap** — previously nothing downstream could ever be exercised by an actual bitstream. Scoreboard now drives the **syntax path**, not the private `p16_zero_mv_valid` hook. Parent-verified `make unit` **rc=0**, assertions **88 → 89**; new localising red-check `got=38 want=37 residual_bit_offset=296`; the three prior mutations (pred / residual / MV) **unchanged**, as pre-registered. Both predictions matched. No fit.
- (done **W-OSD `a0337e9` + `986a1a3` coverage signal complete**) `test_pixel_format: OK checks=17`, `test_last_frame_latch: OK checks=29`. **Silent direct `build/*` binaries: 1/29 → 0/29.** Every test in the suite now announces its own success, so a dropped or truncated test is visible in the log as well as fatal via roll-call.
- (**RETRACTED — `ddr_bank_reuse_wait` "8× improvement"**) W-FEED re-examined the raw per-bucket series on request and retracted: *"old and new are single-micro-outlier noise. It only proves floor not firing."* The provisional 6.4 → 0.8 µs figure is **withdrawn as a `wtime4` attribution**; the surviving claim is only that the bank-reuse floor is not firing. **Deliberately never published as a result** — it was held as provisional in the Hour-22 report pending exactly this check.
- (**Library codec census — programme-level finding**) `8` items total: **7 synthetic H.264**, **1 real HEVC** (`/metadata/3`, 696×540). **Real H.264 ≤480p content: 0.** Consequence stated by W-FEED and adopted: *"PMS-transcoded H.264 claims remain transcode-delivery claims, not original-Part claims."* Any doc asserting original-Part H.264 direct-play behaviour on real content is **unproven** — no such content exists in the library. Pre-registered census prediction **confirmed**.
- (**AUTHORISED — derived validation asset**) generate a **624×480 Baseline/CAVLC/ref=1/no-B** clip re-encoded from real HEVC source, verified with `pms_baseline_probe`. Condition: label unambiguously as a **derived re-encoded validation asset, not direct-play original content**, and record source/encoder/exact flags alongside it. Real-world image statistics beat synthetic blips for a decode profile; provenance must not be overstated.
- (**scope question raised to the user, not resolved by the fleet**) if the real library is predominantly HEVC at ~700×540 and above, an **H.264-only FPGA decode path decodes almost nothing the user owns**. Surfaced now rather than after fabric work lands.
- (**Hour-22 tally**) 17 commits merged, every one independently re-gated by the parent before keeping. Assertion lines **83 → 89**; per-test passes **63 → 66**; silent binaries **1 → 0**; `UNIT_ROLLCALL_OK prereqs=30 commands=82`. Final integration tip green: `make unit rc=0`.

### Hour-22 late — real EOF product bug found and fixed; EOF PASS narrowed

- (**PRODUCT BUG — known-duration rawvideo EOF stall**) W-CAST was told to go back for the `/metadata/6` stall it had worked around, pre-registered **"real EOF/lifecycle bug, not a degenerate fixture"**, and **scored correct**. Characterisation is unambiguous — the clip reached exactly its duration and stayed *playing*:
  ```
  poll 06..48: location="fullScreenVideo" state="playing" time="30021" duration="30021"
  LOG media: frames=714 vfps=23.2 pfps=23.1 audio_s=29.82 wall_s=30.67 drops=3
  ERROR no navigation after extended bounded wait
  ```
  **Root cause:** rawvideo stopped producing complete frames after the known duration, **but the pipe stayed open**, so the media loop sat in an `EAGAIN` sleep and never emitted `ended`. This is a genuine hang in the product path — not a fixture defect and not synthetic-media-specific in principle.
- (done **W-CAST `912ea76` fix**) adds bounded `knownDurationEofStall()`; the media loop now treats post-duration no-video/no-partial-frame as EOF. **Two-sided mutation proof** (the correct shape — guards against both under- and over-triggering): `return false` → **RED, 2 EOF-stall failures**; `return true` → **RED, 2 over-broad failures**. Parent-verified `make unit` **rc=0**, assertions **89**, per-test **66**, roll-call OK.
- (**EOF PASS NARROWED, on the worker's own recommendation**) the Hour-22 record "EOF works on `wtime4`" is **qualified**: EOF is verified on **real media `/metadata/3`** only. `/metadata/6` (known-duration synthetic) **required a code fix** and still needs a **fixed-daemon device reconfirm** before any unconditional EOF claim. W-CAST proposed this narrowing itself rather than letting its own PASS stand unqualified.
- **Note the sequence:** the certifying run produced the PASS *and* the counter-example in the same window, and the counter-example was initially a footnote. **Working around an anomaly to complete a measurement is how product bugs get buried** — this one was recovered only because the aside was chased rather than accepted.

### Hour-22 rejected — DDR layout derivation sweep (W-GATE `f806990`)

- (**REJECTED — `make unit` rc=2**) W-GATE's codebase-wide "derive, never hardcode, DDR frame layout" guard. Prediction scored: **5 additional sites predicted, 5 found** (second exact count from this worker). Class-level guards are the right design and both mutation proofs bite: `literal_sweep_mutation_rc=1` → `FAIL: runtime DDR frame layout literals must route through ddr_frame_layout derivation`; `mailbox_derivation_mutation_rc=1` → `FAIL: ddr_frame_store PLXS mailbox must derive from DOORBELL_PHYS + 0x100`.
- **Cause: it breaks W-OSD's LastFrame latch on the *green* path, not a red-check.** `test_last_frame_latch: FAILED checks=29 failures=6` with `s.data == latch.frame().data()`, `s.frame_layout.bank_stride == capturedLayout.bank_stride`, `s.frame_layout.doorbell_phys == capturedLayout.doorbell_phys` all failing. Assertion line numbers moved 69/71/72 → 71/73/74, so the commit edited that test's fixture or the layout type it depends on.
- **Isolation, single-variable:** integration `157c38e` → `rc=0`, assertions **89**, per-test **66**; integration `6b2041c` (same tree + `f806990`) → `rc=2`, assertions **33**. Nothing else differed. Integration reset to `157c38e`; the commit is intact in the worker's worktree.
- **Not parent-resolved, deliberately.** Two conflicts *were* parent-resolved this hour (`Makefile` test-list union; `media_player.cpp:2572` union) because both were provably independent changes the compiler could settle. **This one is a semantic disagreement about what the canonical DDR layout derivation yields** — W-GATE's helper versus W-OSD's captured-layout invariant. One side is wrong about the contract, and editing an assertion until it passes is the same failure mode rejected in Hour-21's centralisation. Returned to W-GATE to determine which side is correct, with an explicit instruction **not** to edit W-OSD's test (it owns that contract) and to confirm both latch red-checks still fire afterwards.

### Hour-23 — W-GATE sweep exonerated; the rejection above was wrong twice (parent error)

- (**RETRACTED — the stated cause of the Hour-22 rejection**) The section immediately above attributes W-GATE's `rc=2` to *"it breaks W-OSD's LastFrame latch on the green path"*. **That is false and is withdrawn.** `git show --stat` proves neither `f806990` nor the rebased `9a0f7d7` touches `test_last_frame_latch.cpp`; the assertion-line shift 69/71/72 → 71/73/74 that I cited as evidence came from **W-OSD's own announce commit `986a1a3`**, which landed in between. The worker was sent to fix a defect that did not exist.
- (**RETRACTED — the second parent inference**) I then attributed the failure to product tests (`pms_baseline_profile`, `h264_dpb_mc`). Also false. The assertion collapse **89 → 33** was **log truncation, not failures** — the run aborted early at the invariants stage (3424 lines vs 6600), so most tests never executed. **An assertion-count drop is not by itself evidence of failing tests.**
- (**W-GATE's commit is correct — proven four ways**) (1) pristine worktree at `9a0f7d7`: `make unit rc=0`, assertions **89**; (2) the worker's own worktree, re-run by the parent: `rc=0`, assertions **89**; (3) tree-hash comparison of `9a0f7d7` against the parent's cherry-pick: **only `docs/PHASE_BACKLOG.md` differs** — source identical; (4) controlled A/B below.
- (**REAL DEFECT — a gate whose verdict depends on untracked working-directory debris**) The new invariant scans the **filesystem**, so it tripped over W-OSD's *gitignored* throwaway device-probe scripts:
  ```
  FAIL: runtime DDR frame layout literals must route through ddr_frame_layout derivation;
  found captures/wosd-idle-modes/remote_probe2.sh:45: BASE=0x30000000; STRIDE=0x80000; FRAME=449280; ...
         captures/wosd-idle-modes/remote_scan_window.sh:47,60,61,86,99: ...
  ```
  Single-variable A/B on the **same commit and same tree**:
  ```
  debris present      -> tests/unit/test_rtl_invariants.sh rc=1, 1 FAIL
  debris moved aside  -> tests/unit/test_rtl_invariants.sh rc=0, 0 FAIL
  ```
- **Why this is worth more than the spurious red.** A gate that is **not a function of the committed source** cannot gate anything: it passes on a clean checkout and fails on a developer's machine, or the reverse. It is the same defect family tracked all session — instruments reporting something other than the property under test — **inverted**: instead of manufacturing PASS from *absence* of evidence, it manufactures FAIL from *presence of irrelevant* evidence. Returned to W-GATE to scope the scan via `git ls-files`, with a mutation proof that real violations in tracked files still fire and a regression check that untracked debris cannot change the verdict.
- **Process lesson recorded against the parent, not the worker.** Both wrong diagnoses shared one root: **inferring a cause from a diff of symptoms (line numbers, counts) instead of isolating the variable.** The A/B that settled it took two minutes and should have been the first step, not the fourth. A worker lost a full cycle to this.

### Hour-23 — measurement correction #2: `grep -c ': OK'` is not a valid metric

- (**CORRECTED — per-test "passes" count is build-state dependent**) `grep -c ': OK'` counts *occurrences*, and `extract_h264_golden` emits **one line per golden it regenerates** — 6 on a clean build, 5 on a warm one. The same source therefore reports **66 or 67 per-test passes with no code change**, which is exactly the unexplained drift seen while gating this hour.
  ```
  extract_h264_frame_planes: OK  x14      test_h264_multinal_stream_path: OK  x5
  extract_h264_golden:       OK  x6 / x5  test_status_telemetry:          OK  x2
  ```
- **Replacement metric:** assertions `grep -c '^OK'` **plus unique test count** `grep -o '^[a-zA-Z0-9_]*: OK' | sort -u | wc -l`. Verified stable at **44 unique tests** across all runs this hour, including the 66 vs 67 pair — **no test was ever lost**, which is what the raw count appeared to imply. All workers instructed to stop quoting `: OK`.
- **This is the second parent measurement error published this session** (the first: calling `^OK` assertion lines "tests" for 22 hours). Neither changed an accept/reject decision. Both were found by chasing a number that moved without a cause.

### Hour-23 — merges

- (done **W-INTER `cca1957`** — P16 MV neighbour / `ref_idx` state) parent-verified `make unit rc=0`, assertions **89 → 90**, unique tests **44** (none lost). Five red-checks all localise, including the new `drop neighbour: mb=(2,0) got_addr=0x401c want_addr=0x401d`. `make rtl-lint` `PASS no warning regressions`. Worker **three-for-three** on pre-registered predictions.
- (done **W-CAST `f15e0f8`** — bounded EOF stall guard + explicit terminal cleanup) parent-verified `make unit rc=0`, assertions **90**, unique tests **44**. The commit **added test cases without moving the assertion count** (its checks live inside `test_avclock`'s single summary line), which is precisely the shape a decorative test takes — so the parent **independently reproduced the mutation** rather than accepting the worker's evidence:
  ```
  knownDurationEofStall -> return true  =>  test_avclock: 7 failures
     FAIL !knownDurationEofStall(0, 60000, 59000, 0, 5000)   # elapsed < duration
     FAIL !knownDurationEofStall(0, 60000, 61000, 0, 999)    # inside grace
  restored                              =>  test_avclock: OK
  ```
  The guard is genuinely exercised and the over-broad cases are genuinely defended.
- (**pre-registered prediction scored WRONG, reported plainly by the worker**) W-CAST predicted a **duration-independent** stall path would exist; it traced the source and concluded it does **not** — an `EAGAIN`-only detector cannot be distinguished from a slow/stuttering source absent `read()==0`, a read error/short read, or an explicit stop/seek. **A traced negative is a real result**; it is now the load-bearing justification for shipping a duration-keyed guard and nothing broader, and has been sent back to be defended by tests rather than by a trace in a report.

### Hour-23 late — the scoped sweep pays for itself within the hour; a hole found in the roll-call guard

- (done **W-GATE `15ae470`** — DDR layout sweep, now scoped to tracked files) **Merged after the parent wrongly rejected it twice.** Both halves of the property were verified by the parent, not accepted from the worker:
  - **Insensitivity to untracked debris** — decisive because the integration tree **still contains the exact debris that produced the original `rc=1`** (`captures/wosd-idle-modes/remote_probe2.sh`). Green in the precise environment that previously failed.
  - **Detection not blinded** — a literal injected into a *tracked* file still fires and localises:
    ```
    tests/hw/test_fbar_fast.sh += BASE=0x30000000; STRIDE=0x80000; FRAME=449280; ...
    => rc=1  FAIL: ... found tests/hw/test_fbar_fast.sh:116
    restored => rc=0, tree clean
    ```
  - Parent error recorded: the first mutation attempt was a **C++ comment** and did not fire — wrong violation shape chosen by the parent, not a hole in the gate.
- (**THE GATE CAUGHT A REAL VIOLATION FROM ANOTHER WORKER WITHIN THE HOUR**) W-OSD's new human-visual-verification card was rejected by it:
  ```
  FAIL: runtime DDR frame layout literals must route through ddr_frame_layout derivation;
  found tests/hw/test_bank_release_visual.sh:120: BANK1_W0=$($SSH 'devmem 0x30080000')
  ```
  `0x30080000` is the 624×480 bank1 address hardcoded. **Correct today, wrong the moment geometry changes** — and W-OSD's own `e44c3c4` changed the transcode profile in the same chain. A verification card reading the wrong bank would give a human observer confident wrong answers, which is worse than no card. **Held back; three of four commits merged as `2cfdf81`.**
- (**DEFECT — `test_unit_rollcall.py` protects only a hardcoded list, and reports a constant as if it were a measurement**) Found because the guard's output **did not move** when W-FEED added a test to `unit-unlocked`:
  ```
  before merge: UNIT_ROLLCALL_OK prereqs=30 commands=82
  after  merge: UNIT_ROLLCALL_OK prereqs=30 commands=82
  EXPECTED_PREREQS = 30   actual unit-unlocked prereqs = 33
  test_bitstream_ring_lifecycle in EXPECTED_PREREQS: NO
  ```
  It reports `len(EXPECTED_PREREQS)` and checks one direction only (`missing = [p for p in EXPECTED if p not in actual]`). **Three tests in the gate are unprotected**, and the protection does not extend to new work — the work most likely to be churned. `prereqs=30` reads as "watching 30" when it means "knows about 30 of 33". **A constant that looks like a measurement is worse than no number** — it invited exactly the inference the parent made. Returned to W-TIME (its author) to report the actual count, decide deliberately what happens when `actual ⊃ expected`, and mutation-prove the *addition* direction that was never tested.
- (done **merges this hour**, each independently re-gated; integration `2cfdf81`, `make unit rc=0`, assertions **91**, unique tests **44**): W-INTER `cca1957` MV-neighbour + `a942ece` P16 CAVLC residual scheduling · W-CAST `f15e0f8` bounded EOF guard + `66580ab` terminal policy defence · W-TIME `67287bb` RTL invariant hardening · W-MCFIX `968e564` mutation taxonomy · W-OSD `6eda7f7` RTL cross-check + loud geometry mismatch, `2cfdf81` PLXD degeneracy/provenance + 624×480 profile · W-GATE `15ae470` scoped sweep · W-FEED `2ad3688` rebased ring-lifecycle chain.
- (**stale-base near-miss, recorded as the most dangerous diff of the session**) W-FEED was **nine commits behind** on a base diverging at `2726d35f`. Its `Makefile` side of `unit-unlocked` predated the roll-call guard and three merged tests, so a mechanical union would have **deleted the guard and the tests it protects in one commit, with `make unit` still green afterwards**. Its `ddr_bitstream_ring.hpp` side also reintroduced `0x504C5842u` as a literal after that constant had been centralised into `mailbox_abi`. Returned for a real rebase; the rebased chain merged cleanly and `test_bitstream_ring_lifecycle: ALL PASS`. **Parent process change: workers must now quote their merge-base against the integration tip when handing over SHAs**, so drift is visible immediately rather than at merge time.
- (**parent-resolved conflict, provable superset**) `tests/hw/README.md` — W-FEED's text asserts everything HEAD asserted (`bank1`, `0x30040000`, `0x30080000`, `status[12]`/`[13]`) **plus** doorbell derivation and the mmap doorbell bank bit, with no contradiction. Taken as a superset. Semantic conflicts continue to go back to their authors (W-OSD's PLXD-vs-timed bank-selection strategy did, and was resolved correctly by its author).

### Hour-24 — parent-run mutation verification, derived validation asset, scope correction on three decode claims

- (**parent mutation-verified W-CAST's audio-silence EOF term rather than accepting worker evidence**) `0725224` narrows `knownDurationEofStall()` to require **both** video and audio silence, and raises default grace 1000 → 5000 ms. Removing the audio term:
  ```
  MUTATED (noAudioMs >= graceMs removed) rc=1
  FAIL /home/flynnsbit/Projects/MisterPlex/tests/unit/test_avclock.cpp:127: !knownDurationEofStall(0, ...
  test_avclock: 1 failures
  RESTORED rc=0 ; tree clean
  ```
  **The term is load-bearing, not decorative.** Design note worth reusing: requiring audio silence is what makes the *short-lying-duration* case safe — if a container understates duration, audio still flows, `noAudioMs` stays 0, and the guard cannot fire. The detector is now keyed on **the stream actually being dead** rather than on the clock passing a number the container supplied. W-CAST found that case after **scoring its own earlier prediction wrong**.
  - **Open inverse risk, handed back to W-CAST:** a stream with **no audio track** may never advance `noAudioMs`, which would make the guard **vacuous for that entire class of content** — stricter-looking but unfirable. Same defect family as every instrument problem this session. Prediction to be pre-registered before testing.
- (**parent mutation-verified W-TIME's roll-call fix in the previously-untested direction**) `b19ceaa`:
  ```
  steady: actual_prereqs=33 expected_prereqs=33 actual_commands=86 protected_commands=83 ignored_commands=3
  mutated (unregistered prereq added): UNIT_ROLLCALL_FAIL actual=34 expected=33
                                       UNREGISTERED_PREREQ ... register this unit-unlocked prerequisite
  ```
  Closes the hole where the guard printed `len(EXPECTED_PREREQS)`=30 against 33 real prerequisites and checked one direction only.
- (**AUTHORISED DERIVED VALIDATION ASSET GENERATED — W-FEED — and independently re-probed by the parent**) `build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.mp4`, 12,720,086 bytes. Parent's own `ffprobe`, not the worker's:
  ```
  codec_name=h264  profile=Constrained Baseline  width=624  height=480
  has_b_frames=0   level=30   nb_frames=1800
  ```
  Matches W-FEED's reported `profile_idc=66 entropy_cabac=0 max_num_ref_frames=1 coded=624x480`, slices `i=36 p=1764 b=0`. Re-encoded from the **real HEVC source** so it carries real-world image statistics — **low-entropy synthetic content is exactly what lets a broken residual path score green.**
  - **Outstanding risk at time of writing:** the asset is **untracked under `build/`** with **no committed provenance record**. `build/` is disposable; a probe screenshot quoted in a later report is not. **An unlabelled derived asset is how "validated on real content" silently becomes a false claim about the user's library, which contains zero real H.264 at ≤480p.** Provenance + regeneration command returned to W-FEED as a tracked commit.
- (**SCOPE CORRECTION — three `docs/phase3-decode.md` claims were measured on HEVC / >480p, not on the H.264 path the fabric targets**) W-FEED's enumeration, open for two cycles, now answered: **W-A4 PMS probe** (~line 332), **Phase 3.3n High/CABAC/B sizing** (~line 360), **Phase 3.3p PMS Baseline XML** (~line 374). All derive from HEVC `/metadata/3` via PMS transcode. **They remain valid evidence about the transcode path; what was wrong was the unstated scope.** To be annotated in place, not deleted — a reader who finds a deleted number learns nothing; one who finds a scoped number learns the boundary.
- (**merge**) W-INTER `84a198f` — P16 residual traversal extended from one CAVLC/IDCT block to two sequential blocks, carrying `cavlc_bit_offset_end` into the next start. **assertions 91 → 92, unique tests 44, `make unit` rc=0.**
  - **Handoff hazard recorded:** the commit was based on `aef6232`, which does **not** contain W-INTER's own previously-merged one-block commit `a942ece` — same feature family, adjacent regions of `h264_decode_core.sv`, different patch-ids, externally indistinguishable from a duplicate or amended rework. **Resolved empirically (cherry-pick onto tip, observe clean apply, then gate) rather than by reasoning about it** — consistent with the lesson that inferring cause from a diff of symptoms is what produced two retracted diagnoses in Hour-23.
- (**device queue advanced**) W-FEED released the device and removed its remote profile scratch. W-OSD took it (first in queue), W-CAST second. **Neither FBAR nor 3l2 is affected: still UNSCOREABLE / BLOCKED pending physically attached HDMI capture hardware.**

### Hour-24 late — vacuity audits land in three lanes, ARM boundary quantified on real content

- (**ARM DECODE BOUNDARY MEASURED ON REAL-STATISTIC H.264 AT TARGET GEOMETRY — W-FEED `a799452`**) Phase 3.3q. Bucket sum **40.1902 ms/f**: fits 24 fps (41.667 ms) with **+1.476 ms/f**, **misses 25 fps (40.000 ms) by 0.190 ms/f**. Buckets: ffmpeg decode/null **21.5619 ms/f**, scale/pad/yuv420p delta **2.9543**, pipe delta **5.2634**, parent copy **2.3094**, product present/DDR **10.4106**.
  - **P1 confirmed with numbers, not assertion:** derived real content is **~20.5% larger per macroblock** and **~29.6% larger per P frame** than the synthetic 624×480 P16 fixture (`6.037` vs `5.011` B/MB; P-frame packet mean `6924.8` vs `5344.9` B). **The synthetic fixtures were flattering the workload.**
  - **P3 explicitly NOT scored green:** no derived golden/reference is wired, so this is **performance/boundary evidence only, not a correctness result**. Worker also declared the unattributed residual **"0 by construction … not an independent zero measurement"**, refusing to let an artefact of nested deltas read as a clean number. **Declining to claim the third prediction is worth more than confirming the first two.**
  - **Programme consequence:** on real 624×480 content the ARM path is a **24 fps device**. This is the quantified case for FPGA decode.
- (**VACUITY FOUND AND CLOSED IN THE RTL INVARIANTS — W-GATE `19aa5cd`**) Pre-registered **sound=21, vacuous=0, over-tight=0**; actual **sound=19, vacuous=1, over-tight=1**. **Predicted wrong and published.**
  - VACUOUS: `check_phase_a_surface` accepted menu strings from **any** active `Plex.sv` literal rather than the `CONF_STR` bound into `hps_io`. **Parent mutation-verified the fix rather than accepting the audit:**
    ```
    (replaced "F1,raw,RGB565 frame (320x240);" with a decoy entry)
    MUTATED rc=1
    FAIL: Plex.sv Phase A feature surface: Plex.sv CONF_STR missing `F1,raw`.
          That drops a Phase A shipping file slot; restore F1 raw ...
    RESTORED rc=0 ; tree clean
    ```
  - OVER-TIGHT: `check_yuv_ddr_writer_contract` forbidden-DDR-RGB sweep walked the filesystem and raw text; now `git ls-files`-scoped. **Same defect family as the scope bug already fixed — a verdict depending on working-directory junk rather than committed source.**
  - **Process failure recorded:** on first delivery these fixes existed **only in an untracked worktree-root report**; the branch had rebased to `0725224` with nothing on top. **A convincing narrative with evidence quoted and no code behind it is externally indistinguishable from fabrication.** Returned; recommitted as `62624e8`, `42cbce0`, `ef84ca4`.
- (**FIXTURE VACUITY FOUND AND CLOSED — W-MCFIX `97a974c`, `docs/decode-numeric-fixture-audit.md`**) Audit table of property / mutation / quoted failure.
  - **Live vacuity:** `clamp_coord` upper boundary returning `limit - 2` instead of `limit - 1` was **green before edge sentinels were added** — the fixture never drove coordinates near the upper edge, so the boundary was untested while appearing covered.
  - Also closed: U distinguished from V, luma distinguished from chroma, coefficient scan placement (dequant positions 1 and 4 swapped → `FAIL real RTL sim: block=1 dequant[1]…`).
  - **Honest non-firing mutation recorded:** `scan 1 ↔ 2` did **not** fire because those positions **share the same H.264 dequant matrix class** — **blunt mutation, not a gate hole.** Distinguishing the two is what separates an audit from a rubber stamp.
- (**SURVIVING 640 ASSUMPTION FOUND — W-OSD `3a8fe46`**) `contentResolutionFor480p()` returned hardcoded `{640, 480, "640x480"}` while the DDR contract codes **624×480**, so the OSD would advertise to PMS a geometry the daemon does not decode. Now derived from `kPlex480pCodedWidth`. Commit also distinguishes **presented scanout size (640, what `CONF_STR` labels)** from **coded frame size (624, what the DDR contract and PMS payload use)** — conflating those two is what created the bug.
  - (**PARENT-FOUND, STILL OPEN**) Sweeping `640` after the merge: `arm/misterplexd/main.cpp:330` tiers bitrate `decodeW >= 640 → 2500`, `>= 480 → 1500`. **At 624 this falls to 1500 while the OSD path assigns 2500 for identical geometry — two bitrates for the same coded frame size depending on `OSD_CONTROL`, and no test notices.** Policy half returned to W-OSD (including its unexplained 2000 → 2500 bump, bundled into a geometry commit without justification); structural half to W-TIME, to derive tiering from geometry constants and add a cross-path equality invariant.
- (**merges**) W-INTER `fb1c94c` four P16 luma residual blocks (assertions 92 → 93) · W-CAST `66e1e5d` EOF guard kept live for audio-less streams · W-TIME `a0a024e` measured test-infra counts · W-FEED `46bdb39`/`d795d74` derived-asset provenance + three-claim scope correction.
- (**PARENT ERROR #3, published**) Mutation-verifying W-CAST's `eofStallAudioSilenceMs`, I substituted an identifier not in scope. **The compile failed, the stale binary passed, and I was one step from recording a false "vacuous test" verdict against sound code** — a false accusation produced entirely by my own tooling. Re-run with the correct identifier: **4 failures at `test_avclock.cpp:133/134`**, restored rc=0, tree clean. **Standing rule: before believing any green mutant, `rm -f` the binary, check the build rc, and check the binary timestamp.** Third published measurement error this session; none has changed a decision.

### Hour-24 — device state audit (parent, no deploy)

- (**LIVE DEVICE VERIFIED HEALTHY, provenance traced to an evidence-backed build**) `192.168.1.183`, up 3:06.
  - Live core: `/media/fat/_Utility/Plex.rbf` md5 **`00eebd5e685e6cc821b13bfdcff41d0b`** = the **`wtime4`** fit (base `e18495b`, fitted HEAD `e1dffa3`) — **the first fully timing-closed core of the session**: `post-fit-timing` PASS, `post-fit-hierarchy` PASS, `timing-exclusion` PASS, worst setup `clk_ddr +0.284`, worst hold `clk_sys +0.244`, `clk_ddr` hold `+0.347`, TNS 0 on every section of the raw `Plex.sta.rpt`.
  - Daemon **running**: PID 9298, `/media/fat/misterplex/bin/misterplexd`, md5 `45d530a87faf24647e00a0ab030a6afb`.
  - Known-bad red specimen correctly quarantined as `Plex.failed-fe7673bc.rbf`, not live. Backup `Plex.e9b71d95.bak.rbf` retained.
- (**EXPECTED DRIFT, stated explicitly so it is not mistaken for a defect**) The live core predates every RTL change merged since — notably W-INTER's P16 residual traversal (one → two → four blocks). **The merged RTL is not on the device and cannot be, without a new fit.** No RBF is authorised; the Quartus lane is idle by design while non-fit work proceeds. **Host, daemon, test and docs merges are not on the device either unless separately deployed.**
- (**PARENT ERROR #4, published — a false negative manufactured by a missing tool**) My first device probe used `pgrep -f misterplexd`. **`pgrep` does not exist on the MiSTer**, so the command failed and my `||` fallback printed **"misterplexd NOT RUNNING"**. That was not a measurement; it was the absence of a tool being reported as the absence of a process. Re-probed with `ps w`: the daemon **is running**, PID 9298. **This is the exact defect family the fleet has spent the session hunting — an instrument that manufactures a verdict from absence of evidence — committed by the parent, in a one-line shell check, an hour after writing three worker briefs warning about it.** Fourth published parent error; none has changed a decision, but this one would have, had I reported it.

### Hour-25 — the golden gets plugged in, mailbox ABI vacuities closed, full P16 luma

- (**THE DERIVED GOLDEN NOW RUNS UNCONDITIONALLY — W-FEED `01a8aa6` + `fdbcc97`**) unique tests **44 → 45**.
  - `01a8aa6` landed per-frame Y/U/V plane hashes for the derived 624×480 Constrained Baseline clip, generated with **`-skip_loop_filter all`** so the reference matches the decoder stage the fabric implements. **A golden no correct implementation could satisfy is worse than none.** Coverage published as measured numbers, not caveats: **1790 unique Y hashes / 1800 frames; U and V differ on 1774/1800 — so 26 frames cannot detect a U/V swap at all.**
  - **But in the integration tree it emitted `SKIP-NOT-PASS rc=77`**, because the media lives in untracked `build/`. Honest skip, zero protection: **a gate that skips everywhere except its author's machine is an instrument built and left unplugged.** Soft skip ≠ pass.
  - `fdbcc97` fixes it with an **always-on committed 8-frame I420 slice**, full run demoted to explicit `INFO … optional`. Slice chosen for coverage, not position: source frames `149,392,474,710,937,1183,1349,1675`, **`uv_distinct=8/8`** (all drawn from the 1774 distinguishable frames, none from the 26 alias frames), **`unique_y=8/8`**, **`y_min=0`, `y_max=243`** — driving the lower clamp boundary exactly where W-MCFIX proved the synthetic fixture was blind. Registered in `unit-unlocked`, so W-TIME's roll-call guard protects it.
  - **Parent mutation-verified** (one byte flipped in the `.yuv`): fails at three levels and localises —
    ```
    DERIVED_SLICE_FAIL slice_sha256 got=61006f2f… want=ecfe1c79…
    DERIVED_SLICE_FAIL frame_hash   slice=0 source=149 …
    DERIVED_SLICE_FAIL plane_hash   slice=0 source=149 plane=Y …
    true rc=1 ; restored rc=0 ; tree clean
    ```
- (**MAILBOX ABI VACUITIES — W-GATE `a902e1e` + `c92cc39`, `docs/test-host-unit-vacuity-audit.md`**) Pre-registered `sound=14, vacuous=1, over-tight=1`; actual **`13/2/1`**. **Second audit, second wrong prediction, published both times.**
  - **`test_input_mailbox` and `test_sdram_mailbox` were merely self-consistent with the decoder rather than pinned to the hardware contract.** The worst possible location for this defect: the ABI could drift **coherently** — every constant moving together — and every test would stay green while the FPGA and daemon stopped speaking the same language. Now pinned to fixed contract values.
- (**FULL P16 LUMA RESIDUAL TRAVERSAL — W-INTER `b47dcfa`**) one block → two → four → complete luma set, each increment independently gated, no regressions. assertions 93 → 94.
- (**BITRATE DEFECT CLOSED CONSERVATIVELY — W-OSD `aa093c5` + `e6140a7`**) `kPlex480pWeakBitrateKbps` set to **2000, not 2500**. The 2500 tier was inherited from the `decodeW >= 640` threshold that **was itself the bug**, so adopting it would have carried a defect's side effect forward as a decision. Against W-FEED's measured **+1.476 ms/f** headroom at 24 fps, raising the fallback path 1500 → 2500 would have been a **67% bitrate increase inside a commit described as a refactor**. Parent mutation-verified the structural half: reintroducing a `w < 640` threshold → `FAIL tests/unit/test_osd_menu.cpp:81`, build rc=0 confirming a fresh binary.
- (**PARENT ORCHESTRATION DEFECT — five-file semantic conflict caused by my task split**) I assigned W-OSD "the policy half" and W-TIME "the structural half" of the same bitrate bug **without making the boundary exclusive**. Both correctly did the structural work, incompatibly: `UU` on `main.cpp`, `plex_resolve.cpp`, `osd_menu.hpp`, `test_osd_menu.cpp`, `test_resolve.cpp`. W-OSD's landed first and is verified, so it stands; W-TIME asked to rebase and contribute only what is additive (likely the `plex_resolve` path W-OSD never touched), **with an explicit invitation to argue its design is better rather than defer to arrival order.** **Cherry-picking one lane over another by fiat would have silently discarded real work; a mechanical union across five files where two designs disagree is exactly the merge that produces green tests and broken products.**
- (**PARENT ERROR #5, published**) Reading the slice-mutation result I piped through `tail` and captured **`tail`'s exit status, not the test's** — printing `rc=0` for a run that had just failed. Re-ran capturing the true rc: **`1` mutated, `0` restored.** **A number that arrives through a pipeline is not the number you think you measured.** Fifth published parent measurement error; none has changed a decision, but this one asserted the opposite of the truth.

### Hour-26 — geometry confirmed worst category, visual card made honest end-to-end, chroma scheduling

- (**GEOMETRY IS THE HIGHEST-RISK CATEGORY, CONFIRMED EMPIRICALLY — W-GATE `0330487`**) Pre-registered `sound=8, vacuous=3, over-tight=1`; actual **`sound=8, vacuous=4, over-tight=0`**. **Third audit, third wrong prediction, published every time.** Missed vacuity was the fixed 480p profile. Vacuous set included the OSD 480p label, the PMS 480p profile, and **`kPlex480pYuv420pBankStride`** (`0x80000 → 0x40000` mutation did not fire pre-fix). **Two live geometry bugs this cycle were caught by a human grepping for the string `640`, not by any test** — that is the exposure this audit quantifies.
- (**BUILD-SYSTEM TWIN OF THE STALE-BINARY TRAP — W-GATE `b60436b`**) Mailbox unit tests now rebuild when the ABI header changes. **A test that does not rebuild against a changed contract header keeps passing on a stale object file** — structurally the same defect that bit the parent twice by hand today, made impossible rather than remembered.
- (**VISUAL CARD NOW HONEST AT EVERY LAYER — W-OSD `cbb2ab7` + `c0b400d`; parent ran it on hardware after asking four times**) First run, raw:
  ```
  Resident RBF md5: 00eebd5e685e6cc821b13bfdcff41d0b
  Expected RBF md5: <unset>
  ⚠ RBF identity recorded but not asserted; valid human answers will be UNSCORED rather than PASS/FAIL
  ✓ Daemon running (PID 10131)
  PLXS 0x504C5853 / PLXF 0x504C5846 / PLXD 0x504C5844   (all as expected)
  UNSCORED: missing PLEX_TOKEN/MISTERPLEX_TOKEN; not starting playback
  ```
  **Two of six UNSCORED paths tripped; nothing was faked into a PASS.**
  - **Parent verified the provenance gate in BOTH directions** — the one-directional mistake that produced the roll-call hole: correct hash → UNSCORED count 2 → 1; wrong hash → `HUMAN_RESULT=UNSCORED reason=rbf-md5-mismatch`.
  - (**PARENT-FOUND DEFECT, fixed same hour**) **Every run exited `rc=0`, including the deliberate mismatch.** An UNSCORED verdict exiting zero is indistinguishable from success to any caller, wrapper, CI step or `&&` chain — **the card's entire value is refusing to score, and its exit code said "fine".** Now `rc=77`; parent re-verified on hardware: `rbf-md5-mismatch → true rc=77`, `missing-token → true rc=77`.
  - **Unique evidence the card produced:** all three mailbox magics read correct **off actual silicon**. W-GATE had just found `test_input_mailbox` and `test_sdram_mailbox` were checking those constants only against another copy of themselves. **This card is the only instrument in the tree checking them against hardware.**
- (**CHROMA RESIDUAL SCHEDULING — W-INTER `72e2d2c`**) assertions **94 → 97**, on top of full P16 luma traversal. One luma block → two → four → complete luma → chroma scheduling, every increment independently gated, no regressions.
- (**EOF GUARD WIDENED CORRECTLY — W-CAST `34a32e8`**) Stale partial frames no longer permanently disable the guard (`partialFrameBytes != 0` → `< 0`), plus a video-silence override at `3 × graceMs`. **Parent mutation-verified both new terms, confirming each mutant compiled first:**
  ```
  M1 build rc=0 ; override removed        → rc=1  FAIL test_avclock.cpp:129
  M2 build rc=0 ; stale-partial regressed → rc=1  FAIL test_avclock.cpp:132
  RESTORED rc=0 ; tree clean
  ```
- (**ORCHESTRATION ERROR RESOLVED AT MINIMUM COST — W-TIME `a60ed71`**) After the parent's non-exclusive task split caused a five-file semantic conflict, W-TIME rebased and contributed **only the additive part** — deriving resolve profiles from OSD geometry, the `plex_resolve` path W-OSD's chain never touched — rather than relitigating the overlap. **Insisting on either version of the shared files would have cost a cycle and discarded real work in whichever direction the parent ruled.**
- (**PEER COORDINATION WORKING WITHOUT THE PARENT**) W-MCFIX → W-FEED and W-INTER → W-FEED both obtained fixture paths, formats, frame indices and blind-spot lists directly. W-FEED's handoff explicitly enumerated its instrument's limits: *"only 8 frames; no timing/drop/repeat; no RGB/pillar/deblock; catches mutations only if expressed by selected samples."*
- (**ENVIRONMENTAL BLOCKER CONFIRMED BY MEASUREMENT, not assumption**) `PLEX_TOKEN` absent from `/media/fat/misterplex/misterplex.conf` — **zero matches**. Playback-dependent verification cannot proceed until the user supplies a token. **Combined with absent HDMI capture hardware, picture verification now requires two distinct things from the user.**

### Programme verdict — the ARM path is a demo, not a product (W-FEED, asked four times)

**Position, in W-FEED's words: "24 fps is demo-acceptable only; FPGA decode is now a product requirement."**

This is the answer the parent had been asking for since Hour-23 and is recorded verbatim because **it is the first statement in this programme that converts a measurement into a product decision.** The measurements were never in doubt; what was missing was the judgement of the agent that took them, and the parent explicitly refused to substitute its own.

- **25 fps is not impossible — it is unreliable.** The 0.190 ms/f miss is *"probably within run noise"*, so 25 fps cannot be called a hard failure. **But "coin-flip 25" is not product headroom**, and that distinction is the whole finding. A less careful answer would have reported either "25 fps fails" (false) or "25 fps works" (reckless).
- **The 24 fps margin of 1.476 ms/f is too thin to survive reality** — daemon work, PMS/network variance, a hotter ARM, scene complexity, and A/V scheduling all draw on it. **A margin measured on an idle device is not headroom in a product.**
- **The measured clip may be optimistic, not pessimistic.** It is one derived HEVC source at **~1412 kbps**; real PMS output at the 2000/2500 kbps tiers would be harder. **The parent had assumed the derived clip was an unusually hard case; W-FEED's read is the opposite, and W-FEED holds the data.**
- **ARM-only stopgap, if wanted:** attack present/DDR first — **10.41 ms/f measured against a raw `/dev/mem` microbench of 7.199 ms/f, so ~3 ms/f is recoverable without any FPGA work.** That would clear 25 fps with genuine margin. It does not change the verdict.
- **Why FPGA decode is the product path:** it is the only route that reclaims the dominant **~21.56 ms/f** decode bucket. Every ARM-side optimisation is competing for the remaining ~18 ms.
- **Named confidence gaps, unprompted:** repeat runs, a 2000/2500 kbps A/B, a thermal/load run, and end-to-end A/V. **The parent had offered "I cannot tell without measuring X" as an acceptable answer; W-FEED gave a position *and* named its X's, which is strictly better.**

**Programme consequence:** Phase 3 FPGA decode is now justified by measurement rather than by assumption. Until it lands, **the honest description of this device to a user is a 24 fps cast target with thin margin, and the parent will describe it that way.**
