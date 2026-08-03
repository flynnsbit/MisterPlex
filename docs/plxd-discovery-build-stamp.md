# PLXD discovery + build stamp (design)

## Why

Lab RBFs have used **two** PLXD placements:

| Lineage | PLXD phys | Evidence |
|---------|-----------|----------|
| main `ddr_frame_store` default | `0x3007F128` absolute | `ddr_frame_store.sv:27` |
| integ / doorbell-relative | `DOORBELL+0x128` → `0x300FF128` (product) or `0x3047F128` (Option-C) | integ `BANK_MAILBOX_PHYS = DOORBELL_PHYS + 32'h128` |
| SPI daily `Plex_v2` `dfebf2bf` | **no writer** | `docs/v2-video-baseline.md`: v0.2/v0.3 bitstreams have **no** `ddr_frame_store.sv` |

Hardcoding one address makes a live core look dead. RBF md5 alone does not encode the map.

## Runtime discovery (implemented)

Host: `host/libmisterplex/plxd_discover.hpp` + `FpgaSpi::readBankRelease` scan.

Candidates (preference order): ABI absolute → product doorbell+0x128 → Option-C+0x128 → ABI doorbell+0x128.

- **Positive:** first stable word with magic `0x504C5844` wins.
- **Negative:** no magic → discovery fails (no false LIVE).

Does **not** edit `mailbox_abi_spec.hpp` (w-mem).

## Build stamp (design only — no fit)

Goal: bitstream self-describes mailbox base so provenance never depends on tribal knowledge.

### Minimal proposal (one 64-bit word)

Publish **PLXZ** (or reuse unused diag slot) at a **fixed** absolute address that never moves across lineages — recommend **doorbell page is NOT fixed**; use:

`PHYS_BASE + 0x7F0F0` → **`0x3007F0F0`** as **ABI_MAP** anchor (absolute, main-stable hole between existing 0x3007F000-block and bank tails), **or** prefer publishing the map **inside the existing PLXS heartbeat word's reserved bits** if packing allows.

Cleaner dedicated word:

```
// ABI_MAP @ 0x3007F0F0 (FPGA→ARM, heartbeat with other mailboxes)
[31:0]  magic 0x504C5841 "PLXA"   // Address map / ABI
[39:32] abi_ver                   // bump on layout break
[47:40] flags                     // bit0=doorbell_relative_mailboxes
[63:48] doorbell_page_hi          // phys[31:16] of active doorbell page
// Second qword optional:
// plxd_off_from_doorbell[15:0] = 0x0128 when relative; 0xFFFF when absolute-only
// plxd_abs_lo[15:0] when absolute
```

ARM boot: if PLXA present → compute PLXD; else fall back to `discoverPlxdMailbox`.

### What would make RBF provenance knowable

1. Fit log + promote script write `releases/Plex_<md58>.json`:
   `{ "rbf_md5", "git_sha", "branch", "DDR_FRAME_STORE", "BANK_MAILBOX_PHYS", "DOORBELL_PHYS" }`
2. Same JSON embedded path listed in package `SHA256SUMS`.
3. Optional: `CORENAME`/user_io string carries `Plex-<sha8>-mboxA|R` (short).

Without (1)–(2), md5 `dfebf2bf` is only recoverable from docs/device state, not from the bitfile bits alone.

## PLXD publish without doorbell (module)

Verified on main: `bank_mbox_req` reset+heartbeat → WE @ `BANK_MAILBOX_PHYS` with no doorbell. See unit `test_plxd_discover` + prior `plxd_init` Verilator.
