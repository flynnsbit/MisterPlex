# Pre-reg (before STA re-read) — decode clock headroom

| Claim | Prediction | Basis |
|-------|------------|-------|
| clk_sys constrained | 20.000 MHz | prior JOB1 + pll_0002 |
| clk_ddr constrained | 90.000 MHz | prior JOB1 (not 100) |
| Decode domain | clk_sys (general[0]) | stream_path/decode on clk |
| Fmax clk_sys @ 8fdf/t7b (WITH stub) | ~23–24 MHz | JOB1 quoted 23.46 |
| Fmax clk_sys @ c74c6863 (NO stub) | ~32–33 MHz | prior fit 32.59 |
| Fmax clk_ddr | ~96–98 MHz | prior ~96.83 / 97.43 |
| general[0] slack +0.3ns means path ~ | 50ns - 0.3 = 49.7ns → Fmax ~20.1 MHz floor is constrained; unrestricted Fmax higher | period=50ns at 20MHz |
| ao486 heavy path | ~90 MHz | prior external |
| jtcores | 10–24 MHz arcade-match | not headroom bench |
