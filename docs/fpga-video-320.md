# Experimental 320 AU integration

This source path is unfinished and is not a hardware acceptance.
The explicit FPGA320 candidate compiles a bounded IDR/filter-off decoder with
a zero capability-feature mask. Wired logic is not a qualification claim.
The baseline configuration remains selected unless explicitly changed.
The first functional target is HDMI 240p with genuine 24-fps decoded content;
CRT or analog measurements are not a prerequisite. Later 480i, 480p24 and
720p24 cores remain separate qualification steps, not modes advertised by this
320×240 decoder configuration. Native/analog certification is not implied.

## Configuration

`FPGA_VIDEO_320=1`, with `DDR_FRAME_STORE`, selects maximum 320×240 coded bounds,
320×240 planar store, whole-AU ingress, and FPGA-owned presentation. It is not a
640×480 decoder or an upscaled replacement for another advertised decode mode.
Do not combine it with `PLEX_PRESENT_720P_L4` or alternate HD beam configurations.
The original display raster still maps this 320-pixel store to its beam.
Omit `FPGA_VIDEO_320` to select baseline; defining it as zero is rejected.

`FPGA_VIDEO_AU_PROTOCOL=1` independently enables the frontend diagnostic path;
without the 320 publication configuration, attempted unsunk frame writes keep
the drain fence closed. This is not a product playback configuration.

Decoder-only paced-ioctl benches may set `LEGACY_SLICE_DIAGNOSTIC=0` while
keeping `ENABLE_AU_PROTOCOL=0` and DDR disabled. This selects the current bounded
header/controller contract without inventing AU metadata or a presentation
sink. Default header selection is unchanged: legacy for baseline, bounded for
AU mode. Such benches still do not validate AU transport or presentation.

`FPGA_VIDEO_BUILD_ID` is forwarded from the immutable build snapshot, with zero
as the unqualified fallback. A build ID is not a capability claim. FPGA320,
baseline and standalone `stream_path` all advertise feature mask zero. The old
unqualified `0xE19F` advertisement is removed. Ordinary companion capability
negotiation therefore must not accept this source as product playback-ready.
The explicit `IDR_ONLY_PROFILE` parameter selects decoder hardware independently
of feature claims: Plex selects it for FPGA320; standalone diagnostic benches
may select inter without advertising it. Dimensions are bounded to
320×240. Modern source selects a 65536-byte encoded-AU limit and VCL RAM,
16-bit RAM addresses, 17-bit byte counts and 20-bit cursors. The terminal
bit cursor 524288 is representable, rather than wrapping at the final byte.
Scanner, RAM, bounded header and controller derive their widths from the same
source selection. Controller RAM latency remains one cycle, with its adaptive
128-byte residual window and separate 11-bit window cursor.
The complete-AU input FIFO also holds 65536 bytes, because scanning waits for
the final encoded byte. Its existing 16-bit occupancy status saturates at 65535;
full/empty decisions use the full-width pointers.
Legacy diagnostic selection retains 8192-byte VCL RAM and 13/14/17 widths,
with the original 32768-byte legacy input FIFO and diagnostic painter.
The generic transport ring ceiling is not an independently advertised capacity.

The explicit intra-only policy selects controller `STATIC_IDR_ONLY`.
It excludes unused inter prediction, reference-window, and motion-vector
prediction logic while retaining the DPB and presentation paths. Zero-feature
standalone builds default to the diagnostic P path. The composed AU runner selects
this same static policy with `FPGA_VIDEO_TB_IDR_ONLY=1`; its default is unchanged.

These capability dimensions are **maximum coded bounds**, not a promise that
PMS encodes every title at exactly 320×240. A legal 320×192 widescreen picture
must not be stretched, padded by the host, or made to wait for 300 macroblocks.
Runtime coded dimensions and even 4:2:0 crop offsets now reach native completion,
publication and scanout. The actual PMS 320×212 capture is coded as 320×224:
20×14 macroblocks, with a bottom crop of 12 luma lines (six chroma lines).
The coordinator confirmed SAR 1:1 for this transcode from the existing lab
`observation.json`; no new live observation is implied. That transcode
rectangle/SAR is separate from the original movie DAR carried by PLXA.
It reconstructs 280 macroblocks and 107520 coded samples, not 300 macroblocks
and not merely a shortened display viewport. Reference bounds are 320×224
(160×112 for chroma), not the visible crop or the 320×240 allocation.
The separate full 320×240 fixture uses 300 macroblocks and 115200 coded samples.
The movie sample does not qualify full-height support or original-DAR accuracy;
source composition is not hardware, aspect-accuracy or cadence qualification.

## Ownership and completion

The reader's AU valid/ready handshake precedes bytes. Session, sequence, signed
PTS/duration, timebase and flags are retained separately from the next queued AU.
The existing byte FIFO stages the bounded AU; `out_last` releases it to scanning.
Reader acceptance is gated by the selected input source, FIFO capacity, pending
SPI-write priority and reset/flush. Legacy F3 selection holds DDR bytes throughout
an ioctl download, including idle gaps; the final-byte marker and AU metadata use
the same accepted-source boundary. AU mode keeps its DDR ownership over F3.
In AU mode the scanner uses explicit EOF, not an empty-FIFO timeout. It leaves
the next NAL in the FIFO until the parameter parsers, decoder and native-picture
publisher release the previous capture/picture. Completed RBSP RAM does not
accept additional writes until a new capture clears it.
Filling the selected RBSP RAM does not end a NAL. Further payload strobes
remain visible to the RAM/controller overflow detectors until the real boundary;
the scanner reports a saturated one-past-capacity rejection sentinel
(65537 modern, 8193 legacy) rather than wrapping
or silently completing a truncated capture. New-capture clear resets that error.
The separate **encoded AU** bound includes Annex-B framing, emulation-prevention
bytes and all parameter-set NALs. Thus an exact 65536-byte VCL RBSP controller
fixture can exceed the modern 65536-byte transport limit; a controller-only
capacity result is not proof that its entire encoded AU can be admitted.
Annex-B zeros are deferred until the following byte distinguishes payload,
emulation prevention and a delimiter. This prevents separator/trailing zeros
from contaminating SPS/PPS/VCL RBSP. One outstanding FIFO read also prevents
speculative bytes from escaping while deferred zeros are emitted.
`stream_path.next_vcl_ready` exposes that release condition. It also blocks the
one-cycle interval between a decoder frame-counter event and the held native
picture request, preventing premature next-NAL reuse. A coincident final native
write supplies its bank directly to that request rather than using an old bank.
The enabled path wires the bounded header parser's actual slice QP, reference
header and deblocking-idc field instead of MB0 diagnostic results. Baseline
selects the separate legacy diagnostic parser. Geometry and PPS-to-SPS identity
must satisfy the bounded coded/crop contract.
SPS, PPS and slice-header errors, including a PPS referencing an unavailable SPS,
feed the bounded controller's abort input and block header validity and
native-picture enqueueing. This does not change the
legacy diagnostic handshake or implement codec-error MVPS reporting.
The source also binds the controller's `decode_error`. Any nonzero controller
error (including overrun 12, capture overflow 14 and tail error 15), or a
parameter/header error, suppresses exported picture-valid and clears a pending
picture. Neither prior native writes nor a completion-counter edge alone
authorizes publication.
The PPS/header parser carries `num_ref_l0` as the encoded minus-one value.
The controller receives validated SPS `max_num_ref_frames` independently;
an IDR may legitimately declare zero reference pictures.
Actual SPS coded size, crops, SAR, range and matrix feed the controller. The
current path accepts progressive coded dimensions within 320×240, consistent
macroblock counts and a positive, even-cropped visible rectangle. Known
non-square SAR remains unsupported. Unspecified SAR stays unknown (0/0), not
1:1; ARM still requires a valid original DAR from Plex or demux metadata before
submitting playback. Limited-range matrix 5/6 uses BT.601. Matrix 2 is an
explicitly assumed, unqualified limited-BT.601 policy, not signaled colorimetry.

For an active FPGA320 picture in Original aspect mode, the collected PLXA
source DAR reaches MiSTer's `VIDEO_ARX`/`VIDEO_ARY` through the frame store and
presenter. The frame store exports cropped content DE with the same latency as
RGB; `present_core.de_pix` and the overlay forward it to `VGA_DE`. Allocation
padding is outside DE, so the original ratio applies to content, not to a
padded 320×240 canvas. No host aspect compensation or pixel padding is needed.
The default Template beam exposes 529×212 active samples for the cropped
capture, or 529×424 when scandoubled; full-size content exposes 529×240 or
529×480. Cropped horizontal apertures follow the same counter-to-store mapping.
Idle or invalid ratios retain 4:3; fullscreen,
custom user modes, and the legacy configuration retain their existing behavior.
The idle/legacy timing and painter remain unchanged.

The frame store has two existing HPS banks at `0x30000000` and `0x30080000`.
Each new-mode allocation occupies 115200 bytes: Y stride 320, U/V strides 160,
with plane offsets 0, 76800 and 96000 even for shorter or narrower pictures.
The publisher copies all coded pixels, including cropped reference pixels,
and fills only allocation padding with Y=16/U=V=128 without reading unwritten
native RAM. It never compacts the chroma bases to the current coded height.
Reference promotion retains actual coded bounds; fractional border fetches
clamp to those bounds while addressing the fixed strides and plane offsets.
Pending crop geometry crosses with the bank, prefetch starts at its crop-top,
and geometry becomes active atomically with the actual display-bank swap.
The prefetch scheduler compares registered, flat current and pending tag
windows rather than selecting a cache bank inside the pending comparison cone.
Pending tags forward same-edge line commits and generation invalidation, so
the snapshot retains the live-tag behavior without a redundant refill or an
early-ready decision. Two preserved identity LUTs on each line-tag bit pad
only the DDR-to-video synchronization branch; local DDR consumers remain
unpadded. This adds no pipeline cycle or timing exception, and still requires
passing fitted setup and hold timing at every supported corner.
Line clamping compares the base against each constant tap boundary in parallel
with the offset addition; it does not move arithmetic between synchronizer stages.
PLXF samples a registered Gray-coded underrun counter through two synchronizer
stages and a DDR-local binary register, with hold padding only on that crossing.
Its diagnostic count can lag the live video-domain count by three DDR clocks;
the counter's saturation and reset semantics are unchanged. Input-mailbox
sequence counters retire with the existing FIFO-pop pulse, after the command
word is latched, so refill comparisons do not directly drive their enables.
Its 320-pixel line geometry uses a 64-beat burst bound; the old
128-beat bound overflows the narrower line counter.
This configuration explicitly selects limited-range BT.601 conversion for the
native I420 scanout. The legacy full-range conversion remains the default for
existing configurations; treating native limited-range samples as legacy
full-range would raise black levels and reduce white levels.

`frames_out` counts completed legacy RGB output, not native-picture eligibility
or physical presentation. Source enables the controller's native-picture lease:
only the held notification following successful tail validation and genuine DPB
promotion enqueues a copy. Its explicit bank and geometry remain owned while RGB
drain and native copying overlap. Acceptance by `frame_ready` starts the copy;
it does not release the bank. Source releases the lease only after actual
publisher/display retirement and all accepted native reads have returned.
The controller separately waits for RGB completion, so neither consumer can
permit premature next-VCL reuse. Reset cancels the generation through the existing
publisher/display fence; diagnostic painter behavior remains separate.
The publisher reads
the owned DPB bank through the shared read port, writes the non-displayed HPS
bank, and reads the final qword back before requesting a swap. New-mode host
doorbells are ignored. A bank value is stable throughout the copy before its
request toggle crosses to the existing display prefetch logic.
Each accepted native BRAM read produces one registered, client-tagged response.
The out-of-range zero mux follows the RAM output register so Quartus can infer
the 230400-byte M10K array without changing response latency.
Reads and writes are reset-qualified; an idle address does not perform another
read. The composed gate counts DPB and publisher requests/responses separately
and requires both to retire before Drain succeeds.

Presentation count advances only after the real frame store increments
`frames_done` on its safe-boundary swap. The observation and publisher both run
on `clk_sys`; original metadata remains held until completion. Repeated VSync,
reconstruction counters, stale boot frames and mere copy completion cannot
create feedback.
Film cadence comes from original AU timestamps and paced delivery, independently
of the beam's refresh rate. Neither the display refresh counter nor a 24-fps menu
selection proves that 24 distinct decoded pictures are displayed per second.

FPGA320 routes the final native RGB, pixel enable, and sync/DE signals through
the separate playback overlay, keeping all of them aligned. Its byte-wide
index-6 upload uses the live reader epoch and committed Probe nonce; reset,
inactive video, and generation clear fence stale text. AutoFit measures the
actual native DE viewport rather than assuming it equals the decoded dimensions.
Only the text plane is writable: overlay pixels never modify the reference
picture or its native I420 storage. Baseline keeps its direct output path.

The publisher invalidates MVPC first, writes the eight MVPS body qwords, writes
the fresh nonzero MVPC commit last, and reads it back before returning ownership.
MVPC publication identity advances across functional clears; it is not reset
with the presentation count. Reusing it after a same-epoch clear would defeat
the host's before/body/after commit comparison and permit a torn snapshot.
The authoritative 72-byte layout is at `0x30140090..0x301400d0`. In FPGA320 mode,
the publisher snapshots the actual ALSA consumer's reported stereo-pair count
at the display acknowledgement, not at AU admission or native copying. It sets
`HasAudioClock` only when the coherent consumer snapshot is valid and its epoch
and Probe nonce match the latched picture; otherwise the flag and sample count
are zero. The snapshot remains fixed throughout that feedback publication.
This wiring does not establish hardware A/V calibration or enable capabilities.
Fresh nonce and epoch-clear handling invalidate old feedback. Generation clear invalidates DPB
reference state and immediately removes display eligibility, including a queued
swap coincident with VSync. It does not reset the frame-store DDR transaction
state machine. A four-phase level handshake waits for held commands and accepted
read responses to retire, clears cached-line validity and queued prefetch work,
and baselines in-flight start/swap toggles before returning to idle. Repeated
clears coalesce while that acknowledgement returns. Publisher ready/idle and the
decoder Drain fence include this real display-generation retirement. Drain itself
does not flush the decoded reference or displayed picture.

The system-clock transport mux retains each accepted read's client tag.
An independent audio-control submux shares the reader's transport input.
Audio ABI2 uses the committed MACT/MAST mailboxes, not a video-ring event;
the 217-bit control and 448-bit snapshot handshakes connect to the actual
`sys/alsa.sv` consumer through `sys_top.v`. Active or paused audio does not
block an ordinary video Drain. A pending CTRL reset additionally waits for
a consumer snapshot confirming inactive audio with no DMA read or prefetched
samples before the reader can acknowledge reset.
The core's menu/button reset also reaches the ALSA consumer, with asynchronous
assertion and audio-clock-synchronous release. The consumer retires any already
requested DMA response before reporting quiescence; clearing video identity
alone must not leave an orphaned active audio session.
The held-request DDR arbiter accepts commands through a command FIFO, retains
ownership across functional reset, and returns responses through a separate
FIFO. This mode supports single-beat reader/publisher requests and burst reads
from the frame store. DDR BUSY is not treated as a delayed pulse acknowledgement.
FPGA320 held-mode command and response FIFOs select `USE_BLOCK_RAM=1`, requesting
dedicated dual-clock M10K storage instead of a fabric-register payload crossing.
Startup FIFO reset masks the read result until its first prefetch without resetting the RAM
read port; first-word-fall-through timing and ownership are unchanged. The
generic FIFO and baseline Plex retain their existing logic-memory selection.
The transport gate compares observable cycle timing for both storage backends;
physical RAM inference and timing still require the fitted artifact.
Functional reset does not reset either held-mode FIFO or discard its response
owner. An already accepted read still returns to its original reader, including
while reset is asserted; the reader discards the killed parser result. A held,
unaccepted command retains its address/data until acceptance after reset.
Already queued commands can retire at DDR while reset remains asserted.

New builds enable TimeQuest multicorner analysis over the configured junction
temperature range. Setup and hold must close at every analyzed corner; checking
only the default corner can miss a colder-corner violation. No new clock groups
or false-path exceptions are introduced by the FIFO storage selection.

New-mode audio uses the actual framework ALSA DMA consumer with
`SESSION_CONTROL=1`; the legacy F2 core-audio contribution is muted so stale F2
data cannot mix into that session. Baseline keeps its original F2/ALSA behavior.
The currently routed audio control implementation uses independent MACT/MAST
mailboxes, not an Event10 command path. Its coherent, identity-qualified consumed
count can feed the existing MVPS audio fields at the actual display acknowledgement;
this does not by itself qualify the audio lifecycle, cadence or hardware path.

## Targeted gates

Run using the existing Verilator infrastructure:

```sh
bash tests/unit/test_stream_au_frontend.sh
bash tests/unit/test_ddr_bus_arbiter_transport.sh
bash tests/unit/test_fpga_video_publish.sh
FPGA_VIDEO_TB_IDR_ONLY=1 FPGA_VIDEO_TB_SCANDOUBLE=0 \
  bash tests/unit/test_fpga_video_au_publish.sh /path/to/legal-filter-off-capture.264
python tests/unit/test_fpga_audio_routing.py
python -m unittest discover -s tests/unit -p test_fpga_sys_top_elaboration.py -v
```

The whole-top gate elaborates actual `sys_top` in baseline and FPGA320 modes,
including real ALSA, bridge, scaler and core logic. GHDL analyzes/elaborates and
converts the actual `ascal` and `pll_hdmi_adj` VHDL bodies; they are not replaced
with interface-only models. Intel hard primitives use declaration-only boundaries
from installed vendor libraries. One legacy debug atom absent from their public
headers is limited to the exact generated two scalar constant-input connections
in `sysmem.sv`; any change fails the gate. This is structural elaboration, not a
PLL/HPS behavioral model, Quartus synthesis, resource closure or timing proof.
The test records exact source hashes, macros, generated-body identities and
elaborated profile parameters, and rejects source mutation. Its input-only ADC
net adapter and legal combinational variable declarations in the safe terminator
do not change transaction logic.

The fit candidate adds only `FPGA_VIDEO_320=1` to the checked-in QSF macro set
(`DDR_FRAME_STORE`, `FRAME_W=640`, `FRAME_H=480`, `FRAME_LINES_8`,
`SDRAM_CLK_142`, `SDRAM_CL3`); FPGA320 overrides effective decoder/store bounds to
320x240. The reviewed wrapper's existing `--derive-video-build-id` derives identity
from the original immutable source. This is not permission to invoke it: only
the sole lab operator may execute Quartus/deployment after the coordinator grants
one immutable fit. The source QSF retains baseline by default.

The publication test uses the actual DDR mux, CDC arbiter and frame store. It
checks all native I420 bytes, safe-swap causality, authoritative host MVPS decode,
commit ordering, nonce/epoch rejection, repeated VSync, and seek/reset retirement.
Cancellation cases hold accepted display-read responses, stall an offered display
write and a publisher write, clear a ready swap at VSync, and clear a start toggle
in transit. Canceled pictures must never increment the actual display counter;
a fresh generation must subsequently display without a global reset.
It also observes real frame-store RGB at all four picture corners and verifies
limited-range black/white endpoints after accepted display swaps.
Its input picture is a controlled test image, not a decoded Plex title.
The audio-routing case instantiates the actual core with clocks stopped and
injects only the legacy F2 contribution. It checks flag-off passthrough and
flag-on isolation; it does not model PLL behavior or qualify ALSA playback.
These gates record source and binary SHA256 files in their build directories
and fail if their source inputs change during compilation or execution.
The frontend gate runs both 8192- and 65536-byte configurations, reads every
captured byte to detect address aliasing, checks overflow without overwriting
owned RAM, and fills/drains a complete staged AU before explicit EOF.

The arbiter runner also composes the actual AU reader, audio submux, transport
mux and held CDC bridge with unrelated clients inactive. Probe/control traffic
fills the command FIFO behind a BUSY-held write before reset; every accepted
write must reach DDR once, in order, and the still-unaccepted reader write must
survive until reset release. A separate accepted read returns into the response
FIFO while the system clock is stopped, then reaches the original reader once
with reset still asserted. Both cases require a fresh Probe and real capability
commit afterward. A test-only dropped-response fault must strand the reader.
This control-only gate does not instantiate a decoder, presenter or audio DMA
consumer, and does not qualify their drain fences or hardware behavior.

The separate AU composition gate defaults to the richer `p3_inter_pred` 320×240
fixture. It feeds the first two real Annex-B access units through Probe, Begin
and the actual DDR reader; no native-RAM test data is connected in that mode.
It compares complete coded pictures against ordinary ffmpeg with
`-apply_cropping 0`, checks every fixed-layout padding byte, and separately
compares the extracted visible I420 against the normal cropped decode.
The gate reads the actual Probe capability commit from DDR, requires the modern
65536-byte limit, and bounds each submitted AU by that negotiated value.
Its full-width cursor and captured-byte observations remain visible in results.
It also requires copy admission before legacy RGB completion, a stable native
lease through pending display, and release only after actual publication/read
retirement. Decoded CAPS must retain zero features and reject product readiness.
The large-PMS regression selects exact captured IDR/P packets 168/169, sized
17494/1195 bytes, without re-encoding or patching their filter-off headers.
The IDR consumes 17449 RBSP bytes and reaches bit cursor 139592, beyond the
old 17-bit cursor range. Both pictures match ordinary FFmpeg through coded
320×224 reconstruction, cropped 320×212 DDR content and every native RGB sample.
This is a two-picture software composition result, not a full-GOP, sustained
24-fps, original-DAR, audio, fitted-core or Plex Web cast/glass qualification.
It checks held AU metadata at safe-boundary presentation and fences a queued Drain.
It then sends an actual in-ring Flush and observes cleared native-reference
validity, no displayed/pending old picture, and invalidated presentation feedback.
An additional negative AU inserts a truncated PPS before the real VCL. Its
parameter error must reach the controller and cannot produce a reference,
display swap or committed feedback. The positive encoded fixture/reference is
unchanged; this negative case does not qualify error recovery.
`FPGA_VIDEO_TB_PPS_NEGATIVE=sps-mismatch` selects a separate valid-PPS/wrong-SPS-ID
negative, which must abort without relying on a parser syntax error.
`FPGA_VIDEO_TB_NEGATIVE=bad-tail` changes only an RBSP alignment-zero bit in
the negative AU. It requires tail error 15 after all coded native writes and
checks every cycle for forbidden DPB readiness, source picture-valid, display
swap or MVPS completion. Positive media and its reference remain unchanged.
This variant requires a final RBSP byte with padding; it does not rewrite
payload syntax to manufacture that condition.
Repeated no-data Pause followed by queued AUs and Resume checks preservation
through the actual reader/mux/CDC combination before decoding starts.
Decoder aborts and source-union elaboration errors are failures, not skipped
tests. An optional first argument selects another existing bounded fixture;
that does not expand the proof beyond the fixture actually tested.

The AU bench now defaults to the actual `present_core` Template raster and
compares every CE-qualified native RGB sample and every DE line against the
independent decoded picture. `FPGA_VIDEO_TB_SCANDOUBLE=0` selects the native
240p-class raster; the default is scandoubled. Both modes retain the actual
638-pixel line timing and safe-boundary swap, not a fabricated display tick.
`FPGA_VIDEO_TB_NATIVE_BEAM=0` selects the earlier sampled-store ownership model;
only in that mode does `FPGA_VIDEO_TB_VSYNC_CYCLES` select a synthetic interval
(default 128 system cycles). The selections are archived in `simulation.json`;
each `FRAME_PASS` reports the actual frame-store swap cycle
as `display_sys_cycles`. This is a cycle model, not a measured clock or frame-rate
qualification. The serialized controller drain, native copy and safe-swap wait
must all fit the delivery budget; decoder-only cycle headroom is insufficient.
The current full-size PMS pair has a 1002936-cycle display interval in this
native model (about 50.15 ms at an assumed 20 MHz), exceeding the 24-fps budget.
The basic runner uses synthetic AU timestamps; original-timing/cadence evidence
requires the separate original-timing oracle. Passing its pixels does not
establish sustained 24-fps delivery, HDMI fidelity or an audio-bearing tier.

The unchanged diagnostic assertions in
`test_p3_stream_path_recon_rtl_sim.sh` and the source-bound GOP12 oracle are
separate decoder gates. A passing constrained GOP12 fixture or publisher test
does not establish the missing full intra/color/filter behavior, actual
AU-to-decoder-to-display composition, timing closure, or cast/glass acceptance.
Codec-error-to-MVPS reporting remains unwired. A separately encoded, filter-off
two-IDR fixture can exercise the supported intra-only composition; it does not
waive the original filter-on fixture or qualify P decoding. Keep the actual
encoder command, encoded fixture and complete source identity with such a run.
