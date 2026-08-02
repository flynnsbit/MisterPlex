# RESULT — 480p drops = bitrate vs link; product fix (w-cpu)

## PRE_REG misses published

| id | predicted | measured | verdict |
|---|---|---|---|
| Pipe back-pressure on rk=9 | NOT_SUPPLY_LIMITED / full Recv-Q | empty_n=8/8 max_recv_q=0, consume 48–63 KB/s | **MISS** — starved, not blocked |
| P3 “geometry/rescale is the variable” | geom isolates collapse | rk=9 vs rk=27 also differ 4.7× bitrate + refFrames | **CONFOUNDED** — retract geom-as-root |
| Host sws 350 FOAR ≥2× | cost cliff | ~1.28× | **MISS** (earlier) |

## Parent proof (accepted, quoted)

- Link direct download: **1.56 Mbit/s** (`curl_rc=28`).
- rk=9 needs **2154 kbit/s** → 1.38× over link → collapse.
- rk=27 needs **456 kbit/s** → healthy banks 20–28 s.
- Controlled: same clip, `maxVideoBitrate` 2000→1000 → vfps 23.8, drops flat, **audio_s/wall 0.467→0.993**.
- PMS transcoder 53–71 %onecpu / 2000 ceiling — not saturated.

## Floor justification (quoted source)

`host/libmisterplex/osd_menu.hpp` contentResolutionFor480p (updated comment):
- **2000 kbps is a quality/ARM-margin heuristic default**, not an H.264 decoder contract.
- Decoder contracts (still hard): baseline + level ≤ 3.0 (`plex_resolve.cpp` validateWeakLadder).
- Former hard fail at `plex_resolve.cpp` `if (weak.maxVideoBitrateKbps < 2000) return fail("480p profile bitrate is too low")` **removed**.
- Explicit `WEAK_BITRATE` now validates; advisory `bitrate_below_recommended` WARN logged.

## Product changes (this commit)

1. **validateWeakLadder** — no bitrate hard floor; positive only + decoder caps.
2. **recommendedMinVideoBitrateKbps / weakLadderBitrateBelowRecommended** — advisory API.
3. **main.cpp** — WARN on below-recommended; play line prints `recommended_min_bitrate=` + `WEAK_BITRATE_explicit=`.
4. **media: telemetry** — `supply_ratio=` `supply_class=` `supply_ratio_der=audio_s/wall_s`
   - STARVED if wall≥5 && ratio < 0.85 (parent 0.467)
   - OK if ratio ≥ 0.95 (parent 0.993)
   - MARGINAL / WARMUP / NO-DATA otherwise
5. Gates: test_resolve, test_supply_bucket green.
6. docs/release.md WEAK_BITRATE row; pms_recvq PRE_REG header corrected.

## Parent verify (device — parent runs)

After deploy (stage→md5→atomic mv→kill respawn; never scp over live):

```sh
# A) Conf: honor WEAK_BITRATE under floor on 480p tier
# Set WEAK_BITRATE=1000 DECODE=624x480, restart daemon, cast rk=9
# PRE_REG:
#   wire maxVideoBitrate=1000 (not 2000)
#   log contains bitrate_below_recommended AND WEAK_BITRATE_explicit=1
#   media: supply_class=OK or MARGINAL (not STARVED) if link ~1.56M and request≤1000
#   vfps≥22 pfps≥22 drops flat within 30s wall
grep -E 'maxVideoBitrate=|bitrate_below_recommended|WEAK_BITRATE_explicit|supply_ratio=|supply_class=' \
  /media/fat/misterplex_v2/misterplexd.log | tail -40
echo "true rc=$?"

# B) Default 2000 on same link still STARVED (control)
# WEAK_BITRATE unset or 2000; cast rk=9
# PRE_REG: supply_ratio≈0.4–0.6 supply_class=STARVED within wall_s≥10
```

## Deploy note

Binary change requires daemon rebuild+deploy. Parent owns device.
EOF
