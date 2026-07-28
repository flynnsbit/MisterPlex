# W-DECODE-O5 evidence bundle

Captured on branch `w-decode-o5` at commit `2429514` (before the handoff commit).
`build/` is gitignored, so the load-bearing lines are copied here verbatim.

| File | What it proves |
|---|---|
| `gate_results.txt` | 21 gates, exit code per gate, all `0`. No exit-77 skips. |
| `inst_all.txt` | `root=emu`: `product_reachable=47 diagnostic_roots=1 diagnostic_debt=2`. The gap vs `reachable=50` is the pruned `decode_stub` subtree. |
| `inst_core.txt` | `root=h264_decode_core`: `reachable=21`, all 8 `--require` modules `REQUIRED_RTL_MODULE_REACHABLE` from the **pruned** graph. |
| `seam.txt` | The headline finding: 29/53 core inputs constant-tied, 13/13 core outputs unobserved, `presentation_driver=decode_stub`. The core is instantiated but vacuous. |
| `qpel_equiv.txt` | `QPEL EQUIVALENCE PASS compares=20480` — the two independent quarter-pel implementations agree. |
| `qpel_red_block_perturbation.txt` | The matching red: dropping `avg2` rounding in `h264_luma_qpel_block_16x16` gives `mismatches=3542 compares=20480`, first mismatch at `frac=(1,0)`. Restored to rc=0 afterwards. |
| `cavlc_rbsp_wrap_red.txt` | The CAVLC 96-byte RBSP wrap red: `start_byte=64 ok=1 tc=0/5`. Note `ok=1` — the old code failed **silently**. |
| `rtllint_pre_existing_rc2.txt` | `make rtl-lint` rc=2 reproduced at `5105f02` with the working tree stashed, proving it was pre-existing and not introduced by the pps_parser change. |
| `p3_recon.txt` | Real-content end-to-end: `residual_csum=0x14 recon_sig=0x3b`. |

None of this is a claim that any frame was decoded and displayed. It was not.
