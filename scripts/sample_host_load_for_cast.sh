#!/usr/bin/env bash
# Cheap host-load sampler for CBR-DP ladder casts.
# Run ALONGSIDE each cast on the PMS workstation (not on the MiSTer).
# Designed to be light: one sample / interval, no stress on Plex Transcoder.
#
# Usage:
#   ./scripts/sample_host_load_for_cast.sh [duration_s=130] [interval_s=2] [out_tsv]
# Example (parallel with a 120 s cast):
#   ./scripts/sample_host_load_for_cast.sh 130 2 .agent-work/hostload_rk108.tsv &
#   SAMPLE_PID=$!
#   # ... parent cast ...
#   wait $SAMPLE_PID
#   echo "sample true rc=$?"
#
# Columns (TSV):
#   ts_epoch  load1  load5  nproc  mem_avail_mb  plex_cpu_pct  plex_mem_pct  transcoder_procs  agent_cli_cpu_pct
#
set -euo pipefail
DUR="${1:-130}"
INT="${2:-2}"
OUT="${3:-hostload_$(date +%Y%m%dT%H%M%S).tsv}"
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true

echo -e "ts_epoch\tload1\tload5\tnproc\tmem_avail_mb\tplex_cpu_pct\tplex_mem_pct\ttranscoder_procs\tagent_cli_cpu_pct" >"$OUT"

end=$((SECONDS + DUR))
while (( SECONDS < end )); do
  ts=$(date +%s)
  # loadavg
  read -r load1 load5 _ < /proc/loadavg
  nproc=$(nproc)
  # MemAvailable kB → MB
  mem_avail_mb=$(awk '/MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo)
  # docker stats one-shot (Plex container). Quiet if docker missing.
  plex_cpu="NA"
  plex_mem="NA"
  if command -v docker >/dev/null 2>&1; then
    line=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemPerc}}' plex 2>/dev/null || true)
    if [[ -n "$line" ]]; then
      # Name CPU% Mem%
      plex_cpu=$(awk '{gsub(/%/,"",$2); print $2}' <<<"$line")
      plex_mem=$(awk '{gsub(/%/,"",$3); print $3}' <<<"$line")
    fi
  fi
  # count Plex Transcoder processes (host-visible). pgrep -c exits 1 when 0 matches.
  tc=$(pgrep -c -f 'Plex Transcoder' 2>/dev/null || true)
  tc=${tc:-0}
  tc=${tc//$'\n'/}
  # optional: heaviest copilot/cli-ish process CPU (best-effort, may be 0)
  agent_cpu=$(ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | awk 'NR>1 && ($2 ~ /node|copilot|claude|python|chrome/){printf "%s",$1; exit}')
  agent_cpu=${agent_cpu:-0}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$load1" "$load5" "$nproc" "$mem_avail_mb" "$plex_cpu" "$plex_mem" "$tc" "$agent_cpu" >>"$OUT"
  sleep "$INT"
done

# summary line to stderr (not the TSV)
python3 - "$OUT" <<'PY'
import sys, statistics
path = sys.argv[1]
rows = []
with open(path) as f:
    hdr = f.readline()
    for line in f:
        p = line.strip().split("\t")
        if len(p) < 9:
            continue
        try:
            rows.append({
                "load1": float(p[1]),
                "plex_cpu": float(p[5]) if p[5] != "NA" else None,
                "tc": int(float(p[7])),
            })
        except ValueError:
            pass
if not rows:
    print(f"hostload_summary file={path} n=0", file=sys.stderr)
    sys.exit(0)
loads = [r["load1"] for r in rows]
pcs = [r["plex_cpu"] for r in rows if r["plex_cpu"] is not None]
tcs = [r["tc"] for r in rows]
def pct(xs, q):
    xs = sorted(xs)
    if not xs: return float("nan")
    i = int(round((len(xs)-1)*q))
    return xs[i]
print(
    f"hostload_summary file={path} n={len(rows)} "
    f"load1_p50={pct(loads,0.5):.2f} load1_p95={pct(loads,0.95):.2f} "
    f"plex_cpu_p50={pct(pcs,0.5) if pcs else float('nan'):.1f} "
    f"plex_cpu_p95={pct(pcs,0.95) if pcs else float('nan'):.1f} "
    f"transcoder_procs_max={max(tcs) if tcs else 0} "
    f"transcoder_procs_any={int(any(t>0 for t in tcs))}",
    file=sys.stderr,
)
PY

echo "sample_done out=$OUT true rc=0"
