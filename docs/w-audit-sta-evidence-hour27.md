# W-AUDIT hour27 STA evidence audit

Branch audited: `parent/integ-hour27` in `/home/flynnsbit/Projects/mp-wt-integ`.

## Raw findings

- Worktree was clean when first checked; later head observed by the audit script was `839d9cb` on `parent/integ-hour27`.
- Reported comparison artifacts exist and are real TimeQuest text reports:
  - WITH old cuts: `fpga/Plex_MiSTer/remote_out/wfit-hour27-b/Plex.sta.rpt`, md5 `648240255d3c285446ea6993f080cf8a`, first line `TimeQuest Timing Analyzer report for Plex`.
  - WITHOUT the three old cuts: `.copilot-logs/Plex.no_false_paths.sta.rpt`, md5 `e3a4fa39296f032b38c1abda6f6f9be3`, first line `TimeQuest Timing Analyzer report for Plex`.
- The parent-quoted numbers are present in those two reports:
  - WITH old cuts: setup `+0.185`, hold `+0.248`, recovery `+0.676`, removal `+0.902`, min pulse `+1.122`.
  - WITHOUT old cuts: setup `+0.185`, hold `+0.248`, recovery `+0.671`, removal `+0.902`, min pulse `+1.122`.
- The SDC used for `/home/flynnsbit/mplex-builds/wfit-hour27-b/Plex_MiSTer` did contain the three old active cuts:
  - line 26 `set_false_path -to [get_keepers {*ddr_arb|m1_want_s1}]`
  - line 34 `set_false_path -to [get_keepers {*ddr_arb|reset_s1}]`
  - line 85 `set_false_path -from [get_keepers {*ddr_frame_store*underrun_count[*]}] -to [get_keepers {*ddr_frame_store*frame_mbox_last[*]}]`
- The no-false-path rerun SDC at `/home/flynnsbit/mplex-builds/wfit-hour27-no-false-paths/Plex_MiSTer/Plex.sdc` removed those three cuts. It still had the two async FIFO pointer false paths, so "no_false_paths" means "without the three old challenged cuts", not literally zero false paths.
- The parent-quoted reports correspond to RBF md5 `3b1e84355f5fe4e7e137b70a841244fa`, not deploy candidate `fb4bad849ad2db782a5004ce5a3471ce`.
- Deploy candidate `fb4bad849ad2db782a5004ce5a3471ce` appears in later builds:
  - `wfit-hour27-sdc-b`: STA setup `+0.289`, hold `+0.245`, recovery `+0.375`, removal `+1.090`, min pulse `+1.122`, negative summary rows `0`.
  - `wfit-hour27-bdiag-b`: same STA numbers, negative summary rows `0`.
- The fb4bad `wfit-hour27-bdiag-b` SDC has all three challenged cuts converted to finite `set_max_delay` constraints, including the diagnostic path:
  - line 28 `set_max_delay -to [get_keepers {*ddr_arb|m1_want_s1}] 50.0`
  - line 36 `set_max_delay -to [get_keepers {*ddr_arb|reset_s1}] 50.0`
  - line 87 `set_max_delay -from [get_keepers {*ddr_frame_store*underrun_count[*]}] -to [get_keepers {*ddr_frame_store*frame_mbox_last[*]}] 50.0`
- The known bad baseline `slot11/Plex.sta.rpt` still shows setup `-2.137` and has `2` negative setup rows, proving the parser catches the historical failure.
- For both quoted reports and fb4bad reports, parsed summary coverage was `44` rows across Setup/Hold/Recovery/Removal/Minimum Pulse Width, with `0` negative slack rows and `0` negative TNS rows.
- All checked STA reports still list unconstrained IO paths: `Unconstrained Input Port Paths=14/14`, `Unconstrained Output Port Paths=103/103` or `104/104`; internal clocks are reported constrained (`Illegal Clocks=0`, `Unconstrained Clocks=0`).

## Interpretation

The original W-FIT quoted timing numbers are real but are for `wfit-hour27-b` (`3b1e8435`), not directly for the deploy RBF `fb4bad84`. The deploy RBF has its own later TimeQuest reports, and those are also timing-clean by summary rows with the three challenged cuts converted to finite max-delay constraints. The soft spots are naming/provenance clarity and the presence of unconstrained IO paths, not evidence of a hidden negative internal setup row in the reports I checked.

## Reproduction

```bash
scripts/w_audit_sta_evidence.py > build/w_audit_sta_evidence.log 2>&1
scripts/w_audit_postfit_decode_oracle.py --fit-rpt /home/flynnsbit/Projects/mp-wt-integ/fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt --expect-stub-root > build/w_audit_postfit_stub_ok.log 2>&1
scripts/w_audit_postfit_decode_oracle.py --fit-rpt /home/flynnsbit/Projects/mp-wt-integ/fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt --expect-core-root > build/w_audit_postfit_core_expected_red.log 2>&1
```

The final command is expected-red on the integration/display fit: it rejects because `decode_stub` is present and `h264_decode_core` is absent under `stream_path`.
