# PLXJ ACK path on slot720p24j (`968b828a`)

**Worker:** W-plxj-rtl. **RO RTL + j map.rpt.** ZERO Quartus / menu / play / poke.
**ACK_PATH=LIVE.** Soft-skip ≠ PASS. IDLE_SWAP ≠ aspect ACK. **FIT_GO=NO.**

Cite: `/tmp/misterplex-agent-W-plxj-rtl.txt` ·
`remote_out/slot720p24j/Plex.map.rpt` · `/tmp/misterplex-agent-W-lab-plxd.txt` ·
`J_480P_PLAY_REJECT.md` · `T7_PLAYFILE_OSD_720P.md`.

## Verdict

j **does** instance the PLXJ ACK path. T7 `last=4:3 token=0` is the **host
default** while polling **`0x3007F130`**. Fabric writes **`0x3047F130`**.

| Claim | Result |
|-------|--------|
| Ingest missing / pruned | **NO** — `aspect_inst` 90 ALM / 116 reg |
| Aspect ports 10030-undriven | **NO** — zero Warning 10030 on j |
| SPI-only (no mailbox) | **NO** — `ddr_frame_store` writes MAGIC_J |
| Wrong mailbox (T7) | **YES** — canvas 320×240 → 240p page |
| Silicon ever ACKed | **YES** — J_480P `47:20` tokens 34/35 on L4 |

## Module + clocks (token is host-supplied)

1. **`source_aspect_ingest`** `aspect_inst` — **`clk_sys` 20 MHz**. ioctl
   index 4, 9-byte `PLXA` (`0x41584C50`). One-cycle `aspect_commit`.
2. **`ddr_frame_store`** snapshot — **`clk_pix` 24 MHz** (`present_clk` under
   `PRESENT_CLK_PIX_PLL` + L4). Hold `{token,y,x}`, toggle CDC.
3. **`ddr_frame_store`** write — **`clk_ddr`**. `{hold, MAGIC_J}` to
   `ASPECT_MAILBOX_PHYS`.

j map.rpt parameter: `ASPECT_MAILBOX_PHYS = 0x3047F130` (doorbell `0x3047F000`).
No PLXJ heartbeat. Reset does not rewrite the word.

true480 keeps ingest and fstore on **`clk_sys`**. j samples the 1-cycle
`clk_sys` commit on **`clk_pix`** (20 vs 24 MHz, no stretcher). Residual
CDC — **not** undriven. Do not FIT_GO for that this tick.

`map.rpt` `commit Stuck at GND` is **`u_plxg_latch.commit`** (PLXG), not PLXJ.

## pair-2 `hi=0x2301402f`

`0x3047F130` lo=`0x504c584a` hi=`0x2301402f` → **DAR 47:20 token=35**.
Leftover cinema ACK (common[]), stable, **not** 4:3 token=0.
T7 `token=1` means that play never read this word.

## Host vs fabric (do not re-fit)

| Canvas | Host PLXJ |
|--------|-----------|
| 320×240 (T7 OSD `0x6000`) | `0x3007F130` |
| 640×480 | `0x300FF130` |
| **1280×720 L4** | **`0x3047F130`** |

Conf `DECODE` overwrites `--decode`. Next parent play: sidecar
`DECODE=1280x720` (`T7_SIDECAR_L4_CONF`). Do not lengthen 250 ms on the
wrong page. **FIT_GO=NO.**
