# starve_locus — where is supply_ratio starvation?

## Why (parent silicon, rk=9)

Same clip / core / daemon / conf, minutes apart:

| case | audio_s | wall_s | ratio | pfps | drops |
|------|--------:|-------:|------:|-----:|------:|
| COLLAPSED | 175.3 | 244.6 | **0.717** | 12.9 | 1030 |
| HEALTHY | 49.4 | 49.8 | **0.993** | 23.5 | 13 |
| HEALTHY | 162.6 | 166.4 | **0.977** | 23.1 | 49 |

`ok_min=0.90` (`DEFAULT_ASSUMED`) cleanly separates them via `supply_ratio`.

**Back-pressure is falsified** on the collapse (parent probes, not inference):

```
ffmpeg: 20× futex_wait / 1× do_sys_poll — ZERO pipe_write
misterplexd: wchan=pipe_read
recv_q=0 in 9/10 windows
PMS /transcode/sessions: speed=19.8 complete=1 throttled=1
~50 KB/s while lone curl gets 127 KB/s
```

So the old `starved_by_path|backpressure` dichotomy is **not** the default story
for this failure mode. `supply_regime` (FIONREAD fill) remains a useful pipe
probe; **locus** names transport vs consumer with the fuller probe set and keeps
**`starved_unknown` common** when probes are missing.

## Classes and gate rc

| `starve_locus` | condition | rc |
|----------------|-----------|---:|
| `ok` | supply_ratio ≥ ok_min | 0 |
| `starved_transport` | starved + consumer wait + producer **not** pipe_write + **measured** `recv_q=0` | **2** |
| `starved_consumer` | starved + (`pipe_write` **or** fill full **or** `recv_q>0`) | **3** |
| `starved_unknown` | starved, probes missing/partial/conflict — **COMMON, hard** | **4** |
| `NO-DATA` | supply_ratio not established | **77** |
| `SESSION_INVALID` | `session_epoch` / `process_epoch` / `pid` change or counter reset mid-window | **79** |

`rc=77` is never a pass. `starved_unknown` is **rc=4**, not 77.

Transport requires the **full triad**. Missing `recv_q` with only “pipe empty”
→ `starved_unknown`, never silently promoted to transport.

## Provenance

- `ok_min=0.90` → `DEFAULT_ASSUMED` unless conf/env override (`caller_supplied`).
- Missing probe → `NO-DATA`, never `0.0` (ERROR 17 discipline).
- `recv_q=0` is a **measured** zero only when the parent/script sampled it.

## Counters / free ledger

| field | meaning | reset (this tree) |
|-------|---------|-------------------|
| `drops` | **pacer Drop only** (`droppedFrames_.fetch_add` on `!present`) | play-path `:3009` |
| `publish_misses` | DDR/FPGA publish fail | play-path `:3010` |
| `residual` | `frames − presents − drops` | arithmetic each line |

`drops` never means “ffmpeg failed to produce” or “DDR miss”. Residual surfaces
the free gap (often equals `publish_misses` when those are the only non-presents).

**Session restart trap:** supervisor respawn re-zeroes counters and changes
`process_epoch`/`pid`. Scorer marks the window **`SESSION_INVALID` rc=79**
instead of a flattering rebuilt ratio.

## What the daemon emits vs parent probes

| signal | in-daemon media: | parent probe JSON |
|--------|------------------|-------------------|
| `supply_ratio` | yes (interval) | reconstructed from `audio_s`/`wall_s` if needed |
| `pipe_fill_peak` (FIONREAD) | yes → can yield consumer if full | optional |
| ffmpeg `pipe_write` wchan | **no** (needs `/proc` walk) | `ffmpeg_in_pipe_write` / `ffmpeg_wchan` |
| daemon `pipe_read` wchan | **no** | `daemon_in_pipe_read` / `daemon_wchan` |
| TCP `recv_q` | **no** (w-cpu-1 RCA owns deep socket) | `recv_q` measured int or omit |
| `sock_Bps` | no | optional print only |

So live `starve_locus=` on the device without parent probes is typically
`ok` / `starved_consumer` (full pipe) / **`starved_unknown`** — never a fake
transport claim. Full transport class needs the parent probe file.

## Host red-before-green (no device)

```bash
cd /path/to/MisterPlex   # or .worktrees/w-avsync-lane
make "$PWD/build/test_supply_starve_locus"
"$PWD/build/test_supply_starve_locus"; echo "true rc=$?"
# expect: PASS RED collapsed… unknown rc=4; transport triad rc=2; true rc=0

python3 tools/score_supply_starve.py --self-test; echo "true rc=$?"
# expect: PASS collapsed no-probe → unknown; +probes → transport; healthy ok;
#         respawn SESSION_INVALID; true rc=0
```

## Parent — one device command

During cast, capture log + optional probes, then:

```bash
# probes.json example (collapse shape):
# {
#   "ffmpeg_in_pipe_write": false,
#   "daemon_in_pipe_read": true,
#   "recv_q": 0,
#   "sock_Bps": 50000
# }

python3 tools/score_supply_starve.py /path/to/misterplexd.log \
  --probes /path/to/probes.json
echo "true rc=$?"
```

**Expected shapes:**

| situation | stdout class | `true rc` |
|-----------|--------------|----------:|
| healthy ratio ≥ 0.90 | `starve_locus=ok` | 0 |
| collapsed log only (no probes) | `starved_unknown` | **4** |
| collapsed + transport triad | `starved_transport` | **2** |
| collapsed + pipe_write/full/`recv_q>0` | `starved_consumer` | **3** |
| respawn mid-window | `SESSION_INVALID` | **79** |
| no media lines | `NO-DATA` | **77** |

## Coordination

- **w-cpu-1** owns Recv-Q / local-limiter RCA. This lane owns **production
  telemetry** that makes the regime visible; do not duplicate their root-cause
  instrumentation.
- Judder / inter-frame histogram remains **w-instr** (orthogonal to lipsync /
  supply).
