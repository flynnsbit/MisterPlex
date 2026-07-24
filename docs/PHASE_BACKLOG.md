# MiSTerPlex phase backlog (living)

Update this file when work finishes. Loop agents claim items and mark `DONE` / `IN_PROGRESS` / `BLOCKED`.

Evidence sources (2026-07-24 ~12:20 CDT): `/tmp/misterplex-*-agent*.txt`, **R-csum1 log `/tmp/plex_quartus_rcsum1.log` BUILD_OK** (BUILD END **12:17:04** exit=0; Full Compilation successful 0 errors, 5 warnings; wall ~365s after restart 12:10:59; RBF **`dabdaeb0`** full `dabdaeb0c5ae708c4fdbba388ba275b6`), Q-fix1 prior **`820484a6`**, Q-3l1 prior **`aa146c17`**, **G-fpga-rcsum1** `/tmp/misterplex-agent-G-fpga-rcsum1.txt` (FPGA sources **COMMITTED `7bee0a6`**), **H-deploy-rcsum1** + **H-rcsum-gate** `/tmp/misterplex-agent-H-deploy-rcsum1.txt` + `/tmp/misterplex-agent-H-rcsum-gate.txt` (**sole menu deploy PASS**; lab md5 **`dabdaeb0`**; **FBAR PASS** m1=82.9 m2=94.4; **res_dc=-24 PASS**; **res_csum HARD FAIL** unstable 139/222/49 ≠0x14 — soft-skip ≠ PASS; **OVERALL HARD GATE FAIL**), M-fitmon-rc5/rc6 BUILD_OK, residual3, **C-unit12/13 unit GREEN**, **G-docs1** + this **G-docs2**, **W-wide4/5/6 FAIL ~60.5%** on **`820484a6`** Fix-1 dead, **W-fix2-d2/d3 Fix-2 design READY**, **F-package3** still embeds prior `820484a6`, **A-arm-csum** + **A-csum-host2** tools READY, R-csum-rca3/4 GO used for deploy, git **HEAD was `7bee0a6`** (R-csum1 sources; parent `ee339b1` parse helper; docs dirty → G-docs2), FPGA tree **clean** post-7bee0a6, lab host `192.168.1.183`.

## Gate: all green before “complete”
- [x] `make unit` — **GREEN** (**C-unit12** / **C-unit13** 2026-07-24): EXIT=0; goldens PASS (res_dc=-24 res_csum=0x14 y00=73 mean=62); companion OK at plant-hold **`ade6915`**. **A-csum-host2** helper self-test PASS. Reports `/tmp/misterplex-agent-C-unit12.txt`, `/tmp/misterplex-agent-C-unit13.txt`, `/tmp/misterplex-agent-A-csum-host2.txt`
- [~] HW residual hard gate — **FAIL on lab `dabdaeb0`** (**H-deploy-rcsum1** + **H-rcsum-gate**). **R-csum1 BUILD_OK** md5 **`dabdaeb0`** (sources **`7bee0a6`**). Sole menu deploy + lab md5 match **PASS**. **FBAR PASS** on dabdaeb0. **res_dc=-24 PASS** (raw[12]=0xE8 stable). **res_csum HARD FAIL**: raw[13] **UNSTABLE** wrong values (**139 / 0x8b → 222 / 0xde → 49 / 0x31**; soft-skip got 49/139/222 want 20) — **NOT** 0x14/20; **NOT** stream_bytes low; **NOT** dc-only 0xE8. Soft-skip EXIT=0 is **not** hard PASS. Prior FAIL on `820484a6` (232/59/142) and pack-alias on `aa146c17` (0x53). Class = status path / preserve / multi-drive (branch **a**); do **not** re-open tmpc-fold first; do **not** redeploy dabdaeb0 expecting green; do **not** invent hard PASS. **3l2 paint remains BLOCKED**. Tools READY: A-arm-csum + A-csum-host2. Reports `/tmp/misterplex-agent-H-deploy-rcsum1.txt`, `/tmp/misterplex-agent-H-rcsum-gate.txt`, `/tmp/misterplex-agent-G-fpga-rcsum1.txt`, `/tmp/misterplex-agent-R-csum1.txt`, log `/tmp/plex_quartus_rcsum1.log`
- [x] FBAR visual PASS — **DONE on lab `dabdaeb0`** (**H-deploy-rcsum1**): `test_fbar_fast` EXIT=0 m1=82.9 m2=94.4 (≥15). Prior PASS on `820484a6` / `aa146c17` / `6db3a4d8`. Report `/tmp/misterplex-agent-H-deploy-rcsum1.txt`
- [ ] Full-width VGA verified (HBlank@320) — **eyes-on FAIL open** last measured on lab **`820484a6`** (**W-wide4/5/6**): HDMI span **~60.5%** = content320/DE529 pillar; R5%=0. Fix-1 state C **ineffective** (**Fix-1 dead**). **No more HSync-only thrash.** **Fix-2 paint-full-DE@529 design READY** (**W-fix2-d2** / **W-fix2-d3**) — RTL apply when Quartus free (R-csum1 done; prefer residual RCA settled or separate rebuild). [docs/p3-wide-rca.md](p3-wide-rca.md). Eyes `/tmp/misterplex-agent-W-wide4.txt`…`W-wide6.txt`; design `/tmp/misterplex-agent-W-fix2-d2.txt`, `/tmp/misterplex-agent-W-fix2-d3.txt`

- [x] DDR F1 ≥30 fps path stable in misterplexd — **B-ddr5 PASS** on prior lab **`820484a6`**: mean≈18.0 ms has_frame=1. Report `/tmp/misterplex-agent-B-ddr5.txt`
- [x] `make package` — **F-package3 PASS** embeds prior RBF **`820484a6`**. Re-package after hard residual green if needed. Report `/tmp/misterplex-agent-F-package3.txt`
- [x] misterplexd soak PASS (wifi) — **D-soak4 PASS** on prior **`820484a6`** ok=6; **D-soak3** on `aa146c17` ok=6; **D-park** PASS
- [x] Safe deploy only (`DEPLOY_LOAD=none|menu` via `scripts/deploy_plex_core.sh`)

## Phase 3 (decode / present)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P3-FBAR | Force bars O[9] visual = bars when pattern=grid | **DONE** (on dabdaeb0) | **H-deploy-rcsum1** sole menu deploy lab **`dabdaeb0`**: `test_fbar_fast` EXIT=0 m1=82.9 m2=94.4. Prior PASS H-gate-fix1 on `820484a6`. Report `/tmp/misterplex-agent-H-deploy-rcsum1.txt` |
| P3-WIDE | Full-width DE HBlank@320 | **PARTIAL / FAIL open** | Eyes-on **FAIL ~60.5%** on `820484a6` (W-wide4/5/6); Fix-1 **dead**. **Fix-2 design READY** (paint-full-DE@529; W-fix2-d2/d3). R-csum1 free — RTL apply when residual path allows / separate fit. **Not DONE.** [docs/p3-wide-rca.md](p3-wide-rca.md) |
| P3-DDR | DDR F1 kick reliable in product path | **DONE** | **B-ddr5 PASS** mean≈18.0 ms on `820484a6` |
| P3-3l0 | Host quant/IDCT golden | DONE | `test_idct_quant` first 4×4 locked |
| P3-3l1 | FPGA full 16 coeffs | **PARTIAL — hard-gate FAIL on lab dabdaeb0** | **Host DONE** goldens `res_csum=0x14`. **R-csum1 BUILD_OK** RBF **`dabdaeb0`**; sources **`7bee0a6`** (running XOR + lev[] + preserve status). **Sole deploy PASS**; **FBAR PASS**; **res_dc=-24 PASS**; **res_csum HARD FAIL** unstable 139/222/49 ≠0x14 (H-rcsum-gate). Soft-skip ≠ PASS. Next: residual RCA branch **a** (status/preserve/multi-drive) — **no invent PASS**; no thrash redeploy dabdaeb0. Reports `/tmp/misterplex-agent-H-deploy-rcsum1.txt`, `/tmp/misterplex-agent-H-rcsum-gate.txt`, `/tmp/misterplex-agent-G-fpga-rcsum1.txt`, `/tmp/misterplex-agent-R-csum1.txt` |
| P3-3l2 | Inv quant + IDCT first 4×4 | **PARTIAL / BLOCKED** | Host goldens + RTL sketch DONE. **Hard-blocked** until hard res_csum=20 on lab (still FAIL on dabdaeb0). Contingency: stay BLOCKED; residual RCA only. See `docs/phase3-3l-idct.md` *P3-3l2 UNBLOCK GATE*. |
| P3-3l3 | First full MB recon | TODO | I_NxN modes+CBP+residual+chroma |
| P3-3l4 | All MBs / frame mae | TODO | Full I-slice mae vs host |
| P3-3l5 | Hybrid gate product | TODO | When 3.3l-4 mae competitive |
| P3-SPI | SPI F1 only ~9fps — keep as fallback | DONE | Measured ~112 ms / ~9 fps |

## Phase 4 (UX)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P4-SCRUB | Scrubber/playqueue edge cases | **DONE** | plant-hold **`f635858`** + atomic plant **`ade6915`**; C-unit12 EXIT=0 |
| P4-HZ | Match-source-Hz modeline (docs only OK) | DEFER | docs only |
| P4-SUB | Subtitles burn-in plan | DEFER | docs only |

## Phase 5 (release / lab)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P5-PKG | Package release tarball | **DONE (F-package3 on 820484a6)** | embeds prior **`820484a6`**. Re-package after hard residual green if gates need new artifact. |
| P5-SOAK | WiFi soak multi-round | **DONE** | D-soak3/4 ok=6 on aa146c17 / 820484a6; D-park PASS |
| P5-ETH | Eth vs wifi numbers | BLOCKED | no eth lab path |
| P5-CRT | CRT matrix checklist | **PARTIAL** | LAB HDMI rows updated (CRT3); physical CRT **PENDING**. No false CRT PASS. Reports CRT/CRT2/CRT3 |

## RBF inventory (G-docs2: no Quartus; no deploy; docs only)
| Path | md5 (prefix) | Notes |
|------|--------------|-------|
| `fpga/Plex_MiSTer/output_files/Plex.rbf` | **`dabdaeb0`** | **R-csum1 BUILD_OK**; full `dabdaeb0c5ae708c4fdbba388ba275b6`; size **3433864** B; mtime 12:16 |
| `fpga/Plex_MiSTer/releases/Plex.rbf` | **`dabdaeb0`** | Promoted match |
| `releases/Plex.rbf` (repo root) | **`dabdaeb0`** | Promoted match |
| `misterfpga-dev/out/Plex_MiSTer/Plex.rbf` | **`dabdaeb0`** | Collect match |
| Lab `/media/fat/_Utility/Plex.rbf` | **`dabdaeb0`** | **LOADED** H-deploy-rcsum1; FBAR PASS; res_dc=-24 PASS; **res_csum HARD FAIL** (unstable ≠0x14); soft-skip ≠ PASS |
| `dist/stage-misterplex/cores/Plex.rbf` | **`820484a6`** | F-package3 stage (stale vs lab) |
| `dist/misterplex-0aa744f-dirty.tar.gz` | embeds **`820484a6`** | F-package3 PASS (prior) |

### Quartus status (2026-07-24 ~12:20 CDT)
| Build | Log | Result |
|-------|-----|--------|
| Clean FBAR | `/tmp/plex_quartus_fbar_clean.log` | **BUILD_OK**; RBF `6db3a4d8` (prior) |
| **Q-3l1** | `/tmp/plex_quartus_3l1.log` | **BUILD_OK**; RBF **`aa146c17`** (superseded) |
| **Q-fix1** | `/tmp/plex_quartus_fix1.log` | **BUILD_OK** 12:02:28; RBF **`820484a6`** (prior lab; hard csum FAIL; WIDE FAIL) |
| **R-csum1** | `/tmp/plex_quartus_rcsum1.log` | **BUILD_OK** — BUILD END **12:17:04** exit=0; wall ~365s (restart 12:10:59 after prior timeout kill). RBF **`dabdaeb0`**. Sources committed **`7bee0a6`**. **No Quartus LIVE.** |

- Post-R-csum1 sequence status:
  1. ~~Wait R-csum1 BUILD_OK + collect md5~~ — **DONE** **`dabdaeb0`**
  2. ~~One sole deploy~~ — **DONE** H-deploy-rcsum1
  3. ~~FBAR re-confirm~~ — **DONE PASS** on dabdaeb0
  4. **Hard res_csum=20** — **FAIL** (H-rcsum-gate; soft-skip ≠ PASS) → residual RCA next
  5. **WIDE Fix-2** — design **READY**; apply when fit slot free (prefer residual settled or separate rebuild)
  6. Optional re-package after gates green
- Do **not** invent hard-csum PASS; do **not** thrash-redeploy dabdaeb0 expecting green

## Open (priority next workers)
1. **Hard residual retest / RCA after H-gate FAIL on dabdaeb0** — **OPEN #1**. Lab **`dabdaeb0`**: FBAR PASS; res_dc=-24 PASS; **res_csum HARD FAIL** unstable 139/222/49 ≠0x14. Soft-skip ≠ PASS. Class branch **a** (status path / preserve / multi-drive). **Do not invent PASS.** **Do not redeploy same bitstream expecting green.** Next RTL residual fix only when RCA ready + sole Quartus free. Evidence: `/tmp/misterplex-agent-H-deploy-rcsum1.txt`, `/tmp/misterplex-agent-H-rcsum-gate.txt`, `/tmp/misterplex-agent-G-fpga-rcsum1.txt`, `/tmp/plex_quartus_rcsum1.log`
2. **P3-WIDE Fix-2** — **FAIL open** (~60.5% on 820484a6 eyes); **Fix-1 dead**; **Fix-2 design READY** (W-fix2-d2/d3 paint-full-DE@529). R-csum1 free. Prefer residual path not mid-edit, or separate rebuild after residual green. Design `/tmp/misterplex-agent-W-fix2-d3.txt`, docs/p3-wide-rca.md
3. **P3-3l2..3l5** — **BLOCKED** until hard res_csum=20 PASS post-deploy (still FAIL)
4. **P5-CRT** — PARTIAL; physical CRT pending
5. ~~**R-csum1 BUILD_OK + sole deploy + FBAR**~~ — **DONE** dabdaeb0 / H-deploy-rcsum1 (hard csum still OPEN FAIL)
6. ~~**G-fpga-rcsum1 FPGA source commit**~~ — **DONE** **`7bee0a6`**
7. ~~**make unit**~~ — **DONE green** C-unit12/13
8. ~~**H-deploy-fix1 → FBAR on 820484a6**~~ — **DONE** (superseded lab by dabdaeb0)
9. ~~**F-package3 / P5-PKG**~~ — **DONE** (embeds 820484a6; re-pkg later)
10. ~~**P3-DDR B-ddr5**~~ — **DONE**
11. ~~**host P3-3l2 handoff / L-3l2-rtl / L-csum-note**~~ — **DONE** (paint still blocked)
12. ~~**W-proto7 / W-fix2-d2/d3 Fix-2 design**~~ — **DONE / READY**
13. ~~**W-wide3..W-wide6 eyes**~~ — **DONE (result FAIL ~60.5%)** — gate still open
14. ~~**A-arm-csum + A-csum-host2 tools**~~ — **READY**
15. ~~**R-csum-rca3/rca4 GO**~~ — **DONE** (deploy path used)
16. ~~**G-docs1**~~ — **DONE** d58269b / b5e8320
17. **G-docs2** — this refresh (BUILD_OK dabdaeb0 + H-gate FAIL + WIDE Fix-2 ready)

## Non-RBF always available
- (done **G-fpga-rcsum1**) R-csum1 sources **`7bee0a6`** BUILD_OK md5 dabdaeb0
- (done **H-deploy-rcsum1** / **H-rcsum-gate**) sole deploy + FBAR PASS + hard residual **FAIL** on dabdaeb0
- (done **G-docs1**) prior docs at b5e8320 / d58269b
- (done W-rca + W-fix2-d2/d3) P3-WIDE Fix-2 design READY; eyes FAIL open
- (done C-unit12/13 / G-p4-dirty) unit GREEN; plant-hold ade6915
- (done A-arm-csum / A-csum-host2) hard-gate tools READY
- (done L-3l2e / L-3l2-rtl / L-csum-note / L-3l2-gate2) paint blocked on hard csum
- (done B-ddr5 / D-soak4 / F-package3) product gates on prior RBF
- Residual RCA next fix prep (docs/measure only until sole fit)
- Fix-2 RTL apply when authorized (colorbars.sv only; no residual thrash)
- Unit tests, docs, package after hard green
- P5-CRT physical when hardware available
- **No invented hard-csum PASS**; **no thrash redeploy dabdaeb0**
- git HEAD at G-docs2 commit; FPGA **clean** @ `7bee0a6`; companion clean @ `ade6915`
