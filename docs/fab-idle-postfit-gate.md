# FAB_IDLE post-fit + glass gate (parent commands)

**Hard rule:** a green fit with elided chrome is **void**. Colour PASS without
hierarchy PASS is **void**. Hierarchy PASS without glass CYAN is **void**.

---

## 1. Anti-elision (what the RTL does)

| Mechanism | Where | Why |
|-----------|--------|-----|
| `list_we` boot toggle | `sys_top` `plxc_boot_*` | list RAM not Stuck-at-GND (c74c6863 class) |
| `(* noprune *)` list_a/b | `plex_chrome.sv` | dual-bank M10K retained |
| mon/chrome_hw always clocked | `plex_chrome.sv` | no 0-register ghost entity |
| **blanking keep-sink** | `sys_top` `chrome_keep_r` | mon + sig enables XOR into RGB **only when DE=0** — active video bit-identical; nets not dangling |
| HDMI path | ascal → shadowmask → **chrome** → osd → pins | dout must reach pins or hierarchy is worthless |

Default macros OFF: idle takeover off; chrome still in path (1-cycle delay). Keep-sink still runs so mon nets stay.

---

## 2. Exact post-fit commands (after BUILD_OK)

Replace `FITDIR` with the integration fit output dir (e.g. `fpga/Plex_MiSTer/remote_out/<slot>`).

### Required — FAB_IDLE / chrome plane (always run)

```bash
make post-fit-fab-idle \
  FIT_RPT=$FITDIR/Plex.fit.rpt \
  MAP_RPT=$FITDIR/Plex.map.rpt \
  COMPILE_LOG=$FITDIR/Plex.fit.rpt
# true rc must be 0. rc=1 → VOID FIT (do not deploy as fabric proof).
```

Equivalent expanded form:

```bash
make post-fit-hierarchy \
  FIT_RPT=$FITDIR/Plex.fit.rpt \
  MAP_RPT=$FITDIR/Plex.map.rpt \
  COMPILE_LOG=$FITDIR/Plex.fit.rpt \
  CONFIG=tests/fixtures/critical_fit_hierarchy_fab_idle.json

make post-fit-chrome-elision \
  FIT_RPT=$FITDIR/Plex.fit.rpt \
  MAP_RPT=$FITDIR/Plex.map.rpt
```

### Module list asserted (`critical_fit_hierarchy_fab_idle.json`)

| name | entity / hierarchy_contains | mins (hard) |
|------|----------------------------|-------------|
| **plex_chrome** | `plex_chrome` | ALUT≥50, regs≥40, block_bits≥4096, **M10K≥1** |
| **plex_chrome_host_if** | `plex_chrome_host_if` | ALUT≥5, regs≥10 |
| **ddr_frame_store** | `ddr_frame_store` | ALUT≥100, regs≥50, bits≥1000, M10K≥1 |
| **present_core** | `present_core` | ALUT≥10, regs≥10 |

Elision script additionally rejects: missing entity, M10K=0&bits=0, stuck `list_a/b` in map.rpt, regs&lt;40, ALUTs&lt;50.

### If integration also enables `PRESENT_MULTI_PIXEL=1`

```bash
make post-fit-multi-pixel \
  FIT_RPT=$FITDIR/Plex.fit.rpt \
  MAP_RPT=$FITDIR/Plex.map.rpt \
  COMPILE_LOG=$FITDIR/Plex.fit.rpt
```

| name | hierarchy |
|------|-----------|
| present_beam_ppc | `present_beam_ppc` / u_mp_beam |
| present_npx_path | `present_npx_path` / u_mp_npx |
| present_video_timing_720p | `present_video_timing_720p` / u_mp_timing |

Any of these **MISSING or below min** → void multi-pixel claim (w-clock owns fix).

### What VOID looks like (do not deploy)

- `plex_chrome: MISSING`
- `M10Ks=0` and `block_bits=0` (c74c6863)
- `registers=0` or `comb_aluts=0` with entity present
- map.rpt `list_a … Stuck at GND`

---

## 3. ARM-out arm (glass) — stop daemon by **PID**

```bash
# 1) Confirm fabric RBF loaded (PLEX_FAB_IDLE=1), video_mode=0 already set
scripts/hdmi_capture_idle.sh docs/agent-evidence/fab-idle-t0.png
sleep 3
scripts/hdmi_capture_idle.sh docs/agent-evidence/fab-idle-t1.png

# 2) ARM-out — PID only (killall banned)
ssh root@$MISTER_HOST 'pidof misterplexd'    # note PID, e.g. 1234
ssh root@$MISTER_HOST 'kill 1234'            # specific PID
sleep 2
scripts/hdmi_capture_idle.sh docs/agent-evidence/fab-idle-nodaemon-t0.png
sleep 3
scripts/hdmi_capture_idle.sh docs/agent-evidence/fab-idle-nodaemon-t1.png
```

### PASS (daemon dead) — all must hold

| Metric | PASS | vs control (`d1b24e0c` mode0) |
|--------|------|-------------------------------|
| CYAN_PX | **≥ 2000** | control **0** |
| ORANGE_PX | **≥ 500** | control 12889 (fabric may differ) |
| MEAN | **12..80** | control 14.4 |
| ACTIVE | **> 923×717** toward 1280-class | control 923×717 |
| Motion | t0 vs t1 chevron/ACTIVE shift | control static ARM |
| CYAN ∧ ACTIVE | **agree** | mismatch → investigate |

### Partial results (not full PASS — name them)

| Observation | Meaning |
|-------------|---------|
| CYAN≥2000, ORANGE≥500, **motion frozen** (t0==t1) | Fabric painted **one static frame** or phase stuck — **not** vsync screensaver. Partial: sig+canvas live, phase dead. |
| CYAN≥2000, ORANGE=0 | Signature only; chevron path broken |
| ORANGE high, CYAN=0, motion | **ARM still painting** or wrong macro — fail |
| CYAN≥2000 then black after kill | Was dual-painter; fabric died without daemon — fail |
| Hierarchy PASS, glass CYAN=0 | Elision of **function** despite rows, or macro OFF, or wrong RBF — void glass claim |
| Hierarchy FAIL, glass looks good | **Do not trust** — possible ARM residual / wrong interpretation |

---

## 4. Negative test you can actually fail (ARM still alive)

**Purpose:** prove the contract goes RED when fabric path is broken but daemon still paints.

### N1 — Wrong core (control RBF) with FAB_IDLE expectations

```bash
# Load d1b24e0c (no PLEX_FAB_IDLE) while video_mode=0, daemon running
scripts/hdmi_capture_idle.sh docs/agent-evidence/neg-control.png
# MUST score:
#   CYAN_PX=0  (measured control)
#   ACTIVE≈923x717
# If your scorer says PASS on this frame, the scorer is broken.
```

**Expected RED vs fabric contract:** CYAN&lt;2000 (actually 0).

### N2 — Integration RBF with macro OFF (if you built dual RBFs)

Same capture on macros-at-reset RBF: must match control class (CYAN=0), not fabric PASS.

### N3 — Post-fit mutation (offline, no device)

```bash
# Already in unit: test_plex_chrome_elision_guard.sh RED-C zeros M10K/bits → rc=1
tests/unit/test_plex_chrome_elision_guard.sh; echo "true rc=$?"
# Must be true rc=0 for the *script* (internal reds expected rc=1).
```

### N4 — Kill daemon on control core

```bash
# d1b24e0c + kill misterplexd by PID
# Expect: idle freezes or goes black / last frame — NOT cyan motion
# If CYAN appears with control core, capture chain is contaminated.
```

---

## 5. Deploy order (parent)

1. `make post-fit-fab-idle FIT_RPT=... MAP_RPT=...` → rc=0  
2. If multi-pixel in fit: `make post-fit-multi-pixel ...` → rc=0  
3. ONE `DEPLOY_LOAD=menu`  
4. Glass: t0/t1 + ARM-out by PID  
5. Publish numbers; if CYAN and ACTIVE disagree, publish both and hold GREEN

Soft-skip ≠ PASS. Hierarchy PASS ≠ glass PASS.
