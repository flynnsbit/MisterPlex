derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
#
# Fabric PLL SoT: rtl/pll/pll_0002.v (NOT stale pll.v megawizard strings).
# Shipping rates (must match assets/pll_clock_contract.json + make unit gate
# scripts/check_pll_clock_contract.py):
#   general[0] clk_sys  = 20.000 MHz (period 50.000 ns)
#   general[2] clk_ddr  = 90.000 MHz (period 11.111 ns)
#   min related-edge Δ  = 5.556 ns  (20/90 rising-edge family; STA-proven on
#                                    8fdf440f path panels as Relationship 5.556)
#
# Proposed overclocks are NOT applied here. Do not edit pll_0002.v without a
# parent fit grant. Contract targets (related-edge recomputed by the gate):
#   A 25/90 → related-edge 2.222 ns (CDC HIGH risk vs ~3.5–3.8 ns data delay)
#   B 30/90 → related-edge 11.111 ns (3:1 preferred; hold STA required)
#   C 27/90 → related-edge 3.704 ns (marginal vs data-delay class)
# After any real PLL bump fit: re-run check_pll_clock_contract.py --sta-rpt
# --activate-target <name>, refresh this comment block to the NEW rates, and
# never retcon 20 MHz / 5.556 ns without quoting the new STA relationship.
#
# async_fifo data plane (all instances, dominant: ddr_bus_arbiter.m1_rsp_fifo):
# mem[] is written on wr_clk and sampled into rd_data_r on rd_clk. Gray pointer
# synchronisers are the real CDC (docs/cdc-crossing-inventory.md crossings
# #16/#22/#30). general[0] (clk_sys 20 MHz) and general[2] (clk_ddr 90 MHz)
# share one set_clock_groups -exclusive group in sys_top.sdc, so STA applies a
# related-edge relationship of 5.556 ns across this intentional async path.
# That is placement-fragile, not a want_y logic failure:
#   ac90b155: m1_rsp_fifo mem→rd_data_r setup +0.502 (data delay 4.111)
#   ff2e3ca3: same class setup -0.233 (data delay 4.892) and hold -0.517
#             (hold relationship 0.001 ns — related-edge artifact)
#   8fdf440f: fstore c_line→c_line_v1 ddr→sys setup +0.793 (data delay 3.832,
#             relationship 5.556) — binding CDC class for ratio changes.
# Quartus 17.0 has no set_max_delay -datapath_only. Cut ONLY the FIFO data
# keepers (mem→rd_data_r). Do NOT cut the whole general[0]↔general[2] pair
# (other same-group paths e.g. fstore DDRAM_ADDR / line meta must stay timed).
# Do NOT add false_path/multicycle to silence a real CDC violation.
set_false_path \
	-from [get_keepers {*async_fifo*mem*}] \
	-to   [get_keepers {*async_fifo*rd_data_r*}]
