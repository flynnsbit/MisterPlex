# Cast from `.41` (4edd44aa) — reproduce user “nothing plays”

**TS:** 2026-07-30T17:41Z · **Daemon** `fb9f7619` · **RBF** `14eaeff3` · **CORENAME** Plex  
**SERVER UNDER TEST:** `http://192.168.1.41:32400` · machineIdentifier **`4edd44aac1de0b731553a3a187104ecd175571a0`**  
**Not this report:** plex.direct / `1cdd1b7f…` (user’s earlier long title rk=40868)

## Media-URL HTTP status (lead fact)

| Probe | HTTP | Notes |
|-------|------|-------|
| **Live ffmpeg `-i` URL** `http://192.168.1.41:32400/video/:/transcode/universal/start.mp4?…path=/library/metadata/12…` with conf token + player headers | **`200`** | `Content-Type: video/MP2T`, body starts `47 40…` (MPEG-TS sync) |
| Same URL + `Range: bytes=0-1023` | **400** HTML | **instrument footgun** — not the player path |
| `/decision` sibling URL (ad-hoc) | **400** | not what ffmpeg fetches |

**Artifact:** `01_media_http_and_webpath.txt`

## Reproduce result — **API cast from `.41` PLAYS**

| Step | Result |
|------|--------|
| `playMedia` … `address=192.168.1.41` `machineIdentifier=4edd44aa…` rk=12 | **HTTP 200** ACK |
| Daemon receives | **Yes** — log `playMedia ACK` + `resolved PMS … base=http://192.168.1.41:32400` |
| ffmpeg starts | **Yes** — `-i http://192.168.1.41:32400/.../start.mp4` |
| Frames / time | **Yes** — `state=playing` `time` 0 → **41s+** in ~few seconds; `media: frames=15…` |
| Conf-only playMedia (no address) | Also plays; base falls back to conf `.41` |

**User report “nothing plays from .41” was NOT reproduced** on the product playMedia→ffmpeg path with conf token and `.41` library rk=12.

Predictions: P1 HIT · P2 HIT · P3 HIT (200 + ffmpeg) · P4 N/A (no fail) · P5 partial below.

## Side-by-side vs plex.direct (divergence)

| | **`.41` / `4edd44aa`** (this run + p480 soaks) | **plex.direct / `1cdd1b7f`** (user Web cast rk=40868) |
|--|--|--|
| playMedia address | `192.168.1.41` http | `75-30-183-153…plex.direct` https |
| Library item | rk=12 exists | rk=40868 **404 on .41** |
| Media host | `.41` | plex.direct |
| Playback | **Works** (measured here + soaks) | **Worked** (time→1.1e6) |
| Timeline host | `.41` | plex.direct |
| Conf token on host | sections **200** | sessions **401** |

**First divergence:** cast `address` + `machineIdentifier` + which library exists — **not** “ffmpeg never starts on .41.”

## Provenance of prior metrics

| Evidence pack | Server in playMedia / PLAY URL |
|---------------|--------------------------------|
| p480-verify / p480-audio / p480-headroom | **`.41` / `4edd44aa`** (lab commandIDs, rk=6/12) |
| User “Encounter at Farpoint” session | **plex.direct / `1cdd1b7f`**, rk=40868 |

**480p CPU/A-V numbers were measured against node-worker1 `.41`, not the plex.direct machine.**  
They are **not** automatically invalidated by the dual-server finding.  
The **user’s long Web cast** was a **different PMS identity**.

## Media-fetch vs timeline status-blind sink

| Path | Success criterion | 401/400 HTML |
|------|-------------------|--------------|
| Timeline `plexHttpGetNoBody` | `!body.empty()` | **counts OK** (known defect) |
| `ensureUniversalDecision` | body contains `MediaContainer` or `transcodeDecisionCode` | **rejects** plain 400 HTML (no those markers) |
| **Actual media** | **ffmpeg** reads `start.mp4` | ffmpeg fails on HTML; **not** the same bool sink |

On this `.41` success path, media GET is real **200 MP2T**. Status-blind timeline sink remains a separate bug; **it did not block .41 media in this reproduction.**

## What the daemon believed (quoted)

```
resolved PMS universal 480p 320x240 /library/metadata/12 title=Sync 24000 Long Blip
  dur=360021 transcode=1 base=http://192.168.1.41:32400
PLAY http://192.168.1.41:32400/video/:/transcode/universal/start.mp4?...&X-Plex-Token=REDACTED
```

Conf: `PLEX_BASE=http://192.168.1.41:32400`. Token used = conf token (works on `.41`).

## What we still do **not** have

1. A captured **failed** Web UI cast from `.41` in `misterplexd.log` during this window — only lab `.41` casts + user plex.direct casts.  
2. Proof of the user’s exact UI click path failing right now.  
3. Whether “nothing plays” means **no ffmpeg** vs **frozen idle/screensaver** (other lane) while audio/frames advance off-screen.

**`.41` reachability** during this run: 5/5 identity **200** (~10 ms). Earlier today device saw brief `No route to host` to `.41` — flapping possible but **not** seen in this reproduce window.

## Device left

navigation · no ffmpeg · RBF `14eaeff3` · daemon `fb9f7619` · Plex · DECODE 320x240 · PROFILE 0 · bit4 clear.  
**No binary/RBF change.**

## Handoff

- **w-timeline:** media path on `.41` is OK with conf token; timeline status-blind still matters for scrubber; dual PMS ids still real.  
- **User / parent:** if cast from `.41` Web still fails, need one failing attempt while we watch the log — or confirm symptom is **idle screen frozen** (visual) rather than no `playMedia`.  
- **Scaler S1–S3:** still parked.
