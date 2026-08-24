# T7_SIDECAR_95bff255_RECONFIRM — RO pin PIN_OK

**Worker:** W-sidecar-ro · **2026-08-13T23:44:57Z** · **PIN_OK.**
**Did not write conf. Did not play. Did not deploy. Did not kill 2397.**
**ZERO** Quartus / menu / `load_core` / HDMI / overwrite `Plex.rbf` / `PHASE_BACKLOG` edit.

**PIN_OK ≠ T7 PASS.** Sidecar ≠ mix matrix. Soft-skip ≠ PASS.

Cite: `/tmp/misterplex-agent-W-sidecar-ro.txt` · `/tmp/t7-l4.conf` ·
`T7_SIDECAR_L4_CONF.md` · `/tmp/misterplex-agent-W-sidecar-prep.txt` ·
`/tmp/misterplex-agent-W-comp-pin2.txt` · `COMPANION_6f1afebe_DEPLOYED.md`

---

## Verdict

| | |
|--|--|
| **This worker** | **PIN_OK** — local **23:44:42Z** + lab SSH **23:44:57Z** |
| **Sidecar** `/tmp/t7-l4.conf` | **`95bff255c605f81dd543b861f9e5472c`** both sides |
| **Sidecar keys** | `DECODE=1280x720` `OSD_CONTROL=0` |
| **Product** `/media/fat/misterplex/misterplex.conf` | **`4a05032a39803428a63369ceca898c50`** |
| **Product keys** | `DECODE=640x480` `OSD_CONTROL=1` |
| **local == lab sidecar** | **YES** (equal-md5) |
| **T7** | still **FAIL** pfps=**14.1** (not re-run; this worker did **not** play) |
| **P4-720P-MIX** | still **TODO** — sidecar ≠ mix matrix |
| **FIT_GO** | **NO** |

**PIN_OK ≠ T7 PASS.** **PIN_OK ≠ mix PASS ≠ HDMI PASS.**

---

## RO pin (this worker)

### Local (build host **23:44:42Z**)

| Item | Value | Expected | Match |
|------|-------|----------|-------|
| `/tmp/t7-l4.conf` md5 | **`95bff255c605f81dd543b861f9e5472c`** | `95bff255c605f81dd543b861f9e5472c` | **YES** |
| size / mtime | **1001** / 2026-08-13 16:46:11 −0500 | 1001 (sidecar-prep) | **YES** |
| `DECODE` | **1280x720** | 1280x720 | **YES** |
| `OSD_CONTROL` | **0** | 0 | **YES** |

### Lab (`root@192.168.1.183` **23:44:57Z**)

Read-only SSH (`md5sum` + `grep DECODE\|OSD_CONTROL` + `stat`). **No** scp, tee, play, TERM, or conf write.

| Item | Live | Expected | Match |
|------|------|----------|-------|
| `/tmp/t7-l4.conf` md5 | **`95bff255c605f81dd543b861f9e5472c`** | `95bff255c605f81dd543b861f9e5472c` | **YES** |
| sidecar size / mtime | **1001** / 2026-08-13 16:46:20 −0500 | sidecar-prep | **YES** |
| sidecar `DECODE` | **1280x720** | 1280x720 | **YES** |
| sidecar `OSD_CONTROL` | **0** | 0 | **YES** |
| product md5 | **`4a05032a39803428a63369ceca898c50`** | `4a05032a` | **YES** |
| product `DECODE` | **640x480** | 640x480 | **YES** |
| product `OSD_CONTROL` | **1** | 1 | **YES** |
| product size / mtime | **582** / 2026-08-13 18:07:52 −0500 | W-comp-pin2 | **YES** |

**DRIFT: NO** vs W-sidecar-prep **21:46Z** sidecar and W-comp-pin2 **23:25:55Z** sidecar+product.

Product stays **distinct** from sidecar (640×480 / OSD on vs 1280×720 / OSD off). **Do not** play against product conf for T7 L4.

---

## Sidecar vs product (lab **23:44:57Z**)

| Key | Product `4a05032a` | Sidecar `95bff255` |
|-----|--------------------|--------------------|
| `DECODE` | **640x480** | **1280x720** |
| `OSD_CONTROL` | **1** | **0** |

---

## Honesty

- **PIN_OK ≠ T7 PASS.** T7 unique pfps still **FAIL 14.1**. This worker did **not** play.
- Sidecar file existence / pin **≠** mix matrix **≠** HDMI raster PASS.
- **Do not** upsert live `misterplex.conf`. **Do not** kill **2397**.
- **FIT_GO=NO.** **ZERO** Quartus / play / deploy this tick.
