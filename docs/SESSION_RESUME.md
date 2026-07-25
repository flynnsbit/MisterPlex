# MiSTerPlex session resume — 2026-07-25

**Purpose:** Handoff after **VSync present / product A/V cast** milestone.  
**Repo:** `/home/shawn/Projects/misterplex`  
**Lab:** `root@192.168.1.183` (sshpass pass=`1`)  
**Full notes:** [`docs/MILESTONE_VSYNC_PRESENT.md`](MILESTONE_VSYNC_PRESENT.md)

---

## Snapshot

| Item | Value |
|------|--------|
| **Milestone** | VSync page-flip + DMA hold-off + product cast path |
| **Lab RBF** | **`1441d409ad3f8ccc5dcb0033c32ff7c8`** |
| **Host RBF** | `fpga/Plex_MiSTer/output_files/Plex.rbf` + `releases/Plex_vsync_tear_1441d409.rbf` |
| **CORE** | Plex |
| **Conf** | `PRESENT=fpga` `STREAM=0` `DECODE=320x240` |
| **User** | Video + vsync look good (2026-07-25 eyes-on) |
| **holdoff2** | half/mid/multi tear rates **0.00/s** — see milestone doc |

### What fixed tears

1. **Swap only on vsync** (`frame_store`) — no mid-scan bank flip  
2. **Hold DMA while `swap_pending`** (`ddram_frame_rd`) — no overwrite of completed back buffer  
3. **Host:** every-frame DDR present, wall-48k audio, doorbell kick, heal Main on stop  

### Re-verify

```bash
md5sum /media/fat/_Utility/Plex.rbf   # 1441d409…
# Cast via Plex Web → MiSTerPlex; set_status --status → has_frame=1
# HDMI capture /dev/video4
```

### Open (not this milestone)

- Dialogue lipsync on film still subjective  
- F12 may still need heal after long SPI sessions if doorbell falls back  
- Residual csum / WIDE bar work is separate backlog history  

---

**Do not** thrash RBF while this is green unless a new gate fails.
