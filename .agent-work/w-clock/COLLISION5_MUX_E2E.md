# Collision #5 E2E (w-clock)

w-mem landed `force_native_960 = ~plxg_live` (+ `FAULT_B8_FORCE_ALWAYS` red hook).
w-clock **did not edit** that symbol; tree carries a copy for E2E compile.

| Test | Expect |
|------|--------|
| GREEN product mux→beam | PLXG 624×480, **416×234**, 320, 960 exact DE; idle → 960 fallback |
| RED `-DFAULT_B8_FORCE_ALWAYS` | pins 960 over live 624 (regression class that killed B13) |

V705 STA prereg: `assets/ascal_native_sta_prereg.json` schema 4.
H_TOTAL line rate: `tests/unit/test_beam_htotal_line_rate.sh` + `H_TOTAL_1182_LINE_RATE.md`.
