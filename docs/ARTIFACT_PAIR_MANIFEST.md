# Artifact pair manifest (RBF md5 ↔ daemon md5 ↔ commit)

**Fleet rule (parent 2026-08-01):** publish no measurement without the artifact
pair it was taken on. Judder / soak / CPU numbers without a version stamp are
not attributable.

## Required stamp line

Every scored measurement log must include:

```
ARTIFACT_PAIR label=<name> rbf_md5=<32hex> daemon_md5=<32hex> commit=<sha8>
```

Emit via:

```bash
source scripts/lib/artifact_pair.inc.sh
export ARTIFACT_PAIR_RBF_MD5=...   # device or claim freeze
export ARTIFACT_PAIR_DAEMON_MD5=... # live /proc/PID/exe md5
artifact_pair_stamp "soak-5min" || exit $?   # rc=77 if missing
artifact_pair_append_manifest .agent-work/w-lint/artifact_pair.jsonl
```

## Refuse

| Condition | rc |
|-----------|---:|
| missing rbf or daemon md5 | 77 UNSCORED |
| bad md5 shape | 2 FAIL |

`rc=0` without a stamp is a gate-integrity defect.

## Known lab pins (examples — always re-measure on device)

| Role | md5 prefix | notes |
|------|------------|-------|
| Daily DDR core (parent) | `c5382bee…` | 240-row ceiling ESTABLISHED on this RBF |
| Daemon example | `7c991e47…` | parent-restored healthy pin — re-md5 before cite |

Do not treat this table as live device state. Stamp from `/proc` + resident RBF.
