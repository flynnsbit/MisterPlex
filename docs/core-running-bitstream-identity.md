# Running bitstream identity — investigation + PLXC design

**Lane:** w-lint gate-integrity  
**Date:** 2026-07-31  
**Rule 0:** claims below are from quoted repo sources / host probes only. Device
re-measurement is parent-owned.

## Defect

`scripts/video_regression.sh` `verify_baseline()` md5s **on-disk** RBF files and
checks the **live daemon**. `/tmp/CORENAME` is `Plex` for every build. A mixed
state (SPI core loaded + DDR daemon live, or the reverse) can pass every
non-visual check. Parent-verified class: restore left daemon `e9f79de2` with
core `dfebf2bf` → green screen, `/resources=200`, `n_daemon=1`.

## Device interfaces (honest inventory)

| Interface | What it reports | Identifies *which* RBF? | Evidence in repo |
|---|---|---|---|
| `/tmp/CORENAME` | CONF_STR core name | **NO** — always `Plex` for Plex/Plex_v2/Plex_v3 | `scripts/plexctl.sh:37-43`, `host/libmisterplex/osd_control.hpp:10-11` |
| `/tmp/RBFNAME` | CONF_STR RBF label | **NO** — content also `Plex` | same; mtime **does** advance on reload |
| `/tmp/RBFNAME` **mtime** | reload event | Proves *a* load happened, not *which* file | `plexctl.sh load_core` |
| On-disk `md5sum …/Plex*.rbf` | file on SD | **NO** — file ≠ fabric | `video_regression.sh` pre-fix |
| `sysfs` `/sys/class/fpga_manager/*/state` | Linux FPGA manager | **Not used on MiSTer HPS path**; Main loads via `MiSTer_cmd`, not fpga-mgr | no MiSTerPlex consumer; treat as unavailable unless parent measures otherwise |
| Quartus USERCODE/CHIPID over lightweight bridge | silicon ID | **Not wired** in this core; would need HPS bridge + RTL | no code path found |
| PLXK @ doorbell+0 | doorbell magic `PLXK` | Family signal only (DDR control page present) | `mailbox_abi_spec.hpp` |
| PLXS @ doorbell+0x100 | status magic `PLXS` | Family / heartbeat, **not** build id | same |
| PLXD @ doorbell+0x128 | bank-release | DDR product path alive if magic+advancing `frames_done`; **not** RBF md5; residue can fake magic | parent bank forensics; `mailbox_abi_spec.hpp` |
| HDMI pixels | rendered output | Can catch mixed state **visually** — not a script hash gate | AGENTS.md who-tests |

**Conclusion:** today there is **no** device interface that returns the running
bitstream content hash. Name files are vacuous. Mtime is reload-only.
Mailboxes are family/liveness, not identity.

## Interim gate (landed without new fit)

1. **Running-core claim file** written **only** after a verified load
   (`RBFNAME` mtime advances), path:
   `/media/fat/misterplex/.running_core_claim`
   Fields: `version`, `md5`, `path`, `rbfname_mtime`, `source`.
2. Gate treats claim as authoritative **iff** `claim.rbfname_mtime == live
   RBFNAME mtime`. Stale/missing claim → **FAIL** (not skip).
3. **(core, daemon) pair table** — SPI baseline pins and DDR pins must match
   families. Mixed pair → **FAIL** even if HTTP is 200.
4. CORENAME/RBFNAME strings are logged and **never** used as identity.

## Durable design: PLXC build identity (rides next fit — do not open a slot)

### Address

Reuse frame-store control page (doorbell-relative), free slot after PLXD:

| Field | Value |
|---|---|
| Offset from `DOORBELL_PHYS` | `+0x130` |
| Product absolute (doorbell `0x300FF000`) | `0x300FF130` |
| Legacy example absolute | `0x3007F130` |
| Magic | `0x504C5843` (`PLXC`) |
| Width | 64-bit LE qword |

### Layout

```
[31:0]  magic     = 0x504C5843 "PLXC"
[63:32] build_id  = CORE_BUILD_STAMP (32-bit)
```

### RTL (precise enough to ride an existing fit)

1. Add to `host/libmisterplex/mailbox_abi_spec.hpp`:
   - `kPlxcOffset = 0x130u`
   - `kPlxcMagic = 0x504C5843u`
   - table entry + magic list (update invariant gate arrays).
2. Generate `fpga/Plex_MiSTer/rtl/core_build_stamp.vh` at promote time (not
   from RBF md5 — chicken/egg):
   ```systemverilog
   // Auto/manual stamp — must match assets/core_pair_pins.tsv build_id column.
   localparam [31:0] CORE_BUILD_STAMP = 32'hc538_2bee;
   ```
3. In `ddram_frame_rd.sv` (or the module that already publishes PLXS/PLXD into
   the control page), continuous publish:
   ```systemverilog
   `include "core_build_stamp.vh"
   localparam [31:0] PLXC_PHYS = DOORBELL_PHYS + 32'h130;
   // same DDR write path as PLXS:
   // wr_data <= {CORE_BUILD_STAMP, 32'h504C5843};
   // wr_addr <= PLXC_PHYS;
   ```
4. Do **not** put uniqueness in CONF_STR alone (still collapses to name `Plex`
   for Main). PLXC is the gate-readable identity.
5. Gate read (busybox):  
   `/usr/sbin/devmem 0x300FF130 32` → magic; `devmem 0x300FF134 32` → build_id  
   (or one 64-bit read if available). Compare to pair table.
6. Until PLXC ships, claim file remains mandatory; after PLXC ships, gate
   requires **claim.md5 family ↔ PLXC.build_id ↔ live daemon** all agree.

### Why not USERCODE

USERCODE needs JTAG/bridge plumbing Main does not expose to misterplexd today.
PLXC reuses the already-proven DDR mailbox path (`devmem` / daemon map).

## Pair pins (interim)

| family | core pin | daemon pin | role |
|---|---|---|---|
| spi | `dfebf2bfd08dd70b473b587dd7e81848` | `7cd10b4d…` / `50f4eb92…` / `3e2cbb98…` | daily SPI baseline |
| ddr | prefix `c5382bee` (full md5 TBD parent) | **CURRENT** `edc3a46b` · PREV rollback `e9f79de2` | DDR product pair (parent 2026-07-31 240p+480p pixels) |

Prefix match (≥8 hex) allowed only when full md5 not yet registered; prefer full.

## Soft-skip rule

Unknown core, missing claim, or unreadable identity → **rc=1 FAIL**, never
rc=77 skip and never PASS. Visual confirmation remains parent-only for pixel
correctness; this gate only refuses incoherent / unknown running core.
