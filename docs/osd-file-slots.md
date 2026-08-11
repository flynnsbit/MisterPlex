# OSD file slots

MiSTer `CONF_STR` file entries are `F<idx>,<ext>,<label>;`. The extension list is
parsed in fixed 3-character chunks by `Main_MiSTer` (`ScanDirectory` copies three
bytes at a time and advances `ext += 3`), so a four-character `.h264` or `.mp4`
suffix cannot match a single F slot as written.

## Product (v10+)

| Slot | Ext | Role |
|------|-----|------|
| **F1** | `mpx` | **Play local (daemon)** — load a tiny path stub; core publishes path to **PLXP**; `misterplexd` demuxes/plays the real media |
| **F3** | `264` | H.264 annex-B elementary fabric/lab test (ioctl → bitstream FIFO) |

F2 raw PCM/RGB565 loaders were removed from the OSD menu (not useful for product play).

### Local play flow

1. Place media under e.g. `/media/fat/Games/Plex/*.mp4`.
2. Generate stubs:

   ```bash
   /media/fat/misterplex/bin/gen_mpx_sidecars.sh /media/fat/Games/Plex
   # or from lab host: scripts/gen_mpx_sidecars.sh /media/fat/Games/Plex
   ```

   Each `clip.mpx` contains one absolute path line:

   ```text
   /media/fat/Games/Plex/clip.mp4
   ```

3. On MiSTer: load Plex core → F12 → **Play local (daemon)** → pick a `.mpx`.
4. Main streams ~100 bytes into F1; `path_ingest` captures them; `ddr_frame_store`
   writes the path buffer at `doorbell+0x138` and PLXP ctrl at `doorbell+0x130`.
5. `misterplexd` edge-detects PLXP and calls `MediaPlayer::play(path)` (same path
   as `curl …/play` or `--play-file`).

**Do not** put real multi‑MB `.mp4` files on F1 — Main would dump the entire file
into the core. Stubs only.

### PLXP ABI (see `mailbox_abi_spec.hpp`)

- Magic `PLXP` (`0x504C5850`)
- CTRL = `doorbell_phys + 0x130` — `[31:0] magic, [39:32] len, [63:48] seq`
- PATH = `doorbell_phys + 0x138` — up to 255 path bytes (host trims CR/LF)

### Legacy (pre-v10)

- `F1,raw,RGB565 frame (320x240);`
- `F2,raw,s16le stereo PCM @48k;`
- `F3,264,H.264 annex-B elementary;`

`F` entries and `J1` controller labels are metadata; they do not consume
`status[]` bits. The OSD v3 bit layout in `host/libmisterplex/osd_menu.hpp` is
unchanged for content/display resolution knobs; `v,10` resets saved menu state
after the F-slot change.
