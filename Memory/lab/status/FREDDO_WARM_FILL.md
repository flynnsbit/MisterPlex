# FREDDO_WARM_FILL — product store after `0f5fa5ed` play

**User L57.** Not a mailbox loop.

## Play (measured)

RBF **`0f5fa5ed`** `0f5fa5ed8c541808b789d7d591c5d908` on `/media/fat/Plex.rbf`.
`PLAY_RAN=YES` `PLAY_RC=0` `MPX_STICK_I420=1` `copy_us=0` `fabric=stick`.

| | |
|--|--|
| frames / presented | 209 / **104** |
| pfps | **6.94** |
| drops | 104 |
| hw_fps | NONE |
| MAGIC_F @+0x118 | NO (peek after play still F@+0x110) |
| unique24 | **FAIL** |

Cite `/tmp/pfps-720p24-freddo-after-build.txt` + `/tmp/misterplexd.freddo-after-build.log`.
Stick path **works**. Same unique class as n16. **Not** parked-stick / n17–n28.

## Why 6.94

1312×762 blank is ~7.8%. Live `sdram_i420_store` only filled the stick when
`!rd_active`, and only issued HPS DDR DMA when `!rd_active`. 1.38 MB × 24
in that window needs ~425 MB/s. 16-bit stick cannot do it.

8 line buffers already isolate scan from the stick. Warm DE was going
`S_IDLE` and wasting the port. n13 fill-first (even when `need_*`) presented=0.
n14/n15 ratio knobs stayed blanking-only → 7.2 WASH.

## Product RTL (live store, not n14–n28)

Same handshake as Freddo `sdram.sv` (not `sdram_n7` BL=4).

1. **S_DECIDE:** fill dest bank unless `has_frame && need_*` (prefetch wins).
2. **S_WR_WAIT:** finish the qword; do not abort on DE.
3. **D_IDLE / D_BURST_ISS:** DDRAM **RD** during DE; mailbox **WE** blank-only (n3 hang).

n7 already had this policy on a different controller and was never the
product exclusive. Folded the *policy* into `sdram_i420_store.sv`.

## Small test then one exclusive

Host model `test_sdram_i420_store_sim`. Verilator `tests/unit/test_sdram_i420_store_verilator.sh` if present.
Then **one** `slot720p24freddo` refit. `SKIP_RESTORE=YES`. unique24=FAIL until that play.

Do **not** retarget MAGIC_F. Do **not** n29. BUILD_OK+DEPLOY ≠ unique-24.
