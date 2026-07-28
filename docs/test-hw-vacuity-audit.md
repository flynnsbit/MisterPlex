# Hardware test vacuity audit (W-GATE)

Base/tip audited: `72e2d2c959f44c838683977bf9cc67dd3471f690`.

Pre-registration, before the detailed audit: scope `27` hw scripts, predicted
`sound=9, vacuous=8, over-tight=0, unclassified/tooling=10`. Actual after
classifying every script: `sound=12, vacuous=15, over-tight=0`. The largest
miss was provenance: status/DDR scripts compared live hardware to current-source
expectations without proving the resident RBF was the expected bitstream.

## Findings fixed

| Probe | Problem | Fix | Evidence |
| --- | --- | --- | --- |
| F3/DDR current-source probes (`test_ddr_frame`, `test_f3_bitstream`, `test_f3_decode_stub`, `test_f3_sps`, `test_f3_slice_hdr`, `test_f3_mb0`, `test_f3_residual`, `test_f3_idct_mb0`) | They could score against any loaded Plex RBF, including the stale lab core. | Added `hw_require_expected_rbf_md5`; missing/mismatched `EXPECTED_RBF_MD5` is SKIP-NOT-PASS rc=77. | No expected: `SKIP-NOT-PASS test_f3_sps: EXPECTED_RBF_MD5/HW_EXPECTED_RBF_MD5 is required...` rc=77. Mismatch: `resident RBF md5 mismatch actual=aaaaaaaa... expected=bbbbbbbb...` rc=77. |
| `test_f3_residual` | `res_csum` mismatch was printed as a soft skip and exited 0. | `res_csum` unscored now exits 77. | Fake-status proof: `residual_rc=77`; `SKIP-NOT-PASS test_f3_residual: res_csum unscored (got 19, want 20/0x14)`. |
| `test_f3_idct_mb0` | Missing `recon_sig` was printed as pending while the script could still exit 0. | Missing `res_csum` or `recon_sig` now exits 77. | Fake-status proof: `idct_rc=77`; `SKIP-NOT-PASS test_f3_idct_mb0: recon_sig unscored; need 3.3l-2 paint RBF...`. |
| `test_fbar_fast` / `test_menu_osd` | Obsolete v2 menu cards could produce success-looking results on a v3 core. | Default to SKIP-NOT-PASS unless explicitly enabled for archaeology. | `fbar_rc=77`; `SKIP-NOT-PASS test_fbar_fast: obsolete v2 debug-menu card...`. `menu_osd_rc=77`; `SKIP-NOT-PASS test_menu_osd: obsolete v2 debug-menu card...`. |
| `run_menu_matrix.sh` | RBF deploy/provenance warning and per-row `SKIP` could still lead to process rc=0. | Resident md5/core mismatch is rc=77; any row `SKIP` is rc=77. | Static mutation shape: remote md5 mismatch routes through `hw_skip_not_pass`; skipped PAL/capture rows no longer fall through to `exit 0`. |
| `test_media_fb.sh` | The post-stop `fullScreenVideo` rejection used `grep -qv ... || true`, so the claimed guard was swallowed. | Explicit fail if stopped timeline still contains `fullScreenVideo`. | Mutation shape: a stopped XML containing `fullScreenVideo` now reaches `FAIL: stop retained fullScreenVideo...` and exits 1. |
| `test_soak.sh` | `SOAK_PROGRESS=1` only warned when timeline time did not advance. | Progress-required mode now returns a per-title failure. | Mutation shape: `t1<=t0` now logs `timeline did not advance` and returns 1. |
| `avsync_measure.py` / `avsync_rate.py` | Missing playback or insufficient flash/beep evidence could return JSON with no scoreable measurement. | Timeline-never-playing and insufficient-event paths are rc=77; absent capture remains rc=20. | Local no-capture proof: `measure_rc=20` and `rate_rc=20`; both print `NO_CAPTURE_DEVICE ... reason=absent`. |

## Scripts audited as sound after this pass

`test_bank_release_visual.sh` already had rc=77 for UNSCORED human/RBF paths;
`test_f3_visual_golden.sh` requires declared golden and RBF md5; live PMS scripts
return SKIP-NOT-PASS on missing credentials/tools; companion/daemon smoke tests
fail on missing HTTP/SSH evidence rather than printing PASS from absence. Retired
`test_fpga_push.sh` exits 2 and does not masquerade as a pass.

## Residual caveat

These are still hardware tests: without capture hardware or a matching resident
RBF they are intentionally unscoreable. The point of this pass is that
unscoreable now means non-zero, not green.
