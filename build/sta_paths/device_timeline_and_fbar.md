# Device Timeline & FBAR Gate Justification

## Device Timeline — w-cap Deploy Record

| Event | UTC Timestamp | Evidence |
|-------|--------------|----------|
| RBF copied to device | Jul 28 00:29 UTC | `scp` to `/media/fat/Plex.rbf` |
| `load_core` issued | Jul 28 00:29:30 UTC | `/dev/MiSTer_cmd` write |
| First mailbox read (new) | Jul 28 00:30 UTC | PLXF seq incrementing ~90/s |
| Second stability read | Jul 28 00:31 UTC | All 4 magics stable |
| Third stability read | Jul 28 00:32 UTC | Confirmed stable, PLXS=0x07150010 |

**Core loaded on device since Jul 28 00:29 UTC:**
- md5: `9f364cb1c09a51fc50d0792978889cbf`
- NOT in banned set (confirmed: prefix `9f364cb1` ∉ {8832824e, 75da8bb1, 4d6ee356, 4deaf6cc, dabdaeb0, 94bbfe43, ec21e133, eeff4eee})
- Source: `aed1e8f` (feat/cap-sdc-cdc), based on `e503b09` + 6 SDC constraints

**Previous core (before deploy):**
- md5 prefix: `eeff4eee` (in banned set)
- Was loaded: unknown install time, observed stuck at seq=4 across all pre-deploy reads

**For w-osd reconciliation:** If w-osd's ARM ladder measurements were taken AFTER
Jul 28 00:30 UTC, they measured the `9f364cb1` core, NOT the old `eeff4eee` core.
w-osd must provide their measurement timestamps (UTC) to resolve attribution.

**I cannot reconcile unilaterally** — I know when I deployed; I do not know when
w-osd's measurements were taken. Parent must facilitate timestamp comparison.

## FBAR Gate — Status and Justification

### Why FBAR Cannot Be Run

`tests/hw/test_fbar_fast.sh` lines 1-13 self-document as **OBSOLETE on Plex core v3+**:

> "The v3 CONF_STR removed the debug menu items this script drives — Pattern,
> Audio tone and Force bars — and reclaimed status[9:6] for the video delay.
> `pattern`, `audio_en` and `use_frame_store` are now hardwired to 0 in Plex.sv,
> so there is no way to ask the core for colour bars any more."

The FBAR test drives OSD bits that no longer exist. Running it against a v3+ core
writes bogus values into the video delay field and always fails. **The test fixture
was removed from the product, not the test from the suite.**

### What FBAR Covered

1. OSD status bits control the core (ARM→FPGA communication)
2. Pattern generator produces expected color bars
3. HDMI output shows the generated pattern (end-to-end video path)

### What Currently Covers Each Function

| FBAR coverage | Current replacement | Strength |
|--------------|-------------------|----------|
| ARM→FPGA communication | Mailbox liveness: PLXS/PLXM/PLXF/PLXK magic + seq counters | EQUAL (proven, instrumented) |
| Video output path active | `frames_done` advancing at 61.7/s (w-osd measurement) | WEAKER (internal counter, not HDMI capture) |
| Correct visual output | **NOTHING** | GAP |

### Honest Assessment

**The visual verification gap is real.** FBAR proved the HDMI output was correct by
capturing frames. Nothing in the current suite captures HDMI output and compares it
to expected content. The mailbox and counters prove the data path is running but do
NOT prove what appears on screen.

**However:** The current design produces underrun_count=0xFFFF (saturated) because
no stream is loaded, and the frame store has no meaningful content to display. A visual
verification test has no valid expected output to compare against until:
- A real stream is loaded, OR
- A test pattern generator is re-added to the core

**Recommendation:** Do NOT retire the FBAR gate silently. Instead:
1. Acknowledge the gap: no end-to-end visual verification exists for v3+
2. When a stream can be loaded (daemon integration), create a new visual gate that
   captures HDMI and compares against known-good frames
3. In the interim, accept mailbox + frame_counter as best-available but explicitly
   weaker than HDMI capture

**The gate is not dropped; it is acknowledged as inapplicable with a stated gap.**
