# w-fit lane status — hold ON (2026-08-02)

## Honest priority answer

**Do not abandon the lane.** Do **lower exclusive-fit priority** until w-osd-hires delivers a live PLXC `list_we` path.

| User problem | Fabric role? | w-fit now? |
|--------------|--------------|------------|
| 480p drops / bitrate > link (1.56 Mbit/s vs 2 M floor) | **No** — network/PMS request | **Out of lane** |
| ARM CPU blocked at 480p | **FALSE** (ERROR 15 retracted); decode ~5.8% of ffmpeg | Do not justify fits on this |
| Overlay low-res (bug #2) | **Yes** — post-ascal chrome on `pll_hdmi` | **P1 unmeasured** on c74c6863 (RAM elided) |
| Direct-play / kill PMS transcode | Long-term fabric decode | **Not current cargo**; honest goal if/when frame-store contract + decode path expand |

**Direct-play:** this lane *can* serve it later (PRODUCT_NO_STUB freed M10K/ALM; clk_sys ceiling up). It does **not** serve it with the chrome-only next fit. Say so plainly — next exclusive slot is for **viewable overlay**, not decode offload.

## Preconditions already met (static)

1. **Elision guard** — RED on c74c6863 live reports  
   `true rc=1` (bits=0 M10K=0, 1026 stuck `list_*`). Unit red↔green `true rc=0`. Tip `decc6ea1`.
2. **`stub_busy`** — **tied `1'b0`**, not deleted  
   `stream_path.sv:384`; pack still 8-wide `Plex.sv:890-893`; `status_telem_r[21]` preserved in map; telem gate `true rc=0`.
3. **c74c6863** — P2 playback PASS (parent viewed pixels); P1 **unmeasured**; archived bak; do-not-call “zero benefit.”

## What still blocks the slot

- `sys_top.v` still `.list_we(1'b0)` + `.BOOT_DEMO(1)` — product write path absent.
- Until PLXC drives `list_we`, any chrome fit is another NO-DATA burn.
- Parent hold ON until: elision green on **new** RBF + PLXC-live + prereg published.

## Baseline discipline (do not mix)

| Artifact | ALM | M10K | DSP | Role |
|----------|----:|-----:|----:|------|
| t7b `8fdf440f` (rollback daily) | 23,585 | 465 | 44 | pre-nostub live |
| **c74c6863** (nostub+chrome elided) | **14,354** | **197** | **43** | **next-fit baseline** |
| Parent note “21,078 / DSP 74 / 465” | — | — | — | **not** c74c6863; do not prereg against it without md5 proof |

Next-fit prereg (frozen in `STUB_BUSY_AND_ELISION_SETTLED.md`): ALM ~16.0k±1.5k · M10K 199–209 · DSP 43 · clk_ddr ≥+0.25 · pll_hdmi ≥+0.20 · elision **rc=0** · ledger FLAT.

## Meanwhile (no fit)

- Hold integration branch ready; **no Quartus**.
- Riders when a slot opens for other reasons: `907e5950` swap_pending NBA; −32 DSP comb dequant (UNMEASURED until map).
- `pending_ready` — no exclusive claim.
- No av-lock claims; no device touch.

## Abandon? 

**No** for overlay infrastructure + nostub base.  
**Yes** to treating w-fit as the owner of the 480p-drop or “CPU relief decode” stories — those are closed or not fabric.

When w-osd-hires signals PLXC `list_we` green in sim with elision expected to pass, request slot with prereg table above.
