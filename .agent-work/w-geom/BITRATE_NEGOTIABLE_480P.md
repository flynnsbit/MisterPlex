# 480p bitrate negotiable — w-geom

## Q: Is 2000 a decoder contract?

**No — quality/link heuristic.**

Hard decoder contracts still in `validateWeakLadder` (quoted):
- `videoCodec == h264`
- `h264Profile == baseline`
- `h264Level <= 30`
- positive quality/bitrate
- coded size ≤ DDR max

Former hard fail (REMOVED):
```
if (weak.maxVideoBitrateKbps < 2000)
    return fail("480p profile bitrate is too low");
```
That was **not** an H.264 level requirement. Comment on `contentResolutionFor480p` historically mixed "don't go higher for ARM margin" with a **lower** floor — wrong sign for link starvation.

`kPlex480pWeakBitrateKbps = 2000` remains the **default / recommended** request.

## Product behaviour

1. `WEAK_BITRATE` honors or fails loudly (invalid non-positive); never silently overridden by 2000 floor.
2. Below recommended → `WARN bitrate_below_recommended` + play still proceeds.
3. Wire log: `maxVideoBitrate=` on PLAY line + `WEAK_BITRATE_explicit=`.
4. `supply_ratio=audio_s/wall_s` + `supply_class=STARVED|OK|MARGINAL|WARMUP|NO-DATA` on every `media:` Hz line (w-avsync/w-cpu signal — single meter).
5. Sustained STARVED (≥8 consecutive Hz samples) → once per stream:
   `ERROR media: LADDER_STEPDOWN_RECOMMENDED next_bitrate_kbps=… geometry_unchanged=1`
6. `AUTO_LADDER_STEPDOWN=1` applies next step and restarts same title at position (bitrate only).

Ladder steps: 2000→1500→1000→750→500→400. **No hardcoded link speed.**

## Gates (true rc direct)

| gate | rc |
|------|----|
| test_resolve | 0 |
| test_supply_bucket | 0 |

## Parent device verify

```sh
# A) Honor WEAK_BITRATE=900 under 480p tier
# conf: DECODE=624x480 DECODE_ALLOW_LAB_480P=1 WEAK_BITRATE=900
# restart daemon, cast
grep -E 'maxVideoBitrate=|bitrate_below_recommended|WEAK_BITRATE_explicit|supply_ratio=|supply_class=|LADDER_STEPDOWN' \
  /media/fat/misterplex_v2/misterplexd.log | tail -50
echo "true rc=$?"
# PRE_REG: maxVideoBitrate=900 present; bitrate_below_recommended WARN; NOT fallen to 240p

# B) Default 2000 control on slow link
# WEAK_BITRATE unset; PRE_REG supply_class=STARVED within wall≥10 if path still ~1 Mbit

# C) Optional auto step-down
# AUTO_LADDER_STEPDOWN=1; PRE_REG LADDER_STEPDOWN_RECOMMENDED then AUTO_LADDER_STEPDOWN apply
```

## Caveats (parent)

- Lowering request alone may not reach realtime until w-cpu-1 second limiter settled (~47 KB/s vs 108 available).
- 240p@1000 A/B confounded geometry — this fix keeps **geometry** on step-down.
