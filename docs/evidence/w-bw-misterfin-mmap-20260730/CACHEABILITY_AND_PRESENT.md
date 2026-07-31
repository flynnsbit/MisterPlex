# ARM mmap cacheability + PRESENT regression note

## Product map (quoted)

`FpgaSpi::ensureDdrMap` (`arm/misterplexd/fpga_spi.cpp`):

- `open("/dev/mem", O_RDWR|O_CLOEXEC` + `O_SYNC` when `ddrMemSync_==true`)
- `mmap(..., PROT_READ|PROT_WRITE, MAP_SHARED, fd, phys_base)` with `phys_base=0x30000000`
- Defaults (`fpga_spi.hpp`): `ddrMemSync_=true`, `ddrMemFlush_=false`
- Hot path: `memcpy` + `__sync_synchronize()`; `cleanDcacheRange` only if `!ddrMemSync_ && ddrMemFlush_`

**Cache policy on device:** not asserted until parent runs `--matrix`. Pre-reg: **50–70 MiB/s** = uncached-class HIT; **≥800 MiB/s** = write-through-class HIT. MiSTerFin 60 MB/s vs 1.5 GB/s is **their** claim, not ours.

## If proposing a write-through route off `/dev/mem`

Any new mapping path **must** still open the FPGA present path when the Plex core is the HDMI sink.

`MediaPlayer::initPresent()` (`arm/misterplexd/media_player.cpp`):

- Product default `PRESENT=fpga`.
- Historical regression: `PRESENT=fb0` used to skip `fpga_.open()` → DDR frame store never repainted → frozen idle on core HDMI (user-reported twice).
- Current code forces `wantFpga = true` for every non-`none` PRESENT so core scanout still gets DDR paints.
- Product `PRESENT=fpga|both` still **requires** `fpgaOk` or init fails.

A WT/WC kernel driver mapping `0x30000000` must not reintroduce “fb0-only / skip FPGA open”. `PRESENT=none` remains decode-only lab.

## fb0 is not the frame store

`/dev/fb0` `smem_start` is a **different** physical range. Matrix case `fb0` is a **control** only. It cannot replace DDR present without a driver that maps the frame-store reserved range.
