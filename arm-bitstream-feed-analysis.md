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

## Recommendations

1. **No code changes needed on the producer side.** The path is sound.
2. When FPGA H.264 decode is ready, enable with `STREAM=1` in `misterplex.conf`.
3. The `beginBitstreamSession` 250ms timeout on FPGA read may need tuning for
   first-time startup of a cold core — consider a longer initial timeout.
4. Consider a diagnostic that logs the DDR mailbox magic validity at startup,
   so future probes can distinguish "never written" from "written then cleared".
