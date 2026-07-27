# STREAM=1 Pre-Committed Acceptance Criteria

Written **before** any attempt to enable STREAM=1. These criteria are pre-committed
and will not be revised based on observed results — only on new structural facts
about the codebase.

## 1. What "STREAM=1 works" means

STREAM=1 is **safe to enable by default** when all of the following are true,
measured on the live device, with magic-word verification on every register read:

### Hard acceptance criteria (all must pass)

| ID | Criterion | Evidence | How to verify |
|----|-----------|----------|---------------|
| H1 | ARM rawvideo path continues to produce frames with STREAM=1 | `frameIndex > 0` in end-of-session summary | Run `STREAM=1 PRESENT=both` and confirm ARM frame count is non-zero |
| H2 | F3 ring carries real data | CTRL has PLXB magic (`0x504C5842`) and `producer_count > 0` after playback | `readBitstreamStatus()` returns `producer_count > 0` and PLXB present |
| H3 | FPGA consumer advances | READ has PLXR magic (`0x504C5852`) and `consumer_count > 0` after F3 delivery | `readBitstreamFpgaCount()` returns true and count matches producer count |
| H4 | No transport desync or fatal | `desync_count == 0` and `fatal == false` across a full playback session | End-of-session `ddr_status` in log shows `desync=0 flags=u*o0d0f0` |
| H5 | FPGA decode produces pixel output distinguishable from ARM | See §3 (provenance) below | Provenance evidence is unforgeable and measured, not inferred |
| H6 | No user-visible regression | `STREAM=1 PRESENT=both` produces at least as many frames as `STREAM=0 PRESENT=fpga` | Side-by-side frameIndex comparison ±5% |
| H7 | Session lifecycle clean | `beginBitstreamSession` succeeds (returns true within timeout), `endBitstreamSession` succeeds | No "F3 NAL producer begin failed" or "end failed" in log |

### Soft criteria (must be measured; waivable with evidence)

| ID | Criterion | Notes |
|----|-----------|-------|
| S1 | No ring Full escalations | `full_escalations == 0` in f3Stats; transient Full is OK if it self-recovers |
| S2 | Seek/pause/resume work | Position after seek is within 2s of target; pause freezes, resume continues |
| S3 | CPU load acceptable | `stream_cpu_us / stream_wall_ms` ratio does not exceed STREAM=0 by >30% |
| S4 | Audio continues during STREAM | No MrAudio underruns attributable to STREAM CPU contention |

## 2. Failure modes when enabled prematurely

### Mode A: `STREAM=1 PRESENT=both` (safe configuration)

```
ARM rawvideo path:  RUNS (skipRgb=false because PRESENT!=fpga)
Host I-slice recon: RUNS (wantF3=true, pushes to F3)
F3 DDR ring:        WRITES data
FPGA decode_stub:   SUPPRESSED (host_owns_fs=1 after first ARM frame swap)
User sees:          ARM-decoded frames at full rate — identical to STREAM=0
Risk:               ~zero. Extra CPU from demux thread is the only cost.
```

**This is the safe testing mode.** The ARM path is fully intact as fallback.
The FPGA receives data but its output is suppressed by `host_owns_fs`. The user
sees no difference from STREAM=0.

### Mode B: `STREAM=1 PRESENT=fpga STREAM_SKIP_RGB=auto` (danger zone)

```
ARM rawvideo path:  SKIPPED (skipRgb=true because PRESENT=fpga)
Host I-slice recon: RUNS (~1 fps keyframe-only → F1 DDR)
F3 DDR ring:        WRITES data
FPGA decode_stub:   SUPPRESSED after first recon F1 (host_owns_fs=1)
User sees:          ~1 fps keyframe updates (CAVLC) or NOTHING (CABAC)
Risk:               HIGH. No ARM fallback for continuous playback.
```

**This configuration removes the ARM decode path.** If the FPGA cannot decode
(which today it cannot — decode_stub is a diagnostic, not a decoder), the user
gets at most 1 fps of I-frame recon. With High/CABAC content (which PMS
delivers regardless of Baseline XML), even that fails and the screen freezes.

### Mode C: `STREAM=1 PRESENT=fpga STREAM_SKIP_RGB=off` (forced fallback)

```
ARM rawvideo path:  RUNS (skipRgb=false because STREAM_SKIP_RGB=off)
Host I-slice recon: RUNS
F3 DDR ring:        WRITES data
User sees:          ARM-decoded frames at full rate (same as STREAM=0)
Risk:               Low. Both ARM and FPGA paths active.
```

**Key insight: `STREAM_SKIP_RGB=off` is the runtime escape hatch.** It forces
the ARM rawvideo path to stay active even with `PRESENT=fpga`. This is the
correct lab configuration for testing STREAM=1 without risking a blank screen.

## 3. Frame provenance — how to prove "the FPGA decoded this"

### The problem

Today the frame store pixel path is: ARM decode → DDR YUV420p → `ddram_frame_rd` → display.
With STREAM=1, the same path still works (ARM frames via F1). The FPGA
`decode_stub` cannot write to the frame store while `host_owns_fs = 1`.

**If we cannot distinguish an FPGA-decoded frame from an ARM-decoded frame, we
cannot claim the ARM has been retired.** The system would work and we would not
know why.

### Provenance evidence design

Three independent, unforgeable signals that prove FPGA decode provenance:

**Signal 1: DDR ring consumer advancement (transport proof)**
```
Register:  READ @ 0x30140008 (64-bit)
Magic:     PLXR (0x504C5852) in bits [31:0]
Evidence:  consumer_count in bits [63:32] advances monotonically
Rule:      consumer_count == producer_count after session end
           → FPGA consumed all bytes the ARM produced
Check:     readBitstreamFpgaCount() returns true AND count > 0
```
This proves the FPGA **received** the bitstream. It does NOT prove it decoded it —
the reader might consume bytes and discard them (which is what happens with
decode_stub today: bytes are consumed into the NAL FIFO, parsed by
slice_hdr_parser, but decode_stub paints a diagnostic, not decoded pixels).

**Signal 2: FPGA-side decode telemetry (decode proof)**
```
Register:  status_in[127:0] via getCoreStatus()
Fields:    nalu_count (status[31:16])   — NALs seen by stream_path
           recon_sig  (status[119:112]) — XOR of 16 reconstructed Y samples
           recon_dbg  (status[127:120]) — coeff/dequant/IDCT/recon non-zero flags
Rule:      nalu_count > 0 proves NALs were parsed
           recon_sig != 0 proves reconstruction math ran
           recon_sig == golden (0x3B for MB0 block0) proves correct reconstruction
Check:     readCoreStatus() → parseCoreStatus() → CoreStatus fields
```
This proves the FPGA **processed** NAL data. Combined with Signal 1, it proves
end-to-end: ARM produced → FPGA consumed → FPGA parsed → FPGA decoded.

**Signal 3: Frame store origin bit (presentation proof)**
```
Current:   host_owns_fs (Plex.sv:660) latches high on first F1/DDR swap
Needed:    A new "fpga_owns_fs" signal that latches when decode_stub (or its
           successor) successfully swaps a frame. The two signals are mutually
           exclusive per frame. The ARM can read which one is set.
Status:    NOT YET IMPLEMENTED — requires RTL change (w-rel owns Plex.sv)
```
This would prove the displayed frame came from the FPGA decoder, not the ARM.
Until it exists, we rely on Signals 1+2 (transport+decode) plus the ARM being
disabled (Mode B with skipRgb=true) as a process-of-elimination argument.

### Provenance verdict for "the ARM has been retired"

The claim "decode has moved off the ARM" requires ALL THREE:
1. Signal 1: FPGA consumed all bitstream bytes (transport complete)
2. Signal 2: FPGA reconstructed frames (recon_sig matches golden)
3. Signal 3: Displayed frames came from FPGA, not ARM (frame store origin)

Without Signal 3, the strongest available evidence is:
- ARM rawvideo FFmpeg is NOT running (skipRgb=true, no FFmpeg video process)
- FPGA consumed and decoded the stream (Signals 1+2)
- Frames are being displayed (present_core is scanning out)
- Therefore the frames must come from the FPGA (by elimination)

This is a sound argument but not as clean as a hardware origin bit.

## 4. The early-enable question — my assessment

**The parent's instinct for a middle path is correct, but with one modification.**

The parent proposed: enable STREAM=1 behind opt-in, ARM fallback intact, FPGA
refuses what it cannot handle.

I agree with the structure but would sharpen the configuration:

### Recommended lab configuration (safe to enable now)
```ini
# misterplex.conf
STREAM=1
PRESENT=both
STREAM_SKIP_RGB=off
```

This gives us:
- ARM rawvideo at 25 fps (user sees working playback, identical to today)
- F3 DDR ring carrying real Plex content to the FPGA
- End-of-session telemetry showing producer/consumer counts, desync, etc.
- **First-ever measurement of real content flowing through the FPGA path**

### Why this is better than waiting

The fleet has spent weeks debugging a decode path using synthetic vectors and a
300-frame corpus with zero Intra_16x16 Plane macroblocks (w-cabac measured 0 of
1470 in the corpus, vs 31-78% in real content). **Nobody has seen real Plex
content reach the FPGA.**

With `STREAM=1 PRESENT=both STREAM_SKIP_RGB=off`:
- The ARM path is fully intact — no regression risk
- We learn whether `beginBitstreamSession` succeeds or times out on the real core
- We learn whether the FPGA ring reader advances or stalls
- We learn whether `stream_path` / `slice_hdr_parser` chokes on real content
- We get real content NAL type distribution, sizes, timing
- **decode_stub is suppressed by host_owns_fs, so there is zero risk of wrong pixels**

### What "loud refusal" looks like today

The parent asked about the FPGA refusing unsupported content loudly. The current
coverage in RTL:

| Condition | Response | File |
|-----------|----------|------|
| I16x16 Plane mode | `unsupported_code = 1` | `h264_intra_pred.sv:312` |
| I_PCM | `unsupported_code = 2` | `h264_intra_pred.sv:312` |
| Bad record magic | `fatal_sticky = 1` | `ddr_bitstream_reader.sv:452` |
| Seq mismatch | `desync_sticky = 1` | `ddr_bitstream_reader.sv:mark_desync` |
| Double begin | `fatal_sticky = 1` | `ddr_bitstream_reader.sv:457` |
| Overrun | `overrun_sticky = 1` | `ddr_bitstream_reader.sv:293` |

**What is NOT covered:**
- CABAC entropy (no CABAC engine exists; CAVLC walker simply produces wrong results)
- B-slices (no B-slice support; parser may misparse or hang)
- High-profile 8×8 transform
- Weighted prediction

The "loud refusal" principle is partially implemented for intra, but not for
entropy or slice type. **The ARM-side `cabacSkip_` flag detects CABAC in the
PPS and skips host recon, but this only affects the F1 path — F3 still sends
the NAL to the FPGA regardless.** This is correct for now (let the FPGA see
real content), but a production `STREAM=1` would need the FPGA parser to detect
CABAC and refuse.

### Summary assessment

| Question | Answer |
|----------|--------|
| Is STREAM=1 safe to enable? | **Yes**, in `PRESENT=both STREAM_SKIP_RGB=off` mode |
| Does the ARM path still work? | **Yes**, fully intact — `skipRgb=false` keeps FFmpeg rawvideo running |
| Can we tell FPGA from ARM? | **Partially** — transport (Signal 1) and parse (Signal 2) proof exist; frame origin (Signal 3) needs RTL |
| Should we enable early? | **Yes**, in lab only, for measurement. Every day without real content in the FPGA path is a day the corpus gap stays hidden |
| Should we ship it as default? | **No**, not until H5 (provenance) is met. FPGA cannot decode yet; shipping STREAM=1 with PRESENT=fpga would regress to 0-1 fps |

## 5. Magic-word verification protocol

Every register read in this analysis and any future measurement must follow:

1. Read the raw 64-bit value
2. Check bits [31:0] against the expected magic word
3. If magic matches: interpret bits [63:32] as data
4. If magic does not match: report **"never written"** — do not interpret the value
5. Log the magic check result alongside the data

Magics for the bitstream ring:
- `PLXB` (`0x504C5842`): CTRL — ARM producer count
- `PLXD` (`0x504C5844`): CTRL — ARM producer dormant (STREAM=0)
- `PLXR` (`0x504C5852`): READ — FPGA consumer count
- `PLXE` (`0x504C5845`): ERR — FPGA error/status telemetry
- `PLXN` (`0x504C584E`): Record header — 32-byte framing

A value of `0x00000001` at ERR means "never written by FPGA" — it is DDR boot
residue, not "one error". This was established on 2026-07-27 and retracted
fleet-wide.
