# Phase 3 DPB / reference fetch budget

Scope: the proven Plex transcode profile is Baseline L3.0 with `max_num_ref_frames=1` and no B slices, so the FPGA decoder needs exactly one decoded reference picture and one current reconstruction target. This document intentionally does not design for general H.264 DPB reordering or multiple references.

## Layout

Reuse the ratified I420 frame layout:

- coded size: 624x480 = 39x30 = 1170 macroblocks
- Y: offset 0, stride 624, 299520 bytes
- U: offset 299520, stride 312, 74880 bytes
- V: offset 374400, stride 312, 74880 bytes
- frame bytes: 449280
- bank stride: `0x80000`

The DPB uses two banks in that same layout: one current reconstruction bank and one reference bank. At IDR, the reference bank is invalidated; after a reference picture is complete, current/reference roles swap.

## Access-pattern budget

Worst-case per inter macroblock:

- write reconstructed MB: Y 16x16 + U 8x8 + V 8x8 = 384 useful bytes
- fetch luma reference window: 21x21 = 441 useful bytes
- fetch chroma reference windows: U 9x9 + V 9x9 = 162 useful bytes
- total useful DPB traffic: 987 bytes/MB

At 1170 MB/frame and 25 fps:

- writes: 384 * 1170 * 25 = 11.23 MB/s
- reference reads: 603 * 1170 * 25 = 17.64 MB/s
- total useful traffic: 28.87 MB/s

Using 64-bit DDR beats and row-aligned line fetches:

- luma reference: 21 rows * up to 4 qwords = 84 qwords
- chroma reference: 2 planes * 9 rows * up to 2 qwords = 36 qwords
- MB write: Y 16 rows * 2 qwords + U/V 8 rows * 1 qword each = 48 qwords
- worst-case rounded traffic: 168 qwords/MB = 1344 bytes/MB = 39.31 MB/s at 25 fps

The per-MB time budget at 25 fps is 40 ms / 1170 = 34.2 us. At 142 MHz, 168 data beats consume 1.18 us of bus data time. Even with one command per row and a conservative 60-cycle service latency for each of the 48 row commands, command latency is ~20.3 us, leaving margin inside the per-MB budget. The practical lever remains outstanding row requests; if service latency rises above ~95 cycles for every row with no overlap, the design becomes marginal.

## Memory choice

Use HPS DDR3 first. The HPS DDR I420 path is byte-exact on hardware, has a known layout, and remains available if SDRAM controller bring-up slips. SDRAM is still attractive for isolating random reference reads from presentation line bursts, but the current budget closes on HPS DDR by a large margin and the daughterboard controller is not yet a trustworthy dependency. The DPB module is separate from `ddr_frame_store.sv` so a later SDRAM-backed implementation can keep the same write/fetch interface.

## Interface direction

The DPB owns:

- writing reconstructed macroblocks into the current bank using I420 addresses
- generating clamped reference-sample fetches for a requested MV-displaced partition
- returning bordered sample windows for luma/chroma interpolation

Motion-compensation arithmetic can consume either the bordered windows or a later interpolation wrapper. Edge clipping is normative: requests outside the coded picture replicate edge samples rather than wrapping or faulting.
