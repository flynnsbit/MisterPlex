# Parent soak response (T1–T5) — w-geom

**Daemon measured:** md5 `7c991e47` @ tip `67d6d376`  
**This fix tip:** see `git rev-parse --short HEAD`  
**Gates:** ledger/swap/T1/deploy-syntax true rc=0  

## Parent interval result (scored)

| field | measured |
|---|---|
| p_ge50 | **0.1450** |
| verdict | `ARM_LATE_OR_BIMODAL` |
| acf lag1 | **−0.1950** (catch-up) |
| modal hist | b33_42 dominant (near 41.67) |

**Pre-register MISS published by parent:** expected 9–11%, got 14.5% — ARM late **worse** than band.  
Instrument agrees with glass catch-up. **Not** ARM-exonerated.

T4 now emits `median_ms`, `trimmed_mean_ms`, `p_ge50_steady` (drop first 48 + last 24 notes).

---

## T1 — `frames_done` on DEPLOYED RBF `c5382bee` → **(a) LIVE**

Evidence freeze for RBF md5 `c5382bee73cecdee8220b811e529c297`:
- `.agent-work/w-fit/leftedge3-proj/rtl/ddr_frame_store.sv`
- md5 `c139274e814a4696c485c0bba3781ad8` matches `evidence-leftedge3-build-ok.txt`

**Quoted pack (c5382bee freeze):**
```
DDRAM_DIN <= {bank_vsync_count,  // [63:48] frames_done
```
**Quoted increment of what ARM reads:**
```
bank_vsync_count <= bank_vsync_count + 16'd1;  // on vsync toggle edge
```
**Internal** `frames_done <= frames_done + 1` still only on swap — **not packed**.

**Tip RTL (not on silicon):**
```
DDRAM_DIN <= {frames_done_d2,  // [63:48] real swaps
```

**Therefore (a), not (b):** p_dge2≈0.974 and mean_delta≈3 ≈ 50.4ms/16.67ms is **vsync packing**, not multi-swap-per-frame.  
HISTORICAL FAULT is **LIVE on deployed core**.

Gate: `tests/unit/test_c5382bee_frames_done_pack.sh` true rc=0.

---

## T2 — skip_verdict

When `p_d1 < 0.5`: **`skip_verdict=UNSCORED`**, `fd_semantics=LIKELY_VSYNC_PACKED|UNKNOWN_NOT_SWAP`.  
Never emit `NO_ZERO_REFRESH_SKIP` when premise violated.  
Parent’s `p_d0=0` **must not** be published as zero skips.

---

## T3 — valid skip metric

| RBF | PLXD[63:48] | skip from Δfd? |
|---|---|---|
| **c5382bee (deployed)** | `bank_vsync_count` | **NO** — Δfd = vsyncs between publishes |
| tip RTL (needs fit) | real `frames_done_d2` | YES — Δ∈{0,1} under free-gate |

**vsync_toggle ARM-readable on c5382bee?**  
Indirectly YES as the false `frames_done` field (=bank_vsync_count).  
True swap count: **not** exported. Reserved `[47:36]=0`.

**Minimum change for honest skip:** new RBF packing tip’s `frames_done_d2` (already in tip RTL). Optional: keep vsync count in a second field/mailbox for phase.  
**No fit authorised here.** Until then: glass OCR / `publish_misses` / free-mask Drop only.

---

## T4 — interval stats

Summary line now includes:
`median_ms trimmed_mean_ms steady_sigma_ms steady_n p_ge50_steady`  
Verdict prefers `p_ge50_steady` when `steady_n≥100`.

---

## T5 — deploy false-negative

**Root cause (source):** after `DEPLOY_OK`, script `source`s `scripts/boot_hook_policy.sh` which was **missing on branch** → `set -e` → **rc=1 after successful live verify**.

**Fix:**
- Restored `scripts/boot_hook_policy.sh` from git history
- Ensured `scripts/daemon_backup_policy.sh` present
- Fail-loud missing-file checks **before** source (exit 2), so missing policy cannot look like a soft post-fail after DEPLOY_OK

---

## Parent re-run (agent does not touch device)

```bash
# rebuild+deploy daemon from this tip
scripts/deploy_misterplexd.sh build/arm/misterplexd   # expect true rc=0 end-to-end
# ≥60s soak, stop stream
grep -E 'publish_interval|publish_swap_delta' LOG | tail -20
# Expect: skip_verdict=UNSCORED fd_semantics=LIKELY_VSYNC_PACKED
#         median_ms / trimmed_mean_ms near ~41–45; p_ge50_steady still elevated if ARM late
```
