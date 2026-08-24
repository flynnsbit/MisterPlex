# CLI_DECODE_WINS — `--decode` survives loadConf DECODE=

**Worker:** W-decode-wins · **2026-08-13T21:48Z** · host-only.
**HOST_OK.** Soft-skip ≠ PASS. **This patch ≠ T7 PASS.** pfps=**NONE**.
**P3-720P24** stays **IN_PROGRESS / pfps FAIL**. **FIT_GO=NO**.
Next T7 play is **PARENT-owned only**. ZERO Quartus / menu / play / deploy.

Cite: `/tmp/misterplex-agent-W-decode-wins.txt` · `/tmp/misterplex-agent-W-t7-rca.txt` ·
`/tmp/misterplex-agent-W-osd-720p.txt` · `/tmp/misterplex-agent-W-plxj-rtl.txt`

---

## What this is

Operator `--decode WxH` is re-applied **after** `loadConf(DECODE)`. Play-file
restores that canvas **before** `setSourceAspect` (ACK kept). A future parent T7
`--decode 1280x720` play-file will poll PLXJ at **`0x3047F130`**, not `0x3007F130`.

**HOST_OK ≠ unique pfps.** ACK ≠ ≥23.9. Did **not** deploy the companion.

---

## T7 hole this closes

T7-j: `--decode 1280x720` then conf `DECODE=320x240` overwrote `decodeW/H`.
Play-file laid out 240p, polled **`0x3007F130`**, timed out `last=4:3 token=0`
(default ACK). Live 968b828a publishes PLXJ at **`0x3047F130`** (`ACK_PATH=LIVE`).

`osdRetargetDecodeSizeFromPresented` only **grows** to L4; 240p display does not
raise 320×240. `applyOsd` is **not** this ticket (W-raster-cmd).

---

## Change (`arm/misterplexd/main.cpp` md5 `ccfc26f0`)

1. Track `cliDecodeExplicit` / `cliDecodeW/H` from `--decode`.
2. After the conf block: if CLI set, restore CLI size and log `CLI_DECODE_WINS`
   (`conf DECODE=… ignored` when they differ). Same pattern as `--transcode-profile`.
3. Play-file: `setDecodeSize(decodeW,decodeH)` then log
   `doorbell=` / `PLXJ=` (`L4` when 1280×720) **then** `probe` + `setSourceAspect`.
   Fail-closed string `source display aspect unavailable` is unchanged.

ACK is **not** skipped. Timeout is **not** lengthened.

---

## Evidence (host unit, not T7)

| Gate | RC | Note |
|------|----|------|
| `check_cli_decode_wins` (unfixed) | **1 RED** | missing `CLI_DECODE_WINS` |
| `check_cli_decode_wins` (patched) | **0** | CLI after `loadConf DECODE`; play-file `setDecodeSize` before ACK |
| `check_source_aspect_contract` | **0** | ACK still required |
| `build/test_osd_menu` | **0** | 320×240→`0x3007F130`; 1280×720→`0x3047F130` |
| `test_play_file_delivery.sh` | **0** | see logs below |

`PRESENT=none` play-file (no FPGA, no ACK wait — layout log only):

```
CLI_DECODE_WINS --decode 160x120 (conf DECODE=320x240 ignored)
… decode=160x120 doorbell=0x3007F000 PLXJ=0x3007F130

CLI_DECODE_WINS --decode 1280x720 (conf DECODE=320x240 ignored)
… decode=1280x720 doorbell=0x3047F000 PLXJ=0x3047F130 L4

# no --decode: no CLI_DECODE_WINS; decode=320x240 PLXJ=0x3007F130
```

Logs: `build/unit_play_file_delivery/cli_decode_{wins,l4,conf_only}.log`

---

## What this is not

- Not T7 PASS / not a play / not a companion deploy
- Not pfps ≥23.9 / not any invented pfps
- Not P4-DISPLAY / raster PASS
- Not permission for Quartus, menu, or killing **24016**
- Not a claim that OSD `0x6000` is 720p (still Main-owned)

## Residual

OSD seed still cannot **raise** 240p→L4 (`osdRetarget` grow-only). CLI-wins +
play-file restore is the host path that puts L4 on the canvas before ACK.
`applyOsd` owned elsewhere. Disk `Plex.rbf` remains **`07f54d9f`** (user restore).

## Backlog suggestion

T7 still **FAIL / pfps=NONE**. **P3-720P24 IN_PROGRESS / pfps FAIL**.
**CLI_DECODE_WINS HOST_OK** on lessons tree; **not deployed**. Next T7 =
**PARENT-owned** play-file `--decode 1280x720` (sidecar optional). **FIT_GO=NO**.
P4-DISPLAY / P4-720P-MIX stay **TODO**.
