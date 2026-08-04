# PRODUCT_NO_STUB — Path A enabler for 720p

## Product default
`Plex.qsf` sets `VERILOG_MACRO "PRODUCT_NO_STUB=1"`.
`stream_path.sv` gates `decode_stub` behind `` `ifndef PRODUCT_NO_STUB ``.
Product glass is `DDR_FRAME_STORE` doorbell / `has_frame` → `present_core` (untouched).

## Measured reclaim (fit with stub present)
Source: `output_files/Plex.fit.rpt` Fitter Resource Utilization by Entity
(device 5CSEBA6U23I7). Two independent derivations agree:

| Node | ALMs needed | M10K |
|------|------------:|-----:|
| `decode_stub:stub` | 6761.4 | **268** |
| `sys_top` | 21081.6 | 465 |
| Device | 21082 / 41910 (50%) | 465 / 553 (84%) |

Stub breakdown (same fit): `dpb_mem` 256 M10K + remainder 12 M10K.

## POST-STRIP prediction (pre-register before next fit)
| Metric | Prediction | Formula / control |
|--------|-----------:|-------------------|
| sys_top M10K blocks | **197** | 465 − 268 |
| decode_stub hierarchy rows | **0** | PRODUCT_NO_STUB strip |
| sys_top ALM (approx) | **~14320** | 21082 − 6761; packing may shift |
| Free M10K after strip | **~356** | 553 − 197 |

Falsify if post-fit `decode_stub` row remains or sys_top M10K ≉ 197 (± packing).

## 720p present linebuf budget (static)
| | M10K |
|--|-----:|
| 720p linebufs est | 192–197 |
| Without reclaim | margin **−13** (does not fit) |
| With reclaim | margin **~+255** |

Exact 720p linebuf M10K is ESTIMATE until a 720p fit.

## Shipping path control
- Prefit: `present_core`, `ddr_frame_store`, `stream_path` REACHABLE under PRODUCT_NO_STUB; `decode_stub` PRUNED tooth.
- `test_product_no_stub_active_static.py` GREEN when QSF macro ON + stream_path ifdef.
- DDR present write path / doorbell ABI unchanged by the strip.
