# Asset-class split: 624×350 vs 624×480

**Tip:** w-geom-lane (this commit). Host evidence + parent transcoder-argv check.

## Differing field (library metadata, proven)

| ratingKey | title class | coded | Media@aspectRatio | Stream@pixelAspectRatio | universal decision @624×480 |
|-----------|-------------|-------|-------------------|-------------------------|-----------------------------|
| **6** | Test 480p | 624×480 | **1.78** | **160:117** | **624×350** |
| **9** | BBB | 624×352 | **1.78** | **352:351** | **624×350** |
| **36** | AdvReal 624×480 | 624×480 | **1.33** | *(empty=1:1)* | **624×480** |
| **33** | AdvReal 624×352 | 624×352 | 1.78 | empty | **624×352** |

**Split field:** display aspect **1.78 (16:9)** vs **1.33 (4:3)**, often via non-1:1 SAR on a 624×480 box (rk6).

Math rk6: `DAR=(624/480)*(160/117)=16/9` → square-pixel fit in 624×480 ceiling → **350** even-floor.

AdvReal 624×480: `ar=1.33` ≈ 4:3 square → fit keeps **h≈480**.

Decision XML artifacts: `decision_rk6.xml`, `decision_rk9.xml`, `decision_rk36.xml`, `decision_rk33.xml`.

## force_divisible_by=4 note (open vs decision)

Decision XML says **height=350** for rk6/rk9. **350 % 4 = 2** — so if the live Transcoder argv truly has `scale=w=624:h=480:force_divisible_by=4` only for AdvReal, rk6 must differ.

**Pre-register for parent argv capture:**

| If rk6 scale= | Interpretation |
|---------------|----------------|
| `h=350` | Decision matches; force_divisible_by=4 absent or not applied to h |
| `h=348` or `h=352` | force_divisible_by=4 won; our **measured=350** is a different stage (banner/parser) — chase that |
| `h=480` | Contradiction with decision+measured — attach full argv |

## Parent: exact transcoder argv capture (you run)

During an **rk6** cast (and separately **rk36** AdvReal):

```bash
# 1) Find plex container name
docker ps --format '{{.Names}}' | rg -i 'plex'

# 2) Snapshot Transcoder argv (prefer while cast is buffering/playing)
docker exec "$(docker ps --format '{{.Names}}' | rg -i '^plex$' || docker ps --format '{{.Names}}' | rg -i plex | head -1)" \
  sh -c 'ps -eo args | grep "[T]ranscoder"' | tee /tmp/plex-transcoder-rk6.txt

# 3) Extract scale filter only
rg -o 'scale=[^ ]+|force_divisible_by=[0-9]+|-maxrate[^ ]*|-filter_complex [^ ]+' \
  /tmp/plex-transcoder-rk6.txt
```

Repeat for rk36 → `/tmp/plex-transcoder-rk36.txt`.  
**Side-by-side the two `scale=` strings** — that is the decisive artifact.

Optional: correlate session

```bash
docker exec <plex> sh -c 'ps -eo pid,args | grep "[T]ranscoder"'
# and PMS /transcode/sessions for ratingKey / session
```

## Can we pin true 480 rows?

| Approach | 16:9 DAR (rk6) | 4:3 AdvReal | Safe? |
|----------|----------------|-------------|-------|
| Keep `videoResolution=624x480` ceiling | ~350 | 480 | default product |
| Raise ceiling width to ~854 | 480 square-px | would allow wider 4:3 too | **RBF** bank 624 cannot hold 854 |
| Force square SAR / ignore DAR | would force 624×480 samples of 16:9 content as 4:3 | N/A | **Unsafe** — letterboxes/squashes real widescreen |
| Direct-play H.264 when Baseline | 624×480 anamorphic | 624×480 | keeps rows; SAR display separate |
| Exact height query param | **none in our URL** | — | not available |

**Do not** “fix” 16:9 by forcing 4:3 geometry.

Honest tier text: **480p ceiling; delivered rows depend on source DAR** (full 480 for 4:3 square; ~350 for 16:9 under 624 width).

## Durable daemon fixes (this commit)

1. **REQUEST_VS_MEASURED** at `MEASURED_DELIVERY_FINAL` — compares frozen play-time request vs measured; ERROR when differ.
2. **DELIVERY_MISMATCH_FINAL** + `vertical_detail_frac` vs coded bank.
3. **B5** already in arm teardown; now also greppable `phase_offset=` via `rawPipePhaseOffset` (not unit-only).
4. Stop overwriting play-time source claim with measured dims.

## Gates

```text
./build/test_resolve ; echo true_rc=$?
./build/test_yuv420p_chroma_480p ; echo true_rc=$?
bash tests/unit/test_b2_b5_source_wiring.sh ; echo true_rc=$?
make plexd ; echo true_rc=$?
```

## Bitrate

No changes to `maxVideoBitrate` / floors — **w-cpu-1** owns that path. Coordinate merges via parent.
