# Phase 3.3l — Inv quant + 4×4 IDCT + Intra pred (FPGA)

**Status:** 3.3l-0 done; 3.3l-1 **host goldens locked** (`res_csum` XOR sat8 full-16 = **0x14** / 20); **R-csum1 BUILD_OK** RBF **`dabdaeb0`** (sources **`7bee0a6`**; running XOR + ST_PLACE `lev[]` + preserve status) — lab sole-deployed (**H-deploy-rcsum1**): **`res_dc=-24` OK**, **`res_csum` HARD FAIL** (raw[13] unstable 139/222/49 ≠0x14; soft-skip ≠ PASS — **H-rcsum-gate**); 3.3l-2 **host paint goldens + RTL plug sketch DONE** — **P3-3l2 BLOCKED** (post-deploy contingency: residual RCA only; no paint until hard PASS).  

**Depends on:** 3.3k residual levels/runs → `residual_dc` (HW-green); **3.3l-1 hard `res_csum=20` on lab** (still **FAIL** after R-csum1 BUILD_OK + sole deploy on **`dabdaeb0`**)  
**Product rule:** hybrid host recon → F1 still owns present until FPGA mae is competitive.  
**No Quartus for 3.3l-0 / host 3.3l-1 / host 3.3l-2 / L-3l2-rtl / L-csum-note / L-csum-note2 / L-3l2-gate / L-3l2-gate2** — paint fit / SV wire-up / `files.qip` only after hard csum green + sole build free. **No mid-RCA FPGA commit thrash.**  
**Hard unblock:** `raw[13]==0x14` **AND** `res_dc=-24` stable ≥2 re-pushes on a *new* post-fix RBF (≠ **`dabdaeb0`**); soft-skip EXIT=0 is **NOT** enough. **Do not invent PASS.**  
**Contingency ACTIVE (R-csum-rca3 / H-deploy-rcsum1):** post-R-csum1 sole deploy hard gate **FAILED** on **`dabdaeb0`** (raw[13] unstable **139/222/49**; soft-skip ≠ PASS) → **no 3l2** (stay BLOCKED; residual RCA branch **a** status/preserve/multi-drive; **do not thrash-redeploy dabdaeb0**). Probes: `/tmp/misterplex-agent-H-deploy-rcsum1.txt`.

## Goal

Move from **coeff probe** (`residual_dc = scan coeff[0]`) to **real recon pixels** on FPGA:

1. Inverse quantize first residual 4×4  
2. 4×4 integer IDCT (FFmpeg `ff_h264_idct_add`)  
3. Intra prediction (first MB, then all MBs)  
4. Write reconstructed samples into `frame_store` (F3 diagnostic path)

Host reference (bit-exact vs FFmpeg no-deblock):  
`host/libmisterplex/h264_recon.hpp` — `dequant4x4`, `idct4x4_add`, `predI4` / I16 / chroma.

## Where we are (3.3k baseline)

| Piece | Location | State |
|-------|----------|--------|
| Slice header + mb_type + QP | `slice_hdr_parser.sv` | done |
| CAVLC first residual (nC=0) | same: levels, total_zeros, run_before, ST_PLACE | done |
| Export | `residual_ok`, `residual_tc`, `residual_t1`, `residual_dc` | golden `-24` |
| Paint | `decode_stub.sv` MB0 gray = clamp(128+dc) | diagnostic only |
| Capture | nalu_scanner + MAXB=**48 B** RBSP | first residual ~17 B |
| Product present | host `reconISlice` → F1; `host_owns_fs` | unchanged |
| Fit (5CSEBA6, post-3.3k / current `Plex.fit.summary`) | ALM **22%** (9.4k/41.9k), M10K **74%** (407/553), bits 56%, DSP 33% | headroom: **ALM**, **DSP**; **M10K is tight** |

Golden Baseline F3 vector (`scripts/gen_test_annexb_real.py`):  
`mb0=0` (I_NxN), `qp=25`, first residual `tc=8 t1=3 coeff[0]=-24`.

---

## Architecture

### Dataflow target

```text
bitstream_fifo → nalu_scanner
                    ├─ SPS/PPS parsers (unchanged)
                    └─ slice path:
                         headers + first MB meta (existing bit-walk)
                         → residual CAVLC (extend ST_PLACE → full coeff[16])
                         → inv_quant 4×4
                         → idct4x4_add onto pred
                         → intra pred (I4 / later I16+chroma)
                         → pixel pack RGB565
                         → frame_store wr_en (F3; gated by host_owns_fs)
```

### Module split (new / grow)

| Module | Role | BRAM? |
|--------|------|-------|
| `slice_hdr_parser` | Keep header + CAVLC; **export full `coeff[0:15]`** after ST_PLACE | no (regs) |
| `inv_quant4` (new) | LevelScale × shift; FFmpeg `(level*qmul+32)>>6` | no |
| `idct4x4` (new) | Multi-cycle butterfly = `ff_h264_idct_add` | no |
| `intra_pred4` (new) | Modes 0–8 + DC avail; later I16/chroma | no |
| `mb_recon` (new or in stub) | Seq: pred → idct-add → MB buffer → RGB | first MB: regs only |
| `decode_stub` → evolve | Consume recon pixels instead of gray DC | no extra |
| Neighbour store (all-MB only) | Top row Y/UV + TC for nC | **yes, small** |

**Do not** store full YUV frame in M10K: write RGB565 into existing dual-bank `frame_store` as MBs finish.

---

## What stays logic-only (no new M10K)

Safe for 3.3l first-MB and most of all-MB math:

| Item | Why logic |
|------|-----------|
| `lev[0:15]`, `runv[0:15]`, `coeff[0:15]` | Already regs; 16×9 + 16×4 + 16×16 ≈ few hundred flops |
| Zigzag + LevelScale tables | 6×3 mf + scan — `case` / const ROM → LUT |
| Inv quant multiply | One 16×16 MAC; use **1 DSP** or shift-add by qp%6 |
| 4×4 IDCT | Pure add/shift butterflies; multi-cycle FSM (~8–16 cycles) |
| Intra4×4 modes 0–8 | Spec formulas; DC with hasA/hasL |
| I16 DC Hadamard | Same as host `invQuantHadamardDc4x4` (TRANSPOSE layout!) |
| Chroma 2×2 Hadamard | Small; host `invChromaDc2x2` |
| Within-MB neighbours | Left/above 4×4 of **same** MB = MB Y regs (256 B → MLAB or flops, not M10K) |
| First-MB unavailable | Outside: hasA=hasL=0 → DC=128 (no top-row RAM) |

### Must use BRAM (only for all-MB)

| Buffer | Size | M10K est | Notes |
|--------|------|----------|-------|
| Top luma row | 320 × 8 b | **1** | after each MB row |
| Top chroma U/V | 160 × 8 × 2 | **1** | 4:2:0 |
| TotalCoeff cache (nC) | ~ mb_w×4×5b × 2 rows | **≤1** | or MLAB |
| Live slice stream | **0 new** | 0 | keep reading `bitstream_fifo`; **do not** grow MAXB to whole IDR |
| Optional MB scratch | 16×16×8 | 0 | prefer regs/MLAB |

**Forbidden BRAM growth:** full-slice RBSP capture, dual YUV frame buffers, large coeff FIFOs.

---

## BRAM budget (Cyclone V 5CSEBA6)

Device: **553 M10K**, **5.66 Mbit**. Current fit: **407 / 553 (74%)**, **~3.17 Mbit (56%)**.

### Existing major consumers (approx)

| Block | Bits | ~M10K |
|-------|------|-------|
| `frame_store` 320×240×16×2 | 2,457,600 | ~240 |
| `bitstream_fifo` 32 KiB | 262,144 | ~26 |
| `audio_fifo` 2048×32 | 65,536 | ~7 |
| sys / ascal / misc | rest → 407 total | ~134 |

### Headroom

| Resource | Free now | 3.3l plan use | After 3.3l (est) |
|----------|----------|---------------|------------------|
| M10K | **146** | +0 first-MB; +2…4 all-MB | **~74–76%** |
| Block bits | ~2.5 Mbit | negligible for tables | still ≪ 100% |
| ALM | **77% free** | IDCT+pred+CAVLC walk ~1–3k ALM | ~25–30% |
| DSP | **75 free** | 0–2 for quant mul | ~33–35% |

### Risk controls if M10K creeps

1. Prefer MLAB for ≤2 Kib scratch.  
2. Never enlarge `bitstream_fifo` for decode.  
3. If neighbour rows push fit: drop chroma top-row first (luma-only paint for lab).  
4. Last resort: shrink audio DEPTH 2048→1024 (~3 M10K) — product impact, avoid.  
5. Do **not** dual-buffer YUV; RGB into existing banks only.

---

## Implementation phases

### 3.3l-0 — Host golden stubs (no FPGA) ✅

Lock math before RTL. **Done** in `tests/unit/test_idct_quant.cpp` (`make unit`).

- `dequant4x4` + `idct4x4_add` on synthetic DC and real first residual  
- First I_NxN 4×4: pred=128 (unavailable), qp=25, host coeffs → pixel golden  
- Hard-locked golden + printable dump: coeffs, dequant block, meanY, y[0..3][0..3]  
- Reuse `probeFirstI16Dc` / recon path; no new algorithm

**Locked golden (Baseline clip, first residual):**

| Field | Value |
|-------|-------|
| tc / t1 / qp | 8 / 3 / 25 |
| coeff scan | `-24 4 4 0 -4 0 -1 0 0 -1 1 0 1 0 0 0` |
| synth DC-only y | 62 (uniform; coeff0=-24) |
| y00 / mean4×4 | 73 / 62 |
| y 4×4 | `73 72 76 76` / `72 74 71 73` / `76 71 32 27` / `76 73 27 24` |

**Exit:** `make unit` includes quant/IDCT check; coeffs and 4×4 pixels known for golden clip.

### 3.3l-1 — Full first residual coeffs on FPGA (logic-only)

**Host prep (done, no Quartus):** goldens in `host/libmisterplex/h264_residual_gold.hpp`;
helpers in `h264_cavlc.hpp`; locked by `test_idct_quant`.

| Host / RTL | Value |
|------------|-------|
| coeff scan | `-24 4 4 0 -4 0 -1 0 0 -1 1 0 1 0 0 0` |
| `residualCsum8` | **20 / 0x14** = XOR of `sat_s8(coeff[i])` (host + ST_PLACE RTL) |
| Ports | `residual_coeff[0:15]` signed 9b through `stream_path`; `residual_csum[7:0]` |
| Status pack | `[103:96]=dc` `[111:104]=csum` `[127:112]=bytes[15:0]` (`Plex.sv`) |
| Host status | `push_frame` prints `res_csum=`; `CoreStatus::residual_csum` |
| Unit | `test_idct_quant` locks full-16 + csum; prints `FPGA_GOLD` lines |
| MAXB / M10K | **48** unchanged; **no new M10K** |
| RBF | sources **`7bee0a6`**; lab **`dabdaeb0`** sole-deployed; raw[13] live but csum **HARD FAIL** unstable; **R-csum1 BUILD_OK** done |

Helpers: `satS8`, `residualCsum8`, `dumpResidualCoeffs`, `hostToFpgaResidualExpose`,
`residualCoeffsMatch`. Goldens: `residual_gold::{kCoeffScan,kCsum8,kDc,kY}`.

- Keep `residual_dc = satS8(coeff[0])` = **-24** for regression  
- Still **one** residual block; nC=0; MAXB=48 unchanged  

**Exit unit:** host dump == `residual_gold` (csum **0x14**, full-16). ✅  
**Exit HW (hard):** `test_f3_residual.sh` `res_dc=-24` + **hard** `res_csum=20` (soft-skip ≠ PASS).

#### HW evidence — residual csum (L-csum-note + **L-csum-note2**, 2026-07-24)

| Item | Result |
|------|--------|
| Host unit | XOR sat8(full-16) = **0x14** / **20** locked (`test_idct_quant`, `residual_gold::kCsum8`) |
| Prior RBF `aa146c17` | `res_dc=-24` PASS; `res_csum` FAIL (raw[13]=`0x53` ≈ stream_bytes residue) |
| Prior RBF **`820484a6`** (Q-fix1) | FBAR green; res_dc=-24 OK; hard csum FAIL (raw[13] unstable 232/59/142) — **superseded** |
| **R-csum1 APPLIED** | **BUILD_OK** 12:17:04 exit=0; running XOR + ST_PLACE `lev[]` + preserve; RTL commit **`7bee0a6`**; log `/tmp/plex_quartus_rcsum1.log`; RBF full md5 **`dabdaeb0c5ae708c4fdbba388ba275b6`** |
| Lab RBF **`dabdaeb0`** | **H-deploy-rcsum1** one `DEPLOY_LOAD=menu`; CORENAME=Plex; **FBAR PASS** (m1=82.9 m2=94.4); **`res_dc=-24` PASS** stable `0xE8`; **hard `res_csum=20` FAIL** |
| raw[13] on **`dabdaeb0`** | **Live** pack (≠ stream_bytes low 391/417/444; ≠ 0xE8) but **≠0x14** and **unstable**: **139 / 222 / 49** (`0x8b` / `0xde` / `0x31`) — never golden |
| Soft-skip | `test_f3_residual.sh` EXIT=0 on mismatch (got 49/139/222 want 20) — **still NOT hard PASS** |
| Failure class | Contingency branch **(a)** unstable csum → status path / preserve / multi-drive (do **not** re-open tmpc-fold first; R-csum1 already applied) |
| **3.3l-2 paint** | **remains BLOCKED** — hard raw[13]==0x14 + res_dc=-24 + no soft-skip **not met**; contingency §D ACTIVE → **no 3l2** until next residual fix hard PASS |
| **Do not** | Thrash-redeploy **`dabdaeb0`** expecting green; invent hard PASS; start paint / `files.qip` / mid-RCA FPGA commit |

**H-deploy-rcsum1 probes (silicon SoT for dabdaeb0 FAIL):**
- Reports: `/tmp/misterplex-agent-H-deploy-rcsum1.txt`, `/tmp/misterplex-agent-H-rcsum-gate.txt`
- Probes file: `/tmp/misterplex-H-deploy-rcsum1-probes.txt`
- PROBE1: `res_dc=-24 res_csum=139` raw `e8 8b 87 01` (bytes_in=391) → HARD_FAIL
- PROBE2/3: `res_dc=-24 res_csum=222` raw `e8 de a1 01` (bytes_in=417; stable within one stream state)
- PROBE4 soft: `res_csum=49` soft-skip EXIT=0 (**not** hard PASS)
- Soft log: `/tmp/misterplex-H-deploy-rcsum1-residual-soft.log`

Peer reports: `/tmp/misterplex-agent-H-deploy-rcsum1.txt`, `/tmp/misterplex-agent-H-rcsum-gate.txt`,
`/tmp/misterplex-agent-H-gate-rcsum1.txt`, `/tmp/misterplex-agent-R-csum1.txt`,
`/tmp/misterplex-agent-G-fpga-rcsum1.txt`, `/tmp/misterplex-agent-M-fitmon-rc5.txt`,
`/tmp/misterplex-agent-R-csum-rca3.txt`, `/tmp/misterplex-agent-H-deploy-fix1.txt` (prior 820484a6).

#### Post–R-csum1 sole-deploy + hard-gate protocol (ONE agent after BUILD_OK)

> **STATUS 2026-07-24 (H-deploy-rcsum1 / L-csum-note2):** R-csum1 **APPLIED** (running XOR +
> ST_PLACE `lev[]` + preserve; commit **`7bee0a6`**; BUILD_OK → RBF **`dabdaeb0`**).
> Sole menu deploy **DONE**. FBAR **PASS**. Hard residual **FAIL** — raw[13] unstable
> **139/222/49** never 0x14; res_dc=-24 OK. Soft-skip EXIT=0 is **NOT** hard PASS.
> **3.3l-2 remains BLOCKED** (contingency §D ACTIVE). **Do not thrash-redeploy dabdaeb0.**
> Next: residual RCA branch **(a)** status/preserve/multi-drive (not tmpc rehash) →
> *new* RBF md5 ≠ dabdaeb0 → re-run this checklist once. Probes:
> `/tmp/misterplex-agent-H-deploy-rcsum1.txt`.
>
> **Historical runbook** below is for the *next* sole post-BUILD_OK owner only.
> Do **not** invent BUILD_OK / hard PASS. Soft-skip ≠ PASS. One menu deploy only.

**Preconditions (all required):**

1. R-csum1 Full Compilation **successful** (`BUILD_OK` in `/tmp/plex_quartus_rcsum1.log`; exit 0).
2. New RBF md5 **≠** `820484a686dc6b744954e3c8ef8df3f4` (prefix **≠** `820484a6`).
3. Build inputs were the dirty-fix tree (or post-commit equivalent): running XOR +
   ST_PLACE `lev[]` recompute + `Plex.sv` `st_res_*` preserve barrier — **not** the
   34bf755 tmpc-fold-only path that produced `820484a6`.
4. No parallel residual fit; no mid-fit RTL thrash of `Plex.sv` / `slice_hdr_parser.sv`.
5. **Single owner** for promote → deploy → gate → park (no concurrent `load_core`).

##### ONE-agent checklist (after BUILD_OK only)

Copy-paste order for the sole post-BUILD_OK agent. **Historical checklist** (already run for dabdaeb0; hard FAIL). Do not invent PASS.

1. **Confirm BUILD_OK** — log shows successful Full Compilation; exit 0; do **not** invent.
2. **Collect md5** — `md5sum fpga/Plex_MiSTer/output_files/Plex.rbf` → record full hash + 8-char prefix; **abort** if prefix still `820484a6`.
3. **Promote paths if needed** — copy *same* bitfile to:
   - `fpga/Plex_MiSTer/releases/Plex.rbf`
   - `releases/Plex.rbf`
   Re-`md5sum` all three; all **identical** and **≠ 820484a6**.
4. **Sole menu deploy (ONE only)** —
   ```bash
   DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh
   # or explicit promoted path:
   DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh releases/Plex.rbf
   ```
   Never raw `scp` + `echo load_core … > /dev/MiSTer_cmd` thrash. Never second deploy same tick.
5. **Lab confirm** — remote `/media/fat/_Utility/Plex.rbf` md5 == local new; `/tmp/CORENAME` = **Plex**. If already match after the one deploy, **do not** redeploy.
6. **FBAR** — `./tests/hw/test_fbar_fast.sh` → EXIT=0; hard ok m1/m2 ≥15 (expect PASS; Fix-1 colorbars still in tree).
7. **Hard residual gate** (soft-skip is **NOT** PASS) —
   - Control: `res_ok=1 res_tc=8 res_t1=3 mb0=0 qp=25`
   - **Hard:** `res_dc=-24` (`raw[12]=0xE8`) **and** `res_csum=20` (`raw[13]=0x14`)
   - **Stable** across ≥2 re-pushes after F3 Baseline push
   - Tools: `tests/hw/test_f3_residual.sh` for push/print; then **agent-enforced** hard check via
     `python3 tests/parse_res_csum_status.py` (**A-csum-host2**) on captured status/raw lines;
     lab print path: `push_frame --status` / `--raw` (**A-arm-csum** READY on lab)
8. **Park bars** — `set_status --pattern bars --force-bars 1 --tv ntsc --fps 60`
9. **Report** — write `/tmp/misterplex-agent-H-rcsum-gate.txt` (md5s, FBAR scores, ≥2 raw probes, hard PASS/FAIL, soft-skip note).

##### Numbered steps (detail table)

| # | Action | Pass when / command |
|---|--------|---------------------|
| 1 | **Confirm BUILD_OK** | Log shows successful compile; `output_files/Plex.rbf` mtime/md5 post-build |
| 2 | **Collect RBF md5** | `md5sum fpga/Plex_MiSTer/output_files/Plex.rbf` → record full + 8-char prefix |
| 3 | **Promote RBF** (host paths only) | Copy *same* bitfile to both: `fpga/Plex_MiSTer/releases/Plex.rbf` **and** `releases/Plex.rbf`. All three md5s **identical** and **≠ 820484a6** |
| 4 | **ONE menu deploy** | `DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh` (optional path arg: promoted RBF). **Never** raw `scp` + `echo load_core … > /dev/MiSTer_cmd` thrash |
| 5 | **Lab confirm** | Remote `/media/fat/_Utility/Plex.rbf` md5 == local new; `/tmp/CORENAME` = **Plex**. If already match after deploy, **do not** redeploy |
| 6 | **FBAR** | `./tests/hw/test_fbar_fast.sh` → EXIT=0; hard ok m1/m2 ≥15 |
| 7 | **Hard residual gate** | See hard criteria + tool recipe below — **NOT** soft-skip |
| 8 | **Stability** | ≥2 extra `push_frame` re-pushes: `res_dc` and `res_csum` **stable** at goldens |
| 9 | **Park bars** | `set_status --pattern bars --force-bars 1 --tv ntsc --fps 60` |
| 10 | **Report** | `/tmp/misterplex-agent-H-rcsum-gate.txt`: md5, FBAR, raw probes, PASS/FAIL |

**Hard residual criteria (agent must enforce; script soft-skip is insufficient):**

| Field | Status / raw | Hard expect |
|-------|--------------|-------------|
| `res_ok` / `res_tc` / `res_t1` | status line | `1` / `8` / `3` |
| `mb0` / `qp` | status line | `0` / `25` |
| `res_dc` | `raw[12]` | **`-24` / `0xE8`** stable |
| `res_csum` | `raw[13]` | **`20` / `0x14`** stable across ≥2 re-pushes |
| stream_bytes | `raw[14:15]` LE | live counter — **must not** equal csum (aa146c17 pack alias) |

```bash
# 1) Push Baseline F3 residual (script may soft-skip csum — ignore soft PASS):
./tests/hw/test_f3_residual.sh
# Soft-skip EXIT=0 on res_csum mismatch is NOT hard PASS.

# 2) Capture status / raw (lab ARM — A-arm-csum tools READY):
#   push_frame --status   → must show res_dc=… res_csum=…
#   push_frame --raw      → 16B hex; indices 12..15 = residual pack

# 3) Offline hard decode (host — A-csum-host2; no SPI thrash):
python3 tests/parse_res_csum_status.py              # goldens + map
python3 tests/parse_res_csum_status.py --self-test  # offline OK
# pipe a captured line, or pass raw[12..15] hex:
echo '<status or raw line>' | python3 tests/parse_res_csum_status.py -
python3 tests/parse_res_csum_status.py e8 14 2a 00  # expect HARD_PASS
# Require GATE hard=PASS and class HARD_PASS on ≥2 independent probes.
```

Host goldens (locked unit — never invent other values):

| Field | Value | Notes |
|-------|-------|-------|
| `res_dc` | −24 / `0xE8` | `sat8(coeff[0])` |
| `res_csum` | 20 / `0x14` | XOR sat8 full-16 — **never** arith sum −20 / `0xEC` |

**Hard PASS only if:** FBAR green **and** `res_dc=-24` **and** `res_csum=20` (`raw[13]==0x14`) stable **and** agent did **not** treat soft-skip as PASS.  
**Then (only):** unlock 3.3l-2 paint path (inv_quant/IDCT / `files.qip` per *P3-3l2 UNBLOCK GATE*).  
**Else (post-deploy FAIL):** keep 3l2 **BLOCKED**; follow failure branches below (measure first — no thrash).  
WIDE re-eyes (W-proto7) orthogonal, not a csum blocker.

**NO-GO (do not do):**

- Redeploy **`820484a6`** expecting csum green (H-deploy-fix1 / H-gate-fix1 already FAIL: 232/59/142 class)
- Kill / restart / second Quartus while any residual fit is LIVE
- Second / thrash deploy in the same tick (one `DEPLOY_LOAD=menu` only)
- Count `test_f3_residual.sh` soft-skip EXIT=0 as hard csum PASS
- Invent hard PASS without post-deploy `raw[13]==0x14` evidence
- Start 3.3l-2 paint fit / half-wire `files.qip` before hard csum PASS
- Pre-write further RTL “fixes” before measuring the new RBF
- Residual push storm / thrash loops while diagnosing (capture ≥2 probes, park, report)

**Failure branches (only after post–R-csum1 sole deploy still hard-fails — measure first):**

From R-csum-rca3/4 contingency. Capture ≥2 `push_frame --status`/`--raw` probes, classify with
`parse_res_csum_status.py`, park bars, write report — **then** decide next RTL owner.
Do **not** re-open the tmpc-fold theory as first guess (that is the pre-R-csum1 RCA).

| # | Symptom after **new** RBF | Class (RCA contingency) | Next |
|---|---------------------------|-------------------------|------|
| a | `res_csum` **unstable** / changes per push (820484a6 class: 232/59/142) | status path / preserve / multi-drive | Hunt `status_telem` + `st_res_*` preserve barrier + `status_set` on residual edges; not tmpc rehash |
| b | `res_csum` **stable** but ≠ `0x14` (incl. stale arith `0xEC`) | level fold / sat8 / wrong residual multiset | Check `lev[]` write order, clear-before-signs, sat8 vs host; reject arith-sum fold |
| c | `res_csum` == stream_bytes low again | pack regression (aa146c17 class) | Re-check `Plex.sv` pack `[111:104]` vs `[127:112]`; helper class `STREAM_BYTES_ALIAS` |
| d | `res_csum` == `0xE8` stable (== dc) | ST_PLACE still dc-only collapse | Confirm lev[] recompute actually in **bitstream** (source/md5 mismatch vs R-csum1 inputs?) |
| e | `res_dc` broken (≠ −24) | scalar regression vs R-csum1 delta | **STOP**; residual_dc must stay green — bisect vs dirty fix; no paint, no thrash |
| f | FBAR FAIL | video/pattern path | Fix FBAR first; do **not** residual thrash loop |
| g | Lab ARM lacks `res_csum=` print | tools lag (pre A-arm-csum) | Use `push_frame --raw` / `set_status --raw` + host parse helper; optionally re-push A-arm bins only (**no** RBF thrash) |

Residual risk (R-csum-rca4, does **not** revoke GO): lev[] fold is synth-safer than tmpc[cn],
but silicon is final proof. If still wrong post-deploy: next RCA re-checks lev write order /
clear before ST_SIGNS / multi-cycle latch — **not** re-open tmpc fold as default.

Do **not** pre-land contingency RTL; re-RCA from lab raw dumps on the **new** md5.

**Deploy command reference (only path allowed for this gate):**

```bash
# After promote (checklist step 3):
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh
# or explicit:
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh releases/Plex.rbf
# Env: MISTER_HOST (default 192.168.1.183), MISTER_PASS, DEPLOY_WAIT_S=5
# DEPLOY_LOAD=none = copy only (not enough alone for this gate if CORE still old)
# DEPLOY_LOAD=core = Plex-only reload (only if already on Menu)
```

**Tools inventory (ready before BUILD_OK):**

| Tool | Owner / path | Role |
|------|--------------|------|
| Host parse helper | `tests/parse_res_csum_status.py` (A-csum-host2) | Offline EXPECTED vs ACTUAL + GATE; no SPI |
| Lab status print | `push_frame --status` / `--raw` (A-arm-csum READY) | Live `res_csum=` + raw[13] |
| Residual push | `tests/hw/test_f3_residual.sh` | F3 Baseline push; soft-skip ≠ hard PASS |
| FBAR | `tests/hw/test_fbar_fast.sh` | Visual/pattern gate before residual trust |
| Safe deploy | `scripts/deploy_plex_core.sh` `DEPLOY_LOAD=menu` | Sole load path |

Report template peers: H-deploy-fix1 / H-gate-fix1 scorecards.  
RCA SoT: R-csum-rca3 + R-csum-rca4. Protocol authors: H-rcsum-proto / H-rcsum-proto2.

### 3.3l-2 — Inv quant + IDCT on first 4×4 (logic-only)

**Host prep (done, no Quartus):** `h264_residual_gold.hpp` locks dequant + recon paint;
`test_idct_quant` prints `FPGA_GOLD deq4x4` / `recon_y4x4` / `recon_y00` / `recon_mean`.

New small FSM after residual place (in parser or `mb_recon`):

1. `dequant4x4(coeff, max=16, qp=slice_qp±mb_qp_delta)`  
2. pred block = 128 (MB0 4×4, no neighbours)  
3. `idct4x4_add` → 4×4 recon Y  
4. Status: mean of 16 samples or y00 for eyes-on  
5. `decode_stub`: paint **top-left 4×4** (or full 16×16 if only one block) with true recon gray/RGB

**Bit-exact target vs host** for that 4×4 (mae=0 on block).

#### Locked host paint vector (Baseline first residual)

Source of truth: `host/libmisterplex/h264_residual_gold.hpp` + `tests/unit/test_idct_quant.cpp`
(`3l2-table` table-only + `3l2-real` annex-B). `make unit` locks both.

| Step | Value |
|------|-------|
| coeff scan | `-24 4 4 0 -4 0 -1 0 0 -1 1 0 1 0 0 0` |
| qp / pred | 25 / **128** (unavailable neighbours → DC) |
| residual_csum | **20 / 0x14** = XOR sat8(coeff[i]) — **not** stale arith sum **−20 / 0xEC** |
| dequant 4×4 (row-major) | `-4224 896 0 -224` / `896 -1152 0 288` / `0 0 0 0` / `-224 288 0 0` |
| recon Y 4×4 | `73 72 76 76` / `72 74 71 73` / `76 71 32 27` / `76 73 27 24` |
| y00 / mean4×4 | **73** / **62** = `(sum+8)/16` |
| paint y00 RGB565 | **0x4A49** (`grayRgb565(73)`) |
| 3.3k stub contrast | MB0 gray = `128+dc` = **104** (RGB565 **0x6B4D**) — **not** true recon |
| frame_store addrs @W=320 | `0..3, 320..323, 640..643, 960..963` |

#### `decode_stub` top-left 4×4 sketch (no Quartus this fire)

Today (`decode_stub.sv` 3.3k): when `residual_ok`, **entire MB0 16×16** is painted
`clamp(128 + residual_dc)` → gray **104**, packed RGB565 `{R[7:3],G[7:2],B[7:3]}` with R=G=B.

**3.3l-2 target paint** (logic-only, no new M10K):

```text
// After inv_quant + idct_add onto pred=128 → recon_y[0:3][0:3] = residual_gold::kY
// Sequential paint (existing wr_en / wr_pixel / wr_reset_ptr path):
//   for y in 0..239:
//     for x in 0..319:
//       if (x < 4 && y < 4 && lat_res_ok && recon_ready)
//         wr_pixel = gray_rgb565(recon_y[y][x]);   // true 4×4
//       else if (mb0 && lat_res_ok)
//         // optional: leave rest of MB0 as diagnostic grid / stub 104 / or 128
//         ...
// frame_store linear addrs for top-left 4×4 @ W=320:
//   0,1,2,3, 320,321,322,323, 640..643, 960..963
// y00 RGB565 = grayRgb565(73)  (host residual_gold::kPaintY00Rgb565)
```

**Minimal RTL add** (prefer regs only):

| Item | Notes |
|------|-------|
| Hold `coeff[0:15]` after ST_PLACE | already 3.3l-1 tree |
| `inv_quant4` + `idct4x4` FSM | multi-cycle; match host butterflies |
| `recon_y[0:3][0:3]` 16×8b regs | paint source |
| `recon_ready` sticky | gate paint vs incomplete IDCT |
| Status soft | `recon_y00=73`, `recon_mean=62`; **keep `res_dc=-24`** |

Do **not** require full MB0 true recon in 3.3l-2 — only first coded 4×4 (scan block 0).
Rest of frame may stay strip/MB-grid diagnostic.

**Exit unit:** `test_idct_quant` locks deq + y[][] + paint contract (stub 104 ≠ y00 73).  
**Exit HW:** `tests/hw/test_f3_idct_mb0.sh` — residual gates + recon mean/y00 match host golden.

---

### P3-3l2 UNBLOCK GATE (L-3l2-gate / L-3l2-gate2 — exact checklist)

> **P3-3l2 remains BLOCKED** (L-csum-note2). Do **not** start inv_quant / IDCT fit, SV check-in,
> `files.qip` thrash, or paint Quartus until **all** §A hard-PASS criteria are met on lab
> **after** a residual-fix BUILD_OK + **sole** deploy of a *new* RBF (md5 **≠ `dabdaeb0`**).
> Soft-skip ≠ PASS. **R-csum1 dabdaeb0 sole deploy HARD FAIL** (raw[13] unstable **139/222/49**;
> res_dc=-24 OK) — contingency §D **ACTIVE** → **no 3l2**. Do **not** thrash-redeploy dabdaeb0.
> Probe SoT: `/tmp/misterplex-agent-H-deploy-rcsum1.txt`. Deploy mechanics: protocol above.

#### A) Hard residual PASS criteria (ALL required — no soft-skip)

| # | Criterion | Exact pass value | How to read |
|---|-----------|------------------|-------------|
| **A0** | **Post residual-fix sole deploy only** | Candidate fix RBF lab-loaded via one `DEPLOY_LOAD=menu` (R-csum1 was **`dabdaeb0`** — hard FAIL; next fix must be **≠ dabdaeb0**) | Do **not** invent PASS; **do not** thrash-redeploy dabdaeb0 expecting green |
| A1 | `res_dc` | **−24** | `push_frame --status` → `res_dc=-24`; **`raw[12]==0xE8`** |
| A2 | `res_csum` | **20** | `res_csum=20`; **`raw[13]==0x14`** (XOR sat8 full-16 — **never** arith −20 / 0xEC) |
| A3 | No soft-skip | Hard only | `test_f3_residual.sh` soft EXIT=0 on csum mismatch is **NOT** hard PASS and **NOT** unblock |
| A4 | Stability | ≥2 re-pushes | A1+A2 hold across ≥2 Baseline F3 pushes (not one lucky sample) |
| A5 | Control plane | green | `res_ok=1 res_tc=8 res_t1=3 mb0=0 qp=25`; FBAR still green on *new* RBF |
| A6 | Host unit still locked | 0x14 | `make unit` / `test_idct_quant` — do not re-derive goldens |

**One-line hard PASS formula (L-3l2-gate2):**

```text
HARD_PASS = FBAR green on candidate residual-fix RBF
         && res_dc  = -24  (raw[12] == 0xE8)  // A1
         && res_csum = 20  (raw[13] == 0x14)  // A2 — BOTH A1 AND A2 required
         && stable across ≥2 re-pushes        // A4
         && NOT soft-skip-as-pass             // A3: script EXIT=0 on mismatch ≠ PASS
// dabdaeb0 (R-csum1 XOR+lev APPLIED): A1 PASS; A2+A4 FAIL (139/222/49) → NOT HARD_PASS
// → 3.3l-2 remains BLOCKED (soft-skip still not hard PASS)
```

**NOT hard PASS / NOT unblock:**
- `test_f3_residual.sh` EXIT=0 with soft-skip on `res_csum` mismatch
- host unit XOR `0x14` alone (already locked — HW must match)
- thrash-redeploying **`dabdaeb0`** (or prior **`820484a6`**) expecting csum green
- inventing PASS without post-deploy **`raw[13]==0x14`** evidence
- A1 alone (res_dc green) without A2 — **both** required (dabdaeb0 is this case)
- treating soft-skip EXIT=0 as unblock (**soft-skip still NOT hard PASS**)

**Lab now (blocked evidence — L-csum-note2 / H-deploy-rcsum1):** RBF **`dabdaeb0`**
(R-csum1 APPLIED: running XOR + `lev[]` + preserve, commit `7bee0a6`; sole menu deploy done).
A1 PASS (stable 0xE8); FBAR PASS; **A2 FAIL** (raw[13] live/unstable **139/222/49** =
0x8b/0xde/0x31 — never 0x14); A3 soft-skip EXIT=0 is **not** unblock; A4 FAIL (unstable).
Contingency §D **ACTIVE**: **no 3l2**. Next RCA: status path / preserve / multi-drive —
**do not** re-open tmpc-fold first; **do not** thrash-redeploy dabdaeb0.
Evidence: `/tmp/misterplex-agent-H-deploy-rcsum1.txt`, probes
`/tmp/misterplex-H-deploy-rcsum1-probes.txt`.

```bash
# After sole deploy of NEW RBF only (A0):
./tests/hw/test_f3_residual.sh                 # status print; soft EXIT=0 ≠ PASS
# Agent hard-check (status + raw):
#   res_dc=-24  res_csum=20
#   raw[12]=e8  raw[13]=14
python3 tests/parse_res_csum_status.py e8 14 .. ..   # expect dc=-24 csum=20
# ≥2 extra push_frame re-pushes → both fields STABLE
```

Helper: `python3 tests/parse_res_csum_status.py` (or pipe status line through `-`).

#### B) Pre-unblock sequence (R-csum path — 3l2 must wait)

Hard residual measurements (§A) **only count after B1**. No parallel paint work during B0–B3.

| Step | Owner | Action | Gate / result (2026-07-24) |
|------|-------|--------|----------------------------|
| B0 | R-csum1 | BUILD_OK new RBF md5 **≠** `820484a6` | **DONE** — `/tmp/plex_quartus_rcsum1.log` BUILD END 12:17:04 exit=0 → **`dabdaeb0`** |
| B1 | Deploy | **One** sole menu deploy of *new* RBF | **DONE** — H-deploy-rcsum1; lab==host `dabdaeb0`; CORENAME=Plex |
| B2 | FBAR | `test_fbar_fast` reconfirm on **new** RBF | **PASS** on dabdaeb0 (m1=82.9 m2=94.4) |
| B3 | Hard residual | §A **A0–A5** | **FAIL** — res_dc=-24 OK; raw[13] unstable **139/222/49** never 0x14; soft-skip ≠ PASS |
| B4 | Unblock 3l2 | Only if B3 hard PASS | **NOT unlocked** — 3.3l-2 **remains BLOCKED** (contingency §D) |

Report for B0–B3 owner: `/tmp/misterplex-agent-H-deploy-rcsum1.txt` / `/tmp/misterplex-agent-H-rcsum-gate.txt`.
Next after B3 FAIL: residual RCA only (no paint); **no thrash redeploy** of dabdaeb0.

#### C) After hard PASS only — SV wire-up order (logic-only, **no new M10K**)

> **Execute C0–C9 only after §A HARD_PASS on post–R-csum1 lab RBF.** Docs-only until then.
> Do **not** half-wire. Prefer full modules at sole paint-fit start; **no orphan SV** in
> tree / `files.qip` before C1 authorized. Do **not** check in SV while gate is open.
> Order is strict (C1→C2 before C3; C7 only after modules exist; C8 sole fit).

| Step | Action | File(s) | Verify |
|------|--------|---------|--------|
| **C0** | Confirm §A hard residual green on **new** lab RBF | H-rcsum-gate report | **`raw[13]==0x14` AND `res_dc=-24`** stable; no soft-skip; md5 ≠ `820484a6` |
| **C1** | Add `inv_quant4` — match host `dequant4x4` / `kDeq` (deq00=**-4224**) | `fpga/Plex_MiSTer/rtl/inv_quant4.sv` | table vs `residual_gold::kDeq` |
| **C2** | Add `idct4x4_add` — pred=128 → `kY` (y00=**73** mean=**62**) | `fpga/Plex_MiSTer/rtl/idct4x4_add.sv` | host butterflies; **no new M10K** |
| **C3** | Instantiate both in **`stream_path.sv`** next to `decode_stub` (**not** inside `slice_hdr_parser`) | `fpga/Plex_MiSTer/rtl/stream_path.sv` | residual bus untouched; no csum recompute |
| **C4** | Feed `residual_coeff[0:15]` + `slice_qp`/`sl_qp`(=25); start on `residual_ok` / `sl_res_ok` rise | same | coeffs stable post ST_PLACE |
| **C5** | Extend `decode_stub`: paint **top-left 4×4 only** when `recon_ready`; rest MB0 may stay stub 104 | `fpga/Plex_MiSTer/rtl/decode_stub.sv` | addrs @W=320: `0..3,320..323,640..643,960..963`; y00 RGB565 **0x4a49** |
| **C6** | Soft telem optional: `recon_y00=73` / `recon_mean=62` | spare status bytes only | **hard keep** res_dc/csum/ok/tc/t1 |
| **C7** | `files.qip` add both SV modules **only** at sole paint fit start | `fpga/Plex_MiSTer/files.qip` (or equiv) | no orphan modules; `NUM_PARALLEL=2` |
| **C8** | Sole Quartus → one `DEPLOY_LOAD=menu` → FBAR green | paint RBF | BUILD_OK; residual still hard green |
| **C9** | `test_f3_idct_mb0.sh` residual hard + recon soft→hard | HW | y00=73 mean=62 eyes-on ≠104 |

**Do not touch from paint path:** `Plex.sv` residual status pack (`[103:96]` dc / `[111:104]` csum / `[127:112]` bytes); `slice_hdr_parser` ST_PLACE csum/dc compute (R-csum1 owner until green, then leave alone).

Detail interfaces: *3.3l-2 concrete RTL plug sketch* below (L-3l2-rtl).

#### D) Contingency — R-csum-rca3 (**ACTIVE** after dabdaeb0 — **no 3l2**)

Aligned with `/tmp/misterplex-agent-R-csum-rca3.txt` §7, *Failure branches* above, and
**H-deploy-rcsum1** silicon measure on **`dabdaeb0`**:

- **Triggered:** R-csum1 (running XOR+lev) BUILD_OK + sole deploy left hard residual **FAIL** → **P3-3l2 stays BLOCKED**.
- Measured class **(a)** unstable raw[13] **139/222/49** (same class as prior 232/59/142 on 820484a6):
  status path / preserve / multi-drive — **not** tmpc rehash as first guess (R-csum1 already applied).
- Soft-skip EXIT=0 is **still NOT** hard PASS and **still NOT** unblock.
- Do **not** start inv_quant / IDCT / `files.qip` / paint Quartus while residual is red.
- Further residual RCA only (measure first on lab **`dabdaeb0`** probes — do not pre-write paint RTL):
  - csum still unstable → status path / preserve / multi-drive  ← **current**
  - csum stable ≠0x14 → level fold / sat8 / wrong residual multiset
  - csum == stream_bytes again → pack regression (aa146c17 class)
  - csum == 0xE8 stable → ST_PLACE fold still collapsed (dc-only)
- NO thrash-redeploy of **`dabdaeb0`** expecting green; NO invent hard PASS without raw[13]==0x14 evidence.
- Probe SoT: `/tmp/misterplex-agent-H-deploy-rcsum1.txt`, `/tmp/misterplex-H-deploy-rcsum1-probes.txt`.

#### Handoffs / goldens (read, do not re-derive)

| Item | Location |
|------|----------|
| L-3l2e host goldens DONE | `/tmp/misterplex-agent-L-3l2e.txt` |
| L-3l2-rtl plug sketch DONE (docs only, no SV) | `/tmp/misterplex-agent-L-3l2-rtl.txt` + section below |
| L-csum-note HW evidence (pre–R-csum1) | `/tmp/misterplex-agent-L-csum-note.txt` |
| **L-csum-note2** dabdaeb0 silicon FAIL | `/tmp/misterplex-agent-L-csum-note2.txt` (this tick) |
| **H-deploy-rcsum1** probes / hard gate | `/tmp/misterplex-agent-H-deploy-rcsum1.txt`, `/tmp/misterplex-H-deploy-rcsum1-probes.txt` |
| L-3l2-gate / gate2 unblock checklist | `/tmp/misterplex-agent-L-3l2-gate.txt`, `/tmp/misterplex-agent-L-3l2-gate2.txt` |
| H-rcsum-proto sole-deploy protocol | `/tmp/misterplex-agent-H-rcsum-proto.txt` |
| R-csum-rca3 go/no-go + contingency | `/tmp/misterplex-agent-R-csum-rca3.txt` |
| SoT coeffs/csum/deq/Y | `host/libmisterplex/h264_residual_gold.hpp` |
| Unit lock | `tests/unit/test_idct_quant.cpp` (`FPGA_GOLD recon_*`) |
| Tree residual inputs (keep) | `residual_coeff[0:15]` signed 9b ST_PLACE → `stream_path` |

**Host paint goldens (mae=0 target after C9):**

| Field | Value |
|-------|-------|
| `residual_coeff` scan | `-24 4 4 0 -4 0 -1 0 0 -1 1 0 1 0 0 0` |
| res_csum | **20 / 0x14** (XOR sat8) |
| pred / qp | **128** / **25** |
| y00 / mean4×4 | **73** / **62** |
| paint y00 RGB565 | **0x4a49** |
| stub contrast | y=104 RGB565 **0x6B4D** (128+dc — not true recon) |

SoT: `host/libmisterplex/h264_residual_gold.hpp` + `tests/unit/test_idct_quant.cpp`.

#### HW gates after paint RBF (only after §A green + §C complete)

| Step | Gate | Pass when |
|------|------|-----------|
| Residual | `test_f3_residual.sh` | hard `res_dc=-24` + hard `res_csum=20` (no soft-skip) |
| IDCT/paint | `test_f3_idct_mb0.sh` | residual hard; soft→hard y00=73 / mean=62; eyes-on ≠104 |
| FBAR | `test_fbar_fast` | still green |

#### Non-goals while gate open (and paint non-goals)

- Full MB0 / all MBs (3.3l-3/4) · MAXB/FIFO/dual-YUV BRAM · hybrid present  
- Half-wiring inv_quant/idct into `files.qip` **before** §A HARD_PASS  
- Any paint Quartus while R-csum1 (or residual fit) is LIVE  
- Checking in orphan paint SV before C1 authorized  
- Treating `test_f3_residual.sh` soft-skip EXIT=0 as unblock (**soft-skip ≠ PASS**)  
- Thrash-redeploying lab **`dabdaeb0`** (or prior **`820484a6`**) expecting csum green  
- Starting §C SV wire-up while post-R-csum1-deploy residual still FAIL (contingency §D **ACTIVE**)  
- Touching `Plex.sv` residual status pack from paint work  

---

### 3.3l-2 concrete RTL plug sketch (L-3l2-rtl — docs only; no fit)

**Gate still open (do not start paint Quartus / SV wire-up):** lab RBF **`dabdaeb0`**
(R-csum1 BUILD_OK + H-deploy-rcsum1) has `res_dc=-24` PASS + FBAR PASS but
**`res_csum=20` HARD FAIL** (raw[13] live / unstable 139/222/49, never XOR `0x14`;
prior `820484a6` 232/59/142; earlier `aa146c17` raw[13]=`0x53` stream-bytes residue).
Host unit locked XOR sat8 full-16 = **0x14**. Sources **`7bee0a6`** already shipped
running XOR + ST_PLACE `lev[]` + preserve status — hard gate still FAIL (H-rcsum-gate).
Until hard residual is green on a post-RCA sole deploy (`raw[13]==0x14` **AND**
`res_dc=-24`; soft-skip ≠ PASS; do not invent PASS), paint RTL stays sketch-only.
Unblock: *P3-3l2 UNBLOCK GATE* §A–§C.

Reports: `/tmp/misterplex-agent-L-3l2-rtl.txt`, `/tmp/misterplex-agent-L-3l2-gate2.txt`,
`/tmp/misterplex-agent-H-deploy-rcsum1.txt`, `/tmp/misterplex-agent-L-csum-note2.txt`.
Host SoT unchanged (L-3l2e). Soft-skip still **not** hard PASS; 3.3l-2 **remains BLOCKED**.

#### Where modules plug (tree as of L-3l2-rtl)

```text
slice_hdr_parser.sv  ST_PLACE
    residual_ok, residual_dc, residual_csum
    residual_coeff[0:15] signed [8:0]   (*keep*)
         │
         ▼
stream_path.sv
    passes residual_* straight out
    decode_stub today: residual_ok/tc/dc only  ← NO coeff yet
         │
         ├─ (today)  decode_stub MB0 gray = clamp(128+dc) = 104
         │
         └─ (3.3l-2 target)
              residual_coeff[0:15] + slice_qp ──► inv_quant4
                                                    │ deq[4][4]
                                                    ▼
                                                 idct4x4_add (pred=128)
                                                    │ recon_y[4][4]
                                                    ▼
                                                 decode_stub top-left 4×4 paint
                                                    RGB565 gray pack
```

| Port / reg | Source today | Consumer 3.3l-2 |
|------------|--------------|-----------------|
| `residual_coeff[0:15]` signed 9b | `slice_hdr_parser` ST_PLACE → `stream_path` out | **`inv_quant4` input** (scan order) |
| `slice_qp` [5:0] | `slice_hdr_parser` (Baseline first MB: **25**) | **`inv_quant4` qp** |
| `residual_ok` | ST_PLACE sticky | start recon FSM; keep for paint gate |
| `residual_dc` / `residual_csum` | ST_PLACE | **status only** — do not recompute in paint path |
| `recon_y[0:3][0:3]` 8b | new regs after IDCT | `decode_stub` top-left 4×4 |
| `recon_ready` | new sticky | gate paint vs incomplete IDCT |
| `fs_wr_*` | `decode_stub` → `frame_store` | unchanged bus; pixel source changes for x&lt;4,y&lt;4 |

#### Module interfaces (sketch — not in `files.qip`)

**`inv_quant4`** — match `recon::detail_r::dequant4x4` (`h264_recon.hpp`):

```text
inputs:  clk, reset, start, qp[5:0], coeff[0:15] signed [8:0]  (or [15:0])
outputs: busy, done, blk[0:3][0:3] signed [15:0]   // residual domain, row-major
tables:  kZigzag = {0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15}
         kNormAdjust[6][3] = {{10,13,16},{11,14,18},{13,16,20},{14,18,23},{16,20,25},{18,23,29}}
math:    shift = qp/6 + 2
         mi = (i&1)+(j&1) → 0 even/even, 1 one-odd, 2 both-odd
         qmul = (kNormAdjust[qp%6][mi] * 16) << shift
         blk[i][j] = (level * qmul + 32) >> 6
         maxCoeff=16 for first luma residual (use zigzag[k], not k+1)
cycle:   1 start → clear blk; then 0..15 sequential (skip zero levels) or combo if ALM OK
gold:    residual_gold::kDeq  (qp=25, kCoeffScan)  deq00=-4224
```

**`idct4x4_add`** — match `ff_h264_idct_add` / host `idct4x4_add`:

```text
inputs:  clk, reset, start, blk[0:3][0:3] signed [15:0], pred_fill=8'd128 (or pred[16])
outputs: busy, done, recon_y[0:3][0:3] [7:0]
steps:   1) b = blk; b[0][0] += 32
         2) 4 horizontal butterflies (rows)
         3) 4 vertical butterflies (cols); clip8(pred + (z>>6))
multi-cycle FSM (~8–16 cycles); pure add/shift — **no new M10K, 0 DSP required**
gold:    residual_gold::kY  y00=73 mean=(sum+8)/16=62
```

**Optional thin `mb_recon4` wrapper** (or inline in `stream_path`):

```text
on residual_ok rise + coeffs stable:
  inv_quant4.start → wait done
  idct4x4_add.start (pred=128) → wait done → recon_ready=1
  recon_y00 = recon_y[0][0]; recon_mean = (sum+8)/16
```

#### `stream_path` / `decode_stub` wire-up plan (when unblocked)

1. **Instantiate** `inv_quant4` + `idct4x4_add` in `stream_path.sv` (next to `decode_stub`), **not** inside `slice_hdr_parser` (keep CAVLC place pure).  
2. Feed `residual_coeff` + `slice_qp` (`sl_qp`) into inv_quant; trigger on `sl_res_ok` rising edge after ST_PLACE.  
3. Extend `decode_stub` ports:

```text
// add (when wiring):
input wire        recon_ready,
input wire [7:0]  recon_y00,          // optional status mirror
input wire [7:0]  recon_y [0:15],     // row-major 4×4  OR  recon_y[0:3][0:3]
// paint:
//   if (x < 4 && y < 4 && lat_res_ok && lat_recon_ready)
//     gray = recon_y[y*4+x];          // true 4×4 — y00=73
//   else if (mb0 && lat_res_ok)
//     gray = clamp(128+lat_res_dc);   // rest of MB0 stub 104 OK
// RGB565: {R[7:3],G[7:2],B[7:3]} R=G=B
// frame_store @W=320: addrs 0..3, 320..323, 640..643, 960..963
```

4. **Do not** touch `residual_dc` / `residual_csum` packing in `Plex.sv` from paint work — leave R-csum1 (csum fix) sole owner of residual status until green.  
5. Soft telem (optional later): spare status bytes for `recon_y00`/`recon_mean`; hard residual fields stay.  
6. `files.qip`: add `rtl/inv_quant4.sv` + `rtl/idct4x4_add.sv` **only** when sole paint fit starts **after** hard csum PASS.

#### Implementation order (after hard res_csum=20)

| Step | Action | Verify |
|------|--------|--------|
| 0 | **R-csum1** sole-deploy → hard residual (§A: raw[13]=0x14 + res_dc=-24, no soft-skip) | *Post–R-csum1 sole-deploy* + *P3-3l2 UNBLOCK GATE* |
| 1 | Add `inv_quant4.sv` + unit-sim or table ROM vs `kDeq` (optional host C++ already locks) | deq match |
| 2 | Add `idct4x4_add.sv`; pred=128 → `kY` | y00=73 mean=62 |
| 3 | Wire in `stream_path`; extend `decode_stub` paint | no residual bus thrash |
| 4 | Sole Quartus (`NUM_PARALLEL=2`); one deploy | FBAR green |
| 5 | `test_f3_idct_mb0.sh` residual hard + recon soft→hard | y00≠104 eyes-on |

#### Resource / fit notes (unchanged budget)

- Logic-only: 16×9 coeff already present; +16×16 deq regs; +16×8 recon_y; small FSM.  
- **No new M10K.** Optional 1 DSP for quant mul or pure shift-add.  
- Current fit headroom: ALM ~78% free; M10K tight at 74% — do not grow FIFO/MAXB.  
- Prefer **not** checking in orphan SV until step 1 of paint fit (avoids accidental `files.qip` thrash).

#### Hard gate reminder (L-3l2-gate / L-3l2-gate2)

```text
BLOCKED:  P3-3l2 paint / SV / files.qip  (REMAINS BLOCKED after dabdaeb0)
HARD:     raw[13]==0x14 (res_csum=20) AND res_dc=-24 (raw[12]==0xE8)
          both STABLE ≥2 re-pushes; FBAR green; soft-skip NOT enough
WHEN:     after next residual-fix sole deploy (new md5 ≠ dabdaeb0)
LAB NOW:  RBF dabdaeb0 (R-csum1 XOR+lev APPLIED) — res_dc=-24 OK; FBAR PASS;
          raw[13] live but ≠0x14 UNSTABLE 139/222/49 HARD FAIL
SOFT:     test_f3_residual EXIT=0 soft-skip still NOT hard PASS
HOST:     XOR sat8 full-16 = 0x14 locked unit; y00=73/mean=62/paint 0x4a49
DONE:     R-csum1 BUILD_OK + H-deploy-rcsum1 sole deploy + FBAR PASS
FAIL:     B3 hard csum — contingency §D ACTIVE → no 3l2
PROBES:   /tmp/misterplex-agent-H-deploy-rcsum1.txt
          /tmp/misterplex-H-deploy-rcsum1-probes.txt
NEXT:     residual RCA (status/preserve/multi-drive) → new RBF → sole redeploy
NO FIT:   inv_quant/IDCT / 3l2 paint until §A HARD_PASS; no thrash dabdaeb0
```

### 3.3l-3 — First full MB (I_NxN or I16)

Golden clip is **I_NxN** (`mb0=0`):

1. Parse 16× I4 pred mode (already skipped in ST_I4MODE — **retain modes**)  
2. CBP + mb_qp_delta (done)  
3. For each coded 4×4 in scan order: CAVLC(nC), dequant, predI4, idct-add  
4. Within-MB nC from left/above TC (regs)  
5. Chroma: pred + DC/AC residual (host order)  
6. Pack MB → RGB565; stub paints **MB0 only** correctly; rest of frame diagnostic grid OK  

**Capture limit:** first full MB residual body may exceed 48 B.

| Option | Pros | Cons |
|--------|------|------|
| A. Raise MAXB 48→128/256 (regs) | Minimal rewire | ALM/reg; still not full slice |
| B. Stream bit-walker past cap | Scales to all-MB | More work; preferred long-term |

**Plan:** 3.3l-3 may use **MAXB=128** (regs, ~1 Kib — still not M10K) as bridge; 3.3l-4 switches to streaming.

**Exit:** host vs FPGA mae on MB0 Y (16×16) = 0; chroma optional same fire or +1.

### 3.3l-4 — All MBs (I-slice)

1. **Streaming residual path:** after headers, consume bits from live FIFO (or long window), not fixed 48 B only.  
2. Neighbour **top row** M10K (+ chroma).  
3. Left column + TC from previous MB (regs).  
4. Loop mbx,mby to `sps_mb_w × sps_mb_h` (20×15 @ 320×240).  
5. Per MB: write 16×16 Y (+ chroma) → convert RGB565 → `frame_store` sequential or addressed paint.  
6. `decode_stub` becomes thin: kick recon engine, wait done, swap.  
7. Status: `mb_done`, `recon_ok`, fail_mb (if any).  

**Out of scope this phase:** P-slice / motion / CABAC / deblock (optional later; host already skips LF for gold).

**Exit:** full frame maeY≈0 vs host/FFmpeg no-LF on golden 320×240 IDR; `host_owns_fs` still preferred for product until soak.

### 3.3l-5 — Hybrid gate (product)

Only when 3.3l-4 mae competitive on lab titles:

- Allow STREAM path to skip host F1 recon when FPGA `recon_ok`  
- Keep host fallback on CABAC / fail  
- Measure: ALM/M10K fit, decode latency vs present 30 fps budget  

---

## RTL notes (match host / FFmpeg)

### Inv quant (`dequant4x4`)

```text
qmul = (mf[qp%6][pos] * 16) << (qp/6 + 2)
blk[i][j] = (level * qmul + 32) >> 6
zigzag: {0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15}
maxCoeff=15 → skip scan DC slot (I16 AC / chroma AC)
```

### IDCT (`idct4x4_add`)

- `block[0][0] += 32` before butterflies  
- Horizontal then vertical; `(x)>>6` add into pred; clip 0..255  
- Multi-cycle OK; no need one-cycle combo path  

### Intra I4

- MPM / rem already in bitstream (parser must **store** modes in 3.3l-3)  
- Unavailable neighbour → mode forced DC(2) where host does  
- Top-right sample rules: `lumaReady` / replicate above[3] (3.3h lessons)  

### I16 DC

- Hadamard input layout: CAVLC zigzag then **FFmpeg TRANSPOSE** before butterfly  
- Host: `invQuantHadamardDc4x4` — copy exactly or mae will fail  

### First MB availability

| Sample | First MB (0,0) |
|--------|----------------|
| Above / left / TL | unavailable → 128 for DC |
| Top-right outside pic | replicate |

---

## Status / telemetry sketch

Keep existing residual fields. Add without breaking `push_frame --status` parsers more than needed:

| Bits / field | Meaning |
|--------------|---------|
| existing res_* / res_dc | regression 3.3k |
| **`[111:104] residual_csum8`** | **3.3l-1** XOR sat8(coeff[0:15]); host `res_csum=` (gold **20**/0x14) |
| `[127:112] stream_bytes[15:0]` | after 3.3l-1 (was 24b in [127:104]) |
| `recon_y00` or mean4×4 | 3.3l-2 eyes-on — host gold **y00=73 mean=62** (`residual_gold`) |
| `mb_done[7:0]` | 3.3l-4 progress |
| `recon_ok` sticky | full I-slice done |

Host already parses `residual_csum` from raw[13] (soft until RBF). Document assign in `Plex.sv` when RTL lands.

---

## Tests

| Milestone | Unit | HW |
|-----------|------|-----|
| 3.3l-0 | `test_idct_quant` / extend `test_cavlc_dc` | — |
| 3.3l-1 | host `h264_residual_gold` coeff[16]+csum=0x14 | `test_f3_residual.sh` res_dc; soft res_csum=20 after RBF |
| 3.3l-2 | `test_idct_quant` paint/deq goldens + `FPGA_GOLD recon_*` | `tests/hw/test_f3_idct_mb0.sh` residual hard; soft→hard y00=73 mean=62 |
| 3.3l-3 | MB0 Y mae=0 | HW status + optional frame dump |
| 3.3l-4 | full recon maeY=U=V=0 | `test_f3_recon_frame.sh` vs host RGB/YUV |
| Hybrid | — | STREAM smoke; host_owns_fs policy |

Do **not** require Quartus for 3.3l-0. Fit check only when RTL lands (sole build, `NUM_PARALLEL=2`).

---

## Milestone checklist (summary)

1. **3.3l-0** ✅ Host quant/IDCT golden + first-4×4 pixel vector (`test_idct_quant`)  
2. **3.3l-1** Host gold+status ✅ (XOR sat8 full-16 **0x14**/20); **R-csum1 APPLIED** (XOR+lev, `7bee0a6`, RBF **`dabdaeb0`**); sole deploy + FBAR ✅; `res_dc=-24` OK; **hard csum still FAIL** (raw[13] unstable **139/222/49**; soft-skip ≠ PASS) — H-deploy-rcsum1 probes / L-csum-note2  
3. **3.3l-2** Host paint goldens + post-3l1 handoff ✅ (y00=73 mean=62 pred=128; HW script ready); **RTL plug sketch ✅** (L-3l2-rtl docs; no SV/`files.qip`); **UNBLOCK GATE defined** (L-3l2-gate + **L-3l2-gate2**: `raw[13]==0x14` **AND** `res_dc=-24`; soft-skip ≠ PASS); paint/SV/`files.qip` **remains BLOCKED** after dabdaeb0 FAIL (contingency §D **ACTIVE** → **no 3l2** until next residual fix hard PASS)  


4. **3.3l-3** First full MB (I_NxN modes+CBP+16× residual+chroma); MAXB bridge or stream start  
5. **3.3l-4** All MBs + top-row BRAM + stream CAVLC; full-frame mae  
6. **3.3l-5** Product hybrid gate when mae competitive  

---

## Non-goals (3.3l)

- Deblocking filter  
- P/B slices, motion compensation  
- CABAC  
- Resolutions above current 320×240 bring-up (scale after mae@320)  
- Replacing host F1 before 3.3l-5  
- Growing bitstream FIFO or dual YUV M10K framebuffers  

## References in tree

- Residual FSM: `fpga/Plex_MiSTer/rtl/slice_hdr_parser.sv`  
- Paint: `fpga/Plex_MiSTer/rtl/decode_stub.sv`  
- Wire-up: `fpga/Plex_MiSTer/rtl/stream_path.sv`  
- Host gold: `host/libmisterplex/h264_recon.hpp`, `h264_cavlc.hpp`, `h264_residual_gold.hpp`  
- Unit paint/IDCT: `tests/unit/test_idct_quant.cpp` (`FPGA_GOLD recon_*`)  
- HW residual: `tests/hw/test_f3_residual.sh`  
- HW paint gate: `tests/hw/test_f3_idct_mb0.sh` (host contract y00=73 mean=62; soft until paint RBF)  
- Post-3l1 handoff: section above in this doc  
- Parent log: `docs/phase3-decode.md` (Phase 3.3k → 3.3l pointer)
