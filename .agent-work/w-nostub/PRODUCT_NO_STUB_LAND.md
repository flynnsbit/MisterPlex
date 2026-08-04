# PRODUCT_NO_STUB on main e40440ea

## .sv / .qsf changed
| File | Change |
|---|---|
| `rtl/stream_path.sv` | `ifdef PRODUCT_NO_STUB` strips `decode_stub`; ties wr/recon 0 |
| `rtl/plex_product_cfg.sv` | **NEW** fabric cfg stamp (no_stub + ddr_fs constants) |
| `rtl/decode_stub.sv` | DPB_AW-scaled index (kill hard-coded [17:0] alias) |
| `Plex.sv` | instance `u_product_cfg`, keep-chain fold-in |
| `Plex.qsf` | `PRODUCT_NO_STUB=1` product default |
| `files.qip` | add `plex_product_cfg.sv` |

## Reclaim (historical fit L7275; fit HELD)
268 M10K (256 dpb_mem) · 6761 ALM · 10736 ALUT · 5064 REG

720p present linebufs: margin **−13 without / +255 with** stub reclaim.

## Proof
define-parity rc=0 · rtl-lint rc=0 · product gate GREEN/RED · budget rc=0
