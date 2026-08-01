# ARM offload inventory — wall ms/frame basis only

**Lead (≤10 lines):** Withdrew %onecpu decode↔scale adjudication (cumulative vs marginal +
occupancy≠wall). Ranking is **wall ms/f** from FEED table only. Largest discrete offloadable
term = **product present/DDR 10.411 ms/f** (3.5× scale delta). 25 fps margin **−0.190 ms** is
the programme headline — must reconfirm under `fast_bilinear`. SUSPEND is occupancy reclaim;
**does not automatically** buy wall-ms margin. Main poll spin / sampler work unchanged side lane.

**Authoritative stack** (`docs/evidence/p480/p720-bus-and-bitrate-margin.md:100-116`,
`docs/phase3-decode.md` W-FEED): 624×480 / 1412 kb/s / 1800 frames / **one instrument family**.

| bucket | wall ms/f | role | tag |
|--------|----------:|------|-----|
| decode_null | **21.562** | **cumulative** baseline (demux+decode+loop, out discarded) | `measured` archived |
| **product present/DDR** | **10.411** | discrete product path | `measured` archived |
| +pipe delta | **5.263** | marginal vs prior nested probe | `measured` archived |
| +scale delta | **2.954** | marginal @ **native** 624 (not 240→480 upscale) | `measured` archived |
| **sum** | **40.190** | full-stack | `measured` archived |

| budget | full-stack margin |
|--------|------------------:|
| 24 fps (41.667) | **+1.476 ms** |
| **25 fps (40.000)** | **−0.190 ms** |
| **30 fps (33.333)** | **−6.857 ms** |

**Rules:** never rank occupancy with wall-ms in one table. Label instrument every row.
Absence = NO-DATA. Agent does not touch device.

**WITHHELD for ranking:** live ffmpeg/daemon/Main **%onecpu** (supporting signal only);
old “~50 vs ~6 scale/decode split” (withdrawn).

---

## 1. Ranked offload targets (wall ms/f)

| Rank | Target | wall ms/f | Instrument | Offload shape | Notes |
|-----:|--------|----------:|------------|---------------|-------|
| **1** | **Product present/DDR** | **10.411** | W-FEED product-present bucket | Native geom bytes and/or fabric/HPS DMA | **3.5×** scale delta; see §2 decomposition |
| **2** | Pipe drain (marginal) | **5.263** | FEED nested delta | Goes away with in-fabric decode or shmem | Not “decode” |
| **3** | Scale (marginal, native) | **2.954** | FEED nested delta | w-geom fabric scaler; **240p upscale is a different, larger term — NO-DATA in this table** | Do not use this row to size 240p upscale |
| **4** | decode_null body | **21.562 cumulative** | FEED | Fabric decode — but **undecomposed**; not a discrete offload quantum | §4: no bad split |
| **—** | MiSTer Main spin | n/a wall-ms of *our* pipeline | occupancy `measured` parent | timeout=5 / SUSPEND | §5 conversion question |
| **—** | Overlay / idle / A/V pace CPU | NO-DATA wall-ms here | — | fabric plane / low value | secondary |
| **—** | YUV→RGB, audio FIFO | 0 on ARM | fabric already | exclude | — |

**Fit budget (caller-supplied):** M10K **88 free** binding; `decode_stub` reclaim ~268 M10K (w-fit-1) before serious decode silicon.

---

## 2. Decompose present/DDR 10.411 ms/f — bytes vs fixed

### 2.1 Source stages (`fpga_spi.cpp` `sendDdrFrame` + `DdrTiming`)

| Stage | Field | What |
|-------|-------|------|
| Bank select / PLXD wait or absent-path sleep | `prep_wait_us`, `plxa_poll_us`, `bank_reuse_wait_us` | **Mostly fixed / policy** (usleep 1500 absent path; reuse floor) — not bytes-proportional |
| `memcpy` into `ddrMap_` | `copy_us` | **Bytes-proportional** (BW-bound class) |
| `cleanDcacheRange` (if flush path) | `flush_us` | **Bytes-proportional** when enabled |
| Doorbell / SPI kick | `doorbell_us` | **~Fixed** (words + optional first-kick poll) |

Logged when profile on: `ddr_prep_wait_us_p`, `ddr_copy_us_p`, `ddr_flush_us_p`, … (`media_player.cpp`).

### 2.2 Archived microbench (same programme, pure bank fill)

| Mode | wall ms/f @ 449280 B | MiB/s | tag |
|------|---------------------:|------:|-----|
| no-sync `/dev/mem` | **7.199** | 59.521 | `measured` `p480-bandwidth` / phase3-decode |
| O_SYNC | **7.378** | 58.074 | `measured` |
| no-sync + cacheflush | **13.246** | 32.348 | `measured` |

**Implication (arithmetic on measured rates, still label ESTIMATED for product mix):**

| Component | wall ms/f | basis |
|-----------|----------:|-------|
| Copy class @ 624×480 | **~7.2** | microbench `measured` |
| Product present − copy class | **10.411 − 7.199 ≈ 3.21** | **ESTIMATED** residual = prep/wait/doorbell/product overhead |
| Copy if **native 320×240** (115200 B) at same 59.521 MiB/s | **115200/449280 × 7.199 ≈ 1.85** | **ESTIMATED** bytes-scaled from `measured` rate |
| **Copy save from native geom alone** | **≈ 5.35 ms/f** | ESTIMATED |
| Fixed overhead if unchanged | **≈ 3.2 ms/f** | ESTIMATED |
| **Present total if native copy + same fixed** | **≈ 1.85 + 3.2 ≈ 5.05** | ESTIMATED — still leaves fixed |
| **DMA eliminating ARM memcpy+flush only** | saves ~7.2 (or ~1.85 native); **not** prep_wait | ESTIMATED |

**Decision rule for w-geom sizing:**

| If parent §3 measures… | Then |
|------------------------|------|
| `copy_us` ≈ 70%+ of present wall and scales ~linear with len | **Native geometry is the primary present win** (~5 ms/f class ESTIMATED) |
| `prep_wait_us` / bank_reuse dominates | **PLXD/ready path**, not bytes — DMA alone won’t fix |
| `flush_us` large | flush policy / coherent mapping — not scaler |
| copy scales with bytes **and** residual fixed > 2 ms | **Native geom +** later DMA/ready cleanup |

**Native geom alone does not remove fixed ~3 ms ESTIMATED.**  
**DMA alone does not remove prep_wait.**  
**Both** needed only if both buckets stay hot after geom.

Bytes today: **449280** = `624*480*3/2` `source`. Native 240p I420 **115200** `source`.

---

## 3. Parent commands — present split + margin reconfirm

### 3.0 Artifact pair (every run)

```sh
echo -n "rbf_md5="; md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null || echo NO-DATA
# daemon by exe
for d in /proc/[0-9]*; do
  e=$(readlink -f "$d/exe" 2>/dev/null) || continue
  [ "$(basename "${e% (deleted)}")" = "misterplexd" ] || continue
  echo "daemon_exe=$e"
  md5sum "/proc/${d#/proc/}/exe" 2>/dev/null || md5sum "$e"
done
echo "true rc=$?"
```

### 3.1 Present/DDR decomposition (product path — sizes w-geom)

**PRE_REG before cast (publish misses):**
- P1: `ddr_copy_us_p` ∈ **[6000, 9000]** µs/f at 624×480 (microbench 7.2 ms class)
- P2: `ddr_prep_wait_us_p + ddr_doorbell_us` sum **≥ 1000** µs/f (fixed class non-zero)
- P3: if lab can publish **115200** B frames into a native store, `ddr_copy_us_p` drops by **~3.5–4×** vs 449280 (kill if drop < 1.5× → not BW-bound)

```sh
# Enable present profile on live daemon conf (parent-owned conf edit; restore after).
# Exact key may be PRESENT_PROFILE=1 or profile bit — parent greps conf / docs:
grep -E 'PROFILE|PRESENT' /media/fat/misterplex_v2/misterplexd.conf 2>/dev/null || true

# During 480p cast, scrape timing lines (log path parent-owned):
grep -E 'ddr_copy_us|ddr_prep_wait|ddr_flush_us|ddr_doorbell|ddr_total' \
  /media/fat/misterplex_v2/misterplexd.log | tail -n 40
echo "true rc=$?"

# Prefer steady mid-soak lines; report means of ddr_*_us_p fields.
# Stamp RBF+daemon md5. Score P1–P3.
```

Optional pure microbench if binary on device (archive name):

```sh
# Only if tool exists — else NO-DATA
ls /media/fat/misterplex*/bin/*ddr* /media/fat/misterplex*/ddr_write_bench 2>/dev/null
# Example from docs: ddr_write_bench --len 449280 --loops 500
# Compare --len 115200 same loops → bytes proportionality
echo "true rc=$?"
```

### 3.2 Full-stack margin under **current** build + `fast_bilinear`

FEED 40.190 / −0.190@25 **predates** several changes. **Reconfirm is first-order.**

**PRE_REG:**
- M1: full-stack wall ms/f @24 content with `FFMPEG_SWS_FLAGS=fast_bilinear` still **≥ 38** (kill if < 35 → large win)
- M2: margin @25 = `40.000 − full_ms` ; if **≥ +1.0 ms** → headline **moved** (publish as result)
- M3: margin @25 still **≤ 0** → headline **holds**

```sh
# Re-run the SAME nested FEED-style probes if scripts still on box, OR
# one product soak with PROFILE that emits per-bucket ms/f.
# Minimum viable: wall-clock ffmpeg null probes + separate present profile mean.

export FFMPEG_SWS_FLAGS=fast_bilinear   # or conf equivalent — parent sets product path
# Arm D: decode_null cumulative (not a split — baseline only)
# Arm S: decode+scale+null (native 624) 
# Arm P: product cast PROFILE present mean ddr_total_us_p/1000 + pipe if available
# full ≈ D + (S-D) + pipe_delta + present   only if same nesting as FEED
# If nesting unavailable: report product-only: mean inter-publish wall and mean ddr_total_ms
# and state plainly "not FEED-comparable full stack".

RBF_PATH=/media/fat/_Utility/Plex.rbf LOG=/media/fat/misterplex_v2/misterplexd.log \
  sh /media/fat/misterplex_v2/arm_cpu_soak.sh 30
echo "true rc=$?"
# Occupancy is SUPPORTING only — do not rank against ms/f.
```

Host-side FEED reproduction only if ARM asset ASSET_OK (`scripts/check_arm_profile_asset.sh`) — else expired.

---

## 4. decode_null 21.562 — decomposition policy

**Not used as a discrete offload quantum.** It is cumulative.

Clean demux/entropy/recon split needs one instrument (e.g. ffmpeg `-c:v` thread bench + bitstream discard vs full decode) with **marginal** arms only.  
**This turn: no decomposition published.** A bad split is worse than none.  
Roadmap: fabric decode is still motivated as “replace the cumulative 21 ms class work,” sized after w-fit-1 M10K reclaim — **not** from a fake demux/scale split.

---

## 5. SUSPEND_MAIN_DURING_PLAY — risks + wall-ms conversion

### 5.1 Residual risks (unchanged substance)

| Risk | Severity | Mitigation |
|------|----------|------------|
| F12/OSD/`MiSTer_cmd`/`load_core`/Main input dead while `T` | UX | default **OFF**; Plex stop :3005 OK |
| Main stuck `T` after kill−9 | brick | verified RESUME; keep startup `resumeStrandedMain` |
| Watchdog CONT during intentional suspend | logic | session hold must block stranded-resume |
| Deploy/load_core while suspended | stuck core | CONT before load |
| Not on HEAD as session conf | ship gap | re-port + tests before opt-in |

**Recommendation:** default **OFF**; opt-in only after HEAD re-port. Prefer **poll timeout=5** for reclaim **with F12 live**. SUSPEND remains largest **occupancy** hammer, zero M10K.

### 5.2 Does SUSPEND convert to wall-ms margin? **Do not assume.**

| If bottleneck is… | SUSPEND effect on 40.190 / −0.190@25 |
|-------------------|-------------------------------------|
| Single-thread wall path (ffmpeg decode+present serial on one core) with **spare** other core | Main scavenger on CPU1 may **inflate** present/decode wall via preemption → SUSPEND **can** shrink wall ms/f |
| Already compute-bound wall with little runq wait | SUSPEND frees occupancy but **margin unchanged** |
| Elastic Main only looks big in % | **No** conversion |

**Parent conversion test (binding):**

```sh
# Same 480p cast, same clip, PROFILE on. Two arms, 60s steady each.
# Arm STOCK: Main running
# Arm STOP:  SIGSTOP Main (or SUSPEND conf if re-ported) — CONT after
# Score ONLY: mean ddr_total_us_p, mean publish interval wall, FEED-style full ms/f if available
# PRE_REG:
#   C1: if daemon schedstat Δrunq_wait drops ≥50% AND ddr_total or full_ms drops ≥0.5 ms/f
#       → SUSPEND helps the −0.190 class margin (publish HIT)
#   C2: runq_wait drops but full_ms / ddr_total flat within ±0.3 ms/f
#       → occupancy-only win; does NOT fix 25 fps margin (publish HIT either way)
#   C3: full_ms worsens → STOP
echo "true rc=$?"
```

Occupancy −45.7 dual-busy `measured` (parent historical) remains valid **as occupancy**, not as ms/f headroom until C1/C2 lands.

---

## 6. Programme order (wall-ms weighted)

1. **§3.1 present split on current build** → sizes native geom vs DMA vs PLXD wait.  
2. **§3.2 margin reconfirm** with `fast_bilinear` → is −0.190@25 alive?  
3. **w-geom** native/store honesty + scaler (bytes cut on present; 240p scale is separate glass/CPU story).  
4. **§5.2 SUSPEND conversion** before default debates; ship default OFF.  
5. **poll timeout=5** lab Main (occupancy, F12 live).  
6. **w-fit-1** M10K → fabric decode against cumulative ~21 ms class.  
7. Pipe delta dies with decode offload.  
8. Overlay plane (w-osd-hires) — not in FEED 40.19.

---

## 7. One-line verdicts

| Question | Answer |
|----------|--------|
| Largest discrete offloadable wall term | **present/DDR 10.411 ms/f** |
| Native 320×240 bytes alone | **ESTIMATED ~5.35 ms/f** copy save; **~3.2 ms fixed remains** |
| Need DMA? | Only if copy still hot after native geom **or** flush path stays expensive |
| −0.190@25 | Headline; **reconfirm** on current+`fast_bilinear` |
| decode_null split | **Not done** (cumulative) |
| SUSPEND → margin | **Unknown until §5.2**; default OFF |
