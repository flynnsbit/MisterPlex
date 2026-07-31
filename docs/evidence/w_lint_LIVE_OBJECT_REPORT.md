# w-lint LIVE OBJECT / DECOY family — gate integrity report

**Branch:** `w-lint-gate-integrity`  
**Base before this land:** `7acfbe54`
**Land SHA:** `7bbb0815`
**Lane:** GATE-INTEGRITY (w-lint)  
**Scope:** host/static only — no device, no Quartus  

## Parent defects addressed (2026-07-31)

| ID | Defect | Fix |
|----|--------|-----|
| INSTANCE 1 | Boot hook gated on DECOY `_user-startup.sh`; S99user runs `user-startup.sh` only | `boot_hook_policy.sh` LIVE default + `boot_hook_check_live_and_decoy`; promote/rollback/deploy target LIVE |
| INSTANCE 2 | Motion `elif` after idle; `PROMOTE_AUTO_CAPTURE=1` made motion dead code | Visual aggregate: idle + motion both run; never exclusive elif |
| Conf-keys | `PROMOTE_REQUIRE_CONF_KEYS` printed NOTE and never touched `rc` | FAIL closed `rc=3` unless conf blob/path injected or explicit `PROMOTE_REQUIRE_CONF_KEYS=0` |
| MENU frame | `postboot.png` (CORENAME=MENU color bars) passed idle envelope | `menu_color_bars` class: low within-row std + high row_mean_spread → rc=8 |

## Live-object rule (reusable)

`scripts/live_object.inc.sh`:

- A check may **PASS** only if it inspected a **live** object: `/proc/<pid>/exe`, `/proc/<pid>/cmdline`, HTTP 200, or captured pixels.
- Where live identity cannot be established → **RED**, never skip/NOTE-as-pass.
- Soft-skip **77** and **UNSCORED** are never success.

## Gate enumeration (promote / pair path)

| Check | Object inspected | Green while broken? |
|-------|------------------|---------------------|
| product core md5 | on-disk RBF path | **yes if alone** — fabric identity still UNVERIFIED without PLXC; pair matrix + visual required |
| v2 rollback core md5 | on-disk Plex_v2.rbf | yes if alone (shape-asserted 32-hex) |
| n_daemon | `/proc` basename(exe)==misterplexd | **no** (not cmdline; flock excluded) |
| live-exe-md5 | `readlink -f /proc/PID/exe` | **no** |
| live-conf | `/proc/PID/cmdline --conf` | **no** (not assumed path) |
| conf-keys DDR | conf blob/path content | **no** — missing inject → FAIL rc=3 (was NOTE) |
| http /resources | live HTTP | empty=NO-DATA rc=4; non-200 FAIL |
| live-pair-compatibility | live core md5 + live exe md5 matrix | catches SPI+DDR green-screen class |
| boot-hook LIVE | **LIVE** `user-startup.sh` body | decoy-only → `decoy_ok_live_bad` RED |
| boot-hook decoy | `_user-startup.sh` (informational) | cannot PASS gate alone |
| visual idle | captured pixels + envelope + menu_color_bars | MENU bars RED; uniform/green RED |
| motion | `hdmi_motion_instrument` when set | **now runs even if idle present** |
| running bitstream PLXC | doorbell+0x130 (when RBF has identity) | pre-identity `c5382bee` → UNVERIFIED (fail-closed if `VIDREG_REQUIRE_CORE_ID=1`) |

### Blind-and-green (historic → fixed this land)

1. **Decoy boot file** — `BOOT_HOOK_OK` on `_user-startup.sh` while LIVE still v1/`54f1d916`. Fixed: LIVE path only; decoy_ok_live_bad.
2. **Unreachable motion** — `elif` after idle. Fixed: aggregate both instruments.
3. **Conf-keys NOTE** — could not fail. Fixed: FAIL rc=3.
4. **MENU idle** — color bars inside mean envelope. Fixed: `menu_color_bars`.

### Blind-but-honest (still true; not green)

- On-disk RBF md5 without PLXC / visual: printed pair OK is **not** fabric proof; visual HARD; identity UNVERIFIED until PLXC RBF.
- `GATE_SKIP CRITICAL live-pms-baseline-profile` / `core_conf_geometry` rc=77: coverage gaps, never aggregate PASS.

## Red-before-green (measured, direct `true rc=`)

| Case | Fixture / inject | true rc |
|------|------------------|---------|
| LIVE v1 + decoy v2 | `tests/fixtures/gate_integrity/boot/*` | **1** (`decoy_ok_live_bad`) |
| bak.20260731T204811Z class | v1 LIVE body | **1** |
| MENU `postboot_menu.png` | fixture copy of archived MENU frame | **8** `menu_color_bars` |
| conf keys missing | SPI conf + ddr profile | **3** |
| motion + idle both | motion 77 with idle OK | motion still invoked; aggregate **8** when required |
| full green path | blob + conf + LIVE hook + visual | **0** `PROMOTE_GATES_OK` |
| glue V2_MD5 | historic contaminated blob | **3** + visual still ran |

### Suite rcs (this land)

```
test_live_object_integrity.sh     true rc=0  pass=26
test_live_object_static_guard.py  true rc=0
test_boot_hook_policy.sh          true rc=0  pass=20
test_promotion_gates.sh           true rc=0  pass=66
test_rollback_honest.sh           true rc=0
test_harness_capture_integrity.py true rc=0
test_pipe_rc_trap.py              true rc=0
test_gate_false_green_guard.py    true rc=0
test_unit_rollcall.py             true rc=0  expected_commands=119
```

## Soft-skip / never-ran policy (unchanged, enforced)

- rc=77 / UNSCORED ≠ pass (harness + promote: motion 77 → visual HARD 8 when required).
- Verilator `PINNOTFOUND`/`%Error` → `run_verilator.sh` rc=2 (guarded by `test_gate_false_green_guard.py`).
- Pipe-rc trap lint: `test_pipe_rc_trap.py` scans scripts/tests.

## Parent actions after merge

1. On device: ensure **LIVE** `/media/fat/linux/user-startup.sh` (not only underscore) points at v2 supervise for DDR pair.
2. Promote claims: require motion and/or warm-up idle (`scripts/capture_hdmi_frame.sh`); bare `-frames:v 1` is defective.
3. `PROMOTE_CONF_BLOB` or live conf required for DDR conf-keys.
4. Do not treat green non-visual as running-bitstream proof until PLXC identity RBF + `VIDREG_REQUIRE_CORE_ID`.

## Pins (reference)

- DDR pair: core `c5382bee…` + daemon CURRENT `edc3a46b…` (PREV `e9f79de2…`)
- SPI daily: `dfebf2bf…`
- `spi_daemon_md5_accepted` must **not** include CURRENT DDR daemon
