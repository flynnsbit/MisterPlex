# ebfe4a12 black idle — fabric swap gate (2026-08-13)

User set F12 Content=720p Display=720p (OSD `0xe020`). Conf `DECODE=1280x720`.
Still black.

**Not** a menu mismatch after that save.

`slot720p24h` / `Plex_720p24.qsf` has `FABRIC_DIRECT_READER=1`.
`ddr_frame_store.sv`:

```
fabric_allows_swap = fabric_copy_visible && (fabric_copy_token == db_token)
db_new_seq = fabric_allows_swap && …
```

A doorbell does **not** promote `has_frame` until the FPGA fabric reader
copies from System-RAM (PLXP) with a matching token. Host memcpy into
`0x30180000` with `MPX_FABRIC_DIRECT` OFF never produces that copy.

`present_core`: Pattern=None + `!has_frame` → **black**.

`17dd3b56` (slot720p24e) could show memcpy picture. **h cannot**, by
compile. First-kick SPI skip does not unblack h.

**Restamp 2026-08-13 (W-stale-gate / W-swap-rca2):** `fabric_allows_swap`
is still the gate. **fd=0** because fstore `fabric_copy_visible` /
`fabric_copy_token` are **undriven** (slot720p24h Warning **10030**).
See `FABRIC_HIER_UNDDRIVEN.md` + `/tmp/misterplex-agent-W-swap-rca2.txt`.

Lab **ebfe4a12** / lessons default **PLXP=`0x3047F138`** — **not**
fit-tree `0x3047F200`. Host dual-write +0x138/+0x200 is a hedge, not
this RBF's miss.

Live 13881 poke src **`0x04100000` legal MATCH** (W-plxp-re2 +
W-maps-13881). `0x01200000` UNMAPPED is **historical 10420 only**
(`POKE_SEEN_WRONG_SRC.md`); **INVERTED** on 13881.

PLXK host token `0xa0001733`..`0xa0001747` **SOURCE_CONTRACT MATCH**
(W-token-ro). **LIVE_LATCH unknown.** **FABRIC_PASS=NO.** Soft-skip ≠
PASS. CARD_OK ≠ FABRIC_PASS.

Fix is RTL **clk_ddr ports** + **NEW RBF** (parent exclusive). Not
another poke / bounce / W-flag-off. Do **not** kill 13881/13872.
**P4-DISPLAY / P4-720P-MIX stay TODO.** No RGB565.
