# Present pace ↔ doorbell contract (fab-pace × w-mem × w-clock)

**Lane:** w-osd (`fab-pace`) · **Default:** sequencer OFF (`present_pace_seq.ENABLE=0` / no `PLEX_FAB_PACE`)  
**No fit · No device** this lane.

## 1. Why this exists

Parent 720p real-content decode (4000k) left ~0.6–9 ms/f depending on tier. ARM still
paces, sleeps, and rings the present doorbell. That is jitter-prone and spends ARM
time that 720p cannot spare. Fabric already *applies* swaps at vsync inside
`ddr_frame_store.sv`; **fab-pace** makes unique-frame *policy* and counters explicit
and default-off so nostub is not destabilised.

## 2. Doorbell contract (writer = w-mem / ARM, consumer = pace seq)

| Signal | Owner | Rule |
|--------|-------|------|
| Bank payload in DDR | Writer | Fully written + ordered before doorbell |
| `pending_bank` | Writer | Bank index of payload just published |
| `pending_ready` | Writer/RTL | 1 only when reader may sample that bank |
| `swap_req_toggle` | Writer | Edge = “new frame available” (PLXK doorbell) |
| `vsync_pulse` | Present beam | 1-cycle at frame start only |
| `do_swap` / `disp_bank` | **pace seq** | Commit only on `vsync_pulse` |

**Never** change `disp_bank` mid-active-scan. Tear-free is non-negotiable.

### Late / early / drop

| Case | Behaviour (ENABLE=1) | Counter |
|------|----------------------|---------|
| Cadence wants unique, pending ready | Swap | `cnt_presented` |
| Cadence wants unique, **not** ready | **Repeat** last disp (not black) | `cnt_late`, `cnt_repeats` |
| Pending ready, cadence holds (2:3) | Keep pending, no swap | `cnt_early_hold`, `cnt_repeats` |
| New doorbell while still pending | Accept new pending (drop old) | `cnt_drops` |
| ENABLE=0 legacy | Swap every vsync if pending∧ready | same as today’s store |

## 3. Judder policy (product decision — surfaced, not silent)

**Default:** fixed `display_hz` (60 on most MiSTer HDMI modes) + `content_fps=24`  
→ `content_index = floor(n * 24 / 60)` → **2:3 pulldown** unique pattern (matches
`present_cadence.sv` / `cadence.hpp`, unit-tested).

**Alternatives (not selected by fab-pace alone):**
- Match-source 24 Hz or 48 Hz raster (see `docs/match-source-hz.md`) — removes 2:3
  judder but needs w-clock mode + display accept.
- 24-in-48 (1:1 on 48 Hz) if glass supports it.

Enabling `PLEX_FAB_PACE` does **not** change the HDMI video_mode; it only gates
*which* vsyncs consume a new DDR bank under the chosen content_fps/display_hz.

## 4. Multi-pixel beam (w-clock) × chrome (w-osd)

From `MisterPlex-wt-clock/.../MULTI_PIXEL_PRESENT_DESIGN.md` + `present_beam_ppc.sv`:

- Multi-pixel (`PRESENT_PX_PER_CLK` ∈ {1,2,4}) widens the **clk_sys present beam**
  (pre-ascal store read). Swap/pace remain **once per frame** on `frame_start` —
  **fab-pace is PPC-invariant.**
- **`plex_chrome` today** sits **post-ascal on `clk_hdmi`**, 1 pixel per `clk_hdmi`.
  Interface assumption: **chrome composites at HDMI ppc=1** unless a future change
  moves multi-pixel past ascal.
- If chrome is ever fed N lanes: hit-test must OR lanes `x0..x0+N-1` and emit N
  RGB outs; hx must not assume `+1` per clock. Tracked as follow-up; not required
  while chrome stays post-ascal 1ppc.
- HIT_SCAN/cmd list are geometry in **pixel units** (12-bit) — valid at 1280×720
  regardless of PPC.

## 5. ARM ms removed

**Unknown** until parent profiles with pace ON vs OFF.

Measurement:
1. `PRESENT_PROFILE=1` playback, plane paths as today — sum sleep/hold around
   publish (`read_eagain_sleep_us`, hold waits, any explicit frame sleep).
2. Enable fabric pace (macro + RBF) — ARM only publishes when a bank is free;
   no wall-clock “present deadline” sleep.
3. Diff ms/f.

Do not invent a number. Expected class: remove present-deadline sleeps / reduce
wakeups; DDR write cost remains until other lanes move it.

## 6. Integration plan (not done this commit)

1. `present_pace_seq` sim + unit gates (this lane) — **landed**.
2. Optional `ifdef PLEX_FAB_PACE` instance beside `ddr_frame_store` swap block —
   parent/w-mem fit after nostub.
3. PLXP-style counter mailbox for parent HDMI-less proof — follow-up.
4. ARM: when pace live, skip present deadline sleeps (mirror chromePlaneLive gate).

## 7. Red-before-green

| Gate | Expect |
|------|--------|
| ENABLE=0 + pending at vsync | swap, presented++ |
| ENABLE=1, 24/60, 5 ticks | unique advances match cadence.hpp |
| ENABLE=1, advance, !ready | late++, repeat, no swap |
| ENABLE=1, ready, !advance | early_hold++, no swap |
| vsync only | do_swap never without vsync_pulse |
