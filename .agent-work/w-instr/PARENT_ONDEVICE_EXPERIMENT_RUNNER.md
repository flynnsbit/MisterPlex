# PARENT — on-device self-validating experiment runner

branch: `w-instr-provenance`
SHA: (tip after commit)

## Why
Your 7-arm bitrate sweep failed four independent ways, all producing output that *looked* like data:
1. silent conf backup fail → empty ORIG_MD5
2. empty SSH arms printed as measurements
3. byte-offset windows spanning multi-session
4. no-op conf write indistinguishable from default wire bitrate

## Deliverable
| path | role |
|---|---|
| `tools/ondevice_experiment_runner.py` | on-device runner + host self-test |
| `tools/ondevice_experiment_launch.sh` | host scp + setsid nohup + poll COMPLETE only |
| `files/device-evidence/experiment_runner/example_bitrate_arms.json` | 7-arm WEAK_BITRATE example (edit cast key) |

## Exit codes
| rc | meaning |
|---|---|
| **0** | `EXPERIMENT_OK` — all arms VALID, `RESTORE_OK` |
| **4** | `ARMS_INVALID` — finished; ≥1 arm INVALID; conf restored (retryable) |
| **80** | `ABORT_USER_STATE` — backup/restore failed; conf at risk / not mutated |
| **77** | UNSCORED — never a pass |
| **2** | usage / self-test fail |

## Guarantees (quoted behaviour)
- Backup: `cp` then exists + md5==source or **ABORT before any conf write**
- Restore: md5 must equal recorded original → `RESTORE_OK` / `RESTORE_FAIL` loud
- Log isolation: `=== MiSTerPlexExperiment BEGIN/END arm_id=… token=… ===` markers (not byte offsets)
- VALID only if: conf key landed AND expect_wire token present AND single session (`maxVideoBitrate` unique, `measured=` unique, one PLAY/spawn)
- INVALID arms emit **no** `measurements` object values (empty dict)
- Absence → `empty_window NO-DATA`, never `ARM br=… -> `

## Host self-test (agent-verified)
```bash
python3 tools/ondevice_experiment_runner.py self-test; echo "true rc=$?"
```
Measured:
```
SELF_TEST conf_noop → INVALID rc=4 reason="conf_write_not_landed … want='1200' got='2000'"
SELF_TEST empty_window → INVALID rc=4 reason='empty_window NO-DATA …'
SELF_TEST multi_session → INVALID reason="multi_session maxVideoBitrate values=['2000', '397'] …"
SELF_TEST happy_path VALID rc=0
SELF_TEST backup_fail ABORT rc=80 conf_untouched
SELF_TEST_OK
true rc_self=0
```

## Device run (YOU only)
1. Edit `cast_cmd` in the spec: replace `REPLACE_PLEX_KEY` with a real `/library/metadata/N` (URL-encoded).
2. Confirm paths (`misterplex` vs `misterplex_v2`).
3. Launch:
```bash
SPEC=files/device-evidence/experiment_runner/example_bitrate_arms.json \
OUT_REMOTE=/media/fat/misterplex_v2/experiments/brsweep_$(date -u +%Y%m%dT%H%M%SZ) \
./tools/ondevice_experiment_launch.sh
# when COMPLETE:
# scp result.json locally; inspect arms[].status / reason / measurements
```
Or manual:
```bash
scp tools/ondevice_experiment_runner.py root@HOST:/media/fat/misterplex_v2/bin/
scp arms.json root@HOST:/media/fat/misterplex_v2/experiments/arms.json
ssh root@HOST 'mkdir -p OUT && setsid nohup python3 …/ondevice_experiment_runner.py run \
  --spec …/arms.json --out-dir OUT >OUT/runner.stdout 2>&1 < /dev/null & echo $!'
# poll: test -f OUT/COMPLETE && cat OUT/result.json
```

## Note on WEAK_BITRATE → maxVideoBitrate
Positive wire check requires the daemon to emit `maxVideoBitrate=<arm>` from the conf key you set. If your ladder uses a different conf key, set `conf_set` + `expect_wire` accordingly. A VALID arm is impossible if the independent variable never reaches the wire — that is intentional.

Agent does not touch the device.
