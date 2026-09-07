# Prebuilt candidate deployment (explicit approval only)

This is **deployment readiness**, not Plex cast, picture, cadence, audio, or
mode acceptance. This document grants no artifact approval. A missing or failed
fit/timing result disqualifies an RBF from a deployment manifest, even when an
RBF was produced. Quartus execution remains coordinator-owned.

## Source-only A/V service trace

`MPX_FPGA_AV_TRACE` defaults to **0**. The daemon-only Make hook accepts exactly
`ARM_PLEXD_AV_TRACE=0|1`; it adds no configuration, launch argument, deployment
allowlist entry, or playback policy. For separately approved diagnostic builds:

```sh
make -j1 arm-plexd-daemon ARM_PLEXD_AV_TRACE=1 \
  ARM_PLEXD_OUTPUT=build/arm/av-service-trace/misterplexd.debug
```

With the default, trace types, storage, pressure mirrors, clock reads and logging
are preprocessed away. With tracing enabled, each compressed FPGA worker
allocates one numeric collector before starting its audio/overlay workers.
Allocation failure leaves playback policy unchanged and is reported after
retirement. Existing workers share its lifetime; each registers a thread-local
writer. There are no new threads, hot-path allocations/formatting/I/O, mutexes,
device reads, sleeps, queue limits, rate changes, or scheduling decisions.
Existing PCM/transport/overlay operations retain their locks and ordering.

The collector retains at most8192 audio,8192 video and256 overlay records:
16640 rows,200 bytes each,3,328,320 bytes including collector metadata on the
tested host ABI. It uses lock-free atomics, not hidden mutex-backed atomics.
Fast events sample at5ms; waits at20ms. Changed outcome/wait-reason values,
spans at least1ms, and explicitly forced lifecycle/failure events bypass
sampling, **not capacity**. Attempted, sampled-out, retained and capacity-dropped
counts are distinct; `truncated=1` declares any capacity loss. Records are
completion/reservation order per lane, not globally time-sorted.

The pause clock is a diagnostic atomic mirror published under the already-held
pause mutex. A one-shot version/fence check marks overlapping updates unavailable;
it never retries, takes that mutex, or feeds playback scheduling. Pressure uses
independent atomic observations of existing demux counters plus PCM/EOF/reserved
packet mirrors updated inside existing critical sections. It is approximate,
not a coherent queue snapshot. In particular, the detailed
`compressedDiagnostics()` still locks `pcmMu` and is **not** called by hot trace
instrumentation. Its existing terminal calls are unchanged.

Only after existing producer joins, release, terminal notification and
`playing=false` does the video writer finish and the collector freeze/dump.
Freeze refuses registered producers. Shared ownership also protects exceptional
unwinding; exceptional termination can omit the dump rather than force a new
terminal callback. No dump changes epochs, generation, pause/seek/Stop, PMS
retirement or device state.

Nonce binding, freeze, record inspection and dumping are owner-serialized, not
a concurrent snapshot/dump API. Producers only use their own writers.

Serialization uses one chunk string (initially reserves64KiB) and approximately
48KiB log chunks, not one log call per field/row. String construction/growth
allocations occur only after quiescence. Even maximum-width rows produce less than10MiB
and fewer than220 row chunks. The footer reports bytes, row chunks and elapsed
serialization plus log-emission microseconds (excluding the final footer call).
This is a **byte/work bound, not an I/O deadline**: existing stderr logging can
block. Natural EOF notification precedes dumping; explicit Stop's existing join
can include dump time. Trace-on hot-path and dump overhead require measurement
on hardware; neither host timing nor default-off equivalence proves audio quality.

### Numeric format version1

`FPGA_AV_TRACE_BEGIN` binds epoch/session/actual boot nonce and declares capacity,
sampling and truncation. Before/after anchors contain
`valid-mask,monotonic-before-us,realtime-ns,monotonic-after-us`; bits1/2/4 validate
the three timestamps. These brackets support later cross-host alignment, not a
claim of synchronized clocks or immunity to realtime clock steps.
Each `FPGA_AV_TRACE_ROWS` chunk repeats epoch/session. Require the matching
`FPGA_AV_TRACE_END`, capacities/counts and complete rows before interpreting a
dump as complete.

Rows contain:
`lane,index,event,flags,begin,end,activeBegin,activeEnd,acquired,serviceBegin,serviceEnd,released,p0..p15`.
Clock fields are monotonic microseconds, except the explicitly named realtime
anchors. Active clocks subtract accumulated/held pause time from monotonic time;
they are not media PTS. Invalid fields are `u`, never fabricated zeros.
Flags1/2/4/8/16/32/64/128 validate those eight clocks;256 marks approximate
pressure and512 marks a cross-thread written-byte observation. Lock timestamps
bracket existing acquisition/release; nested operations already under a lock
leave their own acquisition/release fields unavailable.

Lanes:0 audio,1 video,2 overlay. Unlisted payload fields are unavailable.
Wait enums:0 paused,1 video-not-started,2 PCM-empty,3 clock-unavailable,
4 queue-high,5 audible-due,6 presentation-queue,7 PTS,8 ring-full,
9 first-presentation,10 EOF-drain.

| Event | Payload |
|---|---|
|0 AudioDrain|p0 returned PCM bytes,p1 requested capacity,p2..9 pressure,p10 completed written bytes,p11 pause|
|1 AudioAdvance|p0 existing `AvAudioProgress` enum,p2..9 pressure|
|2 AudioClock,10 VideoClock|p0 live-MAST read success,p1 session,p2 nonce,p3 publication,p4 consumed stereo pairs,p5 active/paused/read-pending/prefetched bits0..3,p6 error,p7 completed written bytes,p8 written-minus-consumed*4 bytes,p9 held PCM,p10 pause|
|3 AudioWrite|p0 accepted bytes (-1 failure),p1 requested bytes,p2 prior completed bytes,p3 prior measured queue,p4 audible due monotonic us,p5 scheduling-decision lateness us,p6 errno only on failed write (0 on success),p7 completed bytes afterward,p8 remaining held PCM,p9 pause,p10 stop|
|4 AudioWait|p0 reason,p1 queue when available,p2 audible due when available,p3 lateness,p4 held PCM,p5 written,p6 pause,p7 stop,p8 video-started|
|5 AudioEof|p0 result of the existing PCM EOF check|
|6 VideoOpen|p0 existing demux open result|
|7 VideoRead|p0 read return,p1 original PTS,p2..9 pressure,p10 read-call count,p11 prior submitted count,p12 pending count,p13 original duration,p14/15 timebase numerator/denominator|
|8 VideoStatus|p0 read result,p1 active,p2 fatal,p3 desync,p4 session|
|9 VideoPresentation|p0 read result,p1 active,p2 error,p3 error code,p4 has-frame,p5 presented count,p6 sequence,p7 original PTS,p8/9 rational timebase,p10 pending,p11 submitted,p12 **frozen MVPS** audio count if supplied,p13 pause|
|11 VideoCommit|p0 presented count,p1 sequence,p2 original PTS,p3/4 rational timebase,p5 remaining pending,p6 position ms,p7 pause|
|12 VideoSubmit|p0 existing push-result enum,p1 sequence,p2 original PTS,p3 duration,p4/5 rational timebase,p6 bytes,p7 pending|
|13 VideoPace|p0 existing pacing-result enum,p1 original PTS,p2 duration,p3/4 rational timebase,p5 pending|
|14 VideoWait|p0 reason,p1 pending,p2 submitted,p3 presented,p4 held original PTS,p5/6 rational timebase,p7 pause,p8 stop; PTS waits also p9 active-us,p10 selected pacing-clock-us,p11 wall-us,p12 relative target-us when representable,p13 audio-clock-selected|
|15 OverlaySend|p0 send result,p1 existing overlay-state enum,p2 pre-send sequence,p3 position ms,p4 pause; terminal hide runs in video lane under the release lock and omits p3/4|
|16 VideoDrain|p0 existing drain acknowledgement|
|17 AudioOpen|p0 existing open return,p1 failure errno (0 on success)|
|18 AudioExit|p0 existing exit enum,p1 written bytes,p2 held PCM before clearing,p3 stop|
|19 Quiesce,20 Release|p0 completion/release success; service timing brackets existing work|

Pressure p2..9 means before-PCM bytes,after-PCM bytes,queued packets,queued bytes,
existing blocked enum,input EOF,audio EOF,reserved-video flag. Written-minus-
consumed is exact for the audio producer's completed-write counter at its existing
read; video uses the existing cross-thread atomic and explicitly marks it
approximate. Unrepresentable differences remain unavailable. Failed live MAST
reads leave identity/publication/consumption/flags/error/queue unavailable:
**the separate frozen MVPS field is never a live-MAST replacement**.
Negative counter differences indicate inconsistency, not a physical negative
queue. The VideoWait selected clock describes the existing pacing cache; it is
not another fresh MAST read.
`serviceBegin - p4` gives write-service lateness, including intervening lock wait;
p5 records the earlier scheduling decision. Do not merge the two.

Records contain numeric service metadata, not URLs, headers, configuration,
tokens, titles or media bytes. This diagnostic distinguishes observations at
existing calls; it does not by itself establish starvation, SPI contention or
any other cause. An approved trace-on artifact still requires a fresh matched
pair proposal and a separate real-Web/held-capture grant. Building or validating
that proposal grants no activation.

Both existing entrypoints have the same whole-pair dispatch:

```sh
bash scripts/deploy_plex_core.sh --prebuilt-candidate \
  --manifest /absolute/path/to/approved-pair.json --mode copy-only

# Only after a separate, explicit hardware switch grant:
bash scripts/deploy_misterplexd.sh --prebuilt-candidate \
  --manifest /absolute/path/to/approved-pair.json --mode menu
```

Either entrypoint accepts either mode. `--mode` is mandatory: `copy-only` stages
the pair without stopping, starting, or loading anything; `menu` stages a fresh
pair and performs at most **one Menu load, then one candidate load**, followed by
one direct companion start. An already-active Menu is not loaded again.
Repeating copy-only then menu creates two separate
staging transactions, not an implicitly approved reuse of an old staged copy.
There is no daemon-only activation, direct-core shortcut, default mode, build,
dependency installation, retry/escalation, reboot, or automatic rollback.
The unflagged historical deploy bodies are unchanged and are **not** candidate
paths. Do not use their `DEPLOY_*` settings as a substitute for this dispatch.

## Approval manifest

Supply all fields below. Angle-bracket placeholders intentionally fail validation.
Artifact paths are absolute or relative to the manifest's directory. Expected
hashes and build ID must come from the coordinator's **matched artifact grant**,
not from automatically approving whatever files happen to exist.

```json
{
  "schema": 1,
  "approved_build_id": "<approved-eight-lowercase-hex-digits>",
  "rbf": {
    "path": "/approved/fit/Plex.rbf",
    "sha256": "<approved-full-64-digit-RBF-SHA256>"
  },
  "arm": {
    "path": "/approved/arm/misterplexd",
    "sha256": "<approved-full-64-digit-ARM-SHA256>"
  },
  "build_inputs": {
    "path": "/approved/fit/inputs.json",
    "sha256": "<approved-full-64-digit-inputs-json-SHA256>"
  },
  "build_result": {
    "path": "/approved/fit/result.json",
    "sha256": "<approved-full-64-digit-result-json-SHA256>"
  },
  "current": {
    "rbf_path": "/media/fat/_Utility/Plex_480p.rbf",
    "rbf_sha256": "9d4977936d1b1a3420a3e97df976058573e70a34fd0c8917f2d785a5fe0d07cf",
    "arm_path": "/media/fat/misterplex/bin/misterplexd",
    "arm_sha256": "acfa03d762833994874b13a8aad4f734cf2f5649a3759238764917b6e3b77e7c",
    "config_path": "/media/fat/misterplex/misterplex.conf"
  },
  "owned_helpers": [
    {
      "path": "/media/fat/misterplex/bin/misterplex_core_watch.sh",
      "sha256": "<full-SHA256-of-the-known-on-device-watcher>"
    },
    {
      "path": "/media/fat/misterplex/bin/misterplexd_supervise.sh",
      "sha256": "<full-SHA256-of-the-known-on-device-supervisor>"
    }
  ],
  "plex_base": "http://192.168.1.24:32400"
}
```

`inputs.json` must contain the exact `fpga_video_build_id`; `result.json` must
identify the exact approved `rbf_sha256`. The cleared build wrapper writes the
latter only after its fit/timing gates. Its `promotion: NOT_AUTHORIZED` does not
grant deployment: authorization is the separately supplied manifest and switch
grant. The helper does not infer approval from a successful compilation or from
an eight-digit prefix.

The `current` object pins the pair that may be displaced. For the named frozen
480p RBF, only the exact frozen daemon and original configuration path are
allowed. Subsequent candidate-to-candidate switches must explicitly name the
previous bundle's `Plex.rbf`, `misterplexd`, and `misterplex.conf`, with full
expected RBF/ARM hashes. Arbitrary active cores are refused.

`owned_helpers` is an explicit list, possibly empty; only known on-device
`bin/` or `scripts/` copies of `misterplex_core_watch.sh` and
`misterplexd_supervise.sh` are eligible. Obtain their hashes through the
operator's read-only inspection. A discovered helper missing from the approved
list, with changed bytes, a foreign interpreter, unexpected arguments, or a
different process owner aborts the operation. Do not substitute local script
hashes for on-device identities.

Unknown/duplicate JSON fields, partial/zero hashes, missing files, a non-static
ARM ELF, mismatched build identity/result, and historical banned RBF MD5/SHA256
values fail **before SSH**. The actual repository ban list is mandatory; an
environment variable cannot replace it. Files are read and validated once into
the upload snapshot, so a later local file edit cannot replace approved bytes
in flight.

## Remote transaction and recovery boundary

The implementation adapts the primary frozen-baseline helper's SSH
`bash -s` transport, named-pair verification, and observed
Menu/Plex sequence. The primary helper and its hash restrictions are unchanged.
No downloaded configuration is executed or copied into host artifacts.

Candidate shutdown now uses a kernel-bound pidfd, not the frozen helper's
separate numeric-PID signal. A read-only probe on the actual MiSTer confirmed
Linux `5.15.1-MiSTer`, ARMv7 EABI32, and working `pidfd_open` plus
`pidfd_send_signal(..., 0)`, producing an `anon_inode:[pidfd]`. No signal was
delivered. Its Python 3.9.6 lacks the convenience functions but has `ctypes`;
the helper calls the documented ARM EABI syscalls 434/424 through libc.
These numbers come from the pinned
[Linux v5.15 ARM syscall table](https://github.com/torvalds/linux/blob/v5.15/arch/arm/tools/syscall.tbl).
On platforms with both Python pidfd APIs it uses those instead. Other bindings,
kernel `ENOSYS`, permissions failures, or a failed self/signal-zero probe refuse
before staging. There is no numeric-kill, ptrace, kernel-change, or signaling
fallback.
`scripts/candidate_pidfd.py` is embedded in the existing stdin transport; it
does not install a service, package, or binary. The approval manifest schema and
explicit entrypoint invocations above are unchanged.

The transport uses existing known-host verification and `sshpass -e`, with
`MISTER_HOST` (default `192.168.1.183`), `MISTER_USER=root`, and `MISTER_PASS`
(existing lab default). Passwords never enter command arguments. Unknown SSH
host keys fail closed; establish their identity separately through the normal
trusted lab access procedure.
Connection setup has a six-second timeout; established SSH permits three
15-second keepalive intervals so large upload heredocs do not trigger false
nine-second timeouts on the ARM board. Shutdown and core-command deadlines
are unchanged, and no reconnection or retry is added.

The remote transaction:

1. Verifies the exact immutable rollback core/daemon, approved current files,
   actual Main executable/core argv, daemon argv/executable identity, helper
   identities, and ownership of the companion listening socket.
2. Acquires a nonblocking device-wide deployment `flock` under
   `/media/fat/misterplex/run/`, without deleting or replacing its lock inode.
3. Uploads to a unique `.incoming` directory, verifies every uploaded SHA256,
   copies and compares exact rollback/current core and daemon backups plus
   current/generic daemon and config backups, then renames the complete directory to
   `/media/fat/misterplex/candidates/<build-id>-<transaction-uuid>/`.
4. For `menu` only, stops owned watchers before supervisors, rediscovers any
   intervening respawn, then stops the actual daemon. Discovery accepts `mpx-main`
   or the exact approved command, not a `pidof misterplexd` assumption. Before
   final verification, the helper acquires a pidfd, then checks start time, root
   UID, executable device/inode/hash, and argv hash through an opened proc
   directory. TERM and the ten-second exit poll both use that same pidfd. If the
   original exits between verification and signal, the handle cannot signal a
   replacement using its numeric PID. An exited handle/`ESRCH` never triggers a
   numeric fallback; subsequent respawn/child checks still apply. A pidfd pins
   process identity, not executable contents: this does not claim to freeze a
   process against `exec` after verification. A stop/owned-child timeout aborts
   without SIGKILL or core commands. Unrelated processes are never signalled.
5. Refuses remaining hardware descriptors/mappings or SPI-lock descriptors,
   rechecks preserved bytes and staged candidate/config hashes, then observes
   each of the two explicit Main core-argv transitions. The command endpoint
   must already be a FIFO or character device; each write has a three-second
   TERM-only timeout, including opening a FIFO whose reader is wedged. A transition timeout
   aborts without another load. Main normally retires and starts a new process
   on a core change. Only inside the bounded wait for an issued command may the
   process pin move: the original must have exited, and the sole replacement must
   have been born no earlier than the command, have the same executable inode and
   full hash, root ownership, the original Main or init as parent, and exactly
   the requested core arguments. Missing, duplicate, stopped, reused or mismatched
   processes are refused; no Main process is started, signalled or resumed by this
   handoff observer. Outside that window the existing process pin remains strict.
   The quiescence audit tolerates a vanished process, a same-generation zombie,
   or a descriptor that closed during inspection. It rechecks process birth
   after the scan, including successful mapping reads. PID reuse, unreadable
   live process metadata/mappings, and a still-present unreadable descriptor
   remain fatal; an absent live `/proc/<pid>/maps` is not assumed empty.
6. Starts the approved candidate directly with a clean environment, the
   versioned configuration, and no inherited deployment lock. It does **not**
   start the historical supervisor's SIGKILL recovery loop. Success requires the
   launched PID/start identity, exact candidate executable inode/SHA256/argv,
   ownership of port 3005, and a responsive `/resources` containing the expected
   `misterplex-dev` player identity.

Only bounded `CANDIDATE_PHASE`, `CANDIDATE_STAGED`, `CANDIDATE_READY`,
`CANDIDATE_LOG`, and `CANDIDATE_ERROR` diagnostics are relayed. Raw SSH output,
configuration contents, and daemon logs are never downloaded or relayed.

Before any stop, menu-mode deployment creates its private on-device log:

```text
/run/misterplex-candidates/<build-id>-<transaction-uuid>/misterplexd.log
```

Both directories are verified owner-only `0700`; the new regular, single-link
log is verified `0600` and owned by the deploying root user. Unexpected existing
permissions/ownership or a reused log directory refuse rather than being
silently repaired. Both daemon streams use the verified, already-open log
descriptor, including exec/startup errors. Failure never deletes or truncates
that log. Only its path is reported. Copy-only does not start a daemon or create
a runtime log.

**Storage limitation:** actual `/media/fat` is exFAT with `fmask=0022`, so
candidate files and the existing production log report `0755`; `chmod` there
cannot establish private per-file permissions. `/root` is on read-only ext4.
The existing `/run` is writable POSIX tmpfs, so the documented candidate-local
log namespace uses it instead. Logs survive daemon/startup failure but are
**volatile across reboot/power loss**. No remount, root-filesystem change, or use
of unrelated service storage is performed. Secrets remain only in the existing
on-device config/rollback copies and private runtime logs; there is no automatic
raw-log/config/token retrieval.

Original `_Utility/Plex_480p.rbf`, `bin/misterplexd.480p`, generic daemon/config,
current candidate files, startup hooks, and pair tables are never overwritten.
The new candidate runs from its own versioned directory. Existing reboot/boot
policy is unchanged; this does not install a persistent candidate autostart.
The existing frozen-baseline rollback remains separate, not a fallback that
silently pairs an old core with a new daemon.

On failure, uploaded bundles/backups and the last phase are retained. There is
no automatic undo: the device may still be on the old core, on Menu, on the
candidate core, or running an unready candidate, depending on the reported
phase. Inspect read-only and obtain a deliberate recovery/switch grant; do not
rerun in a loop. A successful `/resources` check is not cast/glass acceptance.

## Unbound title146 configuration

The helper makes an on-device data-only copy of the approved current config,
preserving secrets and unrelated settings. It replaces duplicate overlay keys
rather than appending a second value. The retained configuration is:

```ini
PLEX_BASE=http://192.168.1.24:32400
MPX_VIDEO_BACKEND=fpga-h264
MPX_H264_PROTOTYPE=idr
MPX_H264_FILTER=off
PRESENT=fpga
AUDIO=on
OSD_CONTROL=0
DECODE=320x240
TRANSCODE_PROFILE=240p
STREAM=0
SUBTITLES=off
SUBTITLE_STREAM=0
AUTO_NEXT=0
SOURCE_FPS=auto
AV_CONTENT_FPS=auto
MATCH_SOURCE_HZ=off
```

This selects the actual IDR/filter-off PMS profile, native source 24000/1001,
independent MrAudio MACT/MAST ABI2, and no legacy hybrid fallback. The expected
engineering core has `0xE19F`, 320x240 maximum, and 8192-byte whole-AU capacity;
the matching ARM path separately enforces 8192-byte VCL RBSP. Those are real
capability/runtime bounds, not fabricated config overrides. The next matched
grant must retain them or explicitly revise this narrow path.

The operator still must use ordinary LAN Plex Web's cast picker, select
MiSTerPlex, and play actual library title146 after deployment authorization.
The deployment helper does not start playback, acquire PMS media, change
subtitle selection, alter Plex profiles, or generate fixtures.

The universal **decision** and subsequent stream request must each carry exactly
one `X-Plex-Client-Profile-Name`, selecting the same XML. On the lab PMS, sending
the default `MiSTerPlex` header before the selected FPGA header cached the wrong
decision: Level 3.1, GOP50, deblocking enabled. A single selected
IDR/23976/filter-off header delivered Level 3.0, all-IDR, deblocking disabled.
The ARM syntax gate still rejects the former; it is not relaxed to accommodate
a mis-selected profile. Final FPGA decoder stops are reported as `stopped`,
not indefinitely relabelled as the legacy seek-plant `buffering` hold. The
media identity and planted position remain available for a deliberate retry.

## Static-safe ARM libav

An ELF without an interpreter is not sufficient proof of runtime compatibility.
The original static FFmpeg build called `iconv` for optional MPEG-TS DVB service
metadata, loading the device's `/usr/lib/gconv/ISO_6937.so`. With device glibc
2.31 and the newer statically linked libc this aborted in
`_dl_call_libc_early_init`, even on a credential-free **local file**. It was not
an HTTP-only problem.

Build FFmpeg **8.1.2** with `--disable-iconv`; retain the existing HTTP/TCP,
file/pipe, MPEG-TS/MOV/Matroska/MPEG-PS/FLV/H.264 demuxers, H.264 parsers/BSFs,
AAC and other audio decoders, and swresample. Optional service-name charset
conversion falls back to raw metadata; compressed media, original timestamps,
and PCM are not remuxed or retimed. There is no HTTP relay workaround.

```sh
# Existing source/toolchain only: no package installation, download, or hardware action.
# Both output directories must be fresh; original source/install are preserved.
FFMPEG_SOURCE=build/deps/ffmpeg-8.1.2 \
FFMPEG_BUILD_DIR=build/deps/ffmpeg-8.1.2-static-safe-build \
ARM_FFMPEG_PREFIX=build/deps/ffmpeg-arm-static-safe \
FFMPEG_JOBS=2 bash scripts/build_arm_ffmpeg.sh

make arm-ffmpeg-static-check
# Keep an already-approved daemon intact while preparing its proposed replacement.
make arm-plexd-daemon ARM_PLEXD_OUTPUT="$PWD/build/arm/proposed-pair/misterplexd"
```

The FFmpeg recipe copies and cleans only its new private source copy, uses project-local
compiler scratch storage, and never overwrites an existing build/install.
`ARM_FFMPEG_CROSS` can select an existing cross-prefix. `make arm-ffmpeg` invokes
the same recipe. `make arm-plexd` defaults to `ffmpeg-arm-static-safe` and checks
the actual four archives before linking: iconv/module-loader symbols and missing
HTTP/MPEGTS/H.264/AAC/PCM capabilities fail closed, including an explicit attempt
to select the old iconv-enabled prefix. A configuration label alone is not trusted.
The historical no-libav build remains available when no libav install exists;
it cannot run the FPGA compressed backend and is not a candidate substitute.

Actual ARM local-file and HTTP probes passed with the iconv-disabled libraries,
and ordinary Web casting no longer hit that libc abort. This does not prove every
possible NSS/DNS configuration safe, or establish picture/audio/cadence acceptance.
Each changed daemon still needs a separately pinned whole-pair grant and the
normal LAN Web-to-HDMI test.

`arm-plexd-daemon` links only `ARM_PLEXD_OUTPUT`; it never builds the DDR bench,
push-frame, status, or input-mailbox tools. Default `arm-plexd` still builds the
daemon and all those auxiliaries. Pin existing outputs before and after isolated
candidate builds; selecting `ARM_PLEXD_OUTPUT` alone on the default target is
not auxiliary-output isolation.

Compressed audio may advance the shared demux on the existing audio thread
while video waits for original PTS against live consumed MAST samples. Demux
access is serialized; video packets remain in order, bounded to32 packets and
2MiB including a reserved look-ahead packet, with the existing4-second PCM cap.
The reserve permits audio immediately after a full regular video queue without
dropping an intervening video packet. An exhausted look-ahead slot returns
explicit backpressure; it cannot hide arbitrarily long video-only interleave.
No initial prebuffer threshold, pacing lead, timeout or clock substitution is
added. Stop wakes PCM waits and interrupts input; callers join audio/readers
before reopening or destroying the source. Audio EOF is separate from empty or
cancelled queues, and pending video remains drainable after demux/audio EOF.

Every compressed exit uses the same finalizer and emits one `FPGA_TERMINAL`
receipt, including ordinary EOF, failed reads/drains/releases, cancellation and
superseded sessions. Compressed classification/drain/reset policy is unchanged: a
receipt classified `ended` describes the delivered stream, not proof that it
contained the complete library title. No duration padding or metadata-duration
guard is introduced.

The receipt retains two snapshots: before requesting source/worker retirement,
and after joining workers but before any audio/video reset. The first preserves
the actual exit/cancellation state; the second can inspect stable demux details.
Both include original input packet and admitted AU counts/PTS/duration/timebase,
raw input/AVIO return/EOF/error state, queued/reserved/pending video, remaining
PCM and audio-pump outcome, submitted PCM, and live MAST identity/flags/consumption.
Frozen MVPS samples and cached-clock age are explicitly separate from fresh
MAST read time/age. Final release/reset/flush/end/abort outcomes are appended
after cleanup, never reconstructed from hardware that has already been reset.
Unavailable fields are labeled `unavailable` or `not-attempted`, not zero.

Detailed demux reads use a try-lock rather than waiting behind a PCM producer;
the joined snapshot supplies those details without a lock-order inversion.
Input-read cancellation is observed when `av_read_frame` returns and retained
with that return value. A later failure-stop or retirement flag cannot relabel
a previously observed I/O error as cancellation. Current source cancellation
is reported separately. Open/reopen creates fresh input observation state.
An interrupted AVIO read can still deliver a buffered packet; its successful
raw return and observed cancellation are both retained, not rewritten as an error.
Cleanup exceptions still emit their retained receipt before propagation;
audio-worker exceptions enter the existing controlled failure path. Error
details are bounded, single-line and redact URLs/credentials. There is no
per-frame diagnostic output.

`tests/unit/test_fpga_compressed_runtime.sh` exercises the shared finalizer
and progress helper,128 lifecycle combinations, cleanup/snapshot exceptions,
late retirement, AU-size rejection after successful input, and384-AU full
versus264-AU byte-prefix EOF. The matrix does not execute `fpgaThreadMain`,
`fpgaAudioPump` or their hardware drain/release callbacks.

A separate focused test injects negative AVIO reads while retaining every
fixture byte; the real libav `av_read_frame`/decoder path must return the error.
It checks that failure-stop and retirement preserve EIO, and separately
interrupts an input read through the existing cancellation callback. A direct
`fpgaAudioPump` invocation supplies real decoded PCM and wraps only the MrAudio
open failure, verifying the error wrapper and final audio exit. It never opens
a real device or runs full player initialization/shutdown. This covers that
worker's open-failure branch, not full playback, hardware drain or release.

The optional `MPX_TERMINAL_REPLAY_SOURCE` selects an
existing local source for offline fixture encoding; it makes no Plex request.
The bounded timing model uses actual emitted PCM pairs and the existing
audio-EOF clock transition, including a50.15ms modeled publication period.
These fixtures do not reconstruct a missing live PMS stream or establish
hardware causality, playback, A/V synchronization or cadence acceptance.

## Natural EOF and the Companion wire state

An actual `ended` notification with no next queue item uses the existing
terminal-stop latch and reports `stopped` over Companion HTTP. It retains the
last original presentation position, including EOF near a seek plant, rather
than replacing it with metadata duration. Later browse mirrors or play/pause
commands cannot resurrect the ended session; a browser Stop preserves terminal
idle. An explicit Stop during ordinary playback retains its existing navigation
hold. A new play or an actual seek can still clear the terminal latch.

Natural-EOF queue completion is fenced by the started play generation, existing
player epoch and seek generation. Guards are checked inside the Companion state
lock. A delayed queue result claims its dispatch generation atomically before
staging; it cannot overwrite a newly cast title. Auto-next still runs off the
media thread, and the existing single in-flight queue owner is retained.

Stop retires the outgoing PMS reporter inside the serialized player handoff.
`MediaPlayer::stop` returns the position/duration it captured after joining its
worker, before clearing those values. The reporter's existing idempotent
`endSession` consumes that snapshot; stale player callbacks remain filtered,
and no newer reporter can be started inside the same handoff.

Absolute/relative seeks atomically reserve the existing play/seek generations
while accepting their plant, before releasing Companion's state lock or writing
the HTTP response. The complete accepted media identity and offset travel with
the deferred request; a later callback cannot reread a newer `lastPlay` or adopt
a newer generation. Previous/restart paths use the same acceptance mechanism.
Queued hooks perform only atomic generation/epoch operations. Resolver/player
operations run after releasing the state lock. Local seek binds its captured
reporting generation after retiring the old worker, before new-worker progress
(or at the existing same-position no-op).

For non-library requests, direct `seekMs` is allowed only when the accepted
media generation matches a binding that MediaPlayer recorded after successfully
launching its worker, with the same accepted/current player epoch. The
Companion's pending media generation is separate from its newly reserved seek
ticket. Neither `activePlayGen` (assigned before `player.play`) nor URL equality
proves that binding. Untracked/loading bindings, including a same-URL new cast
or a changed epoch during startup, start the captured media request at its
accepted offset instead. This fallback releases the handoff lock before calling
the start path. A same-position seek on a proven binding rebinds its generation
without inventing a new epoch.

Pause/resume eligibility and optimistic state publication share one critical
section. Their accepted generation/epoch fences the subsequent player call,
and late progress cannot clear an already committed terminal latch.

Focused host validation, without the broad suite:

```sh
make -j1 "$PWD/build/test_companion_plant_seek" "$PWD/build/test_companion_natural_eof"
build/test_companion_plant_seek
build/test_companion_natural_eof
```

The latter runs the production natural-EOF completion callback and actual
Companion HTTP handlers on an ephemeral loopback-only listener. It covers
no-next, late mirrors, terminal play/pause/stop, fresh and same-title plays,
seek/epoch invalidation, queued advance, lookup/dispatch failure and existing
seek/navigation holds. It does not launch GDM, PMS, MediaPlayer or hardware.
It also uses the same `wirePlaybackControls` registration called by `main`, the
actual PMS reporter with an in-memory HTTP sink, and a controlled player double.
Link wrappers interleave an old queue result before the response write, and
EOF immediately after the control-acceptance unlock (after skipping the common
cast-bound update). Preserved pre-fix code fails Stop retirement, absolute/
relative seek ownership and pause/resume interleavings. Positive cases cover
rapid seek/cast supersession, stale Stop/control rejection, accepted loading
identity, reporter idempotence, local reporting identity and exception release.
Identity regressions additionally model the actually installed URL, headers,
generation and epoch: playing A/pending B, empty current URL, same-URL new cast,
premature reporting counter, URL assignment before worker launch, startup epoch
change, superseded local seeks, and matched active/paused/same-position local
seeks. The preserved f0 registration fails the six loading/startup identity
controls. Worker installation remains modeled, not actual hardware startup.

Queue lookup, worker start/join and dispatch are controlled dependencies. These
tests exercise real control registration, Companion HTTP/state and PMS request
construction/retirement, not full `main` initialization/real PMS queue fetching,
`MediaPlayer` hardware workers, Plex Web, audio continuity or live acceptance.

## Focused offline coverage

The existing Python `unittest` runner uses fake SSH, card files, sockets, and
process identities, and is included in `make unit-unlocked`:

```sh
python3 tests/unit/test_candidate_deploy.py
python3 tests/unit/test_arm_ffmpeg_static.py
```

No device command, daemon build, dependency install, or Quartus job is performed
by this runner.
