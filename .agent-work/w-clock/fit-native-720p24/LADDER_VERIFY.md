# L0–L4 verify (pinned commits via git show/grep — no dirty shared main)

Parent note: live main may move during w-osd land; these pins are frozen.

## Pin `main_local` = `ad928cb1`
FRAME=640x480 BEAM_960=False MULTI=False qip_lines=34
| Module | ON_MAIN/pin | IN_QIP | INSTANTIATED | ENABLED | Level |
|--------|-------------|--------|--------------|---------|-------|
| `present_video_timing_720p.sv` | no | no | no | no | **L0** |
| `present_beam_content_de.sv` | no | no | no | no | **L0** |
| `present_vtotal_bresenham.sv` | no | no | no | no | **L0** |
| `plex_present_geom_mux.sv` | no | no | no | no | **L0** |
| `present_geom_latch.sv` | no | no | no | no | **L0** |
| `present_content_window.sv` | no | no | no | no | **L0** |
| `plex_content_fps_sel.sv` | no | no | no | no | **L0** |
| `present_core.sv` | yes | yes | yes | yes | **L4** |

## Pin `integ_v2` = `bd0433c5`
FRAME=640x480 BEAM_960=False MULTI=False qip_lines=71
| Module | ON_MAIN/pin | IN_QIP | INSTANTIATED | ENABLED | Level |
|--------|-------------|--------|--------------|---------|-------|
| `present_video_timing_720p.sv` | yes | yes | yes | no | **L3** |
| `present_beam_content_de.sv` | yes | yes | yes | no | **L3** |
| `present_vtotal_bresenham.sv` | no | no | no | no | **L0** |
| `plex_present_geom_mux.sv` | yes | yes | yes | no | **L3** |
| `present_geom_latch.sv` | yes | yes | yes | no | **L3** |
| `present_content_window.sv` | yes | yes | yes | no | **L3** |
| `plex_content_fps_sel.sv` | yes | yes | yes | yes | **L4** |
| `present_core.sv` | yes | yes | yes | yes | **L4** |

## Pin `integ_e2e` = `54721a7c`
FRAME=960x540 BEAM_960=True MULTI=False qip_lines=70
| Module | ON_MAIN/pin | IN_QIP | INSTANTIATED | ENABLED | Level |
|--------|-------------|--------|--------------|---------|-------|
| `present_video_timing_720p.sv` | yes | yes | yes | no | **L3** |
| `present_beam_content_de.sv` | yes | yes | yes | yes | **L4** |
| `present_vtotal_bresenham.sv` | no | no | no | no | **L0** |
| `plex_present_geom_mux.sv` | no | no | no | no | **L0** |
| `present_geom_latch.sv` | yes | yes | yes | yes | **L4** |
| `present_content_window.sv` | yes | yes | yes | yes | **L4** |
| `plex_content_fps_sel.sv` | no | no | no | no | **L0** |
| `present_core.sv` | yes | yes | yes | yes | **L4** |
