# W-AUDIT handoff

## Identity / branch / commit

- Worker: W-AUDIT (adversarial verification)
- Worktree: `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-audit`
- Branch: `w-audit`
- Pre-handoff committed audit artifact: `1cab851 test(audit): report hour27 gate blind spots`
- Handoff commit: see branch tip after this file is committed.

## Assignment

Try to prove the fleet's green claims are wrong, with emphasis on "true number about the wrong thing" failures. I stayed read-mostly, did not run Quartus, did not deploy/load any RBF, and did not open `/dev/video0`.

## What is measured vs assumed

Measured:

- Current parent `scripts/check_rtl_module_instantiations.py` exits 0 with `rtl_modules=68 reachable=44 bench_only=24 root=emu`.
- Independent source graph on current parent says `stream_path` and `decode_stub` are reachable; `h264_decode_core`, `h264_decode_top`, `h264_deblock`, `h264_dpb`, and `h264_cavlc_residual_block` are not reachable from `emu` in the current parent tree.
- W-GATE snapshot with `DECODE_REAL_INTRA=1` reaches `h264_decode_top` and drops 14 real MC/DPB/deblock modules.
- Synthetic adversaries reproduced three reachability blind spots: files.qip omission false-reachable, parameter-generate false-reachable, and escaped-instance false-unreachable.
- `scripts/check_pipe_exit_safety.py` exits 0, but W-AUDIT hygiene found 51 broad unchecked status-sink pipelines and 31 masked narrow pipelines.
- 24 shell tests/scripts contain missing-simulator SKIP paths that can exit 0.
- `scripts/check_timing_exclusions.py --sdc fpga/Plex_MiSTer/Plex.sdc --baseline tests/fixtures/timing_exclusion_baseline.json` exits 0 without `--sta-rpt` while warning that STA coverage is omitted.
- W-SWAP livelock gate passed normally and failed under `DDR_FRAME_STORE_FAULT_PREP_INVALID_ONLY` naturally, with no hierarchical injection found in the bench.
- W-DEBLOCK seam snapshot passed with seam scope `2/1170` MBs and tap-direction scope one MB location; red-checks failed as intended.
- W-CAST syntax snapshot passed with `1170/1170` P MB coverage via `331` syntax groups: `928` skipped, `197` inter P16x16, `45` intra. Its `300/300` IDR denominator is a 320x240 fixture, not the 624x480 live clip.

Assumed / not measured:

- I did not compare against a Quartus post-fit hierarchy report; no new fit was run.
- I did not inspect HDMI or hardware display state.
- I did not prove actual STA slack; I only proved the text gate can pass without STA rows.
- I did not prove every pipeline hit is a bug; I proved the existing pipe checker is incomplete as an absence proof.

## Work products

Committed in `1cab851`:

- `docs/w-audit-hour27-report.txt` — prioritized adversarial report with raw numbers and repros.
- `scripts/w_audit_gate_hygiene.py` — read-only audit script for skip-zero, pipe blind spots, and synthetic reachability cases.

Validation run after adding the script:

```bash
python3 -m py_compile scripts/w_audit_gate_hygiene.py
python3 scripts/w_audit_gate_hygiene.py > build/w_audit_gate_hygiene_verify.log 2>&1
```

Summary output:

- `W_AUDIT_SKIP_EXIT0 count=24`
- `W_AUDIT_PIPE_BROAD_UNCHECKED count=51`
- `W_AUDIT_PIPE_MASKED_AFTER_NARROW_CHECK count=31`
- `W_AUDIT_SYNTHETIC_REACHABILITY_FINDINGS count=3`

## Exactly where I stopped

I finished the requested audit pass, committed artifacts, pushed `w-audit` twice, and then received the parent handoff-path correction. This handoff is the only new work after `1cab851`.

## What I tried that did NOT work / did not break

- Tried to make W-SWAP's livelock red artificial by inspecting for hierarchical forcing/poking. I found none: the bench drives top-level public inputs, reads debug outputs, and the fault run naturally stalls at `frames_done=2` with `swap_pending=1`.
- Tried to break W-DEBLOCK ordering. Its seam and tap-direction red-checks failed under injected faults as claimed. The weakness is scope (`2/1170` seam MBs; tap check one MB), not a broken assertion.
- Tried to break the QPc trap. It is honest: `QPy/QPc=40/36` substitution fails. Its limitation is that the real fixture QP range is `25..25`, so real content cannot catch QPy/QPc confusion.
- Tried to treat W-CAST `1170/1170` as false. It is not false for syntax walking, but it is easy to over-read: skipped MBs are covered by skip-run groups, not independent MB-layer RTL parses, and it is not reconstruction validation.

## Gates W-AUDIT owns / how to make each fail

- `scripts/w_audit_gate_hygiene.py`
  - Report-mode script exits 0 intentionally so it can be committed without failing the suite.
  - To see failures/risks, inspect nonzero counts in its output.
  - Synthetic reachability section fails conceptually when count is nonzero; it currently reports 3 known blind spots.
- `docs/w-audit-hour27-report.txt`
  - Static evidence report; no executable pass/fail.
- Existing gates audited:
  - `scripts/check_rtl_module_instantiations.py`: make it falsely green by defining a reachable child in tracked RTL but omitting it from `files.qip`; make it falsely reachable with a parameter-disabled generate branch; make it falsely unreachable with a legal escaped instance name.
  - `scripts/check_pipe_exit_safety.py`: make it falsely green with `cmd | awk ...` or with a `pipefail` file that deliberately masks a pipeline using `|| true`.
  - `scripts/check_timing_exclusions.py`: make SDC text audit green by omitting `--sta-rpt`; it will not enforce STA row coverage despite baseline expectations.

## Peer-to-peer interface contracts captured

- Decode lineage contract from parent ruling: `h264_decode_core` is supposed to be the product decoder; `h264_decode_top` is an intra-MB sub-engine; `decode_stub` is retired scaffolding. Audit finding: current parent still violates this contract (`stream_path -> decode_stub`, no `h264_decode_core` reachability).
- Deblock/DPB seam contract observed in W-DEBLOCK:
  - PRE-deblock samples feed intra neighbour context.
  - POST-deblock samples feed DPB/reference writes.
  - DPB reference promotion must wait until filtered writeback of terminal MB and then a frame boundary/ref-ready phase.
  - Current seam proof scope is `seam_committed_mbs=2/1170`; do not generalize it to full-frame ordering without expanding scope.
- QPc contract observed in W-DEBLOCK:
  - Chroma threshold/deblock paths must use QPc mapping, not QPy, and the real fixture QP=25 is insufficient to distinguish them; synthetic high-QP trap (`40/36`) owns that proof.
- CAVLC/syntax contract observed in W-CAST:
  - `1170/1170` means parser/walker macroblock address coverage for one 624x480 P frame, summarized by 331 syntax groups; it is not full reconstruction validation.
  - `300/300` means a separate 320x240 IDR fixture.
- Hardware/capture contract honored:
  - W-E2E owns `/dev/video0`; W-AUDIT did not open it.
  - No RBF deploy/load_core/Quartus work was performed.

## Most important unfinished item

Replace source-regex reachability as the sole product oracle with an elaboration-aware gate tied to the actual Quartus file list/post-fit hierarchy, and make it prove the architectural ruling: `emu -> stream_path -> h264_decode_core` is present while retired `decode_stub` is absent.
