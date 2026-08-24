# slot720p24j `968b828a` — what it gave (2026-08-13)

**Worker:** W-j-score. **Evidence only.** Soft-skip ≠ PASS. Chevron ≠ unique-24.
**BUILD_OK+DEPLOY ≠ pfps PASS.** This worker: ZERO Quartus, ZERO menu, ZERO
`load_core`, did not kill misterplexd **22654** / supervise **22645**.
Did not start play or T7.

Lab FILE timeline (this worker SSH RO; no bounce):

| When | `/media/fat/_Utility/Plex.rbf` | CORENAME | Notes |
|------|--------------------------------|----------|-------|
| 21:24Z | **`968b828a`** size 2937308 | **MENU** | sibling menu race (W-lab-plxd pair-1) |
| 21:25–21:27Z | **`968b828a`** | **Plex** | HDMI/T7 window. Parent 21:12Z CORE=Plex |
| **21:31Z** (this pin) | **`07f54d9f`** size 3831312 | **Plex** | user restored true480 onto `Plex.rbf` |

j bitstream **kept** as `/media/fat/_Utility/Plex.720p24.968b828a.rbf`
md5 **`968b828a8ec572bccf43b7bc2d31625a`** size **2937308** mtime **16:28 CDT**.
Matches lessons `remote_out/slot720p24j/Plex.rbf`. true480 twin
`Plex.true480.07f54d9f.rbf` still **`07f54d9f8f0eda2fe75d9cc314f6de54`**.
FPGA bitstream after the copy-restore is **not** re-read here (no
`load_core`). Loop: *user must reload for FPGA*.

---

## GAVE

1. **A new lab RBF on disk, not banned, not e/h/i.**
   Prefix **`968b828a`**. Farm+local size **2937308**. Full Comp
   **0 errors / 78 warnings** (Info 293000). Wrapper `summary.txt`
   `exit_code=0` wall **378s**. Not in
   `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0,17dd3b56,e494a767,
   740e19d6,c052be56,5a7c5085,07f54d9f,0bcc6081,ebfe4a12,15bd5db2}`.

2. **BUILD_OK + TIMING_OK (STA floors).**
   `Plex.sta.rpt` Fmax / setup slack:
   clk_sys **89.45** slack **+38.821** (≥20);
   clk_ddr **92.46** slack **+0.295** (≥90);
   clk_pix **54.25** slack **+23.232** (≥24).
   TimeQuest 0 errors. Floors PASS. **TIMING_OK ≠ unique 24.**

3. **DEPLOY_OK as file + idle glass (not pfps).**
   Lab FILE MATCH j RBF. HDMI capture after paint:
   `/tmp/plex-hdmi-eyes/j.png` ==
   `Memory/lab/captures/slot720p24j_idle_hdmi_1280.png`
   (md5 `1b69834cc596623f78c97cfd2ad76384`).
   Recipe `scripts/hdmi_capture_idle.sh`:
   **MEAN=39.8 STD=19.3 ORANGE_PX=11947 ACTIVE=1280x719**.
   Eyes: orange chevron + OSD. **Chevron gate PASS. Unique-24 FAIL (T7 sibling; pfps=NONE).**

4. **RTL swap gate that i did not ship.**
   Lessons `ddr_frame_store.sv` (live md5 `4a8f9b6e…`; i FIT_GO was
   `f37f19bd…`):
   `fabric_allows_swap = !fabric_copy_visible || (fabric_copy_token == db_token)`.
   i wired `fabric_copy_*` ports (10030=0) but kept **AND-only**
   (`visible && token==db`) → doorbell could not promote `has_frame`
   (`FABRIC_PORT_PASSTHRU.md` / `EBFE4A12_FABRIC_SWAP_GATE.md`).
   Comment in tree: *slot720p24i wired the ports but kept AND-only → still black.*

5. **Idle HDMI is no longer i/h black.**
   i `15bd5db2` capture `/tmp/plex-hdmi-eyes/i.png`:
   **MEAN=2.1 ORANGE_PX=0** (OSD box only; no chevron).
   h `ebfe4a12` idle was the same class (`HDMI_USB_EYES.md` MEAN=2.1
   ORANGE_PX=0). j paints the chevron.

6. **Daemon idle fabric path is REAL + painted.**
   `/media/fat/misterplex/misterplexd.log` (pid **22654** while j idle):
   `media: fabric_direct idle src_phys=REAL slot=0x04c80000 how=arena`
   and `media: idle screen painted (mode=0)`.
   OSD word **0xe020** content=720p display=720p decode=1280x720.

7. **Idle PLXD is not the h/i fd=0 class** (sibling RO, not this worker).
   W-lab-plxd pair-2 **21:26Z** CORE=Plex: PLXD **frames_done=3**
   disp=1 pending=0. h/i was fd=0 frozen. **Idle swap ≠ T7.**
   **FABRIC_PASS=NO.** Cite `/tmp/misterplex-agent-W-lab-plxd.txt`.
   This worker did not peek mailboxes and does not invent a second fd.

8. **true480 v0.4.1 glass left on disk (and restored as default).**
   `Plex.true480.07f54d9f.rbf` stayed **`07f54d9f`**. After the j
   chevron window the user copied true480 back onto `Plex.rbf`
   (21:30Z loop; this worker 21:31Z pin). Product 240p/480p pair was
   not discarded.

---

## DID NOT GIVE

1. **Unique 1280×720 @ 24 presented fps (gate ≥23.9).**
   Sibling **W-t7-j T7 FAIL** (`/tmp/misterplex-agent-W-t7-j.txt`,
   `/tmp/pfps-slot720p24j-15s.txt`): ONE play-file **21:27:23Z**,
   **PLAY_RC=1**, **pfps=NONE**, **0 frames**. Abort:
   `PLXJ ACK timeout want=16:9 token=1 last=4:3 token=0` then
   `source display aspect unavailable`. This worker did **not** start
   that play. Historical unique **15.47 best** is **e `17dd3b56`** only
   (`/tmp/pfps-720p24e-drop0-15s.txt` 15.333;
   `/tmp/pfps-720p24e-reconfirm-this.txt` 15.40). **Not remasured as a
   presented number on j. Not ≥23.9. 24 Hz beam ≠ 24 unique fps.**

2. **Native 720p HDMI/VGA raster (P4-DISPLAY).**
   Same j.png OSD: **`1280×720  0.00kHz  24.0Hz`** *request* over
   **`640×480  25.18MHz  59.9Hz`**. Grabber ACTIVE **1280x719** is the
   capture bbox of a 1280×720 request, **not** a proven 720p24 modeline.
   Setting is still meaningless until the core changes the MiSTer raster
   (`DISPLAY_RES_MUST_CHANGE_RASTER.md`, Lessons **L55**).
   **P4-DISPLAY stays TODO.**

3. **720p Display vs non-720p content play (P4-720P-MIX).**
   Not exercised as a mix gate on this RBF by this worker.
   **P4-720P-MIX stays TODO.** OSD cycling in the daemon log is sibling
   RCA, not a mix PASS.

4. **A product replacement for true480 `07f54d9f`.**
   240p/480p glass stays. Do not thrash `07f54d9f` for 720p24 pfps.

5. **Play FABRIC_PASS / presented-unique PASS.**
   Idle chevron + idle fd=3 ≠ play swap under 24 fps content.
   **BUILD_OK+DEPLOY ≠ pfps PASS.** Soft-skip ≠ PASS.

6. **A closed 720p24 product.**
   **P3-720P24 stays IN_PROGRESS / pfps FAIL.**

---

## Contrast (same grabber / same OSD overlay)

| Slot | RBF | HDMI idle | Swap gate |
|------|-----|-----------|-----------|
| e | `17dd3b56` | (memcpy-era; unique **15.47** FAIL) | no fabric AND |
| h | `ebfe4a12` | MEAN=2.1 ORANGE_PX=0 | AND + undriven 10030 |
| i | `15bd5db2` | MEAN=2.1 ORANGE_PX=0 | AND, ports wired |
| **j** | **`968b828a`** | **MEAN=39.8 ORANGE_PX=11947** | **OR if !visible** |

---

## Evidence

- Lab md5 / CORE: this worker SSH RO 21:24Z, 21:27Z (Plex.rbf=`968b828a`); 21:31Z (`Plex.rbf`=`07f54d9f`, j aside)
- T7: `/tmp/misterplex-agent-W-t7-j.txt` · `/tmp/pfps-slot720p24j-15s.txt` · `/tmp/misterplexd.t7j.log`
- STA: `…/remote_out/slot720p24j/Plex.sta.rpt` + `compile.log` + `summary.txt`
- RTL: `MisterPlex-wt-480p-lessons/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv` L1015–1016
- HDMI: `/tmp/plex-hdmi-eyes/j.png` · `Memory/lab/captures/slot720p24j_idle_hdmi_1280.png`
- i black: `/tmp/plex-hdmi-eyes/i.png` · `SLOT720P24I_HDMI_GATE.md`
- Daemon: `/media/fat/misterplex/misterplexd.log` (`0x04c80000`, idle painted)
- Idle PLXD: `/tmp/misterplex-agent-W-lab-plxd.txt` (sibling)
- e pfps: `/tmp/pfps-720p24e-drop0-15s.txt` · `docs/720p24-rbf.md`
- Parent loop: `/tmp/misterplex-loop-status.txt` TICK=21:18Z (j chevron) / 21:30Z (user restored `07f54d9f` onto `Plex.rbf`)

## Backlog suggestion

**P3-720P24** stays **IN_PROGRESS / pfps FAIL**. j **`968b828a`** was
**DEPLOY_OK HDMI chevron**; T7 **FAIL** (pfps=NONE, PLXJ ACK). Default
lab `Plex.rbf` is again **`07f54d9f`**; j kept as
`Plex.720p24.968b828a.rbf`. **P4-DISPLAY / P4-720P-MIX stay TODO.**
true480 **`07f54d9f` stays.**
