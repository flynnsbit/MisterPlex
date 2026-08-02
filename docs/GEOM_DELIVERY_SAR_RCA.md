# Why AdvReal delivers `measured=624x480` but rk6/rk9 deliver `measured=624x350`

**Audience:** w-geom / parent RCA. Asset lane measurements only — no device claims.

## Measured on disk (ffprobe, true rc=0)

| asset | coded WxH | sample_aspect_ratio | display_aspect_ratio | notes |
|-------|-----------|---------------------|----------------------|-------|
| **rk6** `MiSTerPlex Test 480p (2026).mp4` | 624×480 | **160:117** | **16:9** | anamorphic |
| rk8 Soak 480p | 624×480 | 1:1 | 13:10 | square |
| **AdvReal** 624×480 arms | 624×480 | **1:1** | **13:10** | square |
| CBR-DP 624×480 | 624×480 | N/A (unset≈1:1) | N/A | square intent |
| Bank480 FullBleed rk27 | 624×480 | 1:1 | 13:10 | deliberate anti-letterbox |
| Real BBB GlassID **624×352** (rk≈9 class) | **624×352** | N/A | N/A | **native 352 rows** |

Commands (example):

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,sample_aspect_ratio,display_aspect_ratio \
  -of csv=p=0 "/home/flynnsbit/plex/media/movies/MiSTerPlex Test 480p (2026).mp4"
# → 624,480,160:117,16:9
```

## Arithmetic (not a device measurement)

\[
624 \times \frac{9}{16} = 351 \approx 350
\]

So a transcoder that honours **display** 16:9 while capping width at 624 naturally emits
**~624×350** coded frames. Daemon evidence already on record:

```text
MEASURED_DELIVERY_FINAL 624x350 producer_bytes=327600 reader_bytes=449280
# 624*350*1.5 = 327600; 624*480*1.5 = 449280
```

## What differs about AdvReal encodes (control)

`scripts/gen_adversarial_real_ladder.py` forces square samples:

```text
vf = f"scale={w}:{h}:flags=bicubic,setsar=1/1,fps={FPS_STR}"
```

`scripts/gen_bank480_fullbleed_vres_av.py` documents the rk6 trap and forces:

```text
setsar=1/1,setdar=624/480   # DAR 13:10, NOT 16:9
```

AdvReal / CBR-DP / FullBleed therefore present **coded height = display height = 480**.
PMS has no 16:9 letterbox excuse; parent measured `measured=624x480` on those arms.

## rk9 / 624×352

If rk9 is the Real BBB **624×352** title (library bitrate ~2154), then
`measured=624x350` is approximately **identity** to source height (352≈350), not a
downscale of a 480-row master. Do not conflate with rk6’s anamorphic 480→350 path.

## Implications for w-geom

1. **Library `Media@height=480` is a claim**, especially with non-1:1 SAR.
2. Favourable bank tests must use **SAR 1:1** fixtures (AdvReal, CBR-DP, FullBleed).
3. rk6 is a **DAR trap**, not proof that “480p path only gets 350 rows”.
4. On Direct-Play (`transcoded=0`) expect `library_media` claim = coded size; still
   log `measured=` — never assume delivery from metadata alone.

## Optional fix (asset lane, not done unless requested)

Re-wrap/re-encode rk6 with `setsar=1/1,setdar=624/480` (or replace with Soak/FullBleed
twins) so the historical short clip stops poisoning geometry intuition. Prefer a **new**
ratingKey over mutating rk6 in place if timelines depend on it.
