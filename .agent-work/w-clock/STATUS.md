# w-clock STATUS

## Branch
`w-clock-bump` @ MisterPlex-wt-clock  
**Pin main:** detached `035fae51` (`MisterPlex/MisterPlex-wt-clock-pin-035fae51`)

## PARKED
- PLL native-720p kit + CDC 4:15
- No Quartus fit (parent exclusive)

## L4 fit prep (current)

| Item | Status | Evidence |
|------|--------|----------|
| Task A L4 timing exposure | DONE | `.agent-work/w-clock/L4_TIMING_EXPOSURE.md` |
| Task B one-pass STA | DONE runnable | `scripts/l4_sta_onepass.sh` + `l4_sta_onepass.py` + `l4_sta_dump_paths.tcl` |
| Self-test (stale slot11 + nostub dump) | FAIL as expected | true rc=1 (neg slack + ddr Fmax&lt;90); owner parsed residual_csum |
| Task C PRE-REGISTER | LOCKED | `.agent-work/w-clock/L4_FIT_PREREG.md` |

### PRE-REGISTER (before parent fit)
- clk_sys ≥ 20 MHz @ Slow 1100mV 100C: **YES**
- clk_ddr ≥ 90: **YES**
- Fmax owner: **slice_hdr_parser r_tc → residual_csum** (main still combo fold)
- If residual fix `928a600b` in fit tree: owner **not** residual (alternate)

### L4 high-risk signals (source)
- NEW: `present_content_window` `hc*sx_r` / `py*sy_r` → store_x/y
- GROW: ddr `X_W`/`Y_W`, `Y_LINE_QWORDS` 80→160, y_line/c_line CDC tags
- PRIOR: residual_csum combo (still on 035fae51)

## residual_csum fix
On branch `928a600b` default-ON; **not on main@035fae51**. Gate true rc=0 earlier.

## Open below L4 prep
- B20_CLOSED=false; PLXG reset liveness OPEN
