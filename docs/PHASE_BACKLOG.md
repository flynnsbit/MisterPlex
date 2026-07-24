# MiSTerPlex phase backlog (living)

Update this file when work finishes. Loop agents claim items and mark `DONE` / `IN_PROGRESS` / `BLOCKED`.

## Gate: all green before “complete”
- [ ] `make unit` green
- [ ] HW residual `res_dc=-24` (no load_core thrash)
- [ ] FBAR visual PASS on current RBF (`test_fbar_fast.sh`)
- [ ] Full-width VGA verified (HBlank@320 RBF `fa160ea8+`)
- [ ] DDR F1 ≥30 fps path stable in misterplexd (kick verify, not only ddr_busy)
- [ ] `make package` produces tarball with RBF + set_status
- [ ] misterplexd soak PASS (wifi) without SPI death
- [ ] Safe deploy only (`DEPLOY_LOAD=none|menu` via `scripts/deploy_plex_core.sh`)

## Phase 3 (decode / present)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| P3-FBAR | Force bars O[9] visual = bars when pattern=grid | IN_PROGRESS | needs clean RBF if still FAIL |
| P3-WIDE | Full-width DE HBlank@320 | DONE? | fa160ea8 deployed; eyes-on VGA |
| P3-DDR | DDR F1 kick reliable in product path | IN_PROGRESS | ~16ms when works; verify path fixed ARM |
| P3-3l0 | Host quant/IDCT golden | DONE | 2e2c2dc |
| P3-3l1 | FPGA full 16 coeffs | TODO | |
| P3-3l2 | Inv quant + IDCT first 4×4 | TODO | |
| P3-3l3 | First full MB recon | TODO | |
| P3-3l4 | All MBs / frame mae | TODO | |
| P3-3l5 | Hybrid gate product | TODO | |
| P3-SPI | SPI F1 only ~9fps — keep as fallback | DONE | measured |

## Phase 4 (UX)
| ID | Item | Status |
|----|------|--------|
| P4-SCRUB | Scrubber/playqueue edge cases | TODO |
| P4-HZ | Match-source-Hz modeline (docs only OK) | DEFER |
| P4-SUB | Subtitles burn-in plan | DEFER |

## Phase 5 (release / lab)
| ID | Item | Status |
|----|------|--------|
| P5-PKG | Package release tarball | DONE-ish |
| P5-SOAK | WiFi soak multi-round | PARTIAL |
| P5-ETH | Eth vs wifi numbers | BLOCKED no eth |
| P5-CRT | CRT matrix checklist | TODO lab |

## Non-RBF always available
- ARM STREAM/CABAC/recon polish
- unit tests, docs, package
- host 3.3l-0/1 prep
- safe deploy script polish
- soaks PRESENT=fb0 or both without core reload
- set_status / push_frame ARM only
