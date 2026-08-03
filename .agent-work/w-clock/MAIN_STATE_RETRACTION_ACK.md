# Parent main-state retraction — ACK (w-clock)

**When:** parent broadcast retracting “files.qip 34→45 / 720p modules on main”  
**Our measure (this note):**

```
HEAD_BRANCH=w-clock-bump
HEAD_SHA=6009ddec449f40774e93a1ed5c557c3a1524a33b
main_SHA=ad928cb1ac6c62633308ca1a683dabb0d38fa59b
MEASURE_REF=ad928cb1   # git show / cat-file only — not shared dirty tree
qip_lines=34
```

| Module | ON_MAIN | IN_QIP | Level |
|--------|---------|--------|------:|
| present_video_timing_720p | no | no | **L0** |
| present_content_window | no | no | **L0** |
| present_geom_latch | no | no | **L0** |
| present_beam_content_de | no | no | **L0** |
| plex_present_geom_mux | no | no | **L0** |
| h264_intra_nb_ctx | yes | no | **L1** (file on main, not qip) |
| present_core | yes | yes | **L4** (640×480 product) |
| present_cadence | yes | yes | **L4** |

**MATCHES parent retracted-truth.** w-clock’s LADDER_VERIFY / INTEGRATION_LADDER  
already listed main@ad928cb1 as **L0** for the 720p present stack — **no plan  
revert required** for “dead code on main needing instantiate.”

Still in flight: `w-osd-land-720p-present` (branch, not main).  
Physics GO/NO-GO + fit kit **unaffected** (STA artifacts, not main tree).

**Rule adopted:** every repo-state claim quotes `HEAD`/`MEASURE_REF` sha.
