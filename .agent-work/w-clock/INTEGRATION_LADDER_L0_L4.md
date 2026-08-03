# w-clock integration ladder (L0–L4)

**Pinned main inspected (detached via `git show`, not shared dirty tree):**  
`main` = `ad928cb1` (also checked `da64f7a9` — same present qip: 34 lines)  
**Branch tip:** `3aed2b69` `w-clock-bump`  

Parent later measured main with 45 qip + dead L2 modules; **this worktree’s main does not yet contain that land** (still 34-entry qip). Numbers below are **MEASURED here**. If parent main is ahead, re-pin and re-run.

**Ladder:** L0 written → L1 ON_MAIN → L2 IN_FILES_QIP → L3 INSTANTIATED → **L4 ENABLED** = product.

---

## Main @ ad928cb1 / da64f7a9 (product truth)

| Module | ON_MAIN | IN_QIP | INSTANTIATED | ENABLED | Level |
|--------|---------|--------|--------------|---------|------:|
| `present_core.sv` | yes | yes | yes (`Plex.sv`) | yes | **L4** |
| `present_cadence.sv` | yes | yes | yes (via core) | yes | **L4** |
| `present_beam_content_de.sv` | **no** | no | no | no | **L0** |
| `present_vtotal_bresenham.sv` | **no** | no | no | no | **L0** |
| `present_video_timing_720p.sv` | **no** | no | no | no | **L0** |
| `present_video_timing_960.sv` | **no** | no | no | no | **L0** |
| `present_beam_ppc.sv` | **no** | no | no | no | **L0** |
| `present_npx_path.sv` | **no** | no | no | no | **L0** |
| `present_pix_rate_match.sv` | **no** | no | no | no | **L0** |
| `plex_present_geom_mux.sv` | **no** | no | no | no | **L0** |
| `plex_content_fps_sel.sv` | **no** | no | no | no | **L0** |
| `yuv_bt601_npx.sv` | **no** | no | no | no | **L0** |

**Main product anchors (MEASURED):**
- `Plex.qsf`: `FRAME_W=640` `FRAME_H=480` — **still 480p**
- `PRESENT_BEAM_960` — **not set** (no enable)
- `Plex.sv`: `.use_frame_store(1'b0)` — force-bars off; DDR path compile via `DDR_FRAME_STORE=1`

Native 720p24 physics is not the blocker on this pin — **L0 for beam stack** is.

---

## Branch `w-clock-bump` @ 3aed2b69 (not product until land + enable)

| Module | ON_MAIN | IN_QIP (branch) | INSTANTIATED (branch) | ENABLED (branch QSF) | Level on branch | Level if merged as-is to current main QSF |
|--------|---------|-----------------|----------------------|----------------------|----------------:|------------------------------------------:|
| `present_beam_content_de.sv` | no | **yes** | **yes** under `` `ifdef PRESENT_BEAM_960 `` | **no** (macro off; FRAME 640×480) | **L3** | would be L2/L3 dead until macro+FRAME |
| `present_vtotal_bresenham.sv` | no | **yes** | **yes** under BEAM_960 | **no** | **L3** | same |
| `present_video_timing_720p.sv` | no | **yes** | **yes** under `` PRESENT_MULTI_PIXEL `` | **no** | **L3** | L2/L3 dead without MULTI |
| `present_beam_ppc.sv` / `npx` / `pix_rate_match` | no | yes | under MULTI | **no** | **L3** | dead without MULTI |
| `present_video_timing_960.sv` | no | yes | constants / weak | **no** | **L2** | L2 |
| `plex_present_geom_mux.sv` | no | **yes** | **no** (comments only) | no | **L2 DEAD** | **L2 dead code** |
| `plex_content_fps_sel.sv` | no | yes* | **yes** `Plex.sv:268` | partial (wired; q5 path) | **L3** | needs land |
| `yuv_bt601_npx.sv` | no | yes | under MULTI in store | **no** | **L3** | off |

\*confirm fps_sel in branch files.qip:

### Honest summary
- **Nothing w-clock added for Route-B/native beam is L4 on main.**
- On branch, beam/bresenham are **L3 behind `PRESENT_BEAM_960`**, and product QSF **does not enable** it → **not L4 even on branch default build**.
- `plex_present_geom_mux` is **L2 dead on branch** (QIP yes, **zero instances**) — exactly the parent defect class.
- `present_video_timing_720p` is L3 only under MULTI_PIXEL (off) — **not** the native 720p24 GO packet path.

### What parent must sequence for L4 (Route B glass or native)
1. Land modules (L1) + files.qip (L2) — path-filtered, after w-osd order.
2. **Instantiate** mux/latch/window in `Plex.sv` / `present_core` (L3) — mux is not instanced today.
3. **Enable** (L4): `PRESENT_BEAM_960=1` **and** `FRAME_W/H` match (960×540 Route B) **or** native 1280×720 + raised clk per GO/NO-GO — not commented, not 640×480.
4. `use_frame_store` stays `0` for product ext DDR; B20 arms on ext path.

### w-clock will not claim
- “Integrated present path” without L4 fields.
- L2 QIP-only as done.
- GO/NO-GO paper as ship (still ship-proof NO until fit + L4).

