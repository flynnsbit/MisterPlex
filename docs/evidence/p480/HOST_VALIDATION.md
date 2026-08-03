# p480 host validation

**SOURCE_SHA at authoring tip parent:** see `git log -1` on branch `w-arm-p480-measure`  
**Date:** 2026-07-30

## harness `--self-test`

```text
SELF_TEST_CPU_MATH_OK P=25.0 exited_thread_accounted P=20.0
SELF_TEST_PARSE_OK
P480_AB_RESULT=SELF_TEST_OK
```

Captured: `p480_ab_selftest_20260730T164236Z.{json,kv.txt,table.txt}`  
Command: `./tests/hw/test_p480_ab_harness.sh --self-test; echo true rc=$?` → **rc=0**

## make unit

| Step | Result | Evidence |
|------|--------|----------|
| Outer preflight | REFUSED while local `quartus_map` live | correct exclusive-slot behavior |
| `MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1 make unit` | suite ran | `make-unit-override-quartus-present.log` |
| `test_no_private_data` | **OK** | log line after redacting sibling tracked PMS `*:32400` → `YOUR-PLEX-SERVER:32400` |
| Final suite fail | `test_resource_preflight.sh` swap-exhausted fixture **got rc=0 want rc=3** under OVERRIDE | environment interaction with concurrent Quartus + override; **not** a harness/product regression |

Honest status: full green `make unit` without override was **not** obtained while Quartus occupied the host. Product tests through `test_no_private_data` / capture-rig completed OK under override before the preflight fixture fail.

## w-device invocation (this lane has no device access)

```bash
# A/B same clip — force coded tier via conf (OSD_CONTROL=0 for window)
PLEX_KEY=/library/metadata/N WINDOW_S=60 SETTLE_S=20 \
  ./tests/hw/test_p480_ab_harness.sh --both

# Single tier
TIER=480p PLEX_KEY=... ./tests/hw/test_p480_ab_harness.sh

# Optional host HDMI sustained A/V (reuses tests/hw/avsync_rate.py)
HDMI_AVSYNC=1 PLEX_TOKEN=... PLEX_KEY=... ./tests/hw/test_p480_ab_harness.sh --tier 240p
```

DDR fill both tiers (no SPI): see `p480-bandwidth.md` §6 (`run_c2_ddr_bench.sh` WIDTH/HEIGHT matrix).

Records land in `build/p480/p480_ab_<tier>_<stamp>.{json,kv.txt,table.txt}`.
