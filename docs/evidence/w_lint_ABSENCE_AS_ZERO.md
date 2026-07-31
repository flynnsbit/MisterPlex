# Absence-as-zero family (w-lint)

## Rule
An absence of evidence must not be encoded as a measured value.
Three outcomes: measured-value, measured-absence, could-not-measure.

## Instances fixed
| Site | Defect | Fix |
|------|--------|-----|
| `build_rbf_remote.sh` STA | `grep -c \|\| true` → 0 neg slack if report missing | `measure_sta_neg_slack` / hard fail rc=4 |
| `plexctl` / `misterplexd_supervise` trap | TERM → `exit 0` silent disarm | exit 143/130 + SUPERVISE_SIGNAL |
| `measure_c2_pixel_path.sh` | `grep -c \|\| echo 0` | NO_DATA when log absent |
| `pidof misterplexd` call sites | false process identity | `/proc/PID/exe` basename (deleted-tolerant) |

## Primitive
`scripts/lib/measure_status.inc.sh` — shell cousin of Python UNSCORED.
