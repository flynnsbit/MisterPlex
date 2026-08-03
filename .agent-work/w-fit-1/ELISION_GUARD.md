# plex_chrome RAM elision guard (post c74c6863 NO-DATA)

## Why
Fit `c74c6863` had `plex_chrome` entity present (5.3 ALM, 54 regs) but
**Block Memory Bits=0 / M10Ks=0**. Map: 1026× `list_a`/`list_b` Stuck at GND
because `sys_top` tied `list_we=1'b0` + BOOT_DEMO. Glass histogram byte-identical
before/after — nothing to score (P1=NO-DATA). P2 playback PASS on PRODUCT_NO_STUB.

## Gate
- Script: `scripts/check_plex_chrome_elision.py`
- Make: `make post-fit-chrome-elision FIT_RPT=... [MAP_RPT=...]`
- Unit: `tests/unit/test_plex_chrome_elision_guard.sh` (in `make unit`)
- Thresholds: M10Ks ≥ 1 **and** block_bits ≥ 4096 (one 64×64 list)
- Map: any `plex_chrome|list_[ab]* Stuck at GND/VCC` ⇒ FAIL

## Red-before-green (true rc= direct)
| Case | rc |
|------|---:|
| RED-A fixture c74c6863 fit excerpt | 1 |
| RED-B fixture + map stuck list | 1 |
| GREEN synthetic 2 M10K / 8192 bits | 0 |
| RED-C mutate green → 0/0 | 1 |
| LIVE full `fit-nostub-chrome` fit+map | 1 |

## Next exclusive slot still needs
1. This gate green on the **new** fit report (not c74c6863)
2. `list_we` driven by product PLXC (w-osd-hires ARM) — not BOOT_DEMO-only
3. Pre-reg vs c74c6863 baseline: ALM 14354 · M10K 197 · DSP 43 · clk_sys Fmax 32.59 · clk_ddr +0.559 · pll_hdmi +0.587
