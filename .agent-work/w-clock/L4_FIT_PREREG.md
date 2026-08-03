# PRE-REGISTER — L4 enable fit (clk_sys @ ship 20 MHz)

**Committed before parent fit.** Compare after real STA; publish miss.

**Assumed fit netlist (state this explicitly):**
- Base: main@`035fae51` (or successor with same L4 RTL)
- QSF enables: `PLEX_PRESENT_720P_L4=1`, `FABRIC_NATIVE_720P_GEOM=1`,
  `FRAME_W=1280`, `FRAME_H=720` (and **comment out** 640/480)
- PLL: **unchanged** 20 / 90 MHz (`pll_0002.v`)
- residual_csum: **combo ST_PLACE fold still on main** (w-clock `csum_acc`
  latch is on `w-clock-bump` only unless parent merges it into the fit tree)
- `DDR_FRAME_STORE=1` as product today
- Corner of record: **Slow 1100mV 100C Final**

---

## PREDICTION (locked)

| Question | PRE-REGISTER |
|---|---|
| Does **clk_sys close at ≥ 20.000 MHz** (setup slack ≥ 0, Fmax ≥ 20)? | **YES** |
| Does **clk_ddr close at ≥ 90 MHz**? | **YES** |
| Who owns clk_sys Fmax (named)? | **`slice_hdr_parser` `r_tc[*]` → `residual_csum[*]`** |
| Owner class | **PRODUCT real** (not decode_stub) |
| Secondary path in top-5 sameclk | `present_content_window` `hc`→`store_x` mul **or** other `slice_hdr` |
| Related-edge y_line/c_line | setup slack **≥ 0** (watch; prior 1.189 ns @ 5.556 rel) |

### Why YES @ 20 MHz (reasoning, not evidence)

- Prior nostub sameclk residual path: data delay **30.062 ns** @ 50 ns period → ~19.3 ns slack class → Fmax **32.59** MEASURED prior.
- L4 adds area/route and content_window mul, but a healthy 11×20 mul tree is typically **≪ 30 ns** on C5 1100mV — **INFERRED**.
- Congestion can still steal several ns; 20 MHz still leaves ~**12+ ns** paper margin vs prior critical path if residual remains owner.

### Why residual_csum still owns (not content_window)

- main@035fae51 still has combo 16×sat8+XOR into `residual_csum` at ST_PLACE (**MEASURED source**).
- That cone was the nostub Fmax owner with **30 ns** data delay.
- content_window mul is new but shorter on paper; placement could promote it — **miss class A**.

### Explicit miss classes (publish which hit)

| Code | Miss |
|---|---|
| M1 | clk_sys Fmax **&lt; 20** or setup slack **&lt; 0** → PRED YES wrong |
| M2 | Owner **not** residual_csum (e.g. content_window / y_line / other) |
| M3 | Owner is **decode_stub** (miss #18 recurrence — hard process fail) |
| M4 | Related-edge y_line/c_line **negative** slack |
| M5 | clk_ddr Fmax **&lt; 90** |
| M6 | Fit included residual **csum_acc** fix and residual still owns (fix underperformed) |

---

## Counterfactual if fit includes w-clock residual fix (`928a600b`)

| Question | Alternate PRE-REGISTER |
|---|---|
| clk_sys ≥ 20? | **YES** |
| Fmax owner? | **UNKNOWN among product** — expect **not** `r_tc→residual_csum`; likely `present_content_window` store mul, other `slice_hdr`, or MC/decode |

Do not treat alternate as the primary prediction unless parent states the fit tree includes that commit.

---

## One-pass extract (after fit)

```bash
# 1) Path dumps (TimeQuest)
quartus_sta -t scripts/l4_sta_dump_paths.tcl Plex Plex /path/to/fit_out

# 2) Verdict (from repo root)
scripts/l4_sta_onepass.sh \
  /path/to/fit_out/Plex.sta.rpt \
  /path/to/fit_out/clk_sys_sameclk_setup.txt
# true rc: 0=PASS, 1=FAIL — capture:  cmd; echo "true rc=$?"
```

Self-test (existing stale report — expect FAIL on slack, not crash):

```bash
scripts/l4_sta_onepass.sh \
  fpga/Plex_MiSTer/remote_out/slot11/Plex.sta.rpt \
  .agent-work/w-clock/nostub-path-dump/clk_sys_emu_sameclk.txt
```
