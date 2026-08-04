# PREREG — DDR-resident DPB (w-nostub re-aim)

## (1) n=32 (parked M10K lane answer)

**INTENTIONAL** 16 display lines × 2 slot sets (disp+prep), not a broken `FRAME_LINES_16`.

| Quote | Meaning |
|--|--|
| `present_core.sv` `FRAME_LINES_16` → `FRAME_LINE_COUNT = 16` | QSF name means lines **per set** |
| `ddr_frame_store.sv` `LINE_SLOTS = LINE_COUNT * 2` | doubles to 32 RAM instances |
| `video_slot = (disp_buf ? SECOND_SET_BASE : 0) + vi` | beam set |
| `cur_base_idx` / `prep_base_idx` swap | fill set |

## (2) Gap list — existing `h264_dpb.sv` / `h264_dpb_ref_commit.sv`

| Item | Evidence | Gap |
|--|--|--|
| Memory-agnostic byte port | `h264_dpb.sv` `mem_we/waddr/wdata`, `mem_rd/raddr/rdata/rvalid` | Usable against DDR **if** a bridge supplies 1-cycle rvalid |
| On-chip binding | `h264_decode_skeleton.sv:309` `(* ram_style = "block" *) reg [7:0] dpb_mem [0:2*DPB_FRAME_BYTES-1]` | **Assumes on-chip** dual-frame buffer |
| decode_stub same | `decode_stub.sv` DPB_MEM on-chip | Dark silicon path under PRODUCT_NO_STUB |
| Only 2 banks | `h264_dpb_one_ref` `BANK0_BASE`/`BANK1_BASE` ping-pong | No multi-ref List0, no eviction |
| Relative bases | defaults `0` and `FRAME_BYTES` | Not product phys map (`0x30800000` DPB region) |
| Byte-serial MC fetch | 441+81+81 issues | No burst window cache; DDR/beat waste |
| ref_commit | wires deblock → `h264_dpb_one_ref` | Lifecycle OK; still on-chip mem ports |
| Uninstantiated fabric decode | parent p720probe1: zero `h264_*:instance` | Modules parse-only |

**Arithmetic (parent; verified):** 553×10240/8 = 707,840 B on-chip < one 720p I420 (1,382,400 B). DPB **cannot** be on-chip.

## (3) Design

### Address map (extends product layout; host↔RTL parity)

| Constant | Value |
|--|--|
| Present 720p banks | `0x30180000`, stride `0x180000`, Option-C end `0x30600000` |
| PL330 ABI | `0x30600000` .. `0x30781000` |
| **DPB base** | **`0x30800000`** |
| **Slots** | **5** (1 current + 4 short-term) |
| **Stride** | **`0x180000`** (same I420 packing as present) |
| **End** | **`0x30F80000`** |
| Y/U/V offsets | 0 / 921600 / 1152000 |

Sources: `host/libmisterplex/ddr_frame_layout.hpp` `kPlex720pDpb*`, `ddr_frame_layout_params.svh` `DDR_FRAME_720P_DPB_*`.

### Modules

| Module | Role |
|--|--|
| `h264_dpb_slot_mgr` | allocate / promote / List0 / oldest-evict |
| `h264_dpb_ddr_byte_bridge` | byte port ↔ 64b DDR + qword cache |
| `h264_dpb_ref_win_cache` | burst/sample fill 21×21+9×9 into M10K; stream to MC |
| `h264_dpb_ddr_top` | compose slot_mgr + one_ref + bridge; **exports** DDR master |

**Arbiter:** exported master only. Product attach = **w-mem m3** agreement (do not bolt onto arbiter3 alone).

### On-chip ref window cache M10K (layouts stated)

| RAM | Geometry | Legal pack | Blocks |
|--|--|--|--|
| `luma_mem` | 512 × 8 | 1K × 8 | **1** |
| `chroma_mem` | 256 × 8 (U@0, V@128) | 1K × 8 | **1** |
| **PREREG total** | | | **2 M10K** per active window |

vs naive on-chip full frame: impossible (see arithmetic).

FAULT `H264_DPB_DDR_FAULT_SMALL_WIN`: fill 16×16 only → qpel border wrong.

## (4) DDR bandwidth MODEL (not device-measured)

`DEVICE_BW_VERIFIED=0`. Coordinate with w-mem counters.

Assumptions for **model**:

- 720p24, ~3600 MB/frame (80×45), all P 16×16
- Per MB MC window: 441 Y + 81 U + 81 V = **603 useful B**
- With byte-serial DDR via qword cache: best case ~ceil(603/8)≈76 beats if perfect sequential; worst many seeks
- Ref-win cache path: ~21×ceil(21/8) + 2×9×ceil(9/8) ≈ 21×3 + 18×2 = **99 beats/MB** ≈ 792 B transferred / MB

| Model quantity | Value |
|--|--|
| Useful ref read | 603 B/MB × 3600 MB/s @24fps ≈ **52.1 MB/s** |
| Cache-fill transfer EST | 792 B/MB × 3600 × 24 ≈ **68.4 MB/s** |
| Recon write POST | 384 B/MB × 3600 × 24 ≈ **33.2 MB/s** |
| **Model decode DPB R+W** | **~100 MB/s** class |
| Ideal port math @90 MHz×8 B | 720 MB/s (**not** measured HPS BW) |
| Present 720p24 RD (arbiter3 comment) | ~33 MB/s |

**Honest:** if real device BW after present+bitstream is < ~150 MB/s headroom, fabric P-slice DPB contends. **UNKNOWN until w-mem counters on device.**

## (5) Controls

| Test | Expect |
|--|--|
| Slot List0 order + oldest evict | PASS |
| Byte bridge write then read exact | PASS |
| Ref win 21×21 matches DDR pattern | PASS |
| `FAULT_WRONG_EVICT` | newest dropped — negative OK |
| `FAULT_SMALL_WIN` | border mismatch — negative OK |

## PREREG fit impact

Not fitted this lane. Cache +2 M10K; slot mgr ALM small; bridge ALM small. Parent holds exclusive fit.
