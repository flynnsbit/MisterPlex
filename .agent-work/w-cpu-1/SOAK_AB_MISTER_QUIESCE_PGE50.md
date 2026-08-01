# A/B — Quiesce MiSTer vs publish timing (TRIMMED scoring)

**Status:** PRIORITY experiment for "is ARM late, or is observation late?"
**Agent:** w-cpu · no device touch

## Locked parent load (do not re-estimate)

| metric | value | tag |
|---|---:|---|
| SYSTEM_BUSY | 169/200 (84.5%) | measured |
| MiSTer | **90.6** | measured, exe-resolved |
| ffmpeg | 69.6 | measured |
| misterplexd | 25.6 | measured |
| raw `p_ge50` | 0.1450 | **WITHDRAWN as sole verdict** (rd-review: common-mode with acf) |

**Void on RBF c5382bee:** PLXD `frames_done`, `presents`, `drops`.
**Also void as FPGA observe:** `unaccounted` is **`residual` printed twice** (`media_player.cpp:3576-3577`) — same `frameLedgerResidual(...)` value; **no FPGA field**.

---

## 1. What 90.6 is (evidence classes)

### A. Source (quoted — mechanism class)

Upstream + mirror `.agent-work/w-cpu-main-input.cpp:5596-5617`:

```c
int timeout = 0;
if (is_menu() && video_fb_state()) timeout = 25;
poll(pool, NUMDEV + 3, timeout);  // Plex → 0 → spin when idle
```

`main.cpp`: `sched_setaffinity` **CPU1** only.
`scheduler.cpp` co_poll: **no nanosleep**.

### B. Device proof (parent must still capture — not assumed from %)

```sh
# exe resolve — never cmdline / never pgrep
M_PID=""
for d in /proc/[0-9]*; do
  exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
  case "$(basename "${exe% (deleted)}")" in MiSTer|mister) M_PID=${d#/proc/};; esac
done
echo "M_PID=${M_PID:-NO-DATA}"
[ -n "$M_PID" ] || { echo "true rc=77"; exit 0; }

# /proc state + affinity (awk — not read a b c on cpu line)
grep -E '^(Name|State|Cpus_allowed_list):' /proc/$M_PID/status
awk '{print "nice="$19" rt="$18" policy="$41}' /proc/$M_PID/stat

# syscall profile 10s during cast
command -v strace >/dev/null || { echo "NO-DATA strace"; echo "true rc=77"; exit 0; }
strace -c -f -p "$M_PID" 2>/media/fat/misterplex/lab_mister_strace.txt &
SP=$!; sleep 10; kill -INT $SP 2>/dev/null; wait $SP 2>/dev/null
cat /media/fat/misterplex/lab_mister_strace.txt
echo "true rc=$?"
```

| ID | PASS | FAIL |
|---|---|---|
| E1 | top = `poll`/`ppoll` ≥40% | other top → quote; spin class open |
| E2 | `Cpus_allowed_list: 1` | multi-CPU |
| E3 | stack/wchan mostly running or poll path | long D-state |

**Until E1 lands:** 90.6 is **measured load** + **source-class scavenger**, not "proven live poll".

---

## 2. TRIMMED scoring only (rd-review block honored)

### Instrument fields (tree — use these names)

`publish_interval_ledger.hpp` already emits:

| field | meaning | **use for A/B?** |
|---|---|---|
| `mean_ms` / `sigma_ms` / raw `p_ge50` | all intervals incl. startup/outliers | **NO — report only** |
| `median_ms` | steady window (drop first 48 + last 24 notes) | **YES** |
| `trimmed_mean_ms` | steady, 10% each tail | **YES** |
| `steady_sigma_ms` | σ on trimmed body | **YES** |
| `p_ge50_steady` | P(iv>50) on steady window only | **YES — primary fat-tail** |
| `steady_n` | must be **≥100** or arm = UNSCORED | gate |
| `verdict` | already prefers steady when `steady_n≥100` | secondary |

**Ideal period:** 1000/24 = **41.666… ms** (fixtures are 24.000 — not 23.976).

### Reject raw series when

- `sigma_ms ≫ mean_ms` (e.g. σ~500, mean~50) → **UNSCORED for causal claims**
- `steady_n < 100` → **UNSCORED**
- only raw `p_ge50` without `p_ge50_steady` → **UNSCORED** for this A/B

### Current timestamp site (observation bias context)

```cpp
// media_player.cpp publishDdrFrame — stamp is POST-write only today
const bool ok = fpga_.publishDdrFrame(...);
if (ok) {
  const auto tp = steady_clock::now();  // AFTER write returns
  pubInterval_.note(us);
}
```

So today’s intervals are **post→post**. Preemption **during** the write or **between** posts both fatten post-intervals. w-geom pre/post discriminator separates them.

---

## 3. PRE-REGISTER — A/B bands (commit before run)

**Arms**

| Arm | Action | MAIN %onecpu |
|---|---|---|
| **B0** | 480p cast, Main running | expect 80–95 |
| **B1** | same cast, `kill -STOP $M_PID` for soak, **CONT after** | expect ≤2 |

**Duration:** ≥60 s steady after play lock; same asset; soak_continuity pid stable.
**Collect:** full `publish_interval ...` summary line + CPU sample + (when available) pre/post write stats.

### Primary scores (TRIMMED)

| metric | B0 PREDICT | B1 PREDICT if Main drives preemption | B1 if CPU **NOT** cause |
|---|---|---|---|
| `p_ge50_steady` | **0.08–0.18** (repro class of 0.145 raw; steady may be lower) | **≤ 0.05** and **Δ ≥ 0.05** vs B0 | **within ±0.02 of B0** while MAIN≤2 |
| `median_ms` | **41.0–42.5** | still **41.0–42.5** (rate ok either way) | same |
| `trimmed_mean_ms` | **41.0–43.0** | **closer to 41.67** than B0 if B0 was high | unchanged vs B0 ±0.5 ms |
| `steady_sigma_ms` | elevated (e.g. >8 if messy) | **drops by ≥30% relative** if Main causal | **within 15% relative of B0** |
| MAIN % | 80–95 | ≤2 | ≤2 |

### Verdict table

| Outcome | Label | Meaning |
|---|---|---|
| B1 MAIN≤2, `p_ge50_steady` ≤0.05, Δ≥0.05, steady_σ down ≥30% | **MAIN_LOAD_CAUSAL_FOR_OBSERVED_TAIL** | reclaim Main is on critical path for *observed* publish timing |
| B1 MAIN≤2, all trimmed metrics within noise of B0 | **MAIN_NOT_CAUSAL** | 90.6 is real load but **not** the publisher-tail driver; look ffmpeg/daemon path / true arrival |
| B1 improves p_ge50_steady but median/trimmed_mean already ~41.67 on B0 | **MAIN_CAUSAL_TAIL_ONLY** | rate fine; tail/preemption story |
| B0 `steady_n<100` or σ_raw unusable and steady empty | **UNSCORED** | re-soak |
| B0 `p_ge50_steady` <0.03 already | **BASELINE_CLEAN** | Main quiesce is headroom-only for this instrument |

**CPU is NOT the cause** when: Main is confirmed stopped (MAIN≤2 or State=T during soak) **and** `p_ge50_steady_B1 ∈ [p_ge50_steady_B0 − 0.02, p_ge50_steady_B0 + 0.02]` **and** `steady_sigma` ratio ∈ [0.85, 1.15].

---

## 4. PRE-REGISTER — pre/post write discriminator (w-geom)

**Definitions (when instrument lands):**

- `t_pre` = steady_clock immediately **before** DDR/SPI publish write begins
- `t_post` = steady_clock immediately **after** write returns
- `write_us = t_post - t_pre`
- `pre_iv_ms` = intervals between successive `t_pre`
- `post_iv_ms` = intervals between successive `t_post` (≈ today’s ledger)

### Predictions if **observation/preemption during write** dominates (Main scavenger on same CPUs)

Quiescing Main (B1 vs B0):

| signal | PREDICT B1 vs B0 |
|---|---|
| **p90/p99 `write_us`** | **shrinks ≥40%** (or p99 write_us falls below a small floor, e.g. p99 < 2× median write) |
| long post_iv that coincide with large write_us | **decouple** — fewer long iv with large write |
| `p_ge50_steady` on **pre_iv** | mild improve or flat |
| `p_ge50_steady` on **post_iv** | improves **because** write gap shrinks |

### Predictions if **late arrival** (publisher delayed **before** write; write itself short)

| signal | PREDICT B1 vs B0 |
|---|---|
| **median/p90 `write_us`** | **flat** (±20% relative) |
| `p_ge50_steady` on **pre_iv** | **drops** (≤0.05 if Main causal) |
| `p_ge50_steady` on **post_iv** | drops in lockstep with pre_iv |

### Predictions if **post-stamp-only jitter** (write short; preemption after return before note)

Today’s code path is vulnerable only for the tiny post-return→note window (VDSO-class).
**PREDICT:** `write_us` stays small; if B1 still cleans post_iv a lot with tiny write_us on B0 long ivs → not "during write"; more likely **between-frame scheduling** (arrival class).

### Hard falsifiers (CPU / Main NOT explaining discriminator)

1. B1: MAIN≤2, **`write_us` distribution unchanged** (±20%) **and** **pre_iv `p_ge50_steady` unchanged** (±0.02) → Main not in the publish-timing path.
2. B0: long post_iv **without** large `write_us` **and** regular pre_iv → look elsewhere (pipe/decode), not write preemption.
3. Discriminator shows large write_us on **idle** box (Main already low) → not the 90.6 story.

**I commit:** If preemption-from-Main is the common-mode for fat tail + negative acf, **B1 must shrink the pre→post write gap on the same trials that were long**, not merely cosmetic-change raw `p_ge50`. If write gap is flat and pre_iv still late, label **late arrival**. If both flat under B1, label **MAIN_NOT_CAUSAL**.

---

## 5. Runnable B0/B1 (safe daily driver)

```sh
# --- shared resolve ---
LAB=/media/fat/misterplex
M_PID=""
for d in /proc/[0-9]*; do
  exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
  case "$(basename "${exe% (deleted)}")" in MiSTer|mister) M_PID=${d#/proc/};; esac
done
echo "M_PID=${M_PID:-NO-DATA}"; [ -n "$M_PID" ] || exit 0

# B0: cast playing — CPU sample + end-of-soak publish_interval line from daemon log
# Prefer: python3 tools/arm_cpu_sample.py --seconds 30 --label B0
# Grep: publish_interval.*p_ge50_steady

# B1:
trap 'kill -CONT "$M_PID" 2>/dev/null; echo CONT' EXIT INT TERM
kill -STOP "$M_PID"
# same soak duration; collect publish_interval + CPU
kill -CONT "$M_PID"
trap - EXIT INT TERM
grep State /proc/$M_PID/status   # must not stay T
echo "true rc=$?"
```

**Paste back:** full `publish_interval` lines (B0+B1), MAIN%, strace top, State after CONT.
**Do not paste PLXD presents/drops/frames_done as evidence.**

---

## 6. Cost: T7 unique store rows 240→480

**RTL:** `present_core.sv` `V_STORE=240` → 480 (w-geom). Parent: doubles Y-side **fetch** traffic.

**ARM path today** (`ddr_frame_layout.hpp`): publish **already** `624×480×1.5 = 449280` bytes every frame.

| impact | magnitude | tag |
|---|---|---|
| ARM encode/scale/publish **bytes** | **0** | code |
| ARM CPU % direct | **~0** | code |
| FPGA DDR read bandwidth | **~2× on Y fetch** | arithmetic |
| Contention ARM write vs FPGA read | **UNKNOWN** | measure `p_ge50_steady` + `write_us` post-RBF |
| PRE_REG ceiling-only RBF | trimmed metrics **Δ ≤ 0.03** on `p_ge50_steady` if no bus fight; if **worsens ≥0.05**, run B1 on new RBF | prediction |

T7 is **not** an ARM CPU gift and **not** free of bus risk. Score with trimmed publish stats + discriminator write_us, not PLXD.

---

## 7. Cost: native-raster overlay @ 84.5% busy

See updated `OVERLAY_COST_AND_MISTER.md`.

**One-line:** At Main 90.6 + ffmpeg 69.6 + daemon 25.6, **full-time hi-res composite can starve the publisher** (trade judder for chrome). Overlay is **burst/dirty-rect only** until Main A/B says MAIN_NOT_CAUSAL or reclaim lands. Gates: `present_us_p99<35000`, `p_ge50_steady` Δ≤0.03, `PRESENT_PROFILE=1`.

Host bench (NOT A9): 624 YUV overlay ~470 µs/call; scale≥2 ~2×; 1080-class ~3 ms — A9 absolute **UNKNOWN**.

---

## 8. Priority order

1. E1 strace (prove 90.6 class)
2. **B0/B1 trimmed A/B** (this card)
3. Discriminator pre/post when w-geom ships — score §4 predictions
4. T7 RBF — watch trimmed + write_us
5. Overlay only if publisher headroom proven
