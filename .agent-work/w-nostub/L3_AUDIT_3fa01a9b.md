# L3 audit — main@3fa01a9b (eleven present modules)

REF: detached/branch base 3fa01a9b
Active QSF macros: DDR_FRAME_STORE=1 FRAME_W=640 FRAME_H=480 FRAME_LINES_8=1
OFF (commented): PRESENT_BEAM_960 PRESENT_MULTI_PIXEL PRESENT_PX_PER_CLK PRESENT_CLK_PIX_PLL

| Module | ON_MAIN | IN_QIP | INST (product default) | ifdef gate | ENABLED | Level | Evidence |
|--------|---------|--------|------------------------|------------|---------|-------|----------|
| present_video_timing_720p | yes | yes | YES | none (always) | NO — noprune keep only | **L3-obs** | present_core.sv:176 `u_keep_timing_720p`; comment :166-170 observational, does not drive HDMI |
| present_video_timing_960 | yes | yes | YES | none (always) | NO — noprune keep only | **L3-obs** | present_core.sv:194 `u_keep_timing_960` |
| present_beam_content_de | yes | yes | NO | `ifdef PRESENT_BEAM_960` FALSE | no | **L2** | present_core.sv:211-237 instance inside ifdef; macro commented Plex.qsf:88 |
| present_beam_ppc | yes | yes | NO | `ifdef PRESENT_MULTI_PIXEL` FALSE | no | **L2** | present_core.sv:535/572 |
| present_npx_path | yes | yes | NO | `ifdef PRESENT_MULTI_PIXEL` FALSE | no | **L2** | present_core.sv:661 |
| present_pix_rate_match | yes | yes | NO | — no instance anywhere | no | **L2-orphan** | only module def present_pix_rate_match.sv:14 |
| present_content_window | yes | yes | NO | — no instance anywhere | no | **L2-orphan** | only module def; plex_present_geom_mux does not instantiate it |
| present_geom_latch | yes | yes | NO | — no instance anywhere | no | **L2-orphan** | only module def; comment ref in plex_present_geom_mux.sv:15 |
| present_vtotal_bresenham | yes | yes | NO | — no instance anywhere | no | **L2-orphan** | only module def |
| yuv_bt601_npx | yes | yes | NO | — no instance anywhere | no | **L2-orphan** | only module def; present_npx_path uses async_fifo not yuv |
| plex_present_geom_mux | yes | yes | NO | — no instance in Plex.sv/present_core | no | **L2-orphan** | only module def plex_present_geom_mux.sv:13 |

## Summary counts (product default macros)
- L3-obs (in netlist, not driving product video): 2 (timing_720p, timing_960)
- L2 gated (instance exists under FALSE ifdef): 3 (beam_content_de, beam_ppc, npx_path)
- L2-orphan (in qip, zero instances in tree): 6
- L4 product path: none of the eleven drive HDMI content at default

## Reachability from top
emu (Plex.sv) → present_core (Plex.sv:699) → always: keep timing 720/960
                                    → ifdef OFF: beam/npx
                                    → no edge to: geom_latch, geom_mux, content_window, pix_rate_match, vtotal_bresenham, yuv_bt601_npx

Quartus will strip L2-orphans and FALSE-ifdef bodies. L3-obs noprune keeps may survive map.
