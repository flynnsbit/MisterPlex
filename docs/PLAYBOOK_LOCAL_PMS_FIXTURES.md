# How to play fixture assets (local PMS only)

**Host:** `http://192.168.1.24:32400`  
**Ignore:** SHIELD `192.168.1.122`, remote `plex.nevertrustaf.art`  
**Section:** library section **2** (“MiSTerPlex Tests”)  
**Token:** `$TOK` from your lab file — never commit it.

## 1. Copy files into the media mount

PMS docker `plex` mounts `~/plex/media` → `/data`. Movies live in:

```bash
MEDIA=~/plex/media/movies
cp -f assets/avsync/sync_audio_id_glass_480p24_1800s.mp4 \
  "$MEDIA/MiSTerPlex AudioID Glass 480p 24fps 1800s (2026).mp4"
cp -f assets/avsync/sync_audio_id_glass_480p24_60s.mp4 \
  "$MEDIA/MiSTerPlex AudioID Glass 480p 24fps 60s (2026).mp4"
cp -f assets/avsync/sync_audio_id_glass_480p24_60s_audioPlus100ms.mp4 \
  "$MEDIA/MiSTerPlex AudioID Glass 480p 24fps 60s audioPlus100ms (2026).mp4"
cp -f assets/avsync/sync_glass_av_480p24_600s.mp4 \
  "$MEDIA/MiSTerPlex AVSync Glass 480p 24fps 600s (2026).mp4"
cp -f assets/avsync/disc_nyquist_480p_624x480.mp4 \
  "$MEDIA/MiSTerPlex Disc Nyquist 480p 624x480 (2026).mp4"
cp -f assets/avsync/disc_nyquist_240p_320x240.mp4 \
  "$MEDIA/MiSTerPlex Disc Nyquist 240p 320x240 (2026).mp4"
```

(Agent may have already copied these; re-copy is safe.)

## 2. Refresh section 2 and read ratingKeys

```bash
curl -sS "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
# poll
curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" \
  | tr '>' '>\n' | rg -n "AudioID|AVSync|Nyquist|OCRProof|ratingKey"
```

Cast by **ratingKey** via your usual companion / Plex client path to the MiSTer
(parent-owned). Confirm Direct Play when possible (`MISTERPLEX_BASELINE_KEY` may
be unenforced).

## 3. Which fixture for which agent

| need | asset | notes |
|------|-------|-------|
| w-avsync lipsync | AudioID 60s / 1800s / AVSync glass | checksummed FSK + body flash; +100ms twin for RED |
| w-instr 240 vs 480 | Disc Nyquist 480 + 240 pair | ceiling energy; see verify JSON |
| long soak + CPU% | AudioID **1800s** | 10ppm→18ms drift window; sample ARM% yourself |
| glass frame drops | OCRProof 480p rk13 / AudioID | fixed-width + bars; not PLXD drops |

## 4. ffprobe every time (never trust PMS alone)

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,nb_frames,duration,profile,has_b_frames \
  -of default=noprint_wrappers=1 FILE
```

Expect **r_frame_rate=24/1** on these fixtures (ERROR 17 class).
