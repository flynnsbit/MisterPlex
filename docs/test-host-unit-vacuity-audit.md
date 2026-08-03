# Host/unit vacuity audit (W-GATE)

Base/tip audited: `97a974c0a82471aa5f2fd22d8c126ca5d495dc73`.

Pre-registration, before running mutations: `sound=14, vacuous=1, over-tight=1`
for the high-blast-radius host/unit probes below. Actual before fixes:
`sound=13, vacuous=2, over-tight=1`. I predicted the wrong split.
After `a902e1e`, the two vacuous mailbox probes are sound on clean code.

Method for compiled tests: delete the target binary, build with the absolute
`$ROOT/build/...` make target, require build rc 0 unless the expected failure is
a compile-time assertion, then run the rebuilt binary. This avoids stale-binary
false greens.

## Findings fixed in `a902e1e`

| Probe | Property claimed | Mutation | Result | Verdict |
| --- | --- | --- | --- | --- |
| `test_input_mailbox` | Host mailbox/status ABI constants are pinned to the hardware contract, not merely self-consistent with the decoder. | `kFrameStoreDebugFormatError` changed from the ABI value to a neighboring value. | Before the fix this stayed green because the test only round-tripped through the drifted constant. After the fix: `build_rc=0 run_rc=1`; `FAIL ... test_input_mailbox.cpp:105: kFrameStoreDebugFormatError == 0xE1u`; `test_input_mailbox: 1 failure(s)`. | Vacuous before fix; sound after fix. |
| `test_sdram_mailbox` | PLXM summary/diag magic and version are fixed ABI values, not just constants reused by encoder and decoder. | `kSummaryMagic` changed to an unrelated value. | Before the fix this stayed green because the valid word was built from the same drifted constant. After the fix: `build_rc=0 run_rc=1`; `PLXM summary magic drifted`. | Vacuous before fix; sound after fix. |

## Mutation audit table

| Probe | Property claimed | Mutation | Quoted result | Verdict |
| --- | --- | --- | --- | --- |
| `test_unit_rollcall.py` | Unit-unlocked prerequisites/commands are measured, not just a hardcoded list. | Add an unregistered unit-unlocked command to `Makefile`. | `rc=1`; `UNIT_ROLLCALL_FAIL`; `UNIT_ROLLCALL_COUNTS actual_prereqs=33 expected_prereqs=33 actual_commands=87 protected_commands=84 expected_commands=83`; `UNREGISTERED_COMMAND $(ROOT)/build/wgate_unregistered_test -- register this unit-unlocked command`. | Sound. |
| `test_frame_store_math` layout | DDR layout derives stride/doorbell from frame bytes and alignment. | Force the layout stride to a fixed large stride. | `rc=1`; `FAIL ... test_frame_store_math.cpp:51 l.bank_stride == derivedStride`; `FAIL ... test_frame_store_math.cpp:54 l.doorbell_phys == derivedDoorbell`; `test_frame_store_math: 4 fails`. | Sound. |
| `test_frame_store_math` bank alternation | Present-bank selection alternates only on successful sends and propagates to doorbell/SPI offsets. | Return the current bank instead of toggling on send-ok. | `rc=1`; `DDR bank alternation failed for doorbell: saw 0,0,0,0; expected 0,1,1,0`; `DDR bank alternation failed for SPI status[13]: saw 0,0,0,0; expected 0,1,1,0`; `DDR publish alternation failed: saw banks 0,0,0,0; expected 0,1,0,0`. | Sound. |
| `test_osd_menu` | The OSD 480p profile is tied to the coded-width contract, not stale display dimensions. | Change the 480p content-resolution return to stale width/label. | `rc=1`; `FAIL ... test_osd_menu.cpp:57: decodeOsdWord(1u << 4).contentResolution.width == kPlex480pCodedWidth`; `FAIL ... test_osd_menu.cpp:59: std::string(decodeOsdWord(1u << 4).contentResolution.label) == "624x480"`; `test_osd_menu: 2 failure(s)`. | Sound. |
| `test_resolve` | PMS transcode profile/headers advertise the coded 480p geometry. | Change the 480p profile resolution string to stale display geometry. | `rc=1`; `FAIL ... test_resolve.cpp:64: w480.videoResolution == "624x480"`; `FAIL ... test_resolve.cpp:82: start480.find("videoResolution=624x480") != std::string::npos`; `FAIL ... test_resolve.cpp:101: caps480.find("videoDecoders=h264{profile:baseline&resolution:624x480&level:30}") != std::string::npos`; `test_resolve: 6 failures`. | Sound. |
| `test_pms_timeline` | PMS timeline reporting uses the required Plex client/product identity. | Change `X-Plex-Product` default. | `build_rc=0 run_rc=1`; `FAIL ... test_pms_timeline.cpp:80: header(sent[0], "X-Plex-Product") == "Plex Web"`; `test_pms_timeline: 1 failures`. | Sound. |
| `test_status_telemetry` | Raw status/recon signature byte offsets are pinned. | Move `kReconSigByte`. | `rc=2` at build; `error: static assertion failed: raw[14] recon_sig`; `make: *** [.../build/test_status_telemetry] Error 1`. | Sound; compile-time guard localizes the drift. |
| `test_last_frame_latch` | Last-frame latch bank physical address uses the derived layout stride. | Replace derived bank stride in the latch with a fixed stride. | `build_rc=0 run_rc=1`; `FAIL ... test_last_frame_latch.cpp:78: s.bank_phys == expectedPhys`; `test_last_frame_latch: FAILED checks=29 failures=1`. | Sound. |
| `test_avclock` | Audio-less/no-audio-yet EOF fallback uses video silence rather than being disabled by audio silence. | Return `noAudioMs` unconditionally from the silence selector. | `rc=1`; `FAIL ... test_avclock.cpp:133: eofStallAudioSilenceMs(false, false, 6000, 0) == 6000`; `FAIL ... test_avclock.cpp:136: knownDurationEofStall(...)`; `test_avclock: 4 failures`. | Sound. |
| `test_ddr_publish_path_static.py` | All publish paths pass through `publishDdrFrame` with the expected contexts. | Rename the idle context string without changing publish behavior. | `rc=1`; `FAIL ddr_publish_path_static: expected publish contexts ['idle DDR', 'recon DDR', 'playback DDR'], saw ['idle frame DDR', 'recon DDR', 'playback DDR']`. | Over-tight: it protects call-site coverage but is coupled to diagnostic string spelling. |
| `test_bitstream_ring_lifecycle` | The ring producer copies accepted NAL payload bytes and lifecycle stats expose transport failures. | Make the push loop stop appending bytes. | `rc=-11`; first failures include `FAIL ... test_bitstream_ring_lifecycle.cpp:98: ring.snapshot().size() > 0`; `FAIL ...:99: ring.snapshot().size() >= sps.size() + pps.size() + idr.size()`; `FAIL ...:394: got.size() > 100`. | Sound; the mutant also exposed later unsafe assumptions after the first failures. |
| `test_companion_eof` | Real terminal EOF/disconnect clears media identity and returns timeline location to navigation. | Make `endMediaSession` call the non-terminal stopped path. | `build_rc=0 run_rc=1`; `FAIL: EOF did not return to navigation: ... location="fullScreenVideo" ... key="/library/metadata/3" ...`. | Sound. |
| `test_companion_plant_seek` | Empty/failed demux after a planted seek must preserve the scrubber bind and time. | Clear media in the non-terminal stopped path. | `build_rc=0 run_rc=1`; `FAIL: planted seek was cleared by stopped@0: ... location="navigation" ... time="0" duration="0" ...`. | Sound. |
| `test_pixel_format` | RGB565 packing/expansion and YUV conversion are bit-exact. | Shift the red field by the wrong amount in `packRgb565`. | `build_rc=0 run_rc=1`; `FAIL ... test_pixel_format.cpp:22: packRgb565(255, 0, 0) == 0xF800`; `FAIL ... test_pixel_format.cpp:51: (bgra[0] == 0 && bgra[1] == 0 && bgra[2] == 255 && bgra[3] == 255)`; `test_pixel_format: FAILED checks=17 failures=4`. | Sound. |

## Boundary

This audit focused on host/unit tests whose false-green blast radius is highest:
geometry derivation, DDR bank/doorbell addressing, mailbox ABI, EOF/terminal
state, PMS identity, and roll-call coverage. Decode numeric fixtures and RTL
simulation vectors are intentionally excluded here because W-MCFIX owns that
parallel numeric-fixture vacuity audit.
