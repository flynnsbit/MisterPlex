# MiSTerPlex phase backlog (living)

Update this file when work finishes. Loop agents claim items and mark `DONE` / `IN_PROGRESS` / `BLOCKED`.

Evidence sources (2026-07-24 ~11:48 CDT): `/tmp/misterplex-*-agent*.txt`, Q-3l1 log `/tmp/plex_quartus_3l1.log`, Q-3l1 report `/tmp/misterplex-agent-Q-3l1.txt`, M-fitmon `/tmp/misterplex-agent-M-fitmon.txt`, residual3 `/tmp/misterplex-agent-I-residual3.txt`, unit4 `/tmp/misterplex-agent-C-unit4.txt`, soak-D2 `/tmp/misterplex-agent-D-soak2.txt`, L-3l2e `/tmp/misterplex-agent-L-3l2e.txt`, W-rca chain `/tmp/misterplex-agent-W-rca.txt`…`W-rca6.txt`, clean FBAR log `/tmp/plex_quartus_fbar_clean.log`, git `56e4e30` (+dirty possible), lab host `192.168.1.183`.

## Gate: all green before “complete”
- [x] `make unit` green — EXIT=0 (**C-unit4** reconfirm): all unit + companion + browse; 3.3l-0/1/2 goldens locked (`test_idct_quant`: res_dc=-24 res_csum=0x14 y00=73 mean=62); residual_csum XOR `0x14` / res_csum=20; report `/tmp/misterplex-agent-C-unit4.txt` (prior C-unit3 `/tmp/misterplex-agent-C-unit3.txt`; C-unit5 run in flight)
- [x] HW residual `res_dc=-24` (no load_core thrash) — **I-residual3 PASS** on lab `6db3a4d8` (pre-3l1): `test_f3_residual` EXIT=0; golden `res_ok=1 res_tc=8 res_t1=3 res_dc=-24`; soft `res_csum` skip. **Hard `res_csum=20` retest pending** on new RBF `aa146c17` (H-deploy-3l1). Report `/tmp/misterplex-agent-I-residual3.txt`
- [~] FBAR visual PASS — **PASS on prior** clean RBF `6db3a4d8` (agent-H `test_fbar_fast` EXIT=0). **Retest IN_PROGRESS / pending** after deploy of 3l1 RBF **`aa146c17`** (bucket `H-deploy-3l1`; no `/tmp/misterplex-agent-H-deploy-3l1.txt` yet at J-backlog6 poll). Prior report `/tmp/misterplex-agent-H-deploy-fbar.txt`
- [ ] Full-width VGA verified (HBlank@320) — **eyes-on FAIL open** on last-confirmed lab `6db3a4d8` (W-wide + W-wide2): HDMI span ~60.5% = content320/DE529 pillar; RTL `edcf536` claims HBlank@320. **RCA FINALIZED (W-rca→W-rca6):** bar edges = hc×800/529 (end x≈484); black in-DE; bitstream behaved H@529 on old RBF. **3l1 RBF `aa146c17` = state B only** (HBlank@320, HSync 544..590); dirty state C (HSync 336..384) **not** in 3l1 map; local collect complete. Deploy aa146c17 is **H-owned** (in flight/pending) — **WIDE retest deferred to W-wide3 after H FBAR green** (no thrash). Protocol: FBAR → residual hard → WIDE re-eyes; if still FAIL → Fix-1 state C or Fix-2 paint-full-DE@529. [docs/p3-wide-rca.md](p3-wide-rca.md). Eyes `/tmp/misterplex-agent-W-wide.txt`, `/tmp/misterplex-agent-W-wide2.txt`; handoff `/tmp/misterplex-agent-W-rca6.txt`

- [x] DDR F1 ≥30 fps path stable in misterplexd (kick verify, not only ddr_busy) — product path prefers DDR; verify=busy OR (status[12]+has_frame); ARM deployed md5 `0b3643ff`. **B-ddr2/B-ddr3 remeasure PASS** on lab `6db3a4d8`: push_frame --ddr ×5 → **~16.0–16.8 ms** (mean≈16.3) has_frame=1 ddr_busy=0 (≥30 fps class). Reports `/tmp/misterplex-agent-B-ddr2.txt`, `/tmp/misterplex-agent-B-ddr3.txt`
- [~] `make package` produces tarball with RBF + set_status — **DONE for prior** agent-F: `dist/misterplex-08fb844-dirty.tar.gz` embeds RBF **`6db3a4d8`**. **Re-package PENDING** for new core **`aa146c17`** (bucket `F-package2`; stage still `6db3a4d8`). Prior report `/tmp/misterplex-agent-F-package.txt`
- [x] misterplexd soak PASS (wifi) without SPI death — prior 6/6 + 8/8; **post-RBF `6db3a4d8` re-confirm PASS** agent-D + **soak-D2 PASS** agent-D-soak2: SOAK_HOLD_S=6 ROUNDS=2 → ok=6 fail=0 (wifi, no load_core). Reports `/tmp/misterplex-agent-D-soak.txt`, `/tmp/misterplex-agent-D-soak2.txt`
- [x] Safe deploy only (`DEPLOY_LOAD=none|menu` via `scripts/deploy_plex_core.sh`) — `530dcdc` + HW tests stop thrash `3f367e5`

## Phase 3 (decode / present)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P3-FBAR | Force bars O[9] visual = bars when pattern=grid | **DONE (prior) / retest pending** | agent-H 2026-07-24: one `DEPLOY_LOAD=menu` of RBF **`6db3a4d8`**; `test_fbar_fast` EXIT=0: grid_off=7.0 force=82.9 bars=94.4 (Δforce_bars=11.5 Δforce_grid=75.9). Parked bars force=1 NTSC 60. **New 3l1 RBF `aa146c17` needs one FBAR retest after H deploy** (do not mark red until retest fails). Report `/tmp/misterplex-agent-H-deploy-fbar.txt` |
| P3-WIDE | Full-width DE HBlank@320 | **PARTIAL / FAIL open** | **Eyes-on FAIL on last-confirmed `6db3a4d8`** (W-wide + W-wide2). Span **~60.5%** = **content320/DE529**; AR=full no help; 5 bars + in-DE black; R5%=0. **RCA FINALIZED W-rca→W-rca6 (read-only fpga):** fingerprint hc×800/529 end x≈484; H1 = bitstream still HBlank@529-class on old RBF; H2 long-porch secondary; H3 AR ruled out. **Q-3l1 BUILD_OK** produced **`aa146c17`** = colorbars **state B** (`edcf536`: HBlank@320, HSync 544..590); dirty uncommitted state C (HSync 336..384) **not** in map. Local collect complete. Deploy **H-owned** — **WIDE retest = W-wide3 after H FBAR** (W-rca6: no thrash / post-deploy retest required). Protocol: FBAR → residual hard res_dc=-24/res_csum=20 → WIDE re-eyes span≥95% → park. If still pillar → Fix-1 commit dirty C + sole clean rebuild; if unlock → Fix-2 paint-full-DE @ HBlank529. **Handoff** `/tmp/misterplex-agent-W-rca6.txt` + [docs/p3-wide-rca.md](p3-wide-rca.md). Eyes `/tmp/misterplex-agent-W-wide.txt`, `/tmp/misterplex-agent-W-wide2.txt`. **Not DONE.** |
| P3-DDR | DDR F1 kick reliable in product path | **DONE** | Product prefers DDR (`useDdrF1_`); verify=busy OR (status[12]+has_frame) in `sendRgb565FrameDdr`. Safe deploy md5 `0b3643ff` misterplexd + `e273b18d` push_frame. **B-ddr2/B-ddr3 remeasure PASS** on lab `6db3a4d8` (no thrash): --ddr ×5 **~16 ms** → has_frame=1 ddr_busy=0; ≥30 fps gate MET. SPI fallback on verify fail. Reports `/tmp/misterplex-agent-B-ddr.txt`, `/tmp/misterplex-agent-B-ddr2.txt`, `/tmp/misterplex-agent-B-ddr3.txt` |
| P3-3l0 | Host quant/IDCT golden | DONE | `2e2c2dc` — `test_idct_quant` synth+real first 4×4 locked |
| P3-3l1 | FPGA full 16 coeffs | **BUILD_OK — deploy pending** | **Host DONE** (agent-L/C/H-3l1b): `h264_residual_gold.hpp` + `test_idct_quant` full-16 + `res_csum=0x14` XOR; unit EXIT=0 (**C-unit4**). **RTL ready** (B-rtl): ST_PLACE `residual_coeff[0:15]`, `Plex.sv` [103:96]=dc [111:104]=csum. Soft HW `res_csum=20` on old RBF; keep `res_dc=-24` (**I-residual3 PASS**). **Quartus:** first attempt ABORTED mid-fit (11:33:45 CDT); sole rebuild resumed 11:38:57 → **BUILD_OK 11:45:24 CDT** exit 0 wall ~387s resume leg; Full Compilation successful (0 errors, 5 warnings). **New RBF md5 `aa146c17031536620039e04dceb23b68`** (prefix **`aa146c17`**, size 3487192) promoted to `releases/` + `output_files/` + misterfpga-dev out. STA Critical Warning (setup slack −18.418 emu pll) pre-existing class. Quartus processes **idle**. Agent Q-3l1b had correctly ABORTed concurrent fit. **Deploy:** bucket `H-deploy-3l1` **IN_PROGRESS / deploying** — expect one `DEPLOY_LOAD=menu` + FBAR + hard `res_csum=20`; **no H-deploy-3l1 report file yet** at J-backlog6 poll (~11:48). Do **not** start another Quartus. Reports `/tmp/misterplex-agent-Q-3l1.txt`, `/tmp/misterplex-agent-M-fitmon.txt`, `/tmp/misterplex-agent-L-3l1.txt`, `/tmp/misterplex-agent-B-rtl33l1.txt`, `/tmp/misterplex-agent-I-residual3.txt`. |
| P3-3l2 | Inv quant + IDCT first 4×4 | **PARTIAL** | **Host DONE / PASS + post-3l1 handoff DONE** (L-3l2..**L-3l2e finalize**): `residual_gold` kDeq+kY + paint RGB565; `test_idct_quant` table+real (y00=**73** mean=**62** pred=**128** ≠ stub 104); `FPGA_GOLD dequant_rowmajor`/`recon_y_*`; res_csum **XOR 0x14/20** (anti-stale sum -20/0xEC). **Post-3l1 handoff finalized** in `docs/phase3-3l-idct.md` (RTL checklist + paint contract) + HW draft `tests/hw/test_f3_idct_mb0.sh` (soft recon until paint RBF). Unit locked under C-unit4. **RTL open** only after 3l1 RBF deploy green + hard `res_csum=20`. Keep res_dc=-24. Report `/tmp/misterplex-agent-L-3l2e.txt`. |
| P3-3l3 | First full MB recon | TODO | I_NxN modes+CBP+residual+chroma |
| P3-3l4 | All MBs / frame mae | TODO | Full I-slice mae vs host |
| P3-3l5 | Hybrid gate product | TODO | When 3.3l-4 mae competitive |
| P3-SPI | SPI F1 only ~9fps — keep as fallback | DONE | Measured ~112 ms / ~9 fps; product SPI fallback intact |

## Phase 4 (UX)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P4-SCRUB | Scrubber/playqueue edge cases | **DONE** | Baseline seek/step/skip menu+browse `fe40a64`. Edges (agent-N + E-P4…E-P4e): clamp 0..duration; wantPlay gate; stop clears URL; late bindMedia ignore; playGen supersede; scrub-during-resolve; plant sticky; same-pos seek ACK; skipPrevious Plex-style. **E-P4g (2026-07-24)**: stop `++playGen` invalidates in-flight doPlay; `lastPlay` commit only under final wantPlay/playGen gate before demux (no zombie queue after stop); playMedia resets stale `durationMs_` so shorter prior title cannot clamp next cast offset; seek/step while paused + `startTimeOffset=` unit; play→instant-stop race unit (no fullScreenVideo re-arm). `make unit` EXIT=0. Reports `/tmp/misterplex-agent-N-p4.txt`, `/tmp/misterplex-agent-E-p4*.txt`, `/tmp/misterplex-agent-E-p4g.txt` |
| P4-HZ | Match-source-Hz modeline (docs only OK) | DEFER | docs only |
| P4-SUB | Subtitles burn-in plan | DEFER | docs only |

## Phase 5 (release / lab)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P5-PKG | Package release tarball | **PENDING re-package** | Prior **DONE** agent-F: `dist/misterplex-08fb844-dirty.tar.gz` (12007676 B) embeds RBF **`6db3a4d8`**. Stage `dist/stage-misterplex/cores/Plex.rbf` still **`6db3a4d8`**. **New core `aa146c17` built** → bucket **`F-package2`** should `make package` to embed `aa146c17031536620039e04dceb23b68` from `fpga/Plex_MiSTer/releases/Plex.rbf` (now promoted). Prefer after H-deploy FBAR green if shipping lab-proven core. Report prior `/tmp/misterplex-agent-F-package.txt`. |
| P5-SOAK | WiFi soak multi-round | **DONE** | Post clean RBF `6db3a4d8` + FBAR PASS: agent-D + **soak-D2 PASS** (agent-D-soak2 2026-07-24 ~11:40): `SOAK_HOLD_S=6 SOAK_ROUNDS=2 SOAK_NET_LABEL=wifi` → **ok=6 fail=0** elapsed=45s EXIT=0; CORENAME stayed Plex; PRESENT=both; plexd PID left up; bars parked force=1 NTSC 60. Prior: soak-agent 6/6, fixed2 8/8, soak-D 6/6. Optional re-soak after aa146c17 deploy. Reports `/tmp/misterplex-agent-D-soak.txt`, `/tmp/misterplex-agent-D-soak2.txt` |
| P5-ETH | Eth vs wifi numbers | BLOCKED | no eth lab path |
| P5-CRT | CRT matrix checklist | **PARTIAL** | Practical checklist + dual **LAB vs physical CRT** tick matrix: [docs/crt-lcd-lab-checklist.md](crt-lcd-lab-checklist.md) (+ [crt-lcd-matrix.md](crt-lcd-matrix.md) pointer, [captures/menu/CRT_LCD_LAB.md](../captures/menu/CRT_LCD_LAB.md)). LAB (HDMI): modes/FBAR/NTSC·PAL/FPS/soak PASS from captures + agent-H/D; CRT2 rechecked `test_cadence` OK. Physical CRT 15 kHz rows **PENDING** (no CRT attached). **No false CRT PASS.** No Quartus/`load_core`. Reports `/tmp/misterplex-agent-CRT.txt`, `/tmp/misterplex-agent-CRT2.txt` |

## RBF inventory (agent-J-backlog6: no Quartus started)
| Path | md5 (prefix) | Notes |
|------|--------------|-------|
| `fpga/Plex_MiSTer/releases/Plex.rbf` | **`aa146c17`** | Q-3l1 BUILD_OK promote; full `aa146c17031536620039e04dceb23b68`; size 3487192 B; mtime 11:45 |
| `fpga/Plex_MiSTer/output_files/Plex.rbf` | **`aa146c17`** | Same artifact (Assembler output) |
| `misterfpga-dev/out/Plex_MiSTer/Plex.rbf` | **`aa146c17`** | Docker collect SUCCESS match |
| Lab `/media/fat/_Utility/Plex.rbf` | **`6db3a4d8`** (last known) | Still pre-3l1 until H-deploy-3l1 finishes; FBAR was PASS on this; residual3 green |
| `dist/stage-misterplex/cores/Plex.rbf` | **`6db3a4d8`** | Stale vs new core — **package pending** (F-package2) |
| `releases/Plex.rbf` (repo root) | **`6db3a4d8`** | Stale copy; prefer `fpga/.../releases/` for deploy scripts |

### Quartus status (2026-07-24 ~11:48 CDT)
| Build | Log | Result |
|-------|-----|--------|
| Clean FBAR | `/tmp/plex_quartus_fbar_clean.log` | **BUILD_OK** (~447s); RBF `6db3a4d8` — FBAR PASS on lab (prior) |
| **Q-3l1** (P3-3l1 residual full-16 + csum) | `/tmp/plex_quartus_3l1.log` | **First attempt ABORTED mid-fit** 11:33:45 (agent timeout) → **sole rebuild 11:38:57 → BUILD_OK 11:45:24** exit 0; Full Compilation successful; RBF **`aa146c17`** |
| Q-3l1b concurrent | (not started) | Correctly **ABORT** busy (`/tmp/misterplex-agent-Q-3l1b.txt`) |
| Quartus now | — | **IDLE** (no quartus processes) |

- Action this agent (J-backlog6): **refresh backlog only** (no Quartus; no deploy; no package)
- Post-BUILD_OK sequence (in flight / next):
  1. ~~Collect new RBF → releases/~~ — **DONE** (releases + output_files both `aa146c17`)
  2. **H-deploy-3l1 IN_PROGRESS** — one `DEPLOY_LOAD=menu` of `aa146c17` (poll report when present)
  3. FBAR retest (`test_fbar_fast`) — must stay green
  4. Residual hard gate: `res_dc=-24` + `res_csum=20` (0x14)
  5. WIDE re-eyes (W-wide3) per W-rca6 protocol (post-deploy only; no thrash)
  6. **F-package2 PENDING** — re-package with `aa146c17` if shipping new core
- Do **not** start another Quartus unless deliberate sole rebuild (e.g. state C after WIDE still FAIL)

## Open (priority next workers)
1. **H-deploy-3l1** — **deploying / pending report**: one `DEPLOY_LOAD=menu` of RBF **`aa146c17`** + FBAR retest + hard `res_csum=20` / residual HW — **do not thrash**; poll `/tmp/misterplex-agent-H-deploy-3l1.txt` when present
2. **P3-WIDE** — still **FAIL open** on lab (last eyes on `6db3a4d8`); **RCA FINALIZED** through **W-rca6** (`/tmp/misterplex-agent-W-rca6.txt`); after H deploy + FBAR → re-eyes (W-wide3); if fail → Fix-1 state C (dirty HSync@336) or Fix-2 paint-full-DE; FBAR then WIDE; see [docs/p3-wide-rca.md](p3-wide-rca.md); **no thrash**
3. **F-package2 / P5-PKG re-package** — **PENDING** embed `aa146c17` (stage still `6db3a4d8`)
4. **P3-3l2..3l5** — inv quant/IDCT → MB → frame mae → hybrid gate (**host 3l2 goldens+handoff PASS** L-3l2e; RTL after aa146c17 hard res_csum=20)
5. **P5-CRT** — **PARTIAL** practical checklist + LAB/CRT tick matrix; physical CRT eyes-on still open
6. ~~**P3-3l1 Quartus**~~ — **BUILD_OK** RBF `aa146c17` (Q-3l1 + M-fitmon)
7. ~~**host P3-3l2 handoff**~~ — **DONE** L-3l2e
8. ~~**P3-FBAR (on 6db3a4d8)**~~ — **DONE** agent-H (retest after aa146c17 deploy)
9. ~~**P5-SOAK re-confirm**~~ — **DONE** agent-D + soak-D2 on `6db3a4d8`
10. ~~**P4-SCRUB**~~ — **DONE** agent-N + E-P4…E-P4g (stop/playGen + stale-duration + unit)
11. ~~**P3-DDR remeasure**~~ — **DONE** B-ddr2/3 ~16 ms PASS on `6db3a4d8`
12. ~~**make unit**~~ — **DONE** C-unit4 EXIT=0 (C-unit5 may reconfirm)
13. ~~**HW residual reconfirm (soft)**~~ — **DONE** I-residual3 res_dc=-24 on `6db3a4d8`; hard gate after deploy

## Non-RBF always available
- (done W-wide-rca / W-rca2 / W-rca3 / W-rca4 / W-rca5 / **W-rca6**) P3-WIDE RCA FINALIZE + post-deploy retest gate — `/tmp/misterplex-agent-W-rca6.txt`, docs/p3-wide-rca.md; next eyes-on = **W-wide3** after H FBAR on aa146c17
- (done agent-B / B-ddr2 / B-ddr3) Deploy ARM DDR kick-verify product path — remeasure ~16 ms has_frame=1
- (done agent-L / C-unit / C-unit3 / **C-unit4**) P3-3l1 host full-16 gold + res_csum=0x14 (XOR) + FPGA_GOLD dump + unit green
- (done agent-L-3l2 / L-3l2c / L-3l2d / **L-3l2e**) P3-3l2 host inv_quant+IDCT goldens **PASS** (pred=128, y00=73 mean=62, csum XOR 0x14) + **post-3l1 docs handoff finalized** + `test_f3_idct_mb0.sh` — RTL paint next after hard res_csum=20
- (done B-rtl-3l1 + **Q-3l1 BUILD_OK**) P3-3l1 RTL ST_PLACE full-16 + residual_csum XOR + status pack → RBF **`aa146c17`**
- (done M-fitmon) Sole fit monitor → BUILD_OK recorded; no second Quartus
- (done agent-N + E-P4b/c + E-P4 + E-P4e + **E-P4g**) P4-SCRUB scrubber/playqueue edges (stop playGen + lastPlay commit + stale duration)
- (done agent-F) Package with FBAR-green `6db3a4d8` — **re-package pending for aa146c17**
- (done agent-D / D-soak2) Soak re-confirm post-RBF — PASS ok=6 fail=0
- (done agent-I residual2 / **I-residual3**) HW residual res_dc=-24 green on lab without thrash — **PASS** (soft pre-3l1)
- Unit tests, docs
- set_status / push_frame ARM only
- Safe deploy polish (`DEPLOY_LOAD=none|menu`)
- P3-WIDE eyes-on / RCA / capture (no Quartus; no thrash) — **FAIL open**; RCA done (W-rca6); **post-deploy retest required** (W-wide3 on aa146c17)
- P5-CRT fill-in when hardware available
- Post-deploy residual HW soft→hard gate on aa146c17
- **No second Quartus** unless deliberate sole rebuild after WIDE FAIL
