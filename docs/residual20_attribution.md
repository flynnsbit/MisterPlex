# ~20 ms NEW-argv residual — attribution (2026-08-01)

**Corpus (measured):** `/tmp/sixfield/av{1..10}.json` + `/tmp/ab/new_{1..6}.json` (n=16 NEW);
`/tmp/ab/old_{1..6}.json` (grid only); `/tmp/sixfield/rec{1..10}.txt` (H-FIELD).
**Pre-reg:** `.agent-work/w-avsync/prereg_residual20.md`
**Rule 0:** every number below is from those files or derived arithmetic labeled as such.

---

**NOT a mechanism attribution.** "Session common-mode" here is a *variance decomposition label* (excess between-run σ after within-run SE is removed). It names the statistical structure of the residual, not its physical source. No candidate passed CC-1..CC-5. Unknown source remains unknown.


## 0. What is already established

| quantity | value | src |
|----------|-------|-----|
| NEW between-run median range | **25.00 ms** | measured n=16 |
| SE(median) under pair-quant T/√12, n_pairs≈45 | ≈1.8 ms | derived |
| E[range 16 \| that SE] | ≈6.4 ms | derived |
| H-QUANT (pair-independent quant) | **REJECTED** | range 25 ≫ 6.4 |
| series pooling | safe (pooled range = max series) | parent-measured |

---

## 1. G-GRID — integer vs thirds (SETTLED)

| arm | period_ms | pair offsets on integer ms | on thirds (k/3 ms) | flash_t on that grid | beep_t integer ms | n_interp |
|-----|-----------|----------------------------|--------------------|----------------------|-------------------|----------|
| NEW (six+ab) | **33.000** | **712/712 = 100%** | 100% (integers ⊂ thirds) | 100% integer ms | 100% | **0** |
| OLD (ab) | **33.333…** | 69/269 = 25.7% | **269/269 = 100%** | 100% on thirds | 100% integer | **0** |

**Pre-reg:** P1 PASS, P2 PASS, P3 PASS.

**Mechanism (cited from numbers, not guessed device path):**
- NEW `capture_frame_period_ms=33.0` → flash PTS land on integer ms; beep hop=2.0 ms integer → offsets integer.
- OLD period `33.⅓` → flash PTS on thirds; beep still integer ms → offsets on thirds (e.g. −288.666…).
- n_pairs parity does **not** explain this (both arms mostly n_pairs=45; parent already killed that).

**P4 PASS:** grid change is a **≤1 ms timestamp-grid property**. It **cannot** account for ~20 ms residual. Stop.

Within-run dominant level spacing is **2.0 ms** (beep hop), not 33 ms — pair cloud is hop-quantised after flash step-quant.

---

## 2. H-FIELD NULL — what it rules out / does not

Sixfield `rec*.txt` at `first_video_fpga_state` (n=10), Spearman vs run median:

### Constant (no variance → **no correlation possible**; not ruled out as causes)
`plxa_used=1`, `plxd_liveness_proven=1`, `br_ok=1`, `ddr_flush_us=0`, `ddr_post_wait_us=1`, `ddr_bank_reuse_wait_us=0`

### Vary but |Spearman| ≤ 0.5 (ruled out as **monotonic rank-correlate** of residual in this n=10)
| field | Spearman | range |
|-------|----------|-------|
| published_bank | −0.30 | 0..1 |
| free_bank_mask | +0.33 | 0..2 |
| disp_bank | −0.30 | 0..1 |
| swap_pending | −0.08 | 0..1 |
| frames_done | −0.39 | 21655..62275 (lifetime counter) |
| av_hold_count / av_hold_wait_us | −0.11 | 0..10 / 0..22870 µs |
| audio_queued_first_ge0_since_origin_ms | −0.09 | 33..59 ms |
| ddr_total/copy/doorbell/plxa_poll/prep | \|r\|≤0.31 | large |
| aq_before_fv_ms (mono−audio_queued) | +0.04 | 19..115 ms |

### Apparent |r|>0.5 — **not promoted**
`fd_minus_fv_ms = frames_done_mono_ms − mono_ms` → Spearman **−0.65**, range only **4..13 ms**.

**Why not a finding:**
1. It is **poll scheduling latency** between the first_video log line and the PLXD read — not present-lag N.
2. 9 ms span cannot explain 25 ms residual even if causal.
3. ~20 fields tested at n=10 → |r|>0.5 is weak / multiple-testing.

**H-FIELD NULL means (narrow, honest):**
- Among **logged, varying** sixfield scalars, none is a rank-linear tracker of HDMI median offset in this series.

**H-FIELD NULL does NOT mean:**
- constants are innocent (no information)
- unlogged daemon state is innocent
- nonlinear / threshold effects are innocent
- **capture-side** phase under NEW argv is innocent
- **post-`write(/dev/MrAudio)`** / HDMI path is innocent
- the residual is “just noise”

---

## 3. G-WITHIN — structure of the 25 ms

| metric | value | src |
|--------|-------|-----|
| within-run pair stdev (median across runs) | **14.71 ms** | measured |
| CV of within-run stdev | **0.109** | measured → P5 PASS (level shift, not noise inflation) |
| Spearman(first_pair, median) | **0.218** | measured → **P6 MISS** |
| \|first−median\| median / max | 14 / 23 ms | measured |
| Spearman(early_minus_late, median) | −0.09 (pooled) / −0.33 (six) | measured → C6 no |
| within-run slope median | −0.09 ms/s | measured; not a residual driver |
| half2−half1 median | +8 ms | common-mode early/late; not between-run driver |

**P6 miss (published):** residual is **not** “whatever the first pair said.” First pair is a noisy draw from the within-run cloud; the run median is the better session summary.

### Session common-mode variance (stronger than pair-quant SE alone)

Using **empirical** within-run stdev (not T/√12):

| quantity | value | src |
|----------|-------|-----|
| SE(median) ≈ 1.2533·σ_within/√n_pairs | **2.75 ms** | derived from measured σ,n |
| E[range 16 \| that SE] | **9.72 ms** | derived |
| obs range | **25.00 ms** | measured |
| excess range | **≈15.3 ms** | measured−derived |
| excess session σ (√(var_med − SE²)) | **≈6.33 ms** | derived |
| bootstrap P(range≥25 \| no session φ) | **0.000** (0/20000) | measured bootstrap |

**Interpretation (bounded, not a named cause):** the between-run excess is consistent with a **per-session additive offset** φ (σ≈6 ms) that shifts the whole pair cloud. That is a variance-decomposition statement only. Averaging pairs kills independent pair noise; it does **not** kill a session-constant φ. That is why SE(median) from pair quant under-predicts the between-run range. **φ is unnamed** — unknown whether device or residual instrument.

This is **not** a named mechanism. It is a variance decomposition.

---

## 4. Candidates under CC-1..CC-5

| ID | candidate | Q that must vary | In corpus? | VARIES? | Result |
|----|-----------|------------------|------------|---------|--------|
| C1 | capture/content flash phase | flash t mod 1s | YES | YES (range 700 ms) | Spearman vs median **0.16–0.26** → no rank track; **not supported** |
| C2 | ALSA period / start phase | period boundary / first beep sub-period | NO period log | — | **STOP (CC-3)** not testable |
| C3 | display present lag N | Δframes_done audio_release→first++ | NO (only lifetime frames_done + poll delay) | — | **STOP (CC-3)**; fd_minus_fv is poll artifact |
| C4 | hold/release | av_hold_* , audio_queued_since_origin | YES | YES | \|Spearman\|≤0.11 → **not supported** as rank correlate |
| C5 | grabber v4l2−ALSA open delta under NEW | wallclock open Δ | NOT in JSON | — | **STOP (CC-3)** |
| C6 | early/late window bias | early_minus_late | YES | YES (range 37 ms) | Spearman \|r\|≤0.33 → **not supported** |
| C7 | DDR timing path | ddr_*_us | YES | YES | \|r\|≤0.31 → **not supported** |
| C8 | bank/swap state | published/disp/free/swap | YES | YES | \|r\|≤0.33 → **not supported** |

**No candidate is accepted.** Magnitude coincidence with 20 ms was never used.

---

## 5. Verdict

```
ATTRIBUTED:     no named mechanism
RULED OUT:      pair-independent flash quant as sole cause (H-QUANT);
                grid integer/thirds as cause of 20 ms;
                logged varying sixfield fields as rank-linear correlates (n=10);
                first-pair-as-median latch (P6 miss);
                early/late window bias as between-run driver
ESTABLISHED:    ~6.3 ms excess session σ (variance label, not mechanism);
                bootstrap null for pure pair noise rejected at p≈0
UNKNOWN:        physical source of session φ (device vs residual instrument)
```

**Honest answer:** with the instrument and logs we have, the ~20 ms is **real per-session variance** (statistically structured as common-mode across pairs within a run — a *label*, not an explanation) and is **not attributable** to any logged daemon field or to video-frame quantisation after averaging. Device vs residual NEW-argv capture alignment is **not separable** on this corpus (CC-3: the discriminating quantities are not recorded).

---

## 6. What instrument / experiment would settle it

Apply CC before running. Each row names Q, how to vary it, and the predicted-null arm.

### I1 — Capture open delta (instrument residual)
- **Q:** `t_alsa_first_pkt_wall − t_v4l2_first_pkt_wall` (and/or ffmpeg `start_time` per stream before any rebase)
- **VARIES:** must differ across runs under identical NEW argv
- **HELD:** fixture, daemon conf, fingerprint
- **Predict:** if session φ is capture-side, Spearman(|open_delta|, median_offset) high and |open_delta| range ≳15 ms
- **Null arm:** offline file mode of the same MKV (no live race) → open_delta≡0 and residual collapses toward SE-only ~6–10 ms range
- **Kill:** open_delta range <5 ms while median range stays 25 ms → not capture open race

### I2 — Known-zero loopback / electrical A/V reference
- **Q:** absolute offset to a true simultaneous edge
- **Predict:** session φ appears on HDMI path iff loopback residual is flat and HDMI median still moves
- **Null:** loopback median range ≈ SE floor; HDMI range 25 ms → device-side φ

### I3 — Present-lag N (device video)
- **Q:** N = round((t_first_frames_done++ − t_audio_release)/T_disp)
- **Recipe:** `scripts/parent_plxd_present_lag_protocol.sh` (doorbell from layout SoT; no 117.10)
- **Predict:** if video lag is φ, N tracks median with slope ~T_disp per step
- **Null:** N constant across sessions while median range 25 ms → kill present-lag

### I4 — MrAudio rptr phase at release (device audio)
- **Q:** absolute rptr (or rptr/period) at `handoff_at=audio_release`
- **Tool:** `tools/analyze_mraudio_handoff.py --sep-ms <caller> --log-pair …`
- **Predict:** rptr mod ring tracks median
- **Null:** identical rptr/len across sessions with median range 25 → kill visible ring phase

### I5 — Ramped-flash fixture (precision, not root cause)
- Reduces per-pair video quant → smaller within σ → tighter SE(median)
- Does **not** by itself name φ; makes I1–I4 sharper

**Cheapest next parent step:** **I1 null arm** (file-mode reanalysis of live MKVs already on disk, if raw captures retain pre-rebase timestamps) or re-capture with explicit open-delta logging. If file-mode residual range stays ~25 ms with no live race, φ is **not** the dual-input open race under NEW argv.

---

## 7. Pre-reg miss log (this pass)

| ID | prediction | result |
|----|------------|--------|
| P1 NEW integer offsets | ≥95% | **PASS** 100% |
| P2 OLD thirds | ≥95% | **PASS** 100% |
| P3 periods 33.0 / 33⅓ | | **PASS** |
| P4 grid ≤1 ms vs 20 ms | | **PASS** (cannot explain) |
| P5 within stdev CV<0.3 | | **PASS** 0.11 |
| P6 first_pair tracks median \|r\|>0.7 | | **MISS** r=0.22 |
| P7 sixfield \|r\|≤0.5 | | **PASS** on pre-listed fields; fd_minus_fv fluke not promoted |

---

## 8. Parent commands (no device from this agent)

```bash
# Recompute residual SE model + H-QUANT on NEW pool
python3 tools/analyze_avsync_residual.py \
  --json-glob '/tmp/sixfield/av*.json' --json-glob '/tmp/ab/new_*.json' \
  --rec-dir /tmp/sixfield
# true rc: 2 expected (H-QUANT REJECTED); 77 = could-not-measure

# Grid spot-check (host)
python3 - <<'PY'
import json,statistics
from pathlib import Path
for label,glob in [('NEW','/tmp/ab/new_*.json'),('OLD','/tmp/ab/old_*.json')]:
    offs=[]; pers=[]
    for p in sorted(Path('/tmp/ab').glob(glob.split('/')[-1])):
        d=json.loads(p.read_text()); r=d['result']
        offs += [float(x['offset_ms']) for x in r['pairs']]
        pers.append(r['flash_meta']['capture_frame_period_ms'])
    n=len(offs)
    n_int=sum(1 for o in offs if abs(o-round(o))<1e-6)
    n_3=sum(1 for o in offs if abs(3*o-round(3*o))<1e-3)
    print(label,'period',statistics.median(pers),'int',n_int,n,'thirds',n_3,n)
PY
```
