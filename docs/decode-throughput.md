# Decode throughput budget

This note is a realtime ratchet for the FPGA decode path. It deliberately
separates measured cost from unknown future cost; unknown stages are not counted
as free.

## Declared assumptions

| Parameter | Value | Source |
| --- | ---:| --- |
| Target frame rate | 25 fps | PMS 480p stream target |
| 480p coded geometry | 624×480 = 39×30 MBs = 1170 MB/frame | SPS/profile contract |
| `stream_path` clock | 20.000 MHz | `pll_0002.v` `outclk_0`; `Plex.sv` connects `stream_path.clk(clk_sys)` |
| SDRAM clock | selectable, default 100 MHz; `SDRAM_CLK_142` makes `clk_sdram` 142 MHz | `Plex.sv`/PLL |

The decode pipeline is clocked by `clk_sys`, not `clk_sdram`. Therefore the
480p realtime budget is:

```
1170 MB/frame × 25 fps = 29,250 MB/s
20,000,000 cycles/s ÷ 25 fps = 800,000 cycles/frame
800,000 cycles/frame ÷ 1170 MB/frame = 683.761 cycles/MB
```

## Raw measured cycle counts

Measured with Verilator 5.051 using the existing
`tests/unit/test_stream_path_full_frame_compare.sh` harness. The authoritative
cycle source is `build/p3_full_frame/frame_planes_compare.json` field
`summary.cycles`; this is full testbench time from reset/byte injection through
diagnostic frame output. It is not a native decode-quality metric and has no
stage breakdown. `build/p3_full_frame/native_frame_score.json` is the companion
quality scoreboard and has no cycle fields.

| Fixture | Frames | Geometry | Total cycles | cycles/frame | cycles/MB | Budget cycles/MB | Margin |
| --- | ---:| --- | ---:| ---:| ---:| ---:| ---:|
| `plex_inter_p16_baseline_320x240_12f.264` | 12 | 20×15 MB | 969,210 | 80,767.500 | 269.225 | 2,666.667 | 9.905× |
| `wcap_residual14_idr_plus_p.264` | 2 | 20×15 MB | 160,095 | 80,047.500 | 266.825 | 2,666.667 | 9.994× |
| `plex_inter_p16_baseline_624x480_12f.264` | 12 | 39×30 MB | 3,641,853 | 303,487.750 | 259.391 | 683.761 | 2.636× |

Additional raw integration signal:

| Harness | Raw signal | Value | Meaning |
| --- | --- | ---:| --- |
| `test_stream_path_deblock_integration.sh` on `wcap_residual14_idr_plus_p.264` | `recon_sig_3b_cycles` | 16,523 | deblock/stream integration liveness counter, not a per-stage cycle cost |
| `test_h264_multinal_stream_path.sh` 320×240 12f fixture | `recon_sig_3b_cycles` / `cycles` | 39,780 / 55,319 | P-slice DPB/MC liveness context from w-cabac; not full-frame P quality and not a stage cost |

## Stage coverage

| Stage | Status | Current measured cost |
| --- | --- | ---:|
| Aggregate current `stream_path` simulation | measured | 259.391 cycles/MB at 624×480 |
| Annex-B/SPS/PPS/slice parse | included in aggregate | no separate counter |
| CAVLC/dequant/IDCT/intra prediction | included in aggregate for implemented I path | no separate counter |
| MC/DPB fetch for correct P-slices | **UNKNOWN** | not yet bit-exact in this branch |
| Deblock cost | **UNKNOWN** | liveness tested, no per-frame cost counter |
| Product DDR writeback/present arbitration | **UNKNOWN** | current full-frame sim emits diagnostic RGB/I420 comparison, not full product arbitration |

Do not use stale `build/p3_full_frame_624/native_score_624.json` artifacts if
present. The full-frame candidate stream is `I420_FROM_RGB565` diagnostic output;
the cycle number is useful, but its pixel quality is not native-I420 evidence.

## DDR bandwidth

The current DPB fetch/write shape on w-rel's branch issues:

- MC reference fetch: 441 luma + 81 U + 81 V = **603 reads/MB**.
- Filtered/current writeback: 256 luma + 64 U + 64 V = **384 writes/MB**.
- Total DPB traffic: **987 B/MB**.

At 29,250 MB/s:

```
987 B/MB × 29,250 MB/s = 28,869,750 B/s = 28.87 MB/s
```

The display frame store also consumes one 624×480 I420 frame per presented
frame:

```
624×480×1.5×25 = 11,232,000 B/s = 11.23 MB/s
```

The 624×480 12-frame fixture is 70,348 bytes, or 146,558 B/s at 25 fps. Even
doubling that for compressed bitstream write/read is less than 0.30 MB/s.

Known modelled traffic is therefore about **40.4 MB/s** before refresh/arbitration
losses. Raw bandwidth should be enough, but this is not a pass: the bitstream
reader, DPB, and frame store contend for the same `DDRAM_*` path, and the live
PLXF-missing fault means arbitration/liveness remains a first-class risk.

## Verdict

**MARGINAL.** The current 480p aggregate path measures 259.391 cycles/MB against
a 683.761 cycles/MB 20 MHz budget, leaving 2.636× headroom. That is encouraging,
but not a FEASIBLE verdict because the remaining P-slice correctness path,
deblock cost, and product DDR arbitration are still UNKNOWN. Treat any missing
stage as a named gap, not as zero cost.

## Ratchet

`tools/check_decode_throughput.py` consumes the existing full-frame comparison
JSON and a `misterplex.decode_throughput_ratchet.v1` manifest. The full-frame
RTL gate now writes a separate report under `build/realtime_throughput/` for
known fixtures, copying run label, fixture source, and geometry into the JSON.
`tests/unit/test_decode_throughput_gate.sh` proves RED by lowering the cycle and
margin thresholds.
