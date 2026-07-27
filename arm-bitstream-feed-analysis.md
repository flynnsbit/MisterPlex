# ARM→FPGA Bitstream Feed Analysis — w-feed

## TL;DR

**CTRL = 0 is dormant-by-design.** The ARM bitstream producer exists, is fully
wired, and is architecturally sound — but it is gated by a config flag (`STREAM`)
that defaults to `false`. The product configuration is `STREAM=0`. The producer
has never run because nobody asked it to. This is "not wired up yet", not
"wired up and failing".

**ERR = 0x00000001 is DDR boot residue, not a real error.** The FPGA-written
ERR word must have `PLXE` magic (`0x504C5845`) in bits [31:0]. The probe read
`0x00000001` — no magic match. The FPGA bitstream reader never wrote this
register, meaning either the reader was never enabled, or the DDR bus was
broken (the known clk_sys/clk_ddr mismatch on core `eeff4eee`).

---

## 1. The Gate: `STREAM` config flag

```
arm/misterplexd/main.cpp:105:    bool streamEnabled = false;         // DEFAULT OFF
arm/misterplexd/main.cpp:243:            streamEnabled = confTruthy(v);  // reads STREAM= from misterplex.conf
arm/misterplexd/main.cpp:354:    player.setStreamEnabled(streamEnabled);
```

The producer only runs when BOTH conditions are true:
```
arm/misterplexd/media_player.cpp:1953:
    const bool wantStream = streamEnabled_ && fpga_.ok() && !testPattern;
```

And `streamPump` (which owns the NAL demux + F3 feed) is only spawned when
`wantStream` is true. Product docs confirm:

```
docs/PHASE_BACKLOG.md:12:  | Conf | PRESENT=fpga STREAM=0 DECODE=320x240 |
docs/PHASE_BACKLOG.md:19:  product cast = STREAM=0 every-frame DDR F1 (not STREAM recon)
```

**When `STREAM=0` (default): no FFmpeg annex-B demux fork, no NAL scanner, no
FpgaBitstreamProducer, no ring writes. CTRL stays at whatever DDR holds from boot.**

## 2. Full End-to-End Path (when `STREAM=1`)

```
Plex server
  → HTTP transcode (h264_mp4toannexb or raw annex-B)
  → pipe(spipe) → fork spawnStreamDemux()
  → streamPump(sfd) reads pipe
  → consumeCompleteNals() finds NAL boundaries
  → pushF3Nal() → NalDispatcher::handleNal()
    → replays SPS/PPS before VCL
    → FpgaBitstreamProducer::pushNal()
      → FpgaSpi::pushBitstreamNal()
        → writeBitstreamRecord(Event::Nal, ...)
          → memcpy(bitstreamMap_ + wr, ...) into DDR ring
          → __sync_synchronize()
          → publishBitstreamCtrl() writes CTRL word
  → FPGA polls CTRL_PHYS, sees new write_count, reads ring data
```

The path exists, is complete, and has comprehensive session/error handling.

## 3. ERR = 0x00000001 Explained

The ERR word format (written by RTL `ddr_bitstream_reader.sv:318-321`):
```
{overrun_count[7:0], underrun_count[7:0],
 active, overrun_sticky, underrun_sticky, 5'd0,
 telem_seq + 1, MAGIC_ERR}
```
where `MAGIC_ERR = 0x504C5845` (PLXE).

Valid ERR words have `0x504C5845` in bits [31:0]. The probe read `0x00000001` —
magic does not match. This is NOT a valid ERR word. It is DDR residue from
boot/previous-core. The FPGA bitstream reader on core `eeff4eee` either:
- Was never enabled (no `enable` signal)
- Could not complete DDR writes due to the clk_sys/clk_ddr bus mismatch (fixed at 60df5a2)
- Predates the current telemetry implementation

**There is exactly zero evidence of "one error". The value is meaningless.**

## 4. Cache Coherency Assessment

**The ring buffer protocol is cache-coherent by construction:**

1. **`O_SYNC` mmap** — `ensureBitstreamDdrMap()` opens `/dev/mem` with `O_SYNC`:
   ```
   bitstreamMemFd_ = ::open("/dev/mem", O_RDWR | O_CLOEXEC | O_SYNC);
   ```
   On ARM, `O_SYNC` + `MAP_SHARED` on `/dev/mem` produces a strongly-ordered or
   device-type mapping. Stores go directly to the SDRAM controller, not the L1/L2
   data cache. No dcache flush is needed.

2. **Full barrier before counter update** — `writeBitstreamRecord()` line 617:
   ```cpp
   __sync_synchronize();   // ARM dmb sy — full memory barrier
   publishBitstreamCtrl(); // then write CTRL with new count
   ```
   This ensures the FPGA sees all data bytes before the counter advances.

3. **`volatile` pointer for CTRL/READ** — `publishBitstreamCtrl()` writes through
   a `volatile uint64_t*`, preventing compiler reordering.

**Verdict: The ordering contract is sound.** Data stores are uncached. A full
barrier separates data from the counter. The FPGA cannot read stale bytes from
the ARM's cache because the mapping bypasses the cache entirely.

## 5. Ring Protocol Mechanics

- **Ring size:** 256 KiB (`kRingBytes = 262144`)
- **Indexing:** Absolute byte counts; `read_ring_index = read_count[17:0]`
- **Wraparound:** Implicit via `bitstreamWriteCount_ & (kRingBytes - 1)`
- **Full/Empty:** `avail = write_count - read_count`; producer spins with backoff
  when `avail + recordLen > kRingBytes`
- **Session framing:** 32-byte record headers with PLXN magic, event type,
  session_id, seq, payload length
- **Sequence validation:** FPGA checks `expected_seq` vs record seq; sets
  `desync_sticky` on mismatch

No protocol bugs found.

## 6. What This Means for the Fleet

**The frozen screen / empty decode problem is NOT caused by a missing producer.**
The product path (`STREAM=0`) uses every-frame FFmpeg decode → DDR YUV420p F1 →
`ddram_frame_rd` → display. The bitstream ring is a separate, future path for
FPGA-native H.264 decode.

The fixes at `60df5a2` (clk domain) and `3c6d1d2` (response FIFO) are on the
DDR bus arbiter which is shared by both paths. Those fixes matter for the frame
store path too, not just the bitstream ring.

**The bitstream producer is ready. The consumer (FPGA decoder) is what's being
built. Nobody needs to "fix" the feed — they need to enable it when the decoder
is ready, by setting `STREAM=1`.**

---

## 7. Ring Capacity at Product Bitrate

**Requirement:** 25 fps at 1345 kbps, sustained indefinitely.

| Metric | Value |
|--------|-------|
| Average frame size | 6,725 bytes |
| Record size (incl 32B header) | 6,757 bytes |
| Ring capacity | 262,144 bytes (256 KiB) |
| Frames fitting in ring | ~38.8 |
| Ring depth (latency buffer) | ~1,552 ms |
| Required drain rate | 168,125 bytes/sec (1.34 Mbps) |
| DDR bus bandwidth | 720 MB/s (64-bit @ 90 MHz) |
| Bus utilization | 0.023% — **~4,000× headroom** |
| Worst-case IDR (40 KiB) | 15.6% of ring |

**Verdict:** The ring can comfortably sustain product bitrate. The constraint
is consumer latency (drain within ~1.5s to avoid Full), not bandwidth. The
FPGA's DDR bus has 4,000× the required throughput.

**Seek/pause/teardown analysis:**
- **Seek:** `flushForSeek()` → `producer.flush()` + `producer.end()` + new
  `begin()`. Clean session boundary. SPS/PPS cleared; demux provides fresh ones.
- **Pause:** `f3Dispatch.pause()` → FPGA holds last frame. NALs silently
  dropped. Resume replays SPS/PPS before next VCL.
- **PMS teardown mid-NAL:** Pipe EOF → `consumeCompleteNals` only pushes
  complete NALs (delimited by start codes). Trailing incomplete data is
  discarded. No mid-NAL splice can reach the ring. Session ends cleanly.

## 8. Fixture Injection (ioctl_download) Independence

The SPI `ioctl_download` path (`sendFileTx` → `sendBitstreamChunk`, index=3)
and the DDR ring path (`writeBitstreamRecord` → `publishBitstreamCtrl`) are
**completely independent:**

| Property | SPI/ioctl path | DDR ring path |
|----------|----------------|---------------|
| Hardware | GPO @ `0xFF706010` | `/dev/mem` @ `0x30100000` |
| Protocol | F3 file_tx download | PLXB/PLXN record ring |
| Concurrency | Requires Main SPI lock | No SPI involvement |
| Used by | Decode gate fixtures | Product stream feed |

Enabling the DDR ring **cannot** interfere with fixture injection. They share
no state, no locks, and no hardware paths.

## 9. STREAM=1 Completion Criteria

Evidence-based prerequisites for `STREAM=1` as shipping default:

### Hard gates (must be green, no exceptions)

| # | Gate | Evidence required | Current status |
|---|------|-------------------|----------------|
| G1 | **FPGA I-slice decode** produces pixel-exact output for at least one fixture | Full-frame ratchet `maeY=0` on `wcap_residual14` with native I420 from FPGA decode, not host recon | **Intra 300/300 MB exact** (P3-3l) but via host recon; FPGA consumer path not yet wired |
| G2 | **DDR bitstream reader** advances `READ` count and publishes PLXR magic after `beginBitstreamSession` | Live device: `readBitstreamFpgaCount` returns true, PLXR magic present | **NOT MEASURED** — requires `60df5a2`/`3c6d1d2` fixes on silicon |
| G3 | **No user-visible regression** — ARM decode path must remain available as fallback | `STREAM=1` with broken FPGA must not freeze or crash; must fall back to ARM decode | **Design OK** — `f3Fatal` path disables F3 without killing the FFmpeg RGB pipeline |
| G4 | **FPGA parser handles all NAL types in the stream** — SPS, PPS, IDR, P at minimum | `stream_path.sv` accepts all NAL types without desync/fatal | **PARTIAL** — SPS/PPS/IDR yes; P-slice inter output is measured red (MAE 76) |
| G5 | **PMS delivers Baseline/CAVLC** or FPGA handles CABAC | Either MiSTerPlex.xml forces Baseline+CAVLC, or FPGA CABAC engine exists | **BLOCKED** — PMS ignores Baseline request (delivers High/CABAC); no FPGA CABAC |

### Soft gates (should be green, waivable with evidence)

| # | Gate | Evidence required | Current status |
|---|------|-------------------|----------------|
| S1 | **Ring sustained at product bitrate** | 1000-frame host test at 1345 kbps without Full | **PASS** — `testRingCapacitySustain` in `test_bitstream_ring_lifecycle` |
| S2 | **Dormant state self-describing** | CTRL carries PLXD when `STREAM=0`; probes can distinguish from boot residue | **IMPLEMENTED** — `publishBitstreamDormant()` writes PLXD at startup |
| S3 | **Seek/pause/resume lifecycle** | Host test: session boundary clean, no mid-NAL splice, SPS/PPS replay | **PASS** — `testSeekFlushReset`, `testPauseResume`, `testMidStreamTeardown` |
| S4 | **beginBitstreamSession timeout** reasonable for cold core | 250ms may be too short if FPGA reader has a long poll interval | **NEEDS MEASUREMENT** on silicon with new RBF |

### The hard truth

**G5 is the structural blocker.** PMS delivers High/CABAC/B-slices regardless
of the Baseline XML profile request. The FPGA has no CABAC engine and no
B-slice support. Until either:
- PMS reliably delivers Baseline/CAVLC (server-side fix), or
- The FPGA gains a CABAC engine (P3-3n scoping says this is "not sane near-term")

...`STREAM=1` can only decode the I-slices (which are CAVLC even in a
High-profile stream), not the P/B-slices that make up 95%+ of frames. This
produces ~1 fps of decoded output (keyframe-only), which is worse than the
current ARM decode at 25 fps.

**The ARM cannot be retired until the FPGA can match its frame rate**, which
requires either CAVLC P-slice support or CABAC support. The producer path
(this work) is ready and waiting.

## Recommendations

1. **PLXD dormant magic** is now implemented. Deploy with next RBF to eliminate
   the uninitialized-DDR ambiguity.
2. When the FPGA decoder handles at least I+P CAVLC, enable `STREAM=1` in lab
   and measure end-to-end frame delivery.
3. The `beginBitstreamSession` 250ms timeout should be tested on silicon with
   the new RBF before shipping `STREAM=1`.
4. **G5 decision needed:** pursue PMS Baseline XML forcing (server-side) vs
   FPGA CABAC engine (RTL). This is a project-level architectural choice that
   determines the critical path to ARM retirement.
