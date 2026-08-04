# w-clock FIT PRE-REG — post nostub land (before exclusive slot)

**Branch tip:** `w-clock-720p-sv` @ 3994677d (pre-rebase).  
**Do not fit.** Numbers below are predictions to score after parent’s single fit.

---

## 1) What the retained 23.17 MHz number actually is

| Fact | Evidence |
|------|----------|
| Report | `fpga/Plex_MiSTer/output_files/Plex.sta.rpt` L128 Fmax Summary |
| clk_sys Restricted Fmax | **23.17 MHz** |
| Setup slack @20 MHz | **+0.849 ns** (same report Setup Summary) |
| `decode_stub` in fit | **YES** — `Plex.fit.rpt` has **2025** `decode_stub:stub` hits |
| ALM class | fit.summary **21,252 / 41,910 (50%)** — stub-in class (~21k), not historical nostub ~14k |
| RBF md5 | `2890baac70c29425…` (Jul 30 lab tree) |
| Path owner in plain STA | **UNKNOWN** — this export has **0** `From Node`/`To Node`/`Data Delay`/`decode_stub` strings in `.sta.rpt`. Cannot name the Fmax endpoint from this file alone. |

**Plain statement:** **23.17 MHz is a STUB-IN netlist measurement**, not nostub.  
It is the same *class* as historical **23.46 MHz** (`8fdf440f`, owner historically cited as `decode_stub` in prior worktree docs). It is **not** the historical nostub **32.59 MHz** (`c74c6863`, owner historically `residual_csum`).

**Implication for clk_sys@24:**  
- On *this* retained stub-in report: 23.17 < 24 → **hard FAIL** (gate already proves).  
- After w-nostub strips `decode_stub`: Fmax **may move**. Historical nostub 32.59 would clear 24 with margin — **but that is a different netlist and a different era**. Revisit CLK_SYS_24 only after a **new** nostub STA, not by retconning 23.17.

---

## 2) PRE-REGISTERED predictions (score me after the fit)

Assumed fit recipe (product present path, not DIAG):

```
PRODUCT_NO_STUB=1          # w-nostub land
DDR_FRAME_STORE=1
PRESENT_MULTI_PIXEL=1
PRESENT_PX_PER_CLK=2
PRESENT_CLK_PIX_PLL=1      # out3 29.700000 MHz
SDC_FILE Plex_clk_pix.sdc  # async groups sys/ddr vs pix
# CLK_SYS_24 OFF — clk_sys stays 20.000000 MHz
FRAME as product 720p if/when parent enables (else 640x480 content window)
```

| # | Quantity | PRE-REG | Confidence |
|---|----------|---------|------------|
| P1 | clk_sys Restricted Fmax (nostub + MULTI PPC2 + pix PLL) | **28.0 – 34.0 MHz** | med — historical nostub 32.59; MULTI+PPC2+YUV N-wide **adds** combo; expect some pull-down from 32.59 |
| P2 | Worst setup slack clk_sys @ **20.0 MHz** | **+0.40 – +1.20 ns** | med |
| P3 | clk_pix (general[3]) Restricted Fmax | **≥ 32 MHz** (need ≥29.7) | med-low — **no prior fit has general[3]**; first measurement |
| P4 | Worst setup slack clk_pix @ **29.7 MHz** | **≥ 0.0 ns** (close: 0.0–0.8) | med-low |
| P5 | clk_ddr@90 setup slack | **≥ 0.0 ns** (expect ~0.3–0.6 like retained) | high for sign-off floor only |
| P6 | Negative slack any domain | **0 failures** (gate hard-fail) | high on process; unknown on silicon path |
| P7 | 720p present path meets timing **as a whole** (sys@20 + pix@29.7 + async SDC + PPC2) | **PASS probability 65%** | — residual risk is **clk_pix unpack + N-wide YUV on sys**, not clk_sys@20 |
| P8 | clk_sys@**24** on same nostub+MULTI netlist (if parent also tries) | **PASS probability 55%** if Fmax≥26; **FAIL** if MULTI path owns Fmax below 24 | low until P1 lands |
| P9 | Fmax owner on clk_sys after nostub | **NOT decode_stub** (absent). Expect `residual_csum` **or** MULTI present (`yuv`/`ddr_frame_store`/`present_*`) | med |

**Miss policy:** publish actual vs band; do not move bands after seeing the report.

### What would falsify the MULTI+PPC2@20 strategy
- P1 Fmax **< 20** (catastrophic present-path regression)  
- P3/P4 clk_pix fails 29.7  
- Hierarchy: `present_npx_path` / `u_keep_pix_rate_match` / `plex_clk_status` stripped despite noprune  

### What would reopen CLK_SYS_24 as product
- P1 ≥ **26 MHz** with owner **not** a false path, and parent wants single-domain L4 1312×762 @24.006 Hz **instead of** clk_pix.  
- Still need consumer sweep + inventory green at 24 (already gated).

---

## 3) PPC=2 risk audit (from source on tip)

### Chain (live MULTI path)

| Stage | Handles PPC=2? | Source |
|-------|----------------|--------|
| `present_beam_ppc` | YES — `glass_x0` step=`PX_PER_CLK`, per-lane `lane_de` | `present_beam_ppc.sv` |
| `ddr_frame_store` | YES — `PX_PER_CLK`, `rd_r/g/b_n`, multi-lane from **same** registered Y/C qwords; even `rd_x` required | `ddr_frame_store.sv` ~33–51, 401–519 |
| `present_core` MULTI | YES — `FS_PX_PER_CLK=PRESENT_PPC`; `mp_npx_* = fs_rd_*_n` under `DDR_FRAME_STORE` | `present_core.sv` FS_PX + mp_npx block |
| `present_npx_path` | YES — whole **groups** in `async_fifo`; unpack serialises lanes on **clk_pix** | `present_npx_path.sv` |
| `present_pix_rate_match` | Arithmetic OK (TB 29.7 Mpix/s) | **Not on live beam** — keep pack only; beam uses FIFO `in_ready` backpressure |

### Unpack timing (clk_pix domain)
- PPC=2 → 2 clk_pix cycles per group after pop.  
- Need glass 29.7 Mpix/s → group rate 14.85 MHz → 2×14.85 = 29.7 ≤ clk_pix. **OK if clk_pix≥29.7.**

### DDR / BRAM feed (coordinate w-mem)
- **Read bytes/frame I420 1280×720** = 1.3824e6 → @24 fps **33.18 MB/s** (arith; w-mem sim is SoT for concurrent R+W).  
- PPC=2 does **not** double DDR beats: N pixels come from line-buffer qwords already filled; one `rd_active` address still maps into hit linebufs.  
- Extra cost is **logic width** (N× BT.601) on clk_sys, not N× DRAM bandwidth.  
- ARM write 33.18 MB/s concurrent remains w-mem’s delivery risk; fabric **read model** alone still fits under 25% of 720 MB/s peak (180 MB/s) — **not** a substitute for their sim.

### Residual PPC risks (honest)
1. Even-align requirement: odd `glass_x0` breaks group-in-one-qword (store comment). Beam H_DE=1280 % 2 == 0 — OK at start of line.  
2. Wider FIFO word + N-wide YUV may **own** Fmax after stub removal (see P9).  
3. Default QSF still PPC=1 / MULTI off — recipe must enable together or rate wall returns.

---

## 4) Landing stance
- **Do not merge** until w-nostub on main; then rebase + `make unit`, `rtl-lint`, `define-parity`.  
- Expect conflicts in `present_core.sv` / `Plex.sv` / `files.qip`.


## 5) rd-duck BLOCKING — MULTI 720p DDR ABI (fixed on this branch)

Pre-fix: `FS_*` 720p constants were under `PLEX_PRESENT_720P_L4` only; MULTI fell through to 480p @ 0x30000000.
Post-fix: `ddr_frame_abi_select.svh` keys off **FRAME_W/H==1280×720** (L4 or MULTI). LINE_COUNT floors to **16** on 720p ABI.
QSF MULTI recipe (commented): FRAME 1280×720 + FRAME_LINES_16 + PPC=2 + CLK_PIX_PLL.
Evidence: `test_ddr_frame_abi_select_verilator.sh` rc=0; `test_present_multi_720p_abi_static.py` rc=0.
