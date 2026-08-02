# PARENT CARD — locus480 LOCAL vs SUPPLY (within-run)

Branch: `w-instr-provenance`
Tool: `tools/locus480_local_vs_supply.py`
Folded: `tools/pms_recvq_backlog_sample.sh` + `tools/lib_live_misterplex_root.sh`
Ledger: `tools/daemon_media_ledger.py` (residual = frames − presents − drops)

## Pre-register (locked)

| hypothesis | recv_q in degrade | ffmpeg wchan |
|---|---|---|
| **LOCAL** | >0 sustained | `pipe_write` |
| **SUPPLY** | ~0 | not pipe_write; socket-readish / daemon `pipe_read` |

Healthy baseline on record: recv_q=0 9/10; zero pipe_write.
`supply_ratio` alone is a **VOID endpoint** (both loci predict the same ratio).

## Exit codes (w-avsync aligned)

| rc | verdict |
|----|---------|
| 0 | HEALTHY |
| 2 | SUPPLY_ESTABLISHED |
| 3 | LOCAL_ESTABLISHED |
| 4 | LOCUS_UNKNOWN |
| 78 | INSUFFICIENT_EVIDENCE |
| 79 | SESSION_INVALID |
| 77 | NO-DATA |

Absence → NO-DATA never 0.0. Negative counter delta → NO-DATA (never fake Mbit/s).

## ON DEVICE (you run; no SSH poll mid-run)

```sh
# During cast — writes LOCAL file only (fetch once at end)
python3 /path/to/locus480_local_vs_supply.py sample \
  --out /media/fat/misterplex_v2/locus480.jsonl \
  --interval 1 \
  --duration 300
# leave running full soak; Ctrl-C or duration ends
# echo true rc after it exits
echo "true rc=$?"
```

Optional parallel Recv-Q window tool (already in tree):
```sh
WINDOWS=30 WINDOW_S=1 sh tools/pms_recvq_backlog_sample.sh | tee /media/fat/misterplex_v2/recvq_win.txt
echo "true rc=$?"
```

Fetch **once**:
```sh
scp root@mister:/media/fat/misterplex_v2/locus480.jsonl ./locus480.jsonl
# optional: daemon log for ledger side-channel
scp root@mister:/media/fat/misterplex_v2/misterplexd.log ./daemon_media.txt
```

## ON HOST (after fetch)

```sh
python3 tools/locus480_local_vs_supply.py self-test
echo "true rc=$?"   # expect 0

python3 tools/locus480_local_vs_supply.py verdict --in ./locus480.jsonl
echo "true rc=$?"

# optional ledger fold
python3 tools/daemon_media_ledger.py ./daemon_media.txt
echo "true rc=$?"

python3 tools/locus480_local_vs_supply.py verdict \
  --in ./locus480.jsonl --media-log ./daemon_media.txt
echo "true rc=$?"
```

## First-class outputs
- `frac_near_zero` (+ n/den) on interval_vfps — your 0.063 vs 0.284 signal
- `recv_q_gt0_frac`, `ffmpeg_pipe_write_frac`, coverages
- `frames` / `presents` / `drops` / `residual` (closable or NO-DATA)
- interval supply mean (labelled measured); never sole locus

## RBG (this lane, true rc direct)

| case | VERDICT | rc |
|------|---------|-----|
| `--self-test` | SELF_TEST_OK | **0** |
| synth LOCAL | LOCAL_ESTABLISHED | **3** |
| synth SUPPLY | SUPPLY_ESTABLISHED | **2** |
| missing recv_q | INSUFFICIENT_EVIDENCE | **78** |
| epoch change | SESSION_INVALID | **79** |
| p480b ledger | LEDGER_OK residual=0 reconstructed | **0** |

Logs: `.agent-work/w-instr/locus_rbg/`

## What each JSONL sample carries (1 Hz, one mono clock `t_mono_ms`)
recv_q (ss -tinp, 0 is measured), ffmpeg+daemon wchan bundles, media: tail
(interval d_frames/d_wall/d_audio, residual when closable), rx_bytes (+bps or
NO-DATA on negative), system_busy + ffmpeg/daemon pct.

## Slice after the fact
Degraded seconds = interval_supply < 0.90 **or** interval_vfps < 1.0
(DEFAULT_ASSUMED thresholds; override with flags). Locus fractions computed
on degraded seconds when present.

Rule 0: agent does not touch device. You run sample on-device.
