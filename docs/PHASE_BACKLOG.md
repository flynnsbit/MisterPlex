# MiSTerPlex phase backlog (living)

Update this file when work finishes. Loop agents claim items and mark `DONE` / `IN_PROGRESS` / `BLOCKED`.

Evidence sources (2026-07-24 ~12:12 CDT): `/tmp/misterplex-*-agent*.txt`, Q-3l1 log `/tmp/plex_quartus_3l1.log`, **Q-fix1 log `/tmp/plex_quartus_fix1.log`** (**BUILD_OK** confirmed — BUILD END **12:02:28** exit=0; Full Compilation successful 0 errors; wall **~467s**), **R-csum1 log `/tmp/plex_quartus_rcsum1.log` LIVE RESTART** (prior attempt START **12:05:27** timeout-killed mid phys-synth; **RESTARTED BUILD START 12:10:59** — “bg resume after timeout kill of prior attempt”; **do not invent BUILD_OK** — `quartus_fit` LIVE again; host RBF still `820484a6`), Q-3l1 report `/tmp/misterplex-agent-Q-3l1.txt`, M-fitmon chain + **M-fitmon-rc1** `/tmp/misterplex-agent-M-fitmon-rc1.txt` + **M-fitmon-rc3** `/tmp/misterplex-agent-M-fitmon-rc3.txt` (STATUS=LIVE; restart noted), residual3 `/tmp/misterplex-agent-I-residual3.txt`, **C-unit11** + **C-unit12 unit GREEN** `/tmp/misterplex-agent-C-unit11.txt` + `/tmp/misterplex-agent-C-unit12.txt` (EXIT=0; HEAD **`ade6915`**; goldens PASS), prior C-unit9 RED superseded, **G-commit9/10/11/12** chain + **G-p4-dirty** `/tmp/misterplex-agent-G-p4-dirty.txt` (companion polish **COMMITTED** HEAD `ade6915`), soak-D2 `/tmp/misterplex-agent-D-soak2.txt`, **soak-D3 `/tmp/misterplex-agent-D-soak3.txt`**, **D-soak4 PASS** `/tmp/misterplex-agent-D-soak4.txt` (ok=6 on **820484a6**), **D-park PASS** `/tmp/misterplex-agent-D-park.txt`, **B-ddr5 PASS** `/tmp/misterplex-agent-B-ddr5.txt` (mean≈18.0 ms on **820484a6**), prior B-ddr4 on aa146c17, L-3l2e `/tmp/misterplex-agent-L-3l2e.txt`, **L-3l2-rtl `/tmp/misterplex-agent-L-3l2-rtl.txt`**, **L-csum-note** `/tmp/misterplex-agent-L-csum-note.txt` (docs: hard csum FAIL + 3l2 paint blocked), W-rca chain `/tmp/misterplex-agent-W-rca.txt`…`W-rca6.txt`, **W-wide3** + **W-wide4 FAIL ~60.5%** + **W-wide5 FAIL ~60.5%** `/tmp/misterplex-agent-W-wide5.txt` + **W-wide6 FAIL ~60.5%** `/tmp/misterplex-agent-W-wide6.txt` on **820484a6** Fix-1 dead, **W-proto7 protocol READY** `/tmp/misterplex-agent-W-proto7.txt`, **F-package3 PASS** `/tmp/misterplex-agent-F-package3.txt` (embeds **`820484a6`**), prior F-package2, F-prep3 `/tmp/misterplex-agent-F-prep3.txt`, **H-deploy-fix1** `/tmp/misterplex-agent-H-deploy-fix1.txt`, **H-gate-fix1** `/tmp/misterplex-agent-H-gate-fix1.txt` (**FBAR PASS**; res_dc=-24 PASS; **res_csum HARD FAIL** 232/59/142), prior H-deploy-3l1 / H-gate-3l1, **G-commit8**…**G-commit12**, **A-arm-csum tools READY** `/tmp/misterplex-agent-A-arm-csum.txt` + A-arm-csum2, J-backlog10–16, **J-backlog17** `/tmp/misterplex-agent-J-backlog17.txt`, **J-backlog18** (this refresh), loop `/tmp/misterplex-loop-status.txt`, clean FBAR log `/tmp/plex_quartus_fbar_clean.log`, **R-csum-rca2** `/tmp/misterplex-agent-R-csum-rca2.txt`, git **HEAD `ade6915`** (fix p4-scrub atomic plant hold + keep scrub across bindMedia; parent `f635858` plant-hold); **dirty tree**: `M fpga/Plex_MiSTer/Plex.sv` + `M fpga/Plex_MiSTer/rtl/slice_hdr_parser.sv` (csum work feeding R-csum1) + docs/tests/captures; **companion.cpp clean** (G-p4-dirty committed); FPGA lab **`820484a6`** (H-deploy-fix1); host RBF still **`820484a6`** until R-csum1 BUILD_OK collect; **R-csum1 sole rebuild LIVE (restarted)** — **do not invent BUILD_OK**, lab host `192.168.1.183`.

## Gate: all green before “complete”
- [x] `make unit` — **GREEN** (**C-unit12** 2026-07-24): EXIT=0; HEAD **`ade6915`** (G-p4-dirty companion polish atop plant-hold); goldens PASS (res_dc=-24 res_csum=0x14 y00=73 mean=62); companion OK. Prior **C-unit11** EXIT=0 on `f635858`; old C-unit9 RED superseded. Reports `/tmp/misterplex-agent-C-unit12.txt`, `/tmp/misterplex-agent-C-unit11.txt`, `/tmp/misterplex-agent-G-p4-dirty.txt`
- [~] HW residual hard gate — **FAIL on lab `820484a6`** (**H-deploy-fix1** + **H-gate-fix1**). **res_dc=-24 PASS** (stable). **res_csum HARD FAIL**: live raw[13] unstable wrong values (**H-deploy: 239/66/149**; **H-gate: 232/59/142**) — **NOT** stream_bytes alias, **NOT** 0x14/20. Soft-skip EXIT=0 is **not** hard PASS. Prior fail on `aa146c17` was pack-alias class; on fix1 RBF field is live but wrong XOR. **R-csum1 sole rebuild LIVE RESTART** (running XOR + lev[] csum fix; prior fit timeout-killed; new START **12:10:59**) — **do not invent BUILD_OK**; re-test only after R-csum1 BUILD_OK → sole redeploy. **A-arm-csum READY**. **L-csum-note** docs: 3l2 paint fit blocked until hard csum green. Reports `/tmp/misterplex-agent-H-deploy-fix1.txt`, `/tmp/misterplex-agent-H-gate-fix1.txt`, `/tmp/misterplex-agent-A-arm-csum.txt`, `/tmp/misterplex-agent-L-csum-note.txt`, `/tmp/misterplex-agent-R-csum-rca2.txt`, log `/tmp/plex_quartus_rcsum1.log`
- [x] FBAR visual PASS — **DONE on lab `820484a6` only** (**H-deploy-fix1** + **H-gate-fix1**): `test_fbar_fast` EXIT=0: grid_off=7.0 force=82.9 bars=94.4 (Δforce_bars=11.5 Δforce_grid=75.9). Prior also PASS on `aa146c17` / `6db3a4d8`. **Re-confirm after next RBF (R-csum1) deploy** — green is for 820484a6 only. Reports `/tmp/misterplex-agent-H-deploy-fix1.txt`, `/tmp/misterplex-agent-H-gate-fix1.txt`
- [ ] Full-width VGA verified (HBlank@320) — **eyes-on FAIL open** on lab **`820484a6`** (**W-wide4** + **W-wide5** + **W-wide6**): HDMI span **~60.5%** = content320/DE529 pillar; R5%=0. Prior same FAIL on `aa146c17` (W-wide3) and `6db3a4d8`. Fix-1 state C (HSync 336..384) **ineffective on silicon** — closed as experiment (**Fix-1 dead**). **No more HSync-only eyes thrash.** Next: **Fix-2 paint-full-DE@529** only **after R-csum1 BUILD_OK** (no second Quartus while busy). [docs/p3-wide-rca.md](p3-wide-rca.md). Eyes `/tmp/misterplex-agent-W-wide4.txt`, `/tmp/misterplex-agent-W-wide5.txt`, `/tmp/misterplex-agent-W-wide6.txt`; protocol `/tmp/misterplex-agent-W-proto7.txt`

- [x] DDR F1 ≥30 fps path stable in misterplexd (kick verify, not only ddr_busy) — product path prefers DDR; verify=busy OR (status[12]+has_frame); ARM deployed md5 `0b3643ff`. **B-ddr5 PASS** on lab **`820484a6`**: push_frame --ddr ×5 → **mean≈18.0 ms** (min 15.6 max 22.1) has_frame=1 ddr_busy=0 (≥30 fps class). Prior B-ddr4 on `aa146c17` mean≈16.9 ms. Report `/tmp/misterplex-agent-B-ddr5.txt` (prior B-ddr4)
- [x] `make package` produces tarball with RBF + set_status — **F-package3 PASS**: `dist/misterplex-0aa744f-dirty.tar.gz` (12038474 B) embeds RBF **`820484a6`** + set_status + misterplexd + push_frame. Prior F-package2 had `aa146c17`. Report `/tmp/misterplex-agent-F-package3.txt`
- [x] misterplexd soak PASS (wifi) without SPI death — **D-soak3 PASS** on lab **`aa146c17`**: SOAK_HOLD_S=6 ROUNDS=2 → **ok=6 fail=0** (wifi, no load_core). **D-soak4 PASS** on lab **`820484a6`**: same recipe → **ok=6 fail=0** (wifi; CORENAME=Plex; bars parked). Reports `/tmp/misterplex-agent-D-soak3.txt`, `/tmp/misterplex-agent-D-soak4.txt`, `/tmp/misterplex-agent-D-soak2.txt`
- [x] Safe deploy only (`DEPLOY_LOAD=none|menu` via `scripts/deploy_plex_core.sh`) — `530dcdc` + HW tests stop thrash `3f367e5`

## Phase 3 (decode / present)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P3-FBAR | Force bars O[9] visual = bars when pattern=grid | **DONE** (on 820484a6) | **H-deploy-fix1 + H-gate-fix1** 2026-07-24 on lab RBF **`820484a6`**: one `DEPLOY_LOAD=menu` (H-deploy only); `test_fbar_fast` EXIT=0: grid_off=7.0 force=82.9 bars=94.4 (Δforce_bars=11.5 Δforce_grid=75.9). Prior PASS on `aa146c17` / `6db3a4d8`. **Green for 820484a6 only** — **re-confirm after R-csum1 redeploy**. Reports `/tmp/misterplex-agent-H-deploy-fix1.txt`, `/tmp/misterplex-agent-H-gate-fix1.txt` |
| P3-WIDE | Full-width DE HBlank@320 | **PARTIAL / FAIL open** | **Eyes-on FAIL on lab `820484a6`** (**W-wide4** + **W-wide5** + **W-wide6**): span **~60.5%** = **content320/DE529**; R5%=0.0; frac≪0.95; verdict PILLAR_320_of_529. Same geometry as prior FAIL on `aa146c17` (W-wide3) and `6db3a4d8`. Fix-1 state C (HSync 336..384 + H_BLANK_S=320) **ineffective on silicon** — experiment **closed / Fix-1 dead**. Next sole rebuild path: **Fix-2 paint-full-DE@529** (keep timing; stretch bars hc 0..528) — **only after R-csum1 BUILD_OK** (no concurrent Quartus). **Handoff** `/tmp/misterplex-agent-W-rca6.txt` + [docs/p3-wide-rca.md](p3-wide-rca.md). Eyes `/tmp/misterplex-agent-W-wide4.txt`, `/tmp/misterplex-agent-W-wide5.txt`, `/tmp/misterplex-agent-W-wide6.txt`; protocol `/tmp/misterplex-agent-W-proto7.txt`. **Not DONE.** |
| P3-DDR | DDR F1 kick reliable in product path | **DONE** | Product prefers DDR (`useDdrF1_`); verify=busy OR (status[12]+has_frame) in `sendRgb565FrameDdr`. Safe deploy md5 `0b3643ff` misterplexd + `e273b18d` push_frame. **B-ddr5 PASS** on lab **`820484a6`** (no thrash): --ddr ×5 **mean 18.0 ms** → has_frame=1 ddr_busy=0; ≥30 fps gate MET. Prior B-ddr4 on `aa146c17` ~16.9 ms. SPI fallback on verify fail. Report `/tmp/misterplex-agent-B-ddr5.txt` |
| P3-3l0 | Host quant/IDCT golden | DONE | `2e2c2dc` — `test_idct_quant` synth+real first 4×4 locked |
| P3-3l1 | FPGA full 16 coeffs | **PARTIAL — hard-gate FAIL on lab 820484a6; R-csum1 rebuild LIVE RESTART** | **Host DONE**: `h264_residual_gold.hpp` + `test_idct_quant` full-16 + `res_csum=0x14` XOR (goldens lock; **C-unit11/12 unit GREEN**). **Lab LOADED `820484a6`** (H-deploy-fix1 sole menu). **FBAR PASS** on 820484a6. **Hard residual:** res_dc=-24 PASS; **res_csum HARD FAIL** — live raw[13] wrong/unstable (**H-deploy 239/66/149**; **H-gate 232/59/142**) — field lives, not stream_bytes alias, never 0x14. **Q-fix1 BUILD_OK** produced **`820484a6`** (csum pack path + Fix-1 colorbars) — pack fix insufficient; values live but wrong XOR. **R-csum1 sole rebuild LIVE RESTART**: prior START **12:05:27** timeout-killed mid phys-synth; **RESTARTED BUILD START 12:10:59** (running XOR + lev[] csum + preserve status regs; log `/tmp/plex_quartus_rcsum1.log`; `quartus_fit` LIVE; **M-fitmon-rc1/rc3** STATUS=LIVE) — **do not invent BUILD_OK**. Dirty tree has `Plex.sv` + `slice_hdr_parser.sv` csum work feeding this rebuild. **A-arm-csum tools READY**. **L-csum-note** + **R-csum-rca2**: 3l2 paint blocked until hard csum=20. Next Open #1: finish R-csum1 → sole deploy → hard csum retest. Reports `/tmp/misterplex-agent-H-deploy-fix1.txt`, `/tmp/misterplex-agent-H-gate-fix1.txt`, `/tmp/misterplex-agent-Q-fix1.txt`, `/tmp/misterplex-agent-A-arm-csum.txt`, `/tmp/misterplex-agent-L-csum-note.txt`, `/tmp/misterplex-agent-R-csum-rca2.txt`, `/tmp/misterplex-agent-M-fitmon-rc1.txt`, `/tmp/misterplex-agent-M-fitmon-rc3.txt`, log `/tmp/plex_quartus_rcsum1.log`. |
| P3-3l2 | Inv quant + IDCT first 4×4 | **PARTIAL** | **Host DONE / PASS + post-3l1 handoff DONE** (L-3l2..**L-3l2e**): `residual_gold` kDeq+kY + paint RGB565; `test_idct_quant` table+real (y00=**73** mean=**62** pred=**128** ≠ stub 104); `FPGA_GOLD dequant_rowmajor`/`recon_y_*`; res_csum **XOR 0x14/20**. Handoff `docs/phase3-3l-idct.md` + HW draft `tests/hw/test_f3_idct_mb0.sh`. **L-3l2-rtl sketch DONE (docs only)** — plug checklist + inv_quant/IDCT sketch; **no SV checked in**. **L-csum-note**: **Hard-blocked** on lab res_csum until R-csum1 BUILD_OK + sole redeploy + hard gate=20; do **not** start inv_quant/IDCT paint fit / files.qip. Keep res_dc=-24. Reports `/tmp/misterplex-agent-L-3l2e.txt`, `/tmp/misterplex-agent-L-3l2-rtl.txt`, `/tmp/misterplex-agent-L-csum-note.txt`. |
| P3-3l3 | First full MB recon | TODO | I_NxN modes+CBP+residual+chroma |
| P3-3l4 | All MBs / frame mae | TODO | Full I-slice mae vs host |
| P3-3l5 | Hybrid gate product | TODO | When 3.3l-4 mae competitive |
| P3-SPI | SPI F1 only ~9fps — keep as fallback | DONE | Measured ~112 ms / ~9 fps; product SPI fallback intact |

## Phase 4 (UX)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P4-SCRUB | Scrubber/playqueue edge cases | **DONE** | Baseline + E-P4…E-P4g + G-commit8 + **E-P4h** + **`f635858`** plant-hold + **G-p4-dirty `ade6915`** (atomic plant hold + keep scrub across bindMedia). **C-unit12** `make unit` EXIT=0 on HEAD `ade6915`; goldens + companion OK. Reports `/tmp/misterplex-agent-G-p4-dirty.txt`, `/tmp/misterplex-agent-C-unit12.txt`, `/tmp/misterplex-agent-E-p4h.txt`, `/tmp/misterplex-agent-C-unit11.txt` (+ E-p4*, G-commit8..12). |
| P4-HZ | Match-source-Hz modeline (docs only OK) | DEFER | docs only |
| P4-SUB | Subtitles burn-in plan | DEFER | docs only |

## Phase 5 (release / lab)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P5-PKG | Package release tarball | **DONE (F-package3 on 820484a6)** | **F-package3 PASS**: `dist/misterplex-0aa744f-dirty.tar.gz` (12038474 B; tarball md5 `4dea7f5530999bb44d7052738cfd2872`) embeds RBF **`820484a686dc6b744954e3c8ef8df3f4`** + set_status + misterplexd + push_frame. Stage cores match. Prior F-package2 had `aa146c17` (superseded). Re-package after R-csum1 new RBF if gates green. Report `/tmp/misterplex-agent-F-package3.txt`. |
| P5-SOAK | WiFi soak multi-round | **DONE** | **D-soak3 PASS** on lab **`aa146c17`** (2026-07-24 ~11:53): `SOAK_HOLD_S=6 SOAK_ROUNDS=2 SOAK_NET_LABEL=wifi` → **ok=6 fail=0**. **D-soak4 PASS** on lab **`820484a6`** (~12:09): same recipe → **ok=6 fail=0** (wifi; no load_core; CORENAME=Plex; bars parked force=1 NTSC 60). **D-park** hygiene PASS bars parked. Reports `/tmp/misterplex-agent-D-soak3.txt`, `/tmp/misterplex-agent-D-soak4.txt`, `/tmp/misterplex-agent-D-park.txt` |
| P5-ETH | Eth vs wifi numbers | BLOCKED | no eth lab path |
| P5-CRT | CRT matrix checklist | **PARTIAL** | Practical checklist + dual **LAB vs physical CRT** tick matrix: [docs/crt-lcd-lab-checklist.md](crt-lcd-lab-checklist.md) (+ [crt-lcd-matrix.md](crt-lcd-matrix.md) pointer, [captures/menu/CRT_LCD_LAB.md](../captures/menu/CRT_LCD_LAB.md)). LAB (HDMI): modes/FBAR/NTSC·PAL/FPS/soak PASS from captures + agent-H/D; CRT2 rechecked `test_cadence` OK. Physical CRT 15 kHz rows **PENDING** (no CRT attached). **No false CRT PASS.** No Quartus/`load_core`. Reports `/tmp/misterplex-agent-CRT.txt`, `/tmp/misterplex-agent-CRT2.txt` |

## RBF inventory (agent-J-backlog18: no Quartus; no deploy invented)
| Path | md5 (prefix) | Notes |
|------|--------------|-------|
| `fpga/Plex_MiSTer/output_files/Plex.rbf` | **`820484a6`** | **Q-fix1 BUILD_OK** Assembler output; full `820484a686dc6b744954e3c8ef8df3f4`; size **3503592** B; mtime 12:02 — **R-csum1 LIVE RESTART will replace** when BUILD_OK (host still this md5) |
| `fpga/Plex_MiSTer/releases/Plex.rbf` | **`820484a6`** | Promoted match (H-deploy-fix1) |
| `releases/Plex.rbf` (repo root) | **`820484a6`** | Promoted match |
| `misterfpga-dev/out/Plex_MiSTer/Plex.rbf` | **`820484a6`** | Docker collect SUCCESS match (Q-fix1) |
| `dist/stage-misterplex/cores/Plex.rbf` | **`820484a6`** | **F-package3** stage embeds new artifact |
| Lab `/media/fat/_Utility/Plex.rbf` | **`820484a6`** | **LOADED** — md5 `820484a686dc6b744954e3c8ef8df3f4` (**H-deploy-fix1**); **FBAR PASS**; **res_dc=-24 PASS**; **res_csum HARD FAIL** (live wrong 232/59/142 class); **WIDE FAIL ~60.5%** (W-wide4/5/6 Fix-1 dead); **B-ddr5 PASS** mean≈18 ms; **D-soak4 PASS** ok=6; bars parked |
| `dist/misterplex-0aa744f-dirty.tar.gz` | embeds **`820484a6`** | **F-package3 PASS** (12038474 B) |
| `dist/misterplex-56e4e30-dirty.tar.gz` | embeds **`aa146c17`** | Prior F-package2 (superseded) |
| `dist/misterplex-08fb844-dirty.tar.gz` | embeds **`6db3a4d8`** | Prior agent-F package (superseded) |

### Quartus status (2026-07-24 ~12:12 CDT)
| Build | Log | Result |
|-------|-----|--------|
| Clean FBAR | `/tmp/plex_quartus_fbar_clean.log` | **BUILD_OK** (~447s); RBF `6db3a4d8` — FBAR PASS on lab (prior) |
| **Q-3l1** (P3-3l1 residual full-16 + csum intent) | `/tmp/plex_quartus_3l1.log` | **BUILD_OK** 11:45:24 exit 0; RBF **`aa146c17`** (superseded on lab) |
| Q-3l1b concurrent | (not started) | Correctly **ABORT** busy (`/tmp/misterplex-agent-Q-3l1b.txt`) |
| **Q-fix1** (csum pack fix + Fix-1 colorbars HSync@336) | `/tmp/plex_quartus_fix1.log` | **BUILD_OK** — BUILD END **12:02:28** exit=0; wall **~467s**. RBF **`820484a6`** lab-loaded; FBAR PASS; **res_csum still HARD FAIL** (live wrong XOR); WIDE still FAIL ~60.5% |
| **R-csum1** (running XOR residual_csum + lev[] + preserve status regs) | `/tmp/plex_quartus_rcsum1.log` | **LIVE RESTART — NOT BUILD_OK**. Prior attempt BUILD START **12:05:27** timeout-killed mid phys-synth. **RESTARTED BUILD START 12:10:59** (“bg resume after timeout kill of prior attempt”); pid `/tmp/plex_quartus_rcsum1.pid`; docker + `quartus_fit` LIVE; **M-fitmon-rc1** + **M-fitmon-rc3** STATUS=LIVE. Host `output_files/Plex.rbf` still **`820484a6`** (mtime 12:02). **do NOT invent BUILD_OK**. **Zero additional Quartus** until this finishes. Dirty `Plex.sv` + `slice_hdr_parser.sv` csum work is the source under fit. |

- Action this agent (J-backlog18): **refresh backlog only** (no Quartus; no deploy; no package; no lab HW thrash)
- Post-R-csum1 sequence (Open #1) — **blocked on LIVE fit restart**:
  1. Wait real **R-csum1 BUILD_OK** + collect new RBF md5 — **IN FLIGHT (restarted 12:10:59)** (do not invent)
  2. **One** sole deploy (`DEPLOY_LOAD=menu`) — do not thrash
  3. **FBAR** re-confirm (`test_fbar_fast`) — was green only on 820484a6
  4. **Hard res_csum=20** gate (raw[13]=0x14; keep res_dc=-24) — **A-arm-csum tools READY**
  5. **WIDE Fix-2** (paint-full-DE) — **after** hard csum path settled; **no second Quartus while R-csum1 busy**; Fix-1 eyes closed (W-wide4/5/6 FAIL ~60.5%; Fix-1 dead)
  6. Optional: re-package + re-soak after gates green
- Do **not** invent R-csum1 BUILD_OK / redeploy / hard-csum PASS; do not start another Quartus

## Open (priority next workers)
1. **finish R-csum1 → sole deploy → hard csum retest** — **OPEN #1**. Lab **`820484a6`**: FBAR PASS; res_dc=-24 PASS; **res_csum HARD FAIL** (H-gate live wrong values **232/59/142**). **R-csum1 sole rebuild LIVE RESTART** (prior fit timeout-killed; **BUILD START 12:10:59**; running XOR + lev[] fix; log `/tmp/plex_quartus_rcsum1.log`; M-fitmon-rc1/rc3 LIVE) — **do not invent BUILD_OK**. After BUILD_OK: one menu deploy → FBAR re-confirm → hard csum (raw[13]=0x14). **Zero concurrent Quartus.** Dirty tree: `Plex.sv` + `slice_hdr_parser.sv` csum work (companion clean @ `ade6915`). Evidence: `/tmp/plex_quartus_rcsum1.log`, `/tmp/misterplex-agent-H-deploy-fix1.txt`, `/tmp/misterplex-agent-H-gate-fix1.txt`, `/tmp/misterplex-agent-L-csum-note.txt`, `/tmp/misterplex-agent-R-csum-rca2.txt`, `/tmp/misterplex-agent-M-fitmon-rc1.txt`, `/tmp/misterplex-agent-M-fitmon-rc3.txt`, `/tmp/misterplex-loop-status.txt`
2. **P3-WIDE Fix-2 after BUILD_OK** — **FAIL open** on **`820484a6`** (**W-wide4/5/6** ~60.5% pillar; **Fix-1 dead/closed**). **Do not start Fix-2 Quartus while R-csum1 busy.** After R-csum1 free: Fix-2 paint-full-DE@529 (keep FBAR-green timing). Eyes `/tmp/misterplex-agent-W-wide5.txt`, `/tmp/misterplex-agent-W-wide6.txt`, RCA `/tmp/misterplex-agent-W-rca6.txt`
3. **P3-3l1 HW residual hard** — **PARTIAL**: deploy+FBAR+res_dc green on 820484a6; hard res_csum **FAIL** until R-csum1 BUILD_OK + redeploy
4. **P3-3l2..3l5** — inv quant/IDCT → MB → frame mae → hybrid gate (**host 3l2 goldens+handoff PASS** L-3l2e; **L-3l2-rtl docs sketch DONE**; **L-csum-note hard-block** paint fit until res_csum=20)
5. **P5-CRT** — **PARTIAL** practical checklist + LAB/CRT tick matrix; physical CRT eyes-on still open
6. ~~**`make unit` plant sticky**~~ — **DONE green C-unit11** on `f635858` + **C-unit12** on **`ade6915`** (EXIT=0). Evidence `/tmp/misterplex-agent-C-unit12.txt`, `/tmp/misterplex-agent-C-unit11.txt`
7. ~~**H-deploy-fix1 → FBAR on 820484a6**~~ — **DONE** FBAR PASS (H-gate-fix1 reconfirm); residual hard still OPEN (item 1)
8. ~~**F-package3 / P5-PKG re-package 820484a6**~~ — **DONE** `dist/misterplex-0aa744f-dirty.tar.gz` embeds `820484a6`
9. ~~**P3-DDR remeasure on 820484a6**~~ — **DONE** B-ddr5 mean≈18.0 ms PASS
10. ~~**host P3-3l2 handoff**~~ — **DONE** L-3l2e
11. ~~**L-3l2-rtl docs sketch**~~ — **DONE** (blocked hard csum for SV) `/tmp/misterplex-agent-L-3l2-rtl.txt`
12. ~~**W-proto7 post-BUILD_OK protocol**~~ — **DONE / READY** `/tmp/misterplex-agent-W-proto7.txt`
13. ~~**P3-FBAR (on aa146c17 then 820484a6)**~~ — **DONE** H-deploy-fix1 + H-gate-fix1 (re-confirm after R-csum1)
14. ~~**P5-SOAK**~~ — **DONE** D-soak3 ok=6 on `aa146c17` + **D-soak4 ok=6 on `820484a6`**; **D-park** hygiene PASS
15. ~~**P4-SCRUB baseline + G-commit8 + E-P4h + f635858 + G-p4-dirty ade6915**~~ — **DONE** plant-hold + atomic plant polish; C-unit12 EXIT=0
16. ~~**A-arm-csum res_csum print tools**~~ — **READY** A-arm-csum + A-arm-csum2
17. ~~**W-wide3..W-wide6 eyes**~~ — **DONE (result FAIL all ~60.5%)** — still open as P3-WIDE gate; **Fix-1 dead**; Fix-2 after R-csum1
18. ~~**HW residual soft / res_dc**~~ — **DONE** res_dc=-24 PASS on 820484a6; hard csum still OPEN
19. ~~**Q-fix1 BUILD_OK + host RBF collect + lab deploy**~~ — **DONE** RBF **`820484a6`** lab-loaded; hard csum FAIL → R-csum1 LIVE RESTART
20. ~~**RBF collect + lab load aa146c17**~~ — **DONE** (superseded by 820484a6)
21. ~~**L-csum-note docs**~~ — **DONE** phase3-3l-idct.md HW evidence + 3l2 paint block `/tmp/misterplex-agent-L-csum-note.txt`
22. ~~**G-p4-dirty companion commit**~~ — **DONE** HEAD **`ade6915`** `/tmp/misterplex-agent-G-p4-dirty.txt`; unit reconfirm C-unit12
23. ~~**J-backlog16 / J-backlog17**~~ — **DONE** prior refreshes; this is **J-backlog18** (R-csum1 restart + HEAD ade6915)

## Non-RBF always available
- (done **C-unit12** / **C-unit11** / **E-P4h** / **G-p4-dirty**) P4-SCRUB plant-hold + atomic plant polish + unit GREEN — HEAD **`ade6915`** — `/tmp/misterplex-agent-C-unit12.txt`, `/tmp/misterplex-agent-G-p4-dirty.txt`, `/tmp/misterplex-agent-C-unit11.txt`, `/tmp/misterplex-agent-E-p4h.txt`
- (done W-wide-rca / W-rca2..**W-rca6** + **W-proto7 READY**) P3-WIDE RCA + protocol — `/tmp/misterplex-agent-W-proto7.txt`, docs/p3-wide-rca.md
- (done **W-wide4** / **W-wide5** / **W-wide6** / W-wide3) Eyes-on 820484a6 Fix-1 state C — **FAIL ~60.5% all**; **Fix-1 dead/closed**; Fix-2 after R-csum1 free
- (done agent-B / B-ddr2..**B-ddr5**) DDR kick-verify — **B-ddr5** mean 18.0 ms has_frame=1 on 820484a6
- (done **C-unit12**) goldens locked + companion OK — unit GREEN on `ade6915`
- (done agent-L-3l2 / **L-3l2e** + **L-3l2-rtl** + **L-csum-note**) host goldens+handoff PASS; **RTL sketch docs DONE**; **hard csum docs note DONE**; **blocked hard csum for paint SV**
- (done B-rtl-3l1 + **Q-3l1 BUILD_OK** + **Q-fix1 BUILD_OK** + **H-deploy-fix1**) → lab **`820484a6`**; hard csum FAIL → **R-csum1 LIVE RESTART**
- (done M-fitmon / M-fitmon2 / M-fitmon3 / **M-fitmon5** / **M-fitmon6**) Q-fix1 BUILD_OK confirmed; **M-fitmon-rc1** + **M-fitmon-rc3** watch R-csum1 LIVE RESTART
- (done **H-deploy-fix1** + **H-gate-fix1**) Sole menu deploy 820484a6 + FBAR PASS + residual hard FAIL (live wrong csum 232/59/142)
- (**pending R-csum1 BUILD_OK → sole redeploy**) Hard csum retest — do not invent BUILD_OK/PASS; fit **restarted 12:10:59** after timeout kill
- (done agent-N + E-P4…**E-P4h** + G-commit8..12 + **G-p4-dirty**) P4-SCRUB green; HEAD **`ade6915`**
- (done agent-F + **F-package2** + **F-package3**) Package with **`820484a6`** — **F-package3 PASS**
- (done agent-D / D-soak2 / **D-soak3** + **D-soak4** + **D-park**) Soak PASS ok=6 on aa146c17 and 820484a6; bars hygiene
- (done agent-I residual2 / **I-residual3**) HW residual res_dc=-24 green soft (prior RBF)
- (done **A-arm-csum** + **A-arm-csum2**) ARM push_frame res_csum print **tools READY**
- (done **R-csum-rca2**) residual_csum RCA vs 34bf755 / dirty R-csum1 source — `/tmp/misterplex-agent-R-csum-rca2.txt`
- Unit tests, docs, set_status / push_frame ARM only
- Safe deploy polish (`DEPLOY_LOAD=none|menu`)
- P5-CRT fill-in when hardware available
- **R-csum1 LIVE RESTART** — sole Quartus; **no second Quartus**; **no invented BUILD_OK / redeploy / hard-csum PASS**
- Next serial lab after R-csum1 BUILD_OK: sole deploy → FBAR re-confirm → hard csum → WIDE Fix-2 (if still open, separate rebuild)
- ~~**E-p4k/E-P4h/C-unit11/G-p4-dirty/C-unit12 plant sticky**~~ — **DONE** unit green HEAD **`ade6915`**
- git HEAD **`ade6915`**; companion **clean** (committed); dirty tree has **Plex.sv + slice_hdr_parser.sv csum work** (R-csum1 source) + docs
