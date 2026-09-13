# MisterPlex progress — 2026-09-12 / 2026-09-13

**Owner context:** true FPGA 480p decode (not host-paint) until glass-verified.
**Lab box:** MiSTer `192.168.1.183` (HDMI grabber on this host). Pass-1 also `.42`.
**Private recovery:** this repo (`flynnsbit/misterplex-memory`).
**Public product:** `flynnsbit/MisterPlex` (source/docs only; no live secrets).

This file is durable bookkeeping — **not** playback acceptance.

---

## Successes today (sealed / shipped)

### 480i product path (host-paint + lipsync)
- Sealed **480i host** pair on glass with free-run ALSA path.
- RBF: `Plex_480i_host_audio.rbf` **e36** hash `56f38fff`.
- DECODE 720×480, legacy-software I420 → DDR, doorbell class 480i.
- Root-cause of beep/flash delay: **`av_lock=0`** on host-paint free-run video left MrAudio queue ~600–900 ms.
- Fixes: force av_lock on host-paint geometries, Hold skip, queue backpressure, `AUDIO_DELAY_MS=100`.
- HDMI flash↔beep median ~**−22 ms** after seal (lab measure).
- User reported 480i **looks good** on `.42`; audio after Plex exit was residual path (session), then addressed on daemon.

### 480p **host-paint** interim (not true FPGA decode)
- RBF **e37** `Plex_480p_host.rbf` hash `9014f49e`, DECODE 640×480, doorbell `0x300FF000`.
- Daemon **unified** `misterplexd` **f3035176**: MrAudio hard cap ~**120 ms** / resume ~100 ms (was thrashing ~274 ms).
- Lab HDMI lipsync 3× PASS medians ~+8 / +14.5 / −14.5 ms with `AUDIO_DELAY_MS=80`.
- playMedia RK **40766** on sealed 480p host: playing, queue 48–92 ms, HDMI content mean ~123.
- **Status:** useful fallback; **not** the true480 goal.

### Mode UX (dual-daemon pain)
- `scripts/switch_misterplex_mode.sh` + `scripts/MiSTerPlex_Mode.sh` TUI.
- One **unified daemon**; mode pick stops runners, starts pair, loads matching RBF.
- RBF does **not** auto-select daemon — pair = RBF + conf + daemon.
- Docs: `docs/MODES.md` (public + copy here).

### Idle chevron
- Lost last-frame-on-open fixed toward **IDLE_SCREEN=logo** (chevron) on open.
- Daemon path includes idle logo restore (verify on next open after true480 trials).

### Unified RBF research (user ask)
- Full write-up: `UNIFIED_RBF_RESEARCH.md` (this folder + public `docs/`).
- **Near-term:** multi-RBF + one daemon + Scripts TUI (done directionally).
- **CRT-capable unified RBF** requires runtime **native VGA timing mux** (240p ~15 kHz progressive ↔ 480i interlaced ↔ 480p ~31 kHz), not HDMI-scaler-only switching.
- Geometry/DDR doorbells/decoder-vs-host-paint are synthesized barriers — not a conf flip.
- Option B (host-paint + native timing mux) is first experiment; full decoder multi-geometry is a later fit campaign.

### True480 RCA (in progress → e35)
- Goal: FPGA H.264 → DPB → present 640×480 (coded 624×480), multi-AU glass.
- Historical stall class: **`presented_au=1` / PLXD `count=1`** then presentation queue stall (e32/e33b/e34).
- **e34 META_ONLY:** NOTES claimed `META_ONLY@0x3080` + present at DPB; **fitted root `Plex.sv` never enabled META_ONLY** (still fullcopy @ `0x3000`). Same stall class.
- DPB bank gap **449280** ≠ present `BANK_STRIDE 0x80000` — meta@DPB with 512KiB stride would mis-address bank1.
- e29 skipped `STATUS_WAIT` but **STATUS_FENCE still pulsed `bus_rd`** then left on `!bus_busy` (abandoned DDR read risk on mux3).
- Hypothesis for multi-present death: after first present, **FRAME_WAIT** needs `bus_dout_ready`; mux3+DPB can starve it → no further SWAP/STATUS.

### R17e35 source (frozen, fit running at publish time)
- Tree: `MisterPlex/build/plex-r17e35-fullcopy/`
- Changes in `rtl/fpga_video_publish.sv`:
  1. No `bus_rd` on `STATUS_FENCE`; IDLE/SWAP without bus wait.
  2. After `presentation_count != 0`, skip `FRAME_FENCE`/`FRAME_WAIT`; go SWAP (or COPIED_WAIT).
  3. Full I420 copy DPB→present `@0x3000`, `PICTURE_BYTES=449280`, `STORAGE 624×480`, `ADDR_W` auto, `META_ONLY=0`.
- `BUILD_ID` `e35a0001`; remote slot **`e35-fullcopy`** (sole Quartus), `ALLOW_UNVERIFIED`.
- Notes: `R17e35_NOTES.md`.
- Persistent glass agent: session agent `073eadfe` continues until glass PASS or hard block.

### Live lab snapshot (at first publish)
- `.183` daemon: unified **f3035176**.
- conf CONTENT/DISPLAY **480p** host path (`MPX_VIDEO_BACKEND=legacy-software`, `MPX_LEGACY_CORE_PREFIX=9014f49e`).
- Utility RBFs present: e36 480i host, e37 480p host, e34 WIP.
- e35 fit: **quartus_fit RUNNING** (map done).

---

## Product mode table (current)

| Mode | RBF (name/hash) | Backend | Daemon | Notes |
|------|-----------------|---------|--------|-------|
| 240p true24 | product AU32 / 882b class | FPGA H.264 | unified f303 | Chevron + cast path known-good class |
| 480i | e36 `56f38fff` host audio | legacy-software 720×480 | unified | Glass OK; lipsync sealed lab |
| 480p host | e37 `9014f49e` | legacy-software 640×480 | unified | Interim; lipsync lab sealed |
| 480p **true** | e35 WIP | FPGA decode 624→640 | unified | **Not sealed** — fit/glass in flight |

Mode switch: Scripts TUI / `switch_misterplex_mode.sh`. Preserve `PLEX_TOKEN`.

---

## Research summary (unified RBF + daemon)

See full doc: `UNIFIED_RBF_RESEARCH.md`.

| Question | Answer |
|----------|--------|
| One daemon for 240p/480i/480p? | **Yes** — unified daemon + mode conf/RBF pair. |
| One RBF switches formats? | **Not yet.** Needs storage geometry mux + **native VGA timing** mux for CRT. |
| HDMI-only “unified”? | Insufficient if CRT/VGA native is required. |
| Near-term UX | Multi-RBF + TUI (implemented direction). |
| True480 vs host 480p | True = FPGA decode; host = FFmpeg paint (current product 480p). |

---

## What is left (ordered)

1. **Finish e35 remote fit** — STA all models; collect RBF + reports to `remote_out/e35-fullcopy/`.
2. **Glass on `.183` (HDMI grabber)**
   - Menu-deploy e35 RBF + matching conf (FPGA backend, not legacy-software).
   - Lab: `lab-simple624nd` / FOAR 624 all-IDR style.
   - Pass criteria: `presented_au > 1`, PLXD count advances, HDMI shows **moving content** (not idle chevron alone), audio if enabled.
   - Fail: preserve logs; restore e37 host pair; iterate e36+.
3. **If still `presented_au=1`**
   - Confirm fence-skip in fitted netlist.
   - Probe bus arbiter / mux3 starvation; optional META_ONLY **with** present `FS_PHYS=0x3080` and `BANK_STRIDE=DPB_PIC_N`.
   - Decode promote / native pulse races if publish returns IDLE but no frame 2.
4. **True480 quality** after multi-present: inter/P frames, deblock, lipsync with FPGA present clock (not only host free-run).
5. **User sign-off path** — Plex Web LAN cast icon → MisterPlex → library title → HDMI matches Web playing (required before “done”).
6. **Port lipsync queue120 / av_lock** into primary tree if still only in fleet WT.
7. **480i residual** — OSD labels / menu options; `.42` audio edge cases if still open after unified daemon.
8. **Unified RBF (later)** — timing generator mux experiment; do not block true480.
9. **Publish** curated private checkpoint after e35 glass outcome (no raw secrets/tokens/media).

---

## Explicit non-goals right now
- Parallel Quartus fits.
- Claiming glass from unit tests or cards alone.
- Deploying unapproved e34/e35 as default product without restore path.
- Uploading live Plex tokens or raw capture dumps to git.

---

## Pointers

| Artifact | Path |
|----------|------|
| e35 source | `MisterPlex/build/plex-r17e35-fullcopy/` |
| e34 FAIL glass | `MisterPlex/build/true24-r17e34-glass-20260912/RESULT.md` |
| 480p host lipsync | `MisterPlex/build/mode-deploy-hq-20260912/avsync-480p-e37/` |
| Mode scripts | `MisterPlex/scripts/switch_misterplex_mode.sh`, `MiSTerPlex_Mode.sh` |
| Fleet entry | `Memory/lab/fpga-h264-30ff2997/RESUME.md` |
| This progress | `docs/true480-20260912/progress.md` |

---

## Next command (human or agent)

```bash
# when fit completes
ls MisterPlex/build/plex-r17e35-fullcopy/remote_out/e35-fullcopy/Plex.rbf
# then menu deploy + glass on .183; restore host e37 on failure
```

**Stop condition:** true 480p FPGA decode multi-present on HDMI via real cast/play path, or user says stop.
