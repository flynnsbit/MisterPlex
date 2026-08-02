# RESULT — Why playback ~47 KB/s when path ~108 KB/s (w-cpu)

## Parent retraction accepted
"Delivered bitrate > link capacity" **does not survive** as the sole RCA:
path carries ~108 KB/s (SSH + concurrent bulk); playback alone ~47 KB/s leaves
~56% idle. PMS transcoder rate-matched static file (median ratio 1.005) —
transcoder-capacity **falsified**.

**Still true product defect:** default 480p request ~2000 kbit/s is far above
what this path sustains in real time. Floor hard-reject was removed in
`3fa5fab4` (advisory only); parent quote of `plex_resolve.cpp:338-339` hard
fail is **stale** on tip `w-cpu-fps-measure`.

## Contradiction: back-pressure vs Recv-Q empty

### What Recv-Q measures (kernel)
`Recv-Q` = bytes received on the socket **not yet copied to userspace**
(`rcv_nxt - copied_seq`). It is **not** "is the path busy" and **not**
"is ffmpeg blocked on stdout".

### Classic HTTP back-pressure chain (H-A)
present slow → rawvideo pipe fills → ffmpeg blocks on stdout write → stops
`read()` on HTTP → kernel `Recv-Q` fills → advertised rwnd → 0 → PMS stops.

**Sustained** empty Recv-Q (parent 8/8) is strong evidence ffmpeg **is still
draining the socket** (or the peer is not sending). It does **not** by itself
prove the present loop is innocent — but it **falsifies** the simple story
"we stopped reading HTTP and the window closed" **unless** pipe/wchan show
consumer BP with data already pulled into ffmpeg's demux/decode buffers.

### Quoted product chain (serial — source)
`arm/misterplexd/media_player.cpp` present loop (STREAM=0 product path):

1. `O_NONBLOCK` read rawvideo; on `EAGAIN` **sleep 2 ms** (lines ~3927–3976)
2. Assemble full frame (`frameBytes`, 449280 @ 624x480)
3. `avDecide` → `Hold` sleeps **2 ms** and loops; `Drop` skips present;
   else `presentCleanFrame` (DDR publish under `presentMu_`) (~3580–4214)
4. Pipe capacity raised via `F_SETPIPE_SZ` (`raw_video_pipe.hpp`, default 2 MiB
   ≈ 4.7 frames) so brief DDR spikes should **not** equal steady 47 KB/s cap

**Collapse regime clue (prior parent telemetry):** `av_drift_ms` **positive**
(video late) → `avDecide` prefers **Drop**, not long Hold. Drop **frees** the
consumer to read more frames. That makes pure pacer-Hold as the 47 KB/s cap
**unlikely** unless `presentCleanFrame`/read path is itself the bottleneck
and frame assemble rate is already ~13 fps (producer-limited raw output).

### How both observations can be true
| Observation | Compatible with |
|---|---|
| Recv-Q always 0 | App drains socket promptly; peer sends only ~47 KB/s **or** tiny rwnd always drained |
| Path spare 60 KB/s on 2nd conn | Limit is **per-connection or per-app**, not device-wide path |
| Playback 47 KB/s alone | Not filling cwnd/path — self-limited flow or app |

**H-A alone does not explain empty Recv-Q without pipe/wchan evidence.**
**H-B (per-conn rwnd/rcvbuf) and H-C (sender/app pace)** remain open.

## PRE_REGISTER (before parent run)

| Hyp | Instruments | Predict on collapsing rk=9 |
|---|---|---|
| **H-A** consumer BP | `pipe_bytes` FIONREAD, `ffmpeg_wchan` | majority `pipe_bytes≥449280` OR wchan `pipe_write`/`pipe_wait` |
| **H-B** per-conn rwnd | `rcv_space`, `rcv_ssthresh`, `tcp_rmem` | `rcv_space` small (&lt;64KiB) stable; pipe empty; wchan ≠ pipe; recv_q empty |
| **H-C** sender/app pace | same + `br_rate_Bps` | pipe empty; wchan ≠ pipe; recv_q empty; **rcv_space healthy/large**; rate ~47 KB/s |

**Lead prior to measure:** H-B or H-C (not H-A), because empty Recv-Q already
kills naive H-A. **Miss** if H-A wins via pipe full.

## Parent command (exact)

```sh
WT=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-cpu-fps-measure
# During LIVE collapsing rk=9 cast (wall_s advancing):
WINDOWS=10 WINDOW_S=2 sh "$WT/tools/playback_rate_limiter_probe.sh" \
  | tee /media/fat/misterplex_v2/limiter_probe_rk9.txt
echo "true rc=$?"

# Optional parallel (same collapse) — already have tools:
# sh "$WT/tools/pipe_backpressure_sample.sh"
# sh "$WT/tools/pms_recvq_backlog_sample.sh"
```

**Expected shapes:**
- `RESULT=H-A_…` + `pipe_hi_n` high → consumer BP (retract lead)
- `RESULT=H-B_…` + `rcv_space` small → per-conn window
- `RESULT=H-C_…` + large `rcv_space` + `pipe_zero_n` high → sender/app pace
- `RESULT=NO-DATA` / empty fields → **NO-DATA**, never invent 0

Also dump one raw socket line for audit:
```sh
FP=$(for d in /proc/[0-9]*; do
  e=$(readlink -f "$d/exe" 2>/dev/null) || continue
  case "$e" in *ffmpeg*) echo ${d#/proc/}; break;; esac
done)
ss -tinp | awk -v p="$FP" 'BEGIN{RS=""; ORS="\n\n"} $0 ~ ("pid=" p) {print; exit}'
echo "true rc=$?"
```

## Product note (unchanged urgency)
Even if H-B/H-C wins, requesting **2000 kbit/s** on a path that sustains
**~0.86–1.0 Mbit/s** remains wrong. Deploy `3fa5fab4`+: honor `WEAK_BITRATE`,
watch `supply_ratio` / `supply_class=STARVED`.
EOF
