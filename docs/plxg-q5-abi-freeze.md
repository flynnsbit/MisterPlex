# PLXG q5 byte-exact layout (w-mem freeze publish for parent #4)

**Owner:** w-mem · **Sources quoted:** `host/libmisterplex/mailbox_abi_spec.hpp`,
`host/libmisterplex/plxg_record.hpp`, `fpga/Plex_MiSTer/rtl/present_geom_latch.sv`  
**Tip at publish:** `w-mem-720p-abi` (refresh with `git log -1 --oneline` after
merge). This is the **signing surface for freeze #4** — field table below is
byte-exact from source constants, not a paraphrase.  
**Purpose:** parent will not award `fps_1001` without this layout. Do not amend
bits without a signed freeze. Parent #4: **bit 34 stays RESERVED** today.

## Placement

| Symbol | Value | Source |
|--------|------:|--------|
| `kPlxgOffset` | `0x800` | `mailbox_abi_spec.hpp` |
| `kPlxgQ5Offset` | `0x828` | `kPlxgOffset + 5*8` |
| `kPlxgBytes` | `48` | 6 qwords |
| Exclusive end | `0x830` | |
| Magic | `0x504C5847` ("PLXG") | `kPlxgMagic` |
| Bootstrap phys | `0x300FF800` | doorbell `0x300FF000` + `0x800` |

Record is little-endian on the control page. Fabric poller always uses the
bootstrap page (chicken-egg with Option-C remap).

## Full 6-qword bit map (lockstep host pack ↔ latch shadow)

### q0 @ +0x800 — commit / seqlock head

From `plxg_record.hpp` `packPlxgQ0` and latch `sh0`:

| Bits | Field | Notes |
|-----:|-------|-------|
| 31:0 | magic | must be `0x504C5847` |
| 32 | win_enable | |
| 33 | geom_enable | |
| 47:34 | epoch (14b) | **0 illegal** (B4 ABA) |
| 63:48 | seq (16b) | |

Latch: `sh_magic=sh0[31:0]`, `sh_win=sh0[32]`, `sh_geom=sh0[33]`,
`sh_epoch=sh0[47:34]`, `sh_seq=sh0[63:48]`.

### q1 @ +0x808 — content window

| Bits | Field |
|-----:|-------|
| 10:0 | content_w |
| 26:16 | content_h |
| 42:32 | content_x0 |
| 58:48 | content_y0 |

### q2 @ +0x810 — DE canvas + coded storage

| Bits | Field |
|-----:|-------|
| 10:0 | h_de |
| 26:16 | v_de |
| 42:32 | coded_w |
| 58:48 | coded_h |

### q3 @ +0x818 — strides + display

| Bits | Field |
|-----:|-------|
| 11:0 | y_stride |
| 26:16 | chroma_stride |
| 42:32 | display_w |
| 58:48 | display_h |

### q4 @ +0x820 — present origin + crop

| Bits | Field |
|-----:|-------|
| 10:0 | present_x |
| 26:16 | present_y |
| 42:32 | crop_left |
| 58:48 | crop_top |

### q5 @ +0x828 — DAR + content_fps (**freeze surface**)

**Quoted from `mailbox_abi_spec.hpp` (not paraphrased):**

```
//   q5 @ +0x828  [11:0]  dar_x       [23:12] dar_y
//                [31:24] content_fps (integer family)
//                [32]    dar_valid   [33] fps_valid
//                [63:34] RESERVED must be 0 (parent #4: bit34 NOT fps_1001)
constexpr uint32_t kPlxgQ5Offset = kPlxgOffset + 5u * 8u; // 0x828
constexpr unsigned kPlxgQ5DarXShift = 0u;
constexpr unsigned kPlxgQ5DarXBits = 12u;
constexpr unsigned kPlxgQ5DarYShift = 12u;
constexpr unsigned kPlxgQ5DarYBits = 12u;
constexpr unsigned kPlxgQ5ContentFpsShift = 24u;
constexpr unsigned kPlxgQ5ContentFpsBits = 8u;
constexpr unsigned kPlxgQ5DarValidBit = 32u;
constexpr unsigned kPlxgQ5FpsValidBit = 33u;
constexpr unsigned kPlxgQ5ReservedLoBit = 34u; // inclusive; thru 63
constexpr unsigned kPlxgQ5ReservedBits = 30u;  // 63:34
constexpr bool kPlxgQ5Fps1001Awarded = false;
```

| Bits | Field | Width | Constant |
|-----:|-------|------:|----------|
| 11:0 | dar_x | 12 | `kPlxgQ5DarXShift=0` |
| 23:12 | dar_y | 12 | `kPlxgQ5DarYShift=12` |
| 31:24 | content_fps | 8 | integer family (24/25/30/…) |
| 32 | dar_valid | 1 | `kPlxgQ5DarValidBit` |
| 33 | fps_valid | 1 | `kPlxgQ5FpsValidBit` |
| **63:34** | **RESERVED** | **30** | `kPlxgQ5ReservedLoBit=34` |

**Receiver rule (quoted `present_geom_latch.sv`, load-bearing):**

```
// q5 reserved [63:34] must be zero (forward-compat trap).
wire        q5_reserved_nz = |sh5[63:34];
wire        q5_ok = !q5_reserved_nz;   // product (!FAULT_IGNORE_Q5_RESERVED)
// sticky observable: q5_reserved_reject (cleared only on good commit)
```

Host mirror (`plxg_record.hpp`): `plxgQ5ReservedOk(q5) == ((q5 >> 34) == 0)`.

Nonzero reserved → **entire commit rejected** (no live promote). Sticky
`q5_reserved_reject` is the diagnostic (PLXF E4 class). Cross-impl twin:
`PLXG_Q5_CROSS_IMPL_PACKED_WORD` in `test_ddr_720p_abi`. Gate
`PLXG_Q5_FREEZE_LAYOUT` asserts reserved=[63:34] from the same constants.

## Parent #4 status

| Item | State |
|------|--------|
| bit34 = fps_1001 ("#2.1") | **VACATED** — not on wire |
| `kPlxgQ5Fps1001Awarded` | `false` |
| reserved extent | **[63:34]** inclusive |
| first candidate bit for future award | **34** (still reserved until freeze) |
| landing rule | single-window: host pack → latch → top → beam/cadence → tests |

## Proposal (not implemented — needs parent rule)

Strict whole-record reject is correct default. Optional refinement after freeze:
on reserved violation, **hold last known-good live q5** and count
`q5_reserved_reject` instead of dropping DAR+FPS to 4:3/24. Do not land without
arbitration (graceful-hold vs fail-closed tradeoff).

## Related 720p map (parent-audited; guard these)

| Constant | Value |
|----------|------:|
| YUV420 frame | 1,382,400 B |
| bank stride | `0x180000` |
| base | `0x30180000` |
| doorbell | `0x3047F000` |

See `docs/p720-ddr-abi.md` + `ddr_frame_layout.hpp` / `.svh`.

## m_gnt note (w-osd R1)

On **w-mem** product `Plex.sv`, chrome is **not** hollow:

- `plex_chrome_ddr_loader.m_gnt(plxc_c_gnt)` ← `ddr_plxc_master_bridge`
- arbiter `ddr_bus_arbiter_plxc` m3 lowest prio, `STARVE_VIDEO=0`
- Verilator: `tests/unit/test_ddr_plxc_grant_verilator.sh` → **true rc=0**
  (`gnt_pulses>0`, `vid_underrun=0`; red twin starve underruns)

`m_gnt(1'b0)` on **w-osd** trees is intentional **HOLLOW** until that lane
adopts the bridge wiring (Plex.sv owner = w-osd; submit patch, no whole-file).
Not a TB artefact and not a stuck grant on the w-mem product path.
