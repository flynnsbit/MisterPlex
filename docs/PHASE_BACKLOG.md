# MiSTerPlex phase backlog (living)

Update this file when work finishes. Loop agents claim items and mark `DONE` / `IN_PROGRESS` / `BLOCKED`.

Evidence sources (2026-07-24 ~11:55 CDT): `/tmp/misterplex-*-agent*.txt`, Q-3l1 log `/tmp/plex_quartus_3l1.log`, **Q-fix1 log `/tmp/plex_quartus_fix1.log`** (LIVE), Q-3l1 report `/tmp/misterplex-agent-Q-3l1.txt`, M-fitmon `/tmp/misterplex-agent-M-fitmon.txt` + M-fitmon2 (+ M-fitmon3 if present), residual3 `/tmp/misterplex-agent-I-residual3.txt`, unit5 `/tmp/misterplex-agent-C-unit5.txt`, soak-D2 `/tmp/misterplex-agent-D-soak2.txt`, **soak-D3 `/tmp/misterplex-agent-D-soak3.txt`**, B-ddr4 `/tmp/misterplex-agent-B-ddr4.txt`, L-3l2e `/tmp/misterplex-agent-L-3l2e.txt`, W-rca chain `/tmp/misterplex-agent-W-rca.txt`…`W-rca6.txt`, **W-wide3 `/tmp/misterplex-agent-W-wide3.txt` + W-wide3b**, F-package2 `/tmp/misterplex-agent-F-package2.txt`, **H-deploy-3l1** `/tmp/misterplex-agent-H-deploy-3l1.txt`, **H-gate-3l1** `/tmp/misterplex-agent-H-gate-3l1.txt`, **G-commit8** `/tmp/misterplex-agent-G-commit8.txt`, loop `/tmp/misterplex-loop-status.txt`, clean FBAR log `/tmp/plex_quartus_fbar_clean.log`, git **HEAD `d63522c`** (+ FPGA dirty for Q-fix1), lab host `192.168.1.183`.

## Gate: all green before “complete”
- [x] `make unit` green — EXIT=0 (**C-unit5**): all unit + companion + browse; 3.3l-0/1/2 goldens locked (`test_idct_quant`: res_dc=-24 res_csum=0x14 y00=73 mean=62); residual_csum XOR `0x14` / res_csum=20; report `/tmp/misterplex-agent-C-unit5.txt` (prior C-unit4 `/tmp/misterplex-agent-C-unit4.txt`)
- [~] HW residual hard gate on lab `aa146c17` — **H-deploy-3l1**: soft script EXIT=0; **res_dc=-24 PASS**; **res_csum=20 FAIL** (raw[13]=0x53 want 0x14; telem still stream_bytes packing 0x1A53=6739). Prior soft-only **I-residual3 PASS** on `6db3a4d8`. **Q-fix1** sole rebuild in flight (dirty csum pack + Fix-1 colorbars) — **not BUILD_OK yet**. Reports `/tmp/misterplex-agent-H-deploy-3l1.txt`, `/tmp/misterplex-agent-I-residual3.txt`
- [x] FBAR visual PASS — **DONE on aa146c17** (**H-deploy-3l1** + **H-gate-3l1**): `test_fbar_fast` EXIT=0: grid_off=7.0 force=82.9 bars=94.4 (Δforce_bars=11.5 Δforce_grid=75.9). Prior also PASS on `6db3a4d8`. Reports `/tmp/misterplex-agent-H-deploy-3l1.txt`, `/tmp/misterplex-agent-H-gate-3l1.txt`, `/tmp/misterplex-agent-H-deploy-fbar.txt`
- [ ] Full-width VGA verified (HBlank@320) — **eyes-on FAIL open** on lab **`aa146c17`** (**W-wide3** / W-wide3b): HDMI span **~60.5%** = content320/DE529 pillar; R5%=0. Prior same FAIL on `6db3a4d8` (W-wide + W-wide2). RTL state B (HBlank@320, HSync 544..590) **ineffective on silicon**. Dirty Fix-1 state C (HSync 336..384) is in **Q-fix1** rebuild (not deployed). Protocol after Q-fix1 BUILD_OK: one deploy → FBAR → hard csum → WIDE re-eyes. [docs/p3-wide-rca.md](p3-wide-rca.md). Eyes `/tmp/misterplex-agent-W-wide3.txt`, `/tmp/misterplex-agent-W-wide3b.txt`, prior `/tmp/misterplex-agent-W-wide.txt`, `/tmp/misterplex-agent-W-wide2.txt`; handoff `/tmp/misterplex-agent-W-rca6.txt`

- [x] DDR F1 ≥30 fps path stable in misterplexd (kick verify, not only ddr_busy) — product path prefers DDR; verify=busy OR (status[12]+has_frame); ARM deployed md5 `0b3643ff`. **B-ddr4 PASS** on lab **`aa146c17`**: push_frame --ddr ×5 → **mean≈16.9 ms** (min 16.4 max 17.7) has_frame=1 ddr_busy=0 (≥30 fps class). Prior B-ddr2/3 on `6db3a4d8` ~16.0–16.8 ms. Report `/tmp/misterplex-agent-B-ddr4.txt` (prior B-ddr2/3)
- [x] `make package` produces tarball with RBF + set_status — **F-package2 PASS**: `dist/misterplex-56e4e30-dirty.tar.gz` (12033663 B) embeds RBF **`aa146c17`** + set_status + misterplexd + push_frame. Report `/tmp/misterplex-agent-F-package2.txt`
- [x] misterplexd soak PASS (wifi) without SPI death — **D-soak3 PASS** on lab **`aa146c17`**: SOAK_HOLD_S=6 ROUNDS=2 → **ok=6 fail=0** (wifi, no load_core). Prior agent-D + soak-D2 PASS on `6db3a4d8`. Reports `/tmp/misterplex-agent-D-soak3.txt`, `/tmp/misterplex-agent-D-soak2.txt`, `/tmp/misterplex-agent-D-soak.txt`
- [x] Safe deploy only (`DEPLOY_LOAD=none|menu` via `scripts/deploy_plex_core.sh`) — `530dcdc` + HW tests stop thrash `3f367e5`

## Phase 3 (decode / present)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P3-FBAR | Force bars O[9] visual = bars when pattern=grid | **DONE** | **H-deploy-3l1 + H-gate-3l1** 2026-07-24 on lab RBF **`aa146c17`**: one `DEPLOY_LOAD=menu` (H-deploy only); `test_fbar_fast` EXIT=0: grid_off=7.0 force=82.9 bars=94.4 (Δforce_bars=11.5 Δforce_grid=75.9). Parked bars force=1 NTSC 60. Prior also PASS on clean RBF `6db3a4d8`. Reports `/tmp/misterplex-agent-H-deploy-3l1.txt`, `/tmp/misterplex-agent-H-gate-3l1.txt`, prior `/tmp/misterplex-agent-H-deploy-fbar.txt` |
| P3-WIDE | Full-width DE HBlank@320 | **PARTIAL / FAIL open** | **Eyes-on FAIL on lab `aa146c17`** (**W-wide3** / W-wide3b, ~11:54): span **~60.5%** = **content320/DE529**; R5%=0.0; frac≪0.95; verdict PILLAR_320_of_529. Same geometry as prior FAIL on `6db3a4d8` (W-wide/W-wide2). State B (HBlank@320, HSync 544..590 in aa146c17 map) **ineffective**. **RCA W-rca→W-rca6** still valid fingerprint. Dirty **Fix-1 state C** (colorbars HSync 336.. / H_BLANK_S=320) in tree + **Q-fix1 LIVE** (not BUILD_OK; not deployed). After BUILD_OK: sole deploy → FBAR → hard res_csum → WIDE re-eyes; if still FAIL → Fix-2 paint-full-DE@529. **Handoff** `/tmp/misterplex-agent-W-rca6.txt` + [docs/p3-wide-rca.md](p3-wide-rca.md). Eyes `/tmp/misterplex-agent-W-wide3.txt`, `/tmp/misterplex-agent-W-wide3b.txt`. **Not DONE.** |
| P3-DDR | DDR F1 kick reliable in product path | **DONE** | Product prefers DDR (`useDdrF1_`); verify=busy OR (status[12]+has_frame) in `sendRgb565FrameDdr`. Safe deploy md5 `0b3643ff` misterplexd + `e273b18d` push_frame. **B-ddr4 PASS** on lab **`aa146c17`** (no thrash): --ddr ×5 **mean 16.9 ms** → has_frame=1 ddr_busy=0; ≥30 fps gate MET. Prior B-ddr2/3 on `6db3a4d8`. SPI fallback on verify fail. Report `/tmp/misterplex-agent-B-ddr4.txt` |
| P3-3l0 | Host quant/IDCT golden | DONE | `2e2c2dc` — `test_idct_quant` synth+real first 4×4 locked |
| P3-3l1 | FPGA full 16 coeffs | **PARTIAL — hard-gate FAIL; fix rebuild LIVE** | **Host DONE** (agent-L/C): `h264_residual_gold.hpp` + `test_idct_quant` full-16 + `res_csum=0x14` XOR; unit EXIT=0 (**C-unit5**). **RTL intent** (B-rtl + dirty tree): ST_PLACE `residual_coeff[0:15]`, `Plex.sv` [111:104]=`residual_csum` (dirty fixes stream_bytes overlay). **Q-3l1 BUILD_OK** → lab RBF **`aa146c17`**. **Lab loaded** (H-deploy-3l1); **FBAR PASS**. **Hard residual on aa146c17:** res_dc=-24 PASS; **res_csum=20 FAIL** raw[13]=0x53. **Q-fix1 LIVE** sole clean rebuild (csum pack + Fix-1 colorbars) start 11:54:41 — **Quartus BUSY (fitter)**; **do not invent BUILD_OK**. Do not thrash / no second Quartus. Reports `/tmp/misterplex-agent-H-deploy-3l1.txt`, `/tmp/misterplex-agent-Q-3l1.txt`, log `/tmp/plex_quartus_fix1.log`. |
| P3-3l2 | Inv quant + IDCT first 4×4 | **PARTIAL** | **Host DONE / PASS + post-3l1 handoff DONE** (L-3l2..**L-3l2e finalize**): `residual_gold` kDeq+kY + paint RGB565; `test_idct_quant` table+real (y00=**73** mean=**62** pred=**128** ≠ stub 104); `FPGA_GOLD dequant_rowmajor`/`recon_y_*`; res_csum **XOR 0x14/20**. **Post-3l1 handoff finalized** in `docs/phase3-3l-idct.md` + HW draft `tests/hw/test_f3_idct_mb0.sh`. Unit locked under C-unit5. **RTL open** only after hard `res_csum=20` (await Q-fix1 + deploy). Keep res_dc=-24. Report `/tmp/misterplex-agent-L-3l2e.txt`. |
| P3-3l3 | First full MB recon | TODO | I_NxN modes+CBP+residual+chroma |
| P3-3l4 | All MBs / frame mae | TODO | Full I-slice mae vs host |
| P3-3l5 | Hybrid gate product | TODO | When 3.3l-4 mae competitive |
| P3-SPI | SPI F1 only ~9fps — keep as fallback | DONE | Measured ~112 ms / ~9 fps; product SPI fallback intact |

## Phase 4 (UX)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P4-SCRUB | Scrubber/playqueue edge cases | **DONE** | Baseline seek/step/skip menu+browse `fe40a64`. Edges (agent-N + E-P4…E-P4g): clamp 0..duration; wantPlay gate; stop clears URL; late bindMedia ignore; playGen supersede; scrub-during-resolve; plant sticky; same-pos seek ACK; skipPrevious Plex-style; stop `++playGen`; `lastPlay` final gate; playMedia resets stale `durationMs_`; seek/step while paused; play→instant-stop race unit. **G-commit8 landed** (non-FPGA): `5bd2e31` feat, `86947f6` tests, `d63522c` docs — **HEAD `d63522c`**. FPGA dirty intentionally left uncommitted for Q-fix1 fit. `make unit` EXIT=0 (**C-unit5**). Reports `/tmp/misterplex-agent-G-commit8.txt`, `/tmp/misterplex-agent-E-p4g.txt`, `/tmp/misterplex-agent-N-p4.txt` |
| P4-HZ | Match-source-Hz modeline (docs only OK) | DEFER | docs only |
| P4-SUB | Subtitles burn-in plan | DEFER | docs only |

## Phase 5 (release / lab)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P5-PKG | Package release tarball | **DONE (F-package2)** | **F-package2 PASS**: `dist/misterplex-56e4e30-dirty.tar.gz` (12033663 B; sha256 `be8e418cf7b12cf13b2ddd39c13c9a79c8a3746a4981b1328bcaead22ae23728`) embeds RBF **`aa146c17031536620039e04dceb23b68`** + set_status + misterplexd + push_frame. Stage `dist/stage-misterplex/cores/Plex.rbf` = **`aa146c17`**. FBAR PASS on packaged RBF (H-deploy-3l1). Report `/tmp/misterplex-agent-F-package2.txt`. Hard residual res_csum still FAIL on aa146c17 (out of package scope). Re-package after Q-fix1 BUILD_OK + promote. |
| P5-SOAK | WiFi soak multi-round | **DONE** | **D-soak3 PASS** on lab **`aa146c17`** (2026-07-24 ~11:53): `SOAK_HOLD_S=6 SOAK_ROUNDS=2 SOAK_NET_LABEL=wifi` → **ok=6 fail=0** elapsed=46s EXIT=0; CORENAME stayed Plex; PRESENT=both; plexd PID left up; bars parked force=1 NTSC 60. Prior: soak-D2 + agent-D on `6db3a4d8`. Optional re-soak after Q-fix1 deploy. Reports `/tmp/misterplex-agent-D-soak3.txt`, `/tmp/misterplex-agent-D-soak2.txt`, `/tmp/misterplex-agent-D-soak.txt` |
| P5-ETH | Eth vs wifi numbers | BLOCKED | no eth lab path |
| P5-CRT | CRT matrix checklist | **PARTIAL** | Practical checklist + dual **LAB vs physical CRT** tick matrix: [docs/crt-lcd-lab-checklist.md](crt-lcd-lab-checklist.md) (+ [crt-lcd-matrix.md](crt-lcd-matrix.md) pointer, [captures/menu/CRT_LCD_LAB.md](../captures/menu/CRT_LCD_LAB.md)). LAB (HDMI): modes/FBAR/NTSC·PAL/FPS/soak PASS from captures + agent-H/D; CRT2 rechecked `test_cadence` OK. Physical CRT 15 kHz rows **PENDING** (no CRT attached). **No false CRT PASS.** No Quartus/`load_core`. Reports `/tmp/misterplex-agent-CRT.txt`, `/tmp/misterplex-agent-CRT2.txt` |

## RBF inventory (agent-J-backlog10: no Quartus started)
| Path | md5 (prefix) | Notes |
|------|--------------|-------|
| `fpga/Plex_MiSTer/releases/Plex.rbf` | **`aa146c17`** | Q-3l1 BUILD_OK promote; full `aa146c17031536620039e04dceb23b68`; size 3487192 B |
| `fpga/Plex_MiSTer/output_files/Plex.rbf` | **`aa146c17`** | Same artifact (Assembler output); **Q-fix1 will overwrite when BUILD_OK** |
| `misterfpga-dev/out/Plex_MiSTer/Plex.rbf` | **`aa146c17`** | Prior Docker collect SUCCESS match |
| Lab `/media/fat/_Utility/Plex.rbf` | **`aa146c17`** | **LOADED** — md5 `aa146c17031536620039e04dceb23b68` (H-deploy-3l1); FBAR PASS; res_csum hard FAIL; WIDE FAIL ~60.5% |
| `dist/stage-misterplex/cores/Plex.rbf` | **`aa146c17`** | F-package2 staged |
| `releases/Plex.rbf` (repo root) | **`aa146c17`** | Synced to match promote (F-package2) |
| `dist/misterplex-56e4e30-dirty.tar.gz` | embeds **`aa146c17`** | F-package2 PASS (12033663 B) |
| `dist/misterplex-08fb844-dirty.tar.gz` | embeds **`6db3a4d8`** | Prior agent-F package (superseded for new core) |

### Quartus status (2026-07-24 ~11:55 CDT)
| Build | Log | Result |
|-------|-----|--------|
| Clean FBAR | `/tmp/plex_quartus_fbar_clean.log` | **BUILD_OK** (~447s); RBF `6db3a4d8` — FBAR PASS on lab (prior) |
| **Q-3l1** (P3-3l1 residual full-16 + csum intent) | `/tmp/plex_quartus_3l1.log` | **BUILD_OK** 11:45:24 exit 0; RBF **`aa146c17`** (lab loaded; hard csum FAIL — status still stream_bytes low) |
| Q-3l1b concurrent | (not started) | Correctly **ABORT** busy (`/tmp/misterplex-agent-Q-3l1b.txt`) |
| **Q-fix1** (csum pack fix + Fix-1 colorbars HSync@336) | `/tmp/plex_quartus_fix1.log` | **LIVE / BUSY** sole clean rebuild start **11:54:41**; Analysis & Synthesis done; **Fitter running** (docker `quartus_sh` + `quartus_fit`). Dirty fingerprint: Plex.sv + slice_hdr_parser + stream_path + colorbars (H_BLANK_S=320, H_SYNC_S=336). **Do NOT invent BUILD_OK.** **Do NOT start another Quartus.** |

- Action this agent (J-backlog10): **refresh backlog only** (no Quartus; no deploy; no package)
- Post-Q-fix1 sequence (Open #1):
  1. Wait **Q-fix1 BUILD_OK** + collect new RBF md5 → releases/ + output_files + misterfpga out
  2. **One** sole deploy (`DEPLOY_LOAD=menu`) — do not thrash
  3. **FBAR** re-confirm (`test_fbar_fast`)
  4. **Hard res_csum=20** gate (raw[13]=0x14; keep res_dc=-24)
  5. **WIDE re-eyes** (Fix-1 state C) — span≥95% / R5%>15; if FAIL → Fix-2 paint-full-DE
  6. Optional: re-package + re-soak after gates green
- Do **not** start another Quartus while Q-fix1 LIVE; do not invent BUILD_OK

## Open (priority next workers)
1. **Q-fix1 wait → one deploy → FBAR → hard csum → WIDE eyes** — **OPEN #1**. Quartus **BUSY** sole rebuild (csum pack + Fix-1 colorbars). Lab remains **`aa146c17`** until BUILD_OK + sole menu deploy. **Zero new Quartus.** Evidence: `/tmp/plex_quartus_fix1.log`, `/tmp/misterplex-loop-status.txt`
2. **res_csum hard gate** — still **FAIL** on lab **`aa146c17`** (raw[13]=0x53 not 0x14). Fix is in dirty tree under Q-fix1; re-test only after deploy of new RBF. Evidence `/tmp/misterplex-agent-H-deploy-3l1.txt`
3. **P3-WIDE** — **FAIL open** on **`aa146c17`** (**W-wide3** ~60.5% pillar). Fix-1 in Q-fix1; re-eyes after deploy. RCA `/tmp/misterplex-agent-W-rca6.txt`, eyes `/tmp/misterplex-agent-W-wide3.txt`
4. **P3-3l1 HW residual hard** — **PARTIAL**: deploy+FBAR+res_dc green on aa146c17; hard res_csum **FAIL** until Q-fix1 artifact
5. **P3-3l2..3l5** — inv quant/IDCT → MB → frame mae → hybrid gate (**host 3l2 goldens+handoff PASS** L-3l2e; RTL after hard res_csum=20)
6. **P5-CRT** — **PARTIAL** practical checklist + LAB/CRT tick matrix; physical CRT eyes-on still open
7. ~~**P3-3l1 Quartus Q-3l1**~~ — **BUILD_OK** RBF `aa146c17` (Q-3l1 + M-fitmon); superseded intent by Q-fix1
8. ~~**RBF collect + lab load aa146c17**~~ — **DONE** H-deploy-3l1
9. ~~**F-package2 / P5-PKG**~~ — **DONE** `dist/misterplex-56e4e30-dirty.tar.gz` embeds `aa146c17`
10. ~~**host P3-3l2 handoff**~~ — **DONE** L-3l2e
11. ~~**P3-FBAR (on aa146c17)**~~ — **DONE** H-deploy-3l1 + H-gate-3l1
12. ~~**P5-SOAK**~~ — **DONE** D-soak3 ok=6 on `aa146c17` (+ prior D-soak2)
13. ~~**P4-SCRUB + G-commit8**~~ — **DONE** HEAD `d63522c` (FPGA dirty left for fit)
14. ~~**P3-DDR remeasure**~~ — **DONE** B-ddr4 ~16.9 ms PASS on `aa146c17`
15. ~~**make unit**~~ — **DONE** C-unit5 EXIT=0
16. ~~**W-wide3 eyes on aa146c17**~~ — **DONE (result FAIL)** — still open as P3-WIDE gate until Fix-1 RBF
17. ~~**HW residual soft / res_dc**~~ — **DONE** res_dc=-24 PASS; hard csum still OPEN

## Non-RBF always available
- (done W-wide-rca / W-rca2..**W-rca6**) P3-WIDE read-only RCA + after-BUILD_OK protocol — `/tmp/misterplex-agent-W-rca6.txt`, docs/p3-wide-rca.md
- (done **W-wide3** / W-wide3b) Eyes-on aa146c17 state B — **FAIL ~60.5%**; next eyes after Q-fix1 deploy
- (done agent-B / B-ddr2 / B-ddr3 / **B-ddr4**) DDR kick-verify — **B-ddr4** mean 16.9 ms has_frame=1 on aa146c17
- (done agent-L / C-unit / **C-unit5**) P3-3l1 host full-16 gold + res_csum=0x14 (XOR) + unit green
- (done agent-L-3l2 / **L-3l2e**) P3-3l2 host inv_quant+IDCT goldens **PASS** + post-3l1 docs handoff
- (done B-rtl-3l1 + **Q-3l1 BUILD_OK**) → RBF **`aa146c17`**; hard csum FAIL → dirty fix under Q-fix1
- (done M-fitmon / M-fitmon2) Q-3l1 sole fit monitor → BUILD_OK; **M-fitmon3** monitors Q-fix1 (no second Quartus)
- (done **H-deploy-3l1** + **H-gate-3l1**) Sole menu deploy aa146c17 + FBAR PASS + residual hard assessment
- (done agent-N + E-P4…E-P4g + **G-commit8**) P4-SCRUB committed HEAD `d63522c`; FPGA dirty left for fit
- (done agent-F + **F-package2**) Package with `aa146c17` — **DONE**
- (done agent-D / D-soak2 / **D-soak3**) Soak — **D-soak3 PASS** ok=6 fail=0 on aa146c17
- (done agent-I residual2 / **I-residual3**) HW residual res_dc=-24 green soft
- Unit tests, docs, set_status / push_frame ARM only
- Safe deploy polish (`DEPLOY_LOAD=none|menu`)
- P5-CRT fill-in when hardware available
- **Q-fix1 BUSY** — monitor only; **no second Quartus**; **no invented BUILD_OK**
- After BUILD_OK only: sole H deploy → FBAR → hard csum → WIDE eyes (serial lab)
