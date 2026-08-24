# SCORE `968b828a` (slot720p24j) — 2026-08-13 W-score-k

Evidence only. Soft-skip ≠ PASS. Chevron ≠ unique-24. 24 Hz ≠ 24 unique fps.
UNIT_OK ≠ T7. IDLE_SWAP ≠ FABRIC_PASS. BUILD_OK+DEPLOY ≠ pfps PASS.
**P3-720P24 stays IN_PROGRESS / pfps FAIL.**

RBF full `968b828a8ec572bccf43b7bc2d31625a` size **2937308**.
Farm `remote_out/slot720p24j/` Full Comp **0e/78w** wall **378s** exit **0**.

| Gate | Result | Cite |
|------|--------|------|
| slot720p24j Full Comp / NEW_RBF not banned | **PASS** | `summary.txt` `exit_code=0` `wall_seconds=378`. compile.log Info **293000** 0 errors, 78 warnings. farm+local md5 **`968b828a`**. ∉ `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0,17dd3b56,e494a767,740e19d6,c052be56,5a7c5085,07f54d9f,0bcc6081,ebfe4a12,15bd5db2}`. |
| STA floors | **PASS** | This worker extracted `Plex.sta.rpt` + `/tmp/misterplex-sta-extract.py` EXIT=0 + `check_quartus_timing.py --sta-rpt` RC=0. clk_sys **89.45** slack **+38.821** (≥20). clk_ddr **92.46** slack **+0.295** (≥90). clk_pix **54.25** slack **+23.232** (≥24). All setup/hold/recovery/removal/min-pulse slack ≥0. **TIMING_OK ≠ unique-24.** |
| Lab file MATCH + CORE=Plex | **PASS** (21:25–21:27Z window only) | Parent SSH **21:27Z** + W-t7-j + W-lab-plxd pair-2: `/media/fat/_Utility/Plex.rbf` = **`968b828a`** CORE=**Plex**. **After 21:31Z** default `Plex.rbf` = **`07f54d9f`**; j kept `Plex.720p24.968b828a.rbf`. Do **not** treat current disk name as 968b828a. true480 backup intact. |
| HDMI chevron (`ORANGE_PX>0`) | **PASS** | `Memory/lab/captures/slot720p24j_idle_hdmi_1280.png` md5 `1b69834cc596623f78c97cfd2ad76384`. Recipe re-score: **MEAN=39.8 STD=19.3 ORANGE_PX=11947 ACTIVE=1280x719**. Eyes: orange `>` + OSD. **Chevron ≠ unique-24.** |
| Native 720p HDMI raster | **FAIL** | Same PNG OSD: request `1280×720 0.00kHz 24.0Hz` over **`640×480 25.18MHz 59.9Hz`**. Grabber 1280×720 is request size, not PHY proof. `DISPLAY_RES_STILL_640x480_ON_J.md`. |
| IDLE_SWAP / PLXD fd advance **under play** | **FAIL** | Idle **IDLE_SWAP=YES** (`/tmp/misterplex-agent-W-lab-plxd.txt`): pair-2 CORE=Plex PLXD **fd=3** disp=1 pending=0 sticky 1.05s; not h/i fd=0. **fd did not increment idle.** Under play: **NOT measured** — T7 0 frames. **IDLE_SWAP ≠ FABRIC_PASS.** |
| T7 unique pfps ≥23.9 | **FAIL** | `/tmp/misterplex-agent-W-t7-j.txt` + `/tmp/pfps-slot720p24j-15s.txt`. PLAY_RC=**1**. pfps=**NONE**. 0 frames. `PLXJ ACK timeout want=16:9 token=1 last=4:3 token=0`. Historical e **15.47** is not this slot. Do not invent ≥23.9. |
| UNIT_OK host | **PASS** | `/tmp/misterplex-agent-W-unit-j.txt` MAKE_UNIT_RC=**0**. Host only. **UNIT_OK ≠ T7 ≠ pfps.** |
| P4-DISPLAY | **FAIL** (stays **TODO**) | Raster still 640×480@59.9. F12 Display did not change MiSTer HDMI/VGA. Lessons **L55**. |
| P4-720P-MIX | **UNKNOWN** (stays **TODO**) | Mix matrix not run on 968b828a. T7 abort is PLXJ ACK, not a mix PASS/FAIL. |
| FIT_GO next exclusive? | **NO** | Loop TICK **21:34Z** exclusive **FREE** **FIT_GO=NO**. Next = PLXJ ACK RCA + P4-DISPLAY design. **No Quartus.** Chevron / UNIT_OK / BUILD_OK do not unlock a fit. |

## Not claimed

FABRIC_PASS. unique-24. product replacement for true480 **`07f54d9f`**. current `Plex.rbf` == 968b828a (restored).

## Evidence

- farm: `MisterPlex-wt-480p-lessons/fpga/Plex_MiSTer/remote_out/slot720p24j/{summary.txt,compile.log,Plex.sta.rpt,Plex.rbf}`
- T7: `/tmp/misterplex-agent-W-t7-j.txt`
- idle PLXD: `/tmp/misterplex-agent-W-lab-plxd.txt`
- unit: `/tmp/misterplex-agent-W-unit-j.txt`
- HDMI: `Memory/lab/captures/slot720p24j_idle_hdmi_1280.png`
- P4: `DISPLAY_RES_STILL_640x480_ON_J.md` · `DISPLAY_RES_MUST_CHANGE_RASTER.md`
- sibling narrative: `SLOT720P24J_WHAT_IT_GAVE.md` (W-j-score; not a second PASS stamp)
