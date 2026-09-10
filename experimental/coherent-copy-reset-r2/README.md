# Coherent copy/reset R2: reviewed experimental FPGA source

This is a **source-only experiment**, not a bitstream, activated default or
playback release. It publishes the reviewed actual-SYS20/SYS85 source family,
the later RGB-retention-only test correction, and independently qualified
R3 timing-tool runtime. Canonical FPGA files, root tools, shipping defaults,
earlier experiments and activation paths are unchanged.

## Select a complete cohort explicitly

| Cohort | Actual SYS selection | Native-copy pipeline | Source / build ID | Effective input |
| --- | --- | --- | --- | --- |
| `sys20-default` | 20 MHz | **off** | `ffcb6cf7` | `be3081d7` |
| `sys20-pipeline` | 20 MHz | explicit opt-in | `5ab65619` | `b4dabf62` |
| `sys85-default` | 85 MHz | **off** | `60fb6250` | `f59a79dd` |
| `sys85-pipeline` | 85 MHz | explicit opt-in | `4bef165d` | `ae6af0d1` |

Each `cohorts/<name>/` contains all **156 exact plain source members** at
`project/fpga/Plex_MiSTer`, its complete original `source.tar`, and the separate
**157-member effective** `inputs.tar`, `inputs.json` and original member maps.
Full identities and exact active QSF macros are in `source-cohorts.json`.
These are product PLL/profile selections, not a control20-only test clock.
The actual clocks and reset distribution still need independent physical
qualification.

The effective inputs apply the normal source-derived `FPGA_VIDEO_BUILD_ID`,
freeze `sys/build_id.tcl` to date **260906**, and include `build_id.v`.
Those ordinary changes are not overlaid onto plain source. A fresh date-based
snapshot is not an exact replay. Original `inputs.json` intentionally records
`git_commit: null`, ancestry `5715891c6db606c7ba1385929a6e0f6bc4edbbcc`,
and the source-preparation/normalization driver identities. None denotes this
public commit or replaces the operational tool binding below.
Full-input digests are computed from full original member sets, never subsets.

Original source release manifest:
`8c9ca88c845cf8dd2147f2f4d0bb192478f52f8440c54e71c06508b5acfa10a7`.
Source correction review:
`51589408987159d4a072cd1917f86d3cd78d626d0ccda7980ecd524330e21382`.
Later merged source/execution review:
`485fa0e09ba744e07b5b62c9fbf00dc09221df890754f7a55b7b1bf42b0c0a33`,
**APPROVED_MERGED_SOURCE_AND_EXECUTION_WITH_ACCOUNTING_LIMITATION**.
Creation-time pending labels in the exact original metadata remain historical;
the later review does not turn them into routed or playback approval.

## Support and correct timing-tool binding

`support/project/` contains 98 exact executed support members. Copy it beside
one explicitly chosen cohort's `fpga/` directory only in a **new, separately
authorized writable workspace**. The two public support archives are explicit
98-of-100 subsets: prepared support and executed support remain distinct.
The only difference is `tests/rtl/fpga_video_publish_tb.cpp`, whose exact
`test-runtime-retention.patch` retains actual native RGB24 and accepted legacy
RGB565 without changing product logic, model ticks or prior assertions.
`test-support-correction.patch` and each cohort's correction patch preserve
the earlier source/test correction.

Use **`tooling/qualified-r3/scripts/rbf_build.py`**, SHA-256
`7fa758c029e00b444ff8c76695a659bac092459b6c8c5feac2d487356f45f796`,
not the root driver, the historical `8166ff88` source-enumeration helper at
`support/project/scripts/rbf_build.py`, or the original R4 compile driver.
The historical helper is preserved for reviewed imports/enumeration only;
its build CLI is not an operational alternative or an authorization.

The actual admitted R3 source identity is
`dc6b27310d5257a91e391479b5b86c99f5fe18901ae4b0fc2af1a0212bee2e1c`,
from original archive
`3df12acb1f3b45e76673adef235b63bb5527b380c803c4f11a9dd5d98198f057`
and manifest
`89ae46b5b152ae50a8f7abd536d46ca4d17813c74bdb9e7b95f44e5585f80f91`.
Qualification
`6ba196e804a003710e97d3155c79c6412ba9e8c54d077e4838582be4665d78f9`
uses **genuine prior R5r2 SDK captures plus exact R3 component equivalence**:
three host-summary/test/documentation changes and 22 unchanged SDK/gate
members. It is **not a new R3 SDK run**. Original R4 compilation used
`0be637cc`; later SDK analysis used `7fa758c0`. Those identities stay separate.

`build-tool-binding.json` binds the complete sibling dependency set and required
policies. In particular, `tests/fixtures/critical_fit_hierarchy.json` and
`tests/fixtures/timing_exclusion_baseline.json` are **runtime build policies**,
not disposable captured fixtures. They and the historical rejected-image
hash gate remain byte-exact. No policy, gate or product behavior was edited.

For future **separately authorized** work:

- Select the backend and an explicit writable project; the driver's default
  project relative to its isolated tool root is not this cohort.
- Replay the chosen `cohorts/<name>/inputs.tar` with its adjacent original
  `inputs.json` and `source.tar`; do not regenerate its source ID/date.
- Use licensed Quartus 17.0.2 Build 602 and pinned image
  `sha256:1fba8b9347973365e9f7851d73f7cb035e38fefb827cbf0ed2ea291b48bdf6dd`,
  a separately qualified reference, and exclusive resource ownership.
- Preserve the qualified **read-only frozen reporter** mount and **SDK-side
  Python `-B` / no-bytecode** invocation. Host-side `-B` alone is insufficient.
  The earlier writable-sidecar failure is not an approved invocation template.
  Do not edit frozen runtime code to work around the invocation contract.

No build, test, SDK or hardware operation was performed to publish this tree.
No reference RBF, auto-deployment or automatic restore target is supplied.

## What the admitted execution means

The later execution used eight guarded RTL batches and four complete A&S
command/report records on the unchanged four cohorts. Twenty-six ordinary
reference-YUV model pictures matched. Both painters, retirement/readback/error
and ownership fences, shared R2 latency2/II2, P/reference/deblock, default
8 KiB AU with separate VCL limit, R3/E1FF and native DAR remain preserved.

For the identical full240 shared-R2 model workload, SYS20 pipeline copy work
saved **117299 / 117359 / 117342 cycles**, about **5.87 ms at 20 MHz**.
Checker-paced display intervals remained **1671560 cycles**. These are
copy-to-final-accept savings, not end-to-end FPS or copy-to-feedback claims.
`execution-summary.json` and its exact scalar projection map preserve the
distinction; raw logs, media, binaries and per-frame payloads are absent.

Reset minima **50.004 ns / 11.768 ns** are model witnesses, not physical pulse
distribution, recovery/removal or sink-width proof. The **81920-bit / 96-M10K**
source floor and A&S estimated ALMs **38330 / 38432 / 38286 / 38476** are not
routed allocation. Unsupported I4 remains unsupported. Original timing,
reader, HDMI, reset, image identity, all-corner policy closure, real LAN Plex
Web casting, full240p/24fps, EOF/tail and clean-audio obligations remain open.
The old SYS20 wrong-50ns metadata and its defects are historical evidence,
not silently repaired or backdated admissions.

### Invocation-accounting limitation

Four complete A&S commands/reports corresponded to **20 observed map ELF
processes, including 16 children**. Twelve child IPC argument vectors were
retained directly; the first four were not, and no exec-event trace exists.
The initial five-process charge and later complete-command reclassification
are both preserved in the reviewed accounting history. **Strict compliance
with the old six-invocation limit is not claimed.** There is no retroactive
waiver and no admission or operational publication of the private execution
orchestrator.

## Omissions, portability, licensing and integrity

`original-members.json` accounts for every member of all eight original
product archives, both original 100-member support archives and the original
25-member R3 archive, with exact byte hash, type, mode, destination or omission.
`public-file-map.json` covers every public file except itself; Git's subtree
binds that map. `publication-checks.json` records host-only archive/member,
mode, full-input, projection and dependency integrity, **not executed tests**.
Git normalizes archive read-only modes to 0644/0755; original modes remain
in original archives and the maps.

R3 public source is an explicit **22-of-25 subset**, not the complete original
archive. Three capture-derived JSON fixtures are omitted; the pure synthetic
Tcl mock, unit-test source and all build policies are retained. Some timing
unit suites therefore need separately supplied omitted fixtures. Likewise,
codec/ingress/full240 support needs omitted validation data and whole-top
tests need licensed vendor declarations. Historical baseline tests may need
their separately retained original inputs. Neither subset is advertised as a
newly executed or entirely self-contained portable test suite.

The two private preparation helpers, raw receipts/grants/registries/handoffs,
absolute lab/runtime metadata, browser/configuration/credentials, raw
execution/SDK archives, media, logs, ELFs, databases and vendor simulation
libraries are not published. Current independently owned SDK work is excluded;
source recovery is not its ingestion, clock/SDC, routed or image qualification.

All per-file copyright and license notices are unchanged. `licenses/` preserves
the existing GPL-2.0 and GPL-3.0 texts, including GPL-3.0-or-later obligations.
Existing Intel-generated project RTL keeps its original notices; no licensed
SDK or simulation-library redistribution is asserted.
