# RESULT — PMS supply is NOT the throughput limiter (MEASURED, closes a standing inference)

Parent-measured on device 192.168.1.183. Session liveness gated on daemon `wall_s` advancing
for every reported number.

## 1. The instrument w-cpu-1 shipped was VOID — fourth void endpoint this session

`tools/pms_arrival_rate_sample.sh` scores ffmpeg's `/proc/<pid>/io` **`rchar`** B/s against a
nominal. Run on a live cast it returned:

```
sample=1..12  d_rchar=0  rchar_Bps=0.0  ratio_vs_nominal=0.000  class=STALL_LT_0_4X
SUMMARY ok_n=12 avg_ratio=0.000 pace_1x_n=0 stall_lt_0_4x_n=12
```

### Why it is void (measured, not inferred)
Cumulative counters for the same ffmpeg during a healthy 480p session:

```
rchar: 1037        wchar: 414442429
syscr: 5           syscw: 14545
```

**ffmpeg made FIVE `read()` syscalls in its entire lifetime while writing 414 MB.** Its HTTP
input arrives via `recv()` on a socket, which does not increment `rchar` on this kernel.
`rchar` is **structurally blind** to PMS supply.

**This is worse than a no-answer.** The endpoint did not fail to discriminate — it returned a
confident *defect* verdict (`STALL_LT_0_4X` on 12/12 windows) for a stream that was provably
healthy (`vfps 23.9`, `av-lock`, `drops=3` flat). A blind instrument that reports FAIL is the
mirror of the blind-and-green class, and it would have sent lanes chasing a nonexistent stall.

The `NOMINAL_BPS=57000` constant was also never measured for this asset — scoring a ratio
against an assumed nominal repeats ERROR 17 (a hardcoded constant inside an instrument printed
alongside real values).

## 2. The valid observable: per-socket `bytes_received` + `Recv-Q`

`/usr/sbin/ss` IS present on the device. ffmpeg's **fd 5 → `socket:[…]`** is the PMS connection.
Match by `pid=` **and** `fd=5` (never by name).

```
ESTAB Recv-Q 485187  192.168.1.183:50346 -> 192.168.1.24:32400 users:(("ffmpeg",pid=13172,fd=5))
      bytes_received:1835283 ... rcv_ssthresh:180248 app_limited
```

## 3. THE MEASUREMENT — ffmpeg is never input-starved

10 samples / 2 s apart, session live throughout (`frames=5707`, `wall_s=238.4`, `av-lock`):

| sample | Recv-Q (unread bytes) | bytes_received |
|---|---|---|
| s0 | 494,010 | 2,442,203 |
| s1–s3 | 484,065 | 2,489,611 |
| s4–s6 | 497,160 | 2,568,251 |
| s7–s9 | 482,895 | 2,619,531 |

**`Recv-Q` NEVER drops below 482,895 bytes.** There is permanently ~0.5 MB of already-delivered,
**unread** data queued in the kernel for ffmpeg.

### Conclusion (falsifying direction)
**PMS supply cannot be what pins throughput at ~24 fps.** The data is already on the device
ahead of demand. The standing item *"PMS supply rate is inferred, not measured"* is now
**MEASURED, and the supply hypothesis is RETIRED.**

Arrival is bursty (~50–78 KB every ~6 s) with `Recv-Q` pinned near the buffer ceiling and
`app_limited` set — the signature of a receive window held nearly closed **because our
application is not draining it**. The sender is throttled by us, not the reverse. This is
consistent with back-pressure propagating from the display pacer through the raw pipe into
ffmpeg and out to TCP, but the back-pressure *chain* is a model, not a measurement; only the
"never starved" conclusion is measured here.

## 4. Correct method for any future supply claim
- Resolve ffmpeg by `readlink -f /proc/<pid>/exe` (ERROR 14).
- Take the socket from `/proc/<pid>/fd/5`; read `ss -tinp` matched on `pid=` and `fd=5`.
- Score on **`Recv-Q` backlog**, which needs no assumed nominal. Backlog > 0 sustained ⇒
  not supply-limited. Do **not** score a ratio against a guessed `NOMINAL_BPS`.
- Gate every window on daemon `wall_s` advancing; absence of ffmpeg is NO-DATA, never 0.0.
