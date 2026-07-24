# MiSTerPlex phase backlog (living)

Update this file when work finishes. Loop agents claim items and mark `DONE` / `IN_PROGRESS` / `BLOCKED`.

Evidence sources (2026-07-24 ~11:52 CDT): `/tmp/misterplex-*-agent*.txt`, Q-3l1 log `/tmp/plex_quartus_3l1.log`, Q-3l1 report `/tmp/misterplex-agent-Q-3l1.txt`, M-fitmon `/tmp/misterplex-agent-M-fitmon.txt` + M-fitmon2, residual3 `/tmp/misterplex-agent-I-residual3.txt`, unit4 `/tmp/misterplex-agent-C-unit4.txt`, unit5 `/tmp/misterplex-agent-C-unit5.txt`, soak-D2 `/tmp/misterplex-agent-D-soak2.txt`, L-3l2e `/tmp/misterplex-agent-L-3l2e.txt`, W-rca chain `/tmp/misterplex-agent-W-rca.txt`…`W-rca6.txt`, F-package2 `/tmp/misterplex-agent-F-package2.txt`, **H-deploy-3l1** `/tmp/misterplex-agent-H-deploy-3l1.txt`, **H-gate-3l1** `/tmp/misterplex-agent-H-gate-3l1.txt`, clean FBAR log `/tmp/plex_quartus_fbar_clean.log`, git `56e4e30` (+dirty possible), lab host `192.168.1.183`.

## Gate: all green before “complete”
- [x] `make unit` green — EXIT=0 (**C-unit4** + **C-unit5** reconfirm): all unit + companion + browse; 3.3l-0/1/2 goldens locked (`test_idct_quant`: res_dc=-24 res_csum=0x14 y00=73 mean=62); residual_csum XOR `0x14` / res_csum=20; reports `/tmp/misterplex-agent-C-unit4.txt`, `/tmp/misterplex-agent-C-unit5.txt` (prior C-unit3 `/tmp/misterplex-agent-C-unit3.txt`)
- [~] HW residual hard gate on lab `aa146c17` — **H-deploy-3l1**: soft script EXIT=0; **res_dc=-24 PASS**; **res_csum=20 FAIL** (raw[13]=0x53 want 0x14; telem still stream_bytes packing 0x1A53=6739). Prior soft-only **I-residual3 PASS** on `6db3a4d8`. Reports `/tmp/misterplex-agent-H-deploy-3l1.txt`, `/tmp/misterplex-agent-I-residual3.txt`
- [x] FBAR visual PASS — **DONE on aa146c17** (**H-deploy-3l1** + **H-gate-3l1**): `test_fbar_fast` EXIT=0: grid_off=7.0 force=82.9 bars=94.4 (Δforce_bars=11.5 Δforce_grid=75.9). Prior also PASS on `6db3a4d8`. Reports `/tmp/misterplex-agent-H-deploy-3l1.txt`, `/tmp/misterplex-agent-H-gate-3l1.txt`, `/tmp/misterplex-agent-H-deploy-fbar.txt`
- [ ] Full-width VGA verified (HBlank@320) — **eyes-on FAIL open** on lab `6db3a4d8` (W-wide + W-wide2): HDMI span ~60.5% = content320/DE529 pillar; RTL `edcf536` claims HBlank@320. **RCA/handoff (W-rca→W-rca6):** bar edges = hc×800/529 (end x≈484); black in-DE; bitstream behaved H@529 on old RBF. **3l1 RBF `aa146c17` = state B only** (HBlank@320, HSync 544..590); dirty state C (HSync 336..384) **not** in 3l1 map. **W-wide3 not started** (no `/tmp/misterplex-agent-W-wide3*.txt`). Protocol: residual hard → WIDE re-eyes; if still FAIL → Fix-1 state C or Fix-2 paint-full-DE@529. [docs/p3-wide-rca.md](p3-wide-rca.md). Eyes `/tmp/misterplex-agent-W-wide.txt`, `/tmp/misterplex-agent-W-wide2.txt`; handoff `/tmp/misterplex-agent-W-rca6.txt`

- [x] DDR F1 ≥30 fps path stable in misterplexd (kick verify, not only ddr_busy) — product path prefers DDR; verify=busy OR (status[12]+has_frame); ARM deployed md5 `0b3643ff`. **B-ddr2/B-ddr3 remeasure PASS** on lab `6db3a4d8`: push_frame --ddr ×5 → **~16.0–16.8 ms** (mean≈16.3) has_frame=1 ddr_busy=0 (≥30 fps class). Reports `/tmp/misterplex-agent-B-ddr2.txt`, `/tmp/misterplex-agent-B-ddr3.txt`
- [x] `make package` produces tarball with RBF + set_status — **F-package2 PASS**: `dist/misterplex-56e4e30-dirty.tar.gz` (12033663 B) embeds RBF **`aa146c17`** + set_status + misterplexd + push_frame. Prior agent-F had `6db3a4d8` in `dist/misterplex-08fb844-dirty.tar.gz`. Report `/tmp/misterplex-agent-F-package2.txt` (prior `/tmp/misterplex-agent-F-package.txt`)
- [x] misterplexd soak PASS (wifi) without SPI death — prior 6/6 + 8/8; **post-RBF `6db3a4d8` re-confirm PASS** agent-D + **soak-D2 PASS** agent-D-soak2: SOAK_HOLD_S=6 ROUNDS=2 → ok=6 fail=0 (wifi, no load_core). Reports `/tmp/misterplex-agent-D-soak.txt`, `/tmp/misterplex-agent-D-soak2.txt`
- [x] Safe deploy only (`DEPLOY_LOAD=none|menu` via `scripts/deploy_plex_core.sh`) — `530dcdc` + HW tests stop thrash `3f367e5`

## Phase 3 (decode / present)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P3-FBAR | Force bars O[9] visual = bars when pattern=grid | **DONE** | **H-deploy-3l1 + H-gate-3l1** 2026-07-24 on lab RBF **`aa146c17`**: one `DEPLOY_LOAD=menu` (H-deploy only); `test_fbar_fast` EXIT=0: grid_off=7.0 force=82.9 bars=94.4 (Δforce_bars=11.5 Δforce_grid=75.9). Parked bars force=1 NTSC 60. Prior also PASS on clean RBF `6db3a4d8`. Reports `/tmp/misterplex-agent-H-deploy-3l1.txt`, `/tmp/misterplex-agent-H-gate-3l1.txt`, prior `/tmp/misterplex-agent-H-deploy-fbar.txt` |
| P3-WIDE | Full-width DE HBlank@320 | **PARTIAL / FAIL open** | **Eyes-on FAIL on lab `6db3a4d8`** (W-wide + W-wide2). Span **~60.5%** = **content320/DE529**; AR=full no help; 5 bars + in-DE black; R5%=0. **RCA W-rca→W-rca6 (read-only fpga):** fingerprint hc×800/529 end x≈484; H1 = bitstream still HBlank@529-class on old RBF; H2 long-porch secondary; H3 AR ruled out. **Q-3l1 BUILD_OK** produced **`aa146c17`** = colorbars **state B** (`edcf536`: HBlank@320, HSync 544..590); dirty uncommitted state C (HSync 336..384) **not** in map. Lab file **is** `aa146c17` (loaded + FBAR green); **W-wide3 not run** (no report). Protocol: residual hard res_csum=20 first → WIDE re-eyes span≥95% → park bars force=1 NTSC 60. If still pillar → Fix-1 commit dirty C + sole rebuild; if unlock → Fix-2 paint-full-DE @ HBlank529. **Handoff** `/tmp/misterplex-agent-W-rca6.txt` + `/tmp/misterplex-agent-W-rca5.txt` + [docs/p3-wide-rca.md](p3-wide-rca.md). Eyes `/tmp/misterplex-agent-W-wide.txt`, `/tmp/misterplex-agent-W-wide2.txt`. **Not DONE.** |
| P3-DDR | DDR F1 kick reliable in product path | **DONE** | Product prefers DDR (`useDdrF1_`); verify=busy OR (status[12]+has_frame) in `sendRgb565FrameDdr`. Safe deploy md5 `0b3643ff` misterplexd + `e273b18d` push_frame. **B-ddr2/B-ddr3 remeasure PASS** on lab `6db3a4d8` (no thrash): --ddr ×5 **~16 ms** → has_frame=1 ddr_busy=0; ≥30 fps gate MET. SPI fallback on verify fail. Reports `/tmp/misterplex-agent-B-ddr.txt`, `/tmp/misterplex-agent-B-ddr2.txt`, `/tmp/misterplex-agent-B-ddr3.txt` |
| P3-3l0 | Host quant/IDCT golden | DONE | `2e2c2dc` — `test_idct_quant` synth+real first 4×4 locked |
| P3-3l1 | FPGA full 16 coeffs | **PARTIAL — hard-gate FAIL** | **Host DONE** (agent-L/C/H-3l1b): `h264_residual_gold.hpp` + `test_idct_quant` full-16 + `res_csum=0x14` XOR; unit EXIT=0 (**C-unit4/5**). **RTL ready** (B-rtl): ST_PLACE `residual_coeff[0:15]`, `Plex.sv` [103:96]=dc [111:104]=csum intent. **Quartus BUILD_OK** → RBF md5 **`aa146c17031536620039e04dceb23b68`** (prefix **`aa146c17`**). **Lab loaded** (H-deploy-3l1 sole menu deploy EXIT=0; CORENAME=Plex). **FBAR PASS** on aa146c17. **Hard residual:** res_ok=1 res_tc=8 res_t1=3 **res_dc=-24 PASS**; **res_csum=20 FAIL** — raw `20 02 d5 65 04 00 00 07 a3 19 14 0f e8 53 1a 00`; raw[12]=0xe8 (−24) PASS; raw[13]=0x53 (83) FAIL want 0x14; raw[13..15] still 24-bit stream_bytes for bytes_in=6739 (0x1A53). Soft script EXIT=0 skips hard csum. **Do not thrash.** Next: RCA status pack [111:104] vs stream_bytes[7:0]; fix + sole rebuild only if RTL gap confirmed. Reports `/tmp/misterplex-agent-H-deploy-3l1.txt`, `/tmp/misterplex-agent-H-gate-3l1.txt`, `/tmp/misterplex-agent-Q-3l1.txt`, `/tmp/misterplex-agent-M-fitmon.txt`, `/tmp/misterplex-agent-L-3l1.txt`, `/tmp/misterplex-agent-B-rtl33l1.txt`, `/tmp/misterplex-agent-I-residual3.txt`. |
| P3-3l2 | Inv quant + IDCT first 4×4 | **PARTIAL** | **Host DONE / PASS + post-3l1 handoff DONE** (L-3l2..**L-3l2e finalize**): `residual_gold` kDeq+kY + paint RGB565; `test_idct_quant` table+real (y00=**73** mean=**62** pred=**128** ≠ stub 104); `FPGA_GOLD dequant_rowmajor`/`recon_y_*`; res_csum **XOR 0x14/20** (anti-stale sum -20/0xEC). **Post-3l1 handoff finalized** in `docs/phase3-3l-idct.md` (RTL checklist + paint contract) + HW draft `tests/hw/test_f3_idct_mb0.sh` (soft recon until paint RBF). Unit locked under C-unit4/5. **RTL open** only after hard `res_csum=20` on aa146c17 (currently FAIL). Keep res_dc=-24. Report `/tmp/misterplex-agent-L-3l2e.txt`. |
| P3-3l3 | First full MB recon | TODO | I_NxN modes+CBP+residual+chroma |
| P3-3l4 | All MBs / frame mae | TODO | Full I-slice mae vs host |
| P3-3l5 | Hybrid gate product | TODO | When 3.3l-4 mae competitive |
| P3-SPI | SPI F1 only ~9fps — keep as fallback | DONE | Measured ~112 ms / ~9 fps; product SPI fallback intact |

## Phase 4 (UX)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P4-SCRUB | Scrubber/playqueue edge cases | **DONE** | Baseline seek/step/skip menu+browse `fe40a64`. Edges (agent-N + E-P4…E-P4e): clamp 0..duration; wantPlay gate; stop clears URL; late bindMedia ignore; playGen supersede; scrub-during-resolve; plant sticky; same-pos seek ACK; skipPrevious Plex-style. **E-P4g (2026-07-24)**: stop `++playGen` invalidates in-flight doPlay; `lastPlay` commit only under final wantPlay/playGen gate before demux (no zombie queue after stop); playMedia resets stale `durationMs_` so shorter prior title cannot clamp next cast offset; seek/step while paused + `startTimeOffset=` unit; play→instant-stop race unit (no fullScreenVideo re-arm). `make unit` EXIT=0 (**C-unit5**). Reports `/tmp/misterplex-agent-N-p4.txt`, `/tmp/misterplex-agent-E-p4*.txt`, `/tmp/misterplex-agent-E-p4g.txt` |
| P4-HZ | Match-source-Hz modeline (docs only OK) | DEFER | docs only |
| P4-SUB | Subtitles burn-in plan | DEFER | docs only |

## Phase 5 (release / lab)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P5-PKG | Package release tarball | **DONE (F-package2)** | **F-package2 PASS**: `dist/misterplex-56e4e30-dirty.tar.gz` (12033663 B; sha256 `be8e418cf7b12cf13b2ddd39c13c9a79c8a3746a4981b1328bcaead22ae23728`) embeds RBF **`aa146c17031536620039e04dceb23b68`** + set_status + misterplexd + push_frame. Stage `dist/stage-misterplex/cores/Plex.rbf` = **`aa146c17`**. FBAR PASS on packaged RBF (H-deploy-3l1). Prior agent-F: `dist/misterplex-08fb844-dirty.tar.gz` had `6db3a4d8` (superseded). Report `/tmp/misterplex-agent-F-package2.txt` (prior `/tmp/misterplex-agent-F-package.txt`). Hard residual res_csum still FAIL on aa146c17 (out of package scope). |
| P5-SOAK | WiFi soak multi-round | **DONE** | Post clean RBF `6db3a4d8` + FBAR PASS: agent-D + **soak-D2 PASS** (agent-D-soak2 2026-07-24 ~11:40): `SOAK_HOLD_S=6 SOAK_ROUNDS=2 SOAK_NET_LABEL=wifi` → **ok=6 fail=0** elapsed=45s EXIT=0; CORENAME stayed Plex; PRESENT=both; plexd PID left up; bars parked force=1 NTSC 60. Prior: soak-agent 6/6, fixed2 8/8, soak-D 6/6. Optional re-soak after res_csum fix rebuild. Reports `/tmp/misterplex-agent-D-soak.txt`, `/tmp/misterplex-agent-D-soak2.txt` |
| P5-ETH | Eth vs wifi numbers | BLOCKED | no eth lab path |
| P5-CRT | CRT matrix checklist | **PARTIAL** | Practical checklist + dual **LAB vs physical CRT** tick matrix: [docs/crt-lcd-lab-checklist.md](crt-lcd-lab-checklist.md) (+ [crt-lcd-matrix.md](crt-lcd-matrix.md) pointer, [captures/menu/CRT_LCD_LAB.md](../captures/menu/CRT_LCD_LAB.md)). LAB (HDMI): modes/FBAR/NTSC·PAL/FPS/soak PASS from captures + agent-H/D; CRT2 rechecked `test_cadence` OK. Physical CRT 15 kHz rows **PENDING** (no CRT attached). **No false CRT PASS.** No Quartus/`load_core`. Reports `/tmp/misterplex-agent-CRT.txt`, `/tmp/misterplex-agent-CRT2.txt` |

## RBF inventory (agent-J-backlog8: no Quartus started)
| Path | md5 (prefix) | Notes |
|------|--------------|-------|
| `fpga/Plex_MiSTer/releases/Plex.rbf` | **`aa146c17`** | Q-3l1 BUILD_OK promote; full `aa146c17031536620039e04dceb23b68`; size 3487192 B; mtime 11:45 |
| `fpga/Plex_MiSTer/output_files/Plex.rbf` | **`aa146c17`** | Same artifact (Assembler output) |
| `misterfpga-dev/out/Plex_MiSTer/Plex.rbf` | **`aa146c17`** | Docker collect SUCCESS match |
| Lab `/media/fat/_Utility/Plex.rbf` | **`aa146c17`** | **LOADED** — md5 `aa146c17031536620039e04dceb23b68` (H-deploy-3l1 sole menu deploy; CORENAME=Plex); FBAR PASS; res_csum hard FAIL |
| `dist/stage-misterplex/cores/Plex.rbf` | **`aa146c17`** | F-package2 staged |
| `releases/Plex.rbf` (repo root) | **`aa146c17`** | Synced to match promote (F-package2) |
| `dist/misterplex-56e4e30-dirty.tar.gz` | embeds **`aa146c17`** | F-package2 PASS (12033663 B) |
| `dist/misterplex-08fb844-dirty.tar.gz` | embeds **`6db3a4d8`** | Prior agent-F package (superseded for new core) |

### Quartus status (2026-07-24 ~11:52 CDT)
| Build | Log | Result |
|-------|-----|--------|
| Clean FBAR | `/tmp/plex_quartus_fbar_clean.log` | **BUILD_OK** (~447s); RBF `6db3a4d8` — FBAR PASS on lab (prior) |
| **Q-3l1** (P3-3l1 residual full-16 + csum) | `/tmp/plex_quartus_3l1.log` | **First attempt ABORTED mid-fit** 11:33:45 (agent timeout) → **sole rebuild 11:38:57 → BUILD_OK 11:45:24** exit 0; Full Compilation successful; RBF **`aa146c17`** |
| Q-3l1b concurrent | (not started) | Correctly **ABORT** busy (`/tmp/misterplex-agent-Q-3l1b.txt`) |
| Quartus now | — | **IDLE** (no quartus processes) |

- Action this agent (J-backlog8): **refresh backlog only** (no Quartus; no deploy; no package)
- Post-BUILD_OK / post-H sequence:
  1. ~~Collect new RBF → releases/ + output_files + misterfpga out~~ — **DONE**
  2. ~~Lab file `/media/fat/_Utility/Plex.rbf` = aa146c17~~ — **DONE** (loaded H-deploy-3l1)
  3. ~~**H-deploy-3l1 / H-gate-3l1**~~ — **DONE**: FBAR PASS; res_dc=-24 PASS; **res_csum=20 FAIL**
  4. **Open #1: res_csum RCA/fix** — raw[13]=0x53 not 0x14; do **not** thrash; sole rebuild only after RTL gap confirmed
  5. Residual hard gate re-run after fix rebuild
  6. WIDE re-eyes (**W-wide3**) per W-rca6 protocol — still open
  7. ~~**F-package2**~~ — **DONE** embeds `aa146c17`
- Do **not** start another Quartus unless deliberate sole rebuild (res_csum RTL fix, or state C after WIDE still FAIL)

## Open (priority next workers)
1. **res_csum RCA/fix** — **OPEN / FAIL** on lab **`aa146c17`**: hard want `res_csum=20` (0x14); got raw[13]=**0x53** (stream_bytes low byte of 6739=0x1A53). RCA status pack `Plex.sv` [111:104] vs still stream_bytes[7:0]. **Do not thrash.** Fix + sole rebuild only if RTL gap confirmed; then one deploy → hard residual again. Evidence `/tmp/misterplex-agent-H-deploy-3l1.txt`
2. **P3-WIDE / W-wide3** — still **FAIL open** (last eyes on `6db3a4d8`); RCA/handoff done through **W-rca6**; after res_csum path settled → re-eyes on aa146c17; if fail → Fix-1 state C (dirty HSync@336) or Fix-2 paint-full-DE; see [docs/p3-wide-rca.md](p3-wide-rca.md)
3. **P3-3l1 HW residual hard** — **PARTIAL**: deploy+FBAR+res_dc green; hard res_csum **FAIL** until RCA/fix
4. **P3-3l2..3l5** — inv quant/IDCT → MB → frame mae → hybrid gate (**host 3l2 goldens+handoff PASS** L-3l2e; RTL after hard res_csum=20)
5. **P5-CRT** — **PARTIAL** practical checklist + LAB/CRT tick matrix; physical CRT eyes-on still open
6. ~~**P3-3l1 Quartus**~~ — **BUILD_OK** RBF `aa146c17` (Q-3l1 + M-fitmon)
7. ~~**RBF collect + lab load**~~ — **DONE** output_files + releases + lab md5 `aa146c17` loaded (H-deploy-3l1)
8. ~~**F-package2 / P5-PKG**~~ — **DONE** `dist/misterplex-56e4e30-dirty.tar.gz` embeds `aa146c17`
9. ~~**host P3-3l2 handoff**~~ — **DONE** L-3l2e
10. ~~**P3-FBAR (on aa146c17)**~~ — **DONE** H-deploy-3l1 + H-gate-3l1 (grid_off=7 force=82.9 bars=94.4)
11. ~~**P5-SOAK re-confirm**~~ — **DONE** agent-D + soak-D2 on `6db3a4d8`
12. ~~**P4-SCRUB**~~ — **DONE** agent-N + E-P4…E-P4g (stop/playGen + stale-duration + unit)
13. ~~**P3-DDR remeasure**~~ — **DONE** B-ddr2/3 ~16 ms PASS on `6db3a4d8`
14. ~~**make unit**~~ — **DONE** C-unit4 + C-unit5 EXIT=0
15. ~~**HW residual soft / res_dc**~~ — **DONE** I-residual3 + H-deploy-3l1 res_dc=-24 PASS; hard csum still OPEN

## Non-RBF always available
- (done W-wide-rca / W-rca2 / W-rca3 / W-rca4 / W-rca5 / **W-rca6**) P3-WIDE read-only RCA + after-BUILD_OK protocol — `/tmp/misterplex-agent-W-rca6.txt`, docs/p3-wide-rca.md; next eyes-on = **W-wide3** after res_csum path
- (done agent-B / B-ddr2 / B-ddr3) Deploy ARM DDR kick-verify product path — remeasure ~16 ms has_frame=1
- (done agent-L / C-unit / C-unit3 / **C-unit4** / **C-unit5**) P3-3l1 host full-16 gold + res_csum=0x14 (XOR) + FPGA_GOLD dump + unit green
- (done agent-L-3l2 / L-3l2c / L-3l2d / **L-3l2e**) P3-3l2 host inv_quant+IDCT goldens **PASS** (pred=128, y00=73 mean=62, csum XOR 0x14) + **post-3l1 docs handoff finalized** + `test_f3_idct_mb0.sh` — RTL paint next after hard res_csum=20
- (done B-rtl-3l1 + **Q-3l1 BUILD_OK**) P3-3l1 RTL ST_PLACE full-16 + residual_csum XOR + status pack intent → RBF **`aa146c17`**
- (done M-fitmon / M-fitmon2) Sole fit monitor → BUILD_OK recorded; no second Quartus
- (done **H-deploy-3l1** + **H-gate-3l1**) Sole menu deploy aa146c17 + FBAR PASS + residual hard assessment (res_dc PASS, res_csum FAIL raw[13]=0x53)
- (done agent-N + E-P4b/c + E-P4 + E-P4e + **E-P4g**) P4-SCRUB scrubber/playqueue edges (stop playGen + lastPlay commit + stale duration)
- (done agent-F + **F-package2**) Package with `aa146c17` — **DONE** `dist/misterplex-56e4e30-dirty.tar.gz`
- (done agent-D / D-soak2) Soak re-confirm post-RBF — PASS ok=6 fail=0
- (done agent-I residual2 / **I-residual3**) HW residual res_dc=-24 green on lab without thrash — **PASS** (soft pre-3l1)
- Unit tests, docs
- set_status / push_frame ARM only
- Safe deploy polish (`DEPLOY_LOAD=none|menu`)
- P3-WIDE eyes-on / RCA / capture (no Quartus) — **FAIL open** until W-wide3 on aa146c17
- P5-CRT fill-in when hardware available
- **res_csum RCA** (status pack vs stream_bytes) — **OPEN #1**; no thrash / no second deploy
- **No second Quartus** unless deliberate sole rebuild after res_csum RTL fix or WIDE FAIL
