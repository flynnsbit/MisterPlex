# Dual misterplexd on ebfe4a12 — TWIN_OK (do not kill 13872/13881)

**Pin:** 2026-08-13T20:20:16Z (reconfirm 20:20:50Z). SSH `/proc` + `ss` only.
Cite **W-bin-re** `/tmp/misterplex-agent-W-bin-re.txt` (`BIN_RE=NEW` exe **`54ff33a0`**).
This **W-twin-re2** killed nothing. **Lab:** `Plex.rbf` **`ebfe4a12215a592b064202ec64a29c53`**.
CORENAME=Plex. true480 **`07f54d9f`** intact. Main **18071** untouched.

**P3-720P24** stays **IN_PROGRESS / pfps FAIL**. **P4-DISPLAY / P4-720P-MIX** stay **TODO**.
Soft-skip ≠ PASS. **TWIN_OK ≠ FABRIC_PASS ≠ T7**. Do not invent poke/PLXP PASS.

## TWIN_OK — 13881 owns :3005 and left alive

Ticket TWIN_OK = **13881 owns :3005** AND **left alive**. Both true after W-bin-re.

| PID | comm | ppid | start UTC | `MPX_FABRIC_DIRECT` | role |
|-----|------|------|-----------|---------------------|------|
| **13872** | `misterplexd_sup` | 1 | 19:54:16Z | **=1** | SSH nohup supervise |
| **13881** | **`mpx-main`** | 13872 | 19:54:16Z | **=1** | **owns :3005** + UDP 32412 |
| 18071 | MiSTer | 1 | 17:45:39Z | NO_FABRIC_ENV | Main untouched |

`ss`: `0.0.0.0:3005` → **pid 13881** fd=4 inode **97760**. UDP **32412** inode
**97762** → 13881 fd=5. Census: one supervise, one `mpx-main`, **zero** watch.
exe `/proc/13881/exe` **`54ff33a0f9a0c928d14e171de9796124`** == disk (W-bin-re).

## DEAD (not this worker)

| PID | was | live |
|-----|-----|------|
| **10411 / 10420** | prior single tree FABRIC=1 :3005 (W-twin-re / card 19:42Z) | **DEAD** |
| 1316 / 4887 / **4898** / 4909 / **4918** | old dual + watch | **DEAD** — watch **ABSENT** |

## Do not kill without a parent token

Do **not** kill / SIGSTOP / rewrite environ of 13872, 13881, or Main.
**Do not spawn W-flag-off.** No bounce unless parent tokens it.
Death of 10411/10420 is **not** this worker (already PIDS_CHANGED in W-bin-re).

## Hygiene only

Live single tree. **TWIN_OK** (13881 :3005 + left alive). Next remains RO PLXP /
pagemap on 13881. **Do not bounce.** **FABRIC_PASS=NO**.
