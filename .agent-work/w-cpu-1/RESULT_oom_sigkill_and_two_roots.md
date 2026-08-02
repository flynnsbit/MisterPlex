# OOM/SIGKILL probe + two-roots audit (w-cpu tools)

## Priority 2 — rc=137 (SIGKILL)

**Fact:** SIGKILL is uncatchable. `crashGuard` / `deathBreadcrumbOnSignal` **never run**. Death file for a pure 137 is **NO-DATA**, not proof of no kill.

**Candidate:** OOM-killer on 1 GB HPS RAM.

### Parent command (read-only)

```sh
cd /path/to/checkout   # or scp tools/ only
sh tools/oom_sigkill_probe.sh
echo "true rc=$?"
```

### PRE_REG

| Outcome | Meaning |
|---------|---------|
| `RESULT=HIT_OOM_EVIDENCE_IN_LOG` + lines naming `misterplexd`/`ffmpeg` | OOM implicated for at least one kill — **resource defect** |
| `RESULT=HIT_OOM_OTHER_PROCESS` | OOM happened; our name not in snippet — correlate timestamps manually |
| `RESULT=MISS_LOG_DOES_NOT_CONTAIN_OOM` | **log does not contain** OOM phrases — **not** “OOM never happened” (ring rotate) |
| `RESULT=NO-DATA` rc=77 | no readable dmesg/messages |

## Priority 3 — two-roots

**Trap:** `/media/fat/misterplex/` stale vs live `/media/fat/misterplex_v2/`.

### Fix shipped

| File | Change |
|------|--------|
| `tools/lib_live_misterplex_root.sh` | `readlink -f /proc/*/exe` → root; `caller_supplied` / `live_exe` / `FALLBACK_ASSUMED` / `NO-DATA` |
| `tools/daemon_exit_correlate.sh` | default ROOT via helper (no sole hardcoded v2) |
| `tools/pms_recvq_backlog_sample.sh` | log resolve via helper |
| `tools/oom_sigkill_probe.sh` | uses helper |
| `tests/unit/test_live_misterplex_root.sh` | host gate |

Hardcoded v2 remains only as **fallback after** live miss, labelled `FALLBACK_ASSUMED`.
