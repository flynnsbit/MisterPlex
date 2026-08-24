# Idle L4 first-kick — missing chevron is not a missing ">"

**Status:** RCA + host-unit only. **Glass ≠ PASS.** Soft-skip ≠ PASS. **UNIT_OK ≠ pfps.**
**P3-720P24** stays **IN_PROGRESS / pfps FAIL**. **P4-DISPLAY / P4-720P-MIX** stay **TODO**.
Do **not** re-derive “missing chevron.” No third menu. No Quartus. Host **not** deployed.

Lab RBF **`ebfe4a12`** (`ebfe4a12215a592b064202ec64a29c53`). true480 **`07f54d9f`** intact.

## Stop re-deriving this

Logo **I420 is already in L4 banks `0x30180000` / `0x30300000`** on **ebfe4a12**.
The painter did not forget `>`. The beam is **BLACK** because it is not
reading that YUV frame (**L56**).

## H1 — memcpy ≠ beam (PROVEN)

- Logo I420 both L4 banks. Y bg=45 fg=157; UV(676,360)=53,169 (720p glyph).
- **PLXD `fd=0` frozen** (free=0x2 disp=0 pending=0). PLXF seq LIVE.
- No swap since reset → **`has_frame=0`** → `use_ext=0` → **BLACK**.
- First-kick **SPI verify FAIL** (“no kick/frame via SPI or doorbell”).
- L4 OSD is mailbox-only; SPI bits never light → `sendDdrFrame` false.
- Doorbell leftover bank=1 is not a completed present.

## H2 — wrong bank if DECODE ≠ 1280×720 (PROVEN class)

- 640×480 / 320×240 `paintIdle` writes `0x30000000` + doorbell `0x300FF000`.
- L4 beam reads `0x30180000` + doorbell `0x3047F000`.
- Live `applyOsd` persist wrote DECODE=display but did **not** call
  `setDecodeSize()` — boot canvas can stay 640×480.

## Host patches — unit-only, NOT deployed

| Worker | Verdict | What | Deployed? |
|--------|---------|------|-----------|
| W-idle-kick | **KICK_OK** | mailbox first-kick accept (L4: doorbell visible + PLXF moving; SPI-dark+frozen fail-closed). 480p SPI path unchanged. | **NO** |
| W-osd-size | **SIZE_OK** | `applyOsd` `setDecodeSize` on 1280×720 present (persist 720p no longer leaves outW=640). 480p not shrunk. | **NO** |

Live misterplexd still SPI-only verify → `ddrKickMode=-1` → BLACK until a
**parent host-deploy token**. Do **not** treat KICK_OK / SIZE_OK as glass.

## L56 / fleet rules

- Idle is a **real YUV raster the beam must read**. No ARM **RGB565**.
- Soft-skip ≠ PASS. **UNIT_OK ≠ pfps.** BUILD_OK+DEPLOY ≠ chevron PASS.
- Glass ≠ PASS. No third menu. No Quartus. **P4-DISPLAY** stays **TODO**
  (fb0 640×480 overlay ≠ HDMI raster proof).

## Evidence

- `/tmp/misterplex-agent-W-idle-rca.txt` (H1/H2)
- `/tmp/misterplex-agent-W-idle-kick.txt` (KICK_OK, not deployed)
- `/tmp/misterplex-agent-W-osd-size.txt` (SIZE_OK, not deployed)
- Freddo L56 (do not rewrite): `FREDDO_YUV_LAST_RGB.md`
- Raster class: `DISPLAY_RES_MUST_CHANGE_RASTER.md`

No Plex tokens in this file.
