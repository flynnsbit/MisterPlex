# T7 PLXJ ACK timeout — class MIX (HOST page + OSD 240p)

**Worker:** W-t7-rca · **2026-08-13T21:36Z** · **NO FIT / NO play / NO menu.**
**T7 unique pfps still FAIL / unmeasured.** Soft-skip ≠ PASS. Chevron ≠ unique-24.
**FIT_GO=NO.** Do not authorize Quartus.

## What T7 did (cite only)

Play on live **`968b828a`** aborted before ffmpeg:

`sendSourceAspect: PLXJ ACK timeout want=16:9 token=1 last=4:3 token=0`

`play-file failed: source display aspect unavailable` · **PLAY_RC=1** · **0 frames** · pfps=**NONE**

Cite: `/tmp/misterplex-agent-W-t7-j.txt` · `/tmp/misterplexd.t7j.log`

## Class

**MIX** — primary **HOST** (ACK poll on 240p PLXJ page). **RASTER/OSD** selected that page (saved Display=240p → `DECODE=320x240`). **Not** fabric-copy. **Not** “silicon ACK’d 4:3”.

## Field decode

| Word | Bits | Value |
|------|------|--------|
| pair-2 PLXJ hi `0x2301402f` @ `0x3047F130` (W-lab-plxd 21:25:59Z, CORE=Plex) | X[11:0]=`0x02f` Y[11:0]=`0x014` token[7:0]=`0x23` | **47:20 token=35** |
| pair-1 leftover `0x2401402f` (MENU race; not live-Plex) | | 47:20 token=36 |
| T7 timeout `last=4:3 token=0` | `SourceAspectAck` default **or** stale 240p page | **≠** live 720p leftover |
| T7 `token=1` | `sourceAspectToken_+1` (baseline read 0 or token 0) | host never decoded 47:20 t=35 |
| OSD `0x6000` | O[15:14]=1 O[5:4]=0 | Display=**240p** Content=**240p** |
| play log `decode=320x240` | `outW_/outH_` at first OSD | 240p canvas |

`readSourceAspectAck` = `doorbell_phys+0x130`. Canvas 320×240 → doorbell **`0x3007F000`** → poll **`0x3007F130`**. L4 silicon publishes **`0x3047F130`**.

## Why `--decode 1280x720` did not stick

`main.cpp` parses CLI then **conf `DECODE` overwrites**. Live conf (RO 21:36Z, also W-display-j): **`DECODE=320x240` `DISPLAY_RES=240p` `CONTENT_RES=240p` `OSD_CONTROL=1`**.

Play-file path does **not** call `setDecodeSize(displayRes)` (that is companion `doPlay` only). `osdRetargetDecodeSizeFromPresented` **refuses to shrink** L4→240p — canvas was already 320×240 from conf.

## Hypotheses

| H | Verdict |
|---|---------|
| HOST: poll 240p PLXJ, miss L4 `0x3047F130` | **PASS** |
| HOST: `last=4:3 token=0` is live 968b828a 4:3 ACK | **FAIL** (L4 leftover is 47:20 t=35) |
| FABRIC-copy / PLXP caused abort | **FAIL** (0 frames; never present) |
| Aspect ingest dead on this netlist | **FAIL** as T7 cause (pair-2 PLXJ live). T7 did not prove ioctl-4 commit. |
| HDMI 640×480@59.9 caused ACK timeout | **FAIL** (mailbox, not PHY). **P4-DISPLAY** stays TODO. |
| OSD/conf 240p selected 240p layout | **PASS** (contributing) |

Contrast (do not merge): `J_480P_PLAY_REJECT.md` on same RBF with **decode=1280×720** was `want=47:20 token=35 last=token=34` — host **on** L4 page, token did not advance. Different class.

## Next (host-only)

Honor `--decode` after conf on play-file, **or** force L4 doorbell when scoring 720p24 T7. **FIT_GO=NO.** No second play this card.

21:36Z pin (this worker, RO): `/media/fat/_Utility/Plex.rbf` = **`07f54d9f`** (user restore). j kept `Plex.720p24.968b828a.rbf`. Supervise **24007** / misterplexd **24016** left **ALIVE**.
