# P4 closeout — software banks vs DRAM banks

**Status:** address-disjoint **HIT**; physical DRAM bank map **UNKNOWN** from in-tree sources.  
**Date:** 2026-07-31 (w-bw)  
**Rule 0:** no HPS DDRC `address_order` / BA bit map is quoted from this tree.

## What is known (quoted math)

Software frame banks (product ABI):

| software bank | phys (480p stride `0x80000`) | source |
|---------------|------------------------------|--------|
| 0 | `0x30000000` | `kDdrFramePhysBase` |
| 1 | `0x30080000` | base + `bank_stride` |

```
bank0 = 0x30000000
bank1 = 0x30000000 + 0x80000 = 0x30080000
XOR   = 0x00080000  → only PA bit 19 differs
```

For 320×240 product stride `0x40000`, bank1 = `0x30040000` → only PA bit 18 differs.

Therefore:

- The two software banks are **byte-address disjoint** (no overlapping payload ranges).
- They land in the **same DRAM bank** **iff** the HPS multiport DDR controller’s bank-select field does **not** include that differing PA bit (bit 19 @480p / bit 18 @240p) after any CS/byte-lane stripping.
- They land in **different DRAM banks** **iff** that bit is part of BA[] (or an equivalent hash into BA).

## What is NOT in this tree

Static search of `fpga/Plex_MiSTer/sys` and docs: **no** `address_order`, ROW/BANK/COL bit assignment, or Qsys HPS DDRC export that would settle BA for DE10-Nano / MiSTer HPS.

Generic Cyclone V TRM tables found on the public web are **not** cited as evidence for *this* image — board/Qsys config can remap.

**Verdict:** physical DRAM bank identity of `0x30000000` vs `0x30080000` is **unknowable from available in-repo docs**. Label remains **UNKNOWN**, not “same bank” and not “different bank”.

## Measurement that would settle it (parent-owned)

1. **Config evidence:** export or dump the running HPS DDR controller address-map (Qsys/`address_order`, or TRM register dump if the kernel/image exposes it). Quote BA bit positions vs PA.
2. **Behavioral A/B (weaker):** while FPGA scanout reads software bank 0, ARM writes software bank 1 vs bank 0 at sustained rate; compare `rd_miss` / underrun mailbox. A large same-bank penalty is *consistent with* BA collision but is **not** a proof of the map (could be interconnect pressure alone).

Until (1) or a decisive (2), do **not** claim bank conflict as a freeze or miss root cause.

## Relation to freeze (parent ERROR 13)

Parent withdrew the playback-freeze instrument (identical HDMI md5 on mostly-black content). Multiport BW negative still stands as a model; it is no longer attached to a freeze RCA.
