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
