# W-ARM — bitstream feed contract (Stage A/B supply line)

Branch `w-arm-feed-staging`, based on `w-decode-hour27`. ARM-side only, header
and daemon; **no RTL, no fit required.** Addressed to **W-CAST** (ring consumer)
and **W-DECODE** (Stage A/B).

## Why this exists

The feed was written for a healthy consumer. Stage A/B is the opposite: the
decoder is absent, then intermittent, then restarts. Two properties of the old
feed made it unusable in exactly that condition, and both would have presented
as decoder bugs.

### 1. Parameter sets were delivered once per session

`sps_delivered_` / `pps_delivered_` were set on first delivery and cleared only
by `begin()` / `resume()`. So SPS and PPS appeared exactly once, near the head
of the stream. A consumer that

- starts after playback has begun (the normal bring-up case), or
- restarts (every reconfiguration), or
- loses the head of the ring to a wrap (256 KB / ~7.2 KB per VCL ≈ 36 NALs)

had no parameter sets and could **never decode a single macroblock**, for the
rest of the session, with no error anywhere.

**Now:** SPS+PPS are re-injected immediately ahead of **every** IDR
(`DispatchConfig::replay_parameters_each_idr`, default on). Every IDR in the
ring is a self-contained random-access point.

**Cost:** 7 IDRs per title × ~35 bytes = ~245 bytes. Measured on the
`wcap_residual14_idr_plus_p` fixture: 9060 → 9095 bytes, **+0.39 %**.

### 2. A full ring killed the feed permanently

`pushWithBackpressure` escalated to `PushResult::Full` after ~100 ms of retry,
and `media_player`'s pump treated any non-`Ok` as fatal: `dispatch.end()`,
`active=false`, pipe drained for the remainder of the session. With no
consumer the 256 KB ring fills in well under a second — so **the feed died
during precisely the condition Stage A and Stage B create**, and every RTL
experiment after that point would be reading a stale ring.

**Now:** a persistent full ring sets `resyncing_`, drops non-IDR NALs, and
rejoins at the next IDR with parameter sets in front of it
(`DispatchConfig::resync_on_full`, default on). The producer keeps running.
Counted in `DispatchStats::resyncs` and `nal_dropped_resync`, logged by the
daemon at the moment it happens and in the `STREAM end` line.

Set `resync_on_full = false` to get the old fatal behaviour back; the raw
transport `Full` verdict is still tested under that flag.

## What changes for W-CAST — read this

This is **strictly additive to the byte stream**, but it is a change and it is
observable:

1. **The ring contains more NALs than the source stream.** `nal_accepted` is
   `input_nals + 2 × idr_count`. Do not assume a 1:1 correspondence.
2. **SPS and PPS repeat.** They will appear before every IDR, with identical
   content. A consumer that treats a second SPS as a stream discontinuity will
   misbehave — re-parsing it is correct and cheap.
3. **`seq` remains strictly monotonic with no gaps**, including across replayed
   parameter sets and across a resync. Unchanged, and asserted.
4. **Gaps in decode order are now possible without an error.** After a resync
   the stream skips to the next IDR. This is signalled by `resyncs` advancing,
   not by an error return.

Nothing in `ddr_bitstream_ring.hpp` or `mailbox_abi_spec.hpp` changed — no ABI
change, no record layout change, no control word change.

## Evidence

`tests/unit/test_bitstream_feed_entry_points.cpp`, `Scope: 4`. Red-proved by
reverting each behaviour independently:

| reverted | result |
|---|---|
| `replay_parameters_each_idr = false` | rc=1 — `everyIdrIsSelfContained` fails |
| `resync_on_full = false` | rc=1 — feed returns non-`Ok`, i.e. fatal |
| resync drops nothing (rejoins mid-GOP) | rc=1 — no drop, `nal_dropped_resync` stays 0 |
| none (restored) | rc=0 |

Existing consumer tests were updated to **exact predicted counts**, not
loosened bounds: `test_h264_bitstream_source` predicts replay bytes from the
observed parameter-set lengths (9060 + 35 = 9095, exact);
`test_bitstream_ring_lifecycle` asserts the ring holds
`sps,pps,sps,pps,idr` byte-for-byte.

`make unit`: my tests green. The suite still stops at
`scripts/run_with_skip_summary.py --self-test`
(`missing derived geometry contract: coded 624x480/display 618x480`) — this is
**pre-existing on the `w-decode-hour27` base**, confirmed by running that script
against a stashed tree (rc=1 with none of my changes applied). Not mine to fix.

## Not verified

Nothing here has run against hardware. The device has been offline since ~11:37
(HPS locked, needs a physical power cycle). These are the two defects that would
have blocked Stage B on a live device; that they are fixed in the header is not
the same as pixels on a screen.

---

# The stale-mailbox deadlock (product bug, fixed)

`chooseDdrPresentBankFromRelease` returned `SkipFrame` whenever
`free_bank_mask == 0` in both samples **and** `frames_done` did not advance
during the poll window. For a busy fabric that is correct. For a **silent**
one it is a self-sustaining deadlock:

```
mask=0, frames_done frozen  ->  SkipFrame
SkipFrame                   ->  host does not write, does not ring PLXK
host silent                 ->  fabric state cannot change
next read identical         ->  SkipFrame ...  forever
```

The host waits for the fabric; the fabric is waiting for the host; nothing
times out. The visible symptom is a display that never updates while the
daemon reports itself healthy.

## Two independent defects, both fixed

**1. A single stale read "proved" liveness.** `plxdLastFramesDone_` starts at
0, so the *first* observation of a residue mailbox with any non-zero
`frames_done` compared unequal and set `plxdLivenessProven_ = true`. DDR
survives FPGA reconfiguration, so residue with a plausible `frames_done` is
the normal case, not an exotic one. Because `plxdLivenessProven_` is sticky
and the staleness escape was gated on `!plxdLivenessProven_`, **one stale read
disabled the only escape for the rest of the session.**
Fixed: the first read *seeds* the comparison, it does not prove anything
(`plxdFramesDoneSeeded_`).

**2. The escape did not cover a fabric that died after being alive.** It was
gated on `!plxdLivenessProven_`. A fabric that ran and then stopped wedges
exactly as hard as one that never started, and liveness proven minutes ago
says nothing about now. Fixed: the escape is ungated; the log line reports
`liveness_ever_proven` so the two cases stay distinguishable.

**3. The policy itself now bounds skipping.** `BankReleasePolicyState` gained
`consecutive_skips`; after `kBankReleaseSkipLimitFrames = 30` consecutive
skips (~1 s at 24-30 sends/s, against a fabric that swaps at 60 Hz) the policy
escapes to the timed fallback. It heals automatically: any `free_bank_mask`
observation clears both the stuck flag and the counter.

This is a pure function with no device dependency, so the escape is covered by
unit tests rather than by hardware observation.

## Evidence

`tests/unit/test_input_mailbox.cpp`, added cases:

| case | asserts |
|---|---|
| permanently silent fabric | skips **are** taken first (backpressure is real), then bounded, then escape to `UseTimedFallback`, then heal on the first free mask |
| busy fabric recovering inside the window | never escapes, and `consecutive_skips` resets to 0 |

Red-proved: deleting the escape → rc=1 (skips run to the loop bound, no
fallback); removing the counter reset on `UseFreeBank` → rc=1 (isolated busy
frames across a session would eventually trip the escape).

**Not verified on hardware.** The device is offline. What is proven is that
the host can no longer wait forever on a handshake that is not coming.

---

# Stage-B keyframe-only feed

`DispatchConfig::idr_only`, exposed as conf key **`F3_IDR_ONLY=1`**
(`main.cpp` → `MediaPlayer::setBitstreamIdrOnly`). Non-IDR slices are dropped
and counted in `nal_dropped_idr_only`; SPS, PPS and IDR still flow, and every
IDR is still self-contained.

For the measured content this turns 350 VCL NALs into **7 keyframes**. A
Stage-B decoder that reconstructs intra only then consumes the whole ring
instead of skipping 98 % of it, and the ring cannot be filled by P slices the
decoder will never use.

Default **off** — the product path is unchanged. W-DECODE flips the conf key
when Stage B is being brought up; no rebuild, no fit.
