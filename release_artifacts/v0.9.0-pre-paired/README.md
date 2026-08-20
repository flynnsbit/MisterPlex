# MiSTerPlex v0.9.0-pre — paired cores

Load **one** named core from the Utility menu. There is no generic `Plex.rbf`.

| Load this (Utility) | Use it for | Matching daemon |
|---------------------|------------|-----------------|
| **Plex_480p** | HDMI 240p or 480p content | `misterplexd.480p` |
| **Plex_240p15** | 15 kHz 240p RGB CRT | `misterplexd.240p15` (same bytes as 480p) |
| **Plex_480i** | 15 kHz 480i RGB CRT | `misterplexd.480i` (same bytes as 480p) |
| **Plex_720p24** | Native 720p 24p HDMI (lab) | `misterplexd.720p24` |

Cast: Plex Web → **MiSTerPlex** → Play.

See `docs/release-notes-v0.9.0-pre.md` for 720p findings (unique-24 ingest,
one-HTTP remux PCM, Star Trek 40868 soaks).

## Install onto the MiSTer SD

```bash
./scripts/install_paired_all.sh
```

Or from the repo: `REL=release_artifacts/v0.9.0-pre-paired ./scripts/install_paired_all.sh`

Set `PLEX_BASE=http://YOUR-PLEX-SERVER:32400` in
`/media/fat/misterplex/misterplex.conf`. Keep `PRESENT=fpga`.

## How to play each pair

### HDMI 240p content — **Plex_480p**

F12 Content **240p**, Display **480p**. Display=240p on this core is a dead store.

### HDMI 480p content — **Plex_480p**

F12 Content **480p**, Display **480p**.

### 15 kHz 240p CRT — **Plex_240p15**

`[Plex] vga_scaler=0`. Do **not** set ascal 15 kHz `video_mode`.

### 15 kHz 480i CRT — **Plex_480i**

Same `[Plex] vga_scaler=0`.

### HDMI 720p 24p (lab) — **Plex_720p24**

F12 Content **720p**, Display **720p**. Star Trek-class 1080 HEVC is transcoded
to 1280×720; exclusive path is live PMS universal, not a local 720p file.

## Hashes (verify after copy)

| File | md5 |
|------|-----|
| `Plex_480p.rbf` | `07f54d9f8f0eda2fe75d9cc314f6de54` |
| `Plex_240p15.rbf` | `4d6efef954acf7b33747f35ac2878c1b` |
| `Plex_480i.rbf` | `61db00e7d54efad7c1a456b127b798bd` |
| `Plex_720p24.rbf` | `0eea3580a5a0dacf60bf65c50499bcc9` |
| `misterplexd.480p` / `.240p15` / `.480i` | `5f1c861486844f4c83bf32a2112cfbb6` |
| `misterplexd.720p24` | `0ffc1483677ef5733971d4f18e4624e4` |
