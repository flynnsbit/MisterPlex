# Pre-fit `frame_underruns` baseline (parent runs on device)

**Agent does not touch the device.** Parent captures before T7 RBF and after.

## What to read

Product PLXF is **doorbell-relative**:

- Doorbell page: `0x300FF000` (`PLXK`)
- PLXF: **`0x300FF118`** = doorbell + `0x118`
- Magic LE32: `0x504C5846` (`PLXF`)
- Word layout (`input_mailbox.hpp` `decodeFrameStoreStatusWord`):
  - `[31:0]` magic
  - `[39:32]` seq
  - `[47:40]` debug_state
  - **`[63:48]` underrun_count** ← `frame_underruns` / present_core `stat_frame_underruns`

RTL: `present_core.sv` assigns `stat_frame_underruns = frame_underruns` from `ddr_frame_store.underrun_count` (line-miss path). T7 doubles unique Y fetches → this is the silicon falsifier for the BW model.

Legacy absolute `mailbox_abi_spec.hpp` `kPlxfAddr=0x3007F118` is **not** product — use doorbell-relative only (`fpga_spi.cpp` comment: product `0x300FF118`).

## Exact commands (parent)

### A. Via live daemon (preferred if PLXF already logged)

During / after a soak on **current** RBF (`c5382bee` pre-T7):

```bash
# On device or ssh — grep daemon log for frame_underrun / underrun=
ssh root@${MISTER_HOST:-192.168.1.183} 'grep -E "frame_underrun=|underrun=" /tmp/misterplexd.log | tail -20'
# Capture true rc on the host that ran ssh:
true; echo "true rc=$?"
```

Daemon path: `FpgaSpi::readFrameStoreStatus` → logs `frame_underrun=%u` (`fpga_spi.cpp` ~1530).

### B. Direct 64-bit PLXF peek (devmem / mem tool)

```bash
# 8 bytes at 0x300FF118 — print hex; underrun = bits [63:48]
ssh root@${MISTER_HOST:-192.168.1.183} 'devmem 0x300FF118 32; devmem 0x300FF11C 32'
# lo = magic expect 0x504C5846; hi[31:16] = underrun_count
true; echo "true rc=$?"
```

If `devmem` missing, use any existing mister mem util the lab already trusts — **do not** invent a new poke path mid-soak.

### C. Protocol for A/B attribution

| Step | Action |
|------|--------|
| 1 | Record RBF md5 + daemon md5 |
| 2 | Idle 30 s → sample PLXF underrun once (`U0`) |
| 3 | Cast same title ≥5 min steady → sample (`U1`) |
| 4 | `ΔU_pre = U1 - U0` (handle 16-bit wrap) |
| 5 | Deploy T7 RBF only (parent/w-fit); **same** daemon if possible |
| 6 | Repeat 2–4 → `ΔU_post` |
| 7 | **PASS model:** `ΔU_post ≈ ΔU_pre` (no new underrun rate). **REGRESS:** `ΔU_post ≫ ΔU_pre` |

Also log `publish_interval` disc_verdict + `p_ge50_steady` on the same soak (independent of underrun).

## Pre-register (before measuring)

- BW model claims full-frame fetch ≪ 180 MB/s residual → **expect ΔU rate ≈ 0** both pre and post if arbiter healthy.
- If pre already saturates underrun, T7 cannot be blamed for “new” underruns without a rate delta.

## Out of scope for agent

No ssh, no deploy, no Quartus from w-geom.
