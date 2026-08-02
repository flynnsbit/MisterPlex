# CBR-DP ladder — proving Direct Play (or voiding the rung)

**Why this doc exists:** PMS shares this workstation with the agent fleet.
Transcode speed is confounded with host CPU. A Direct-Play asset has **no**
Plex Transcoder, so that confound vanishes. **If a rung is transcoded, it is
not a data point** — report VOID, not a `supply_ratio`.

## Fixture contract (already encoded)

| property | required | ladder status |
|----------|----------|---------------|
| H.264 | yes | yes |
| Constrained Baseline | yes | yes (measured) |
| level ≤ 3.0 | yes | level **30** measured |
| B-frames | 0 | has_b_frames=**0** |
| AAC 48 kHz stereo | yes | yes |
| fps | declared | **24/1** ffprobe (not 23.976) |
| glass ID every frame | yes | yes |

Files: `~/plex/media/movies/MiSTerPlex CBR-DP *`  
Docs/table: `docs/CBR_DIRECTPLAY_LADDER.md`  
rks (section 2): **108=400, 109=800, 105=1200, 106=1600, 107=2000, 110=640×480@1200**

## HARD GATE — STREAM mode decides DP vs universal

Quoted from `arm/misterplexd/main.cpp` (resolve call site):

```cpp
// STREAM=1: prefer direct H.264 Part for CAVLC host recon; still weakAlways for
// non-H.264. STREAM=0: always weak universal (dual-A9 cast path).
return misterplex::resolvePlayTarget(..., /*weakAlways=*/true,
                                     ..., /*preferDirectH264=*/streamEnabled);
```

And `arm/misterplexd/plex_resolve.cpp`:

```cpp
const bool wantDirect = preferDirectH264 && key.rfind("/library", 0) == 0;
// ...
if (directH264) {
    ...
    r.transcoded = false;
    r.detail = "direct H.264 Part (STREAM" + profSuffix + ")";
    return r;
}
// Prefer weak universal for dual A9 (STREAM=0 cast path / non-H.264 STREAM)
if (weakAlways && key.rfind("/library", 0) == 0) {
    ...
    r.transcoded = true;
    r.detail = "PMS universal " + ...
}
```

| conf | preferDirectH264 | expected for CBR-DP H.264 library asset |
|------|------------------|----------------------------------------|
| **STREAM=1** | true | **Direct Part** → `transcoded=0` |
| **STREAM=0** (default cast) | false | **Always universal** → `transcoded=1` → **VOID for this ladder** |

**You cannot measure link capacity with STREAM=0 on these fixtures.** The
transcoder is back in the loop and host CPU re-contaminates every number.

## What to look for on EVERY rung (parent)

### 1) Daemon resolve line (authoritative for product path)

```text
misterplexd: resolved direct H.264 Part (STREAM profile=...) title=... transcode=0
```

Source: `main.cpp` fprintf after resolve:

```cpp
std::fprintf(stderr, "misterplexd: resolved %s title=%s dur=%lld transcode=%d ...",
             resolved.detail.c_str(), ..., resolved.transcoded ? 1 : 0, ...);
```

| `detail` / `transcode=` | meaning | ladder |
|-------------------------|---------|--------|
| `direct H.264 Part...` **transcode=0** | Direct Play | **VALID** |
| `PMS universal ...` **transcode=1** | Transcode | **VOID** — do not score supply_ratio as link data |
| anything else | inspect | treat as VOID until understood |

### 2) GEOM line (same flag)

```text
misterplexd: GEOM ... transcoded=0 ... library_media=624x480
```

Source: `main.cpp` GEOM fprintf — field `transcoded=%d` is `resolved.transcoded`.

Also expect for DP: `delivery_basis=library_media` (claim), not `transcode_request`.

### 3) PMS `/transcode/sessions` (host-side, no MiSTer)

During a **valid** DP cast there should be **no** active transcoder session for
that ratingKey (or sessions list empty / other titles only).

```bash
# On PMS host — during cast:
curl -sS "http://192.168.1.24:32400/transcode/sessions?X-Plex-Token=$TOK" \
  -o .agent-work/transcode_sessions.xml
echo "sessions true rc=$?"
# If any Session references the CBR-DP title or a thrashing transcoder → VOID
grep -E 'title=|session=' .agent-work/transcode_sessions.xml | head
```

Complement with host sampler (below): `transcoder_procs` should stay **0** on DP.

### 4) Telemetry still works without HDMI

Score from daemon only:

```text
supply_ratio = audio_s / wall_s
audio_s = audioBytes / (48000 * 4)    # media_player.cpp
wall_s  = wall_ms / 1000.0
```

Pixels optional later (capture card currently unlocked).

## Parent pre-reg (unchanged; DP-only)

Path goodput **1.153 Mbit/s** (greedy-pull).  

| rung | rk | expected supply_ratio |
|-----:|---:|----------------------|
| 400k | 108 | ≥ 0.95 |
| 800k | 109 | ≥ 0.95 |
| **1200k** | **105** | **knee 0.90–1.00** |
| 1600k | 106 | ≈ 0.72 |
| 2000k | 107 | ≈ 0.58 |
| 1200k 640×480 | 110 | same as 105 if link-bound |

**All five bank rungs ≥ 0.95 on verified DP** ⇒ link is not the limit; host-side
collapse remains live. Publish that miss — valued.

**Any rung with `transcode=1`:** VOID — do not enter the dose-response table.

## Host-load control (mandatory companion)

Fleet cannot be quiesced. Publish host conditions beside every `supply_ratio`.

```bash
# cheap sampler — run on PMS workstation in parallel with cast
chmod +x scripts/sample_host_load_for_cast.sh
./scripts/sample_host_load_for_cast.sh 130 2 .agent-work/hostload_rkXXX.tsv
echo "sample true rc=$?"
# stderr ends with hostload_summary load1_p50=... plex_cpu_p95=... transcoder_procs_max=...
```

Report shape:

```text
rk=105 supply_ratio=... DP=1(transcode=0) load1_p50=... plex_cpu_p95=... tc_max=0
```

If `tc_max≥1` during a “DP” claim → re-check; likely VOID.

## PMS frameRate

At index time PMS often leaves `frameRate=None`. **Asset truth is ffprobe
`r_frame_rate=24/1`.** When PMS later fills `frameRate`, quote it; never assume
23.976 (ERROR 17).

## Agent cannot

- Cast, SSH to MiSTer, or set STREAM= on device.
- Assert DP happened without your GEOM/resolve quote.

Agent **did**: encode CB/L30/B=0/AAC ladder, index rks, document gates, ship sampler.
