# Build a product path — not experiment loops

**User 2026-08-14 (standing).** Also **L57**.

## Rule

Do **not** run increment loops (`n17`–`n28` MAGIC_F / WE-ADDR / QSF retiming /
PHYS+8) unless we are at the **end** and only need a few frames.

Write FPGA that looks correct. Use MiSTer-devel cores and this repo’s own
stick store to learn what works and where the 16-bit stick can be pushed.
Validate with a **small synth or on-box test**, then play on the MiSTer
(`192.168.1.183`). One exclusive of a real design. Soft-skip ≠ PASS.

## What “stick parked” means

`DDR_FRAME_STORE` without `SDRAM_I420_STORE` ties `SDRAM_*` off in `Plex.sv`
(`nCS=1`, `CKE=0`, `CLK=0`). The module is in the board; the bitstream does
not use it. Frames then come from HPS DDR3. That is **not** Freddo.

## Freddo / L56 (already the architecture)

- I420 in VRAM; RGB only on the beam (`PLEX_STORE_YUV_PIPE`).
- Scanout on the stick; ARM/DDR produce frames; FPGA DMA into a back buffer.
- Time-mux: scan during active (~33 MB/s); DMA only in blanking.
- Do not scan+fill as 66 MB/s. Tight 1312×762 porches are hostile.
- After a faster blit, re-measure A/V. Idle is a real YUV frame.

The module is `rtl/sdram_i420_store.sv` (not n14–n16 fill-ratio forks).
Product exclusive **`slot720p24freddo`** wires that path: `SDRAM_I420_STORE=1`,
no `FABRIC_NO_MOVER`, no `FABRIC_DIRECT_READER`, host `MPX_STICK_I420=1`.
RBF **`0f5fa5ed`** (`0f5fa5ed8c541808b789d7d591c5d908`) **BUILD_OK+TIMING_OK**
HDMI **+0.534** clk_ddr **+3.097**. unique24=**FAIL** until ONE play measures.

## What is not a product core (do not claim)

| RBF | Chevron | Video | Stick |
|-----|---------|-------|-------|
| j `968b828a` | yes | 14.1 unique | parked / DDR3 |
| n14 `00f36ca0` | not scored | 7.23, 108 presented | silicon yes; that play `memcpy` |
| n28 `c1d74e7a` | no | presented=0 | parked |
| true480 `07f54d9f` | yes | yes | yes, **480p** |

## Lab

Leave 720p on `/media/fat/Plex.rbf` (`SKIP_RESTORE=YES`). true480 bak stays
`_Utility/Plex.true480.07f54d9f.rbf`. No `/bin/fpga`. No MAGIC_F loosen to
`+0x110`. BUILD_OK+DEPLOY ≠ unique-24.
