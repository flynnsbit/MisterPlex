# RTL simulation

MiSTerPlex has a userspace Verilator path for behavioural RTL checks before paying for a Quartus fit. The default local install is outside the repo:

```bash
export OSS_CAD_SUITE="$HOME/.local/oss-cad-suite"
scripts/run_verilator.sh --version
```

Do not source `~/.local/oss-cad-suite/environment` globally and do not prepend the suite to your login `PATH`; that can shadow normal host/Quartus tools. `scripts/run_verilator.sh` scopes `PATH="$OSS_CAD_SUITE/bin:$PATH"` to the single Verilator process only. The unit harness uses that wrapper, which checks `$VERILATOR`, then `$OSS_CAD_SUITE/bin/verilator`, then `verilator` on the existing `PATH`.

## Built-in H.264 IQ/IDCT/recon simulation

Run just the RTL sim:

```bash
make rtl-sim
# or
VERILATOR=$HOME/.local/oss-cad-suite/bin/verilator tests/unit/test_p3_idct_rtl_sim.sh
scripts/run_verilator.sh --version
```

`make unit` invokes the same script. If Verilator is absent it prints a loud `SKIP RTL SIM` notice and exits 0 so non-simulator hosts keep their host tests usable; that skip is not a hardware-quality pass.

The current test elaborates `fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv` with Verilator and drives all 16 luma 4x4 blocks from `tests/fixtures/p3_host_recon/mb0_luma_v1.json`. It compares actual RTL `dequant`, `idct`, and `recon` outputs against the checked-in golden JSON.

## Simulating another module

Create a C++ testbench under `tests/rtl/` that includes the generated `V<top>.h`, drives ports, calls `eval()`, and checks outputs. Then run:

```bash
ROOT=$PWD
TOP=my_top_module
mkdir -p build/verilator/$TOP
scripts/run_verilator.sh --cc --exe --build \
  --Mdir build/verilator/$TOP \
  --top-module $TOP \
  -CFLAGS "-std=c++17 -O2" \
  fpga/Plex_MiSTer/rtl/my_top_module.sv tests/rtl/my_top_module_tb.cpp
build/verilator/$TOP/V$TOP
```

For multi-file RTL, list every required `.sv` on the Verilator command line or use `-f filelist.f`. Keep generated outputs under `build/verilator/`.

## Whole-project RTL lint baseline

Run the Verilator parse/lint gate without starting Quartus:

```bash
make rtl-lint
# or update the checked-in baseline intentionally after triage:
scripts/rtl_lint.py --write-baseline
```

`rtl-lint` parses `fpga/Plex_MiSTer/Plex.qsf` plus sourced `.qip`/`.tcl` assignments, injects the active Quartus product macros into Verilator, runs Verilator on owned RTL, and reports only warnings physically located in MiSTerPlex-owned sources. Vendor/generated context (`sys/`, `rtl/pll/`, Intel primitive stubs) is excluded from the ranked counts so it does not bury project warnings. This is not a Quartus synthesis/buildability check.

The checked-in baseline is `tests/fixtures/rtl_lint_baseline.json`. Existing `WIDTHTRUNC`, `WIDTHEXPAND`, `WIDTH`, `UNSIGNED`, and `IMPLICIT*` counts are allowed; any count above baseline fails. The baseline stores both per-file/type counts and `warning_details` entries with line/message text so a diff shows which warning moved or appeared. `make unit` runs this gate after the RTL simulations. If Verilator is absent, the target refuses with `RTL LINT REFUSED(exit=3)` rather than silently passing.

Run the curated Quartus subset guard before requesting a full fit:

```bash
make define-parity
make quartus-sv-subset
```

`define-parity` prints the raw Quartus/Verilator macro table and refuses if the
product Quartus macro set diverges from the Verilator/lint macro set. Test-only
fault macros are accepted only when declared in
`tests/fixtures/define_parity_allowlist.json`.

`quartus-sv-subset` first proves a real Quartus toolchain is reachable, then scans the product Quartus file list for observed Quartus 17.0.2 SystemVerilog subset hazards that Verilator accepted: function-result part-selects, the observed `ref_win[...]` function-body concatenation pattern, and `localparam` declarations in module parameter lists. If Quartus is absent it refuses with `QUARTUS_SV_SUBSET_REFUSED(exit=4)`. This is still a static curated guard, not Analysis & Elaboration; unsupported inference, generate/parameter scoping, latch inference, and other elaboration-only Quartus failures can still reach a fit unless caught by a real Quartus analysis pass.

After a remote fit, run the hierarchy resource guard against copied Quartus reports:

```bash
make post-fit-hierarchy FIT_RPT=fpga/Plex_MiSTer/remote_out/<slot>/Plex.fit.rpt \
  MAP_RPT=fpga/Plex_MiSTer/remote_out/<slot>/Plex.map.rpt \
  COMPILE_LOG=fpga/Plex_MiSTer/remote_out/<slot>/compile.log
```

`post-fit-hierarchy` prints the fitted hierarchy resources for critical modules
declared in `tests/fixtures/critical_fit_hierarchy.json` and refuses if one is
missing, optimized down below the declared resource floor, or has removal/tie-off
warnings in the compile log. `scripts/build_rbf_remote.sh` copies the map report
and compile log and runs this check automatically. Both build backends also run
timing/exclusion checks against the captured source, the available RBF hash-ban
gate, and the required reference comparison. These are build gates, not product
acceptance or permission to deploy.

The timing gate checks both the standard STA summary and **every indexed
setup/hold report across every captured clock/corner**. For a retained slot:

```bash
slot=fpga/Plex_MiSTer/local_out/your-slot
python3 scripts/check_quartus_timing.py --sta-rpt "$slot/Plex.sta.rpt" \
  --paths-dir "$slot/timing" --require-scoped
```

Detailed artifacts must match their index, completion summary, hashes, original
input/image provenance, reporter, and retained RBF. Only the explicit Quartus
`Report Timing` / `Nothing to report.` format counts as a legitimate zero-path
clock; empty, missing or malformed summaries refuse. Negative worst-case slack
or a nonzero violated-path count rejects, including extra corners absent from
the standard summary. This check runs **after artifact collection**: rejection
retains the RBF and timing evidence, does not rewrite their manifests, and does
not create `result.json`. Existing domain-coverage and exclusion checks remain
required.

New builds require the v2 timing sidecar. Alongside the global top-ten reports,
it reports the single worst setup/hold path per destination clock in both
directions of the decoder keeper scope (`mb_ctrl`, `rbsp`, and `stub`, including
their descendants). A complete from/to matrix is required for every operating
model, including explicit zero-path reports for unused clocks. Older global-only
bundles remain readable without `--require-scoped`; that does not qualify them
under the new build gate.

The sidecar observes the original SDC setter calls without replacing them. It
retains source locations, substituted commands, resolved endpoint/clock-group
membership, completion codes, and per-model used/ignored SDC and exception
reports. The exclusion gate binds execution coverage to frozen SDC source
hashes, distinguishes unsourced optional files from active ones, and rejects
explicit decoder exclusions. Implicit all-keeper directions are recorded as
implicit, not fabricated explicit endpoints. Unsupported or incomplete
collection/source evidence refuses rather than weakening the gate.
`write_sdc -expand` documents macro expansion, not wildcard endpoint expansion;
Cyclone V clock-group coverage uses resolved membership, not the Spectra-Q-only
clock-group path-report option.

The immutable reporter bundle includes its Python collector and shared STA
parser. Local and standalone SSH workers execute that collector in an isolated
Python process, avoiding mutable working-tree imports. Timing and effective
exclusion gates both run before either failure is returned, while frozen sources
are still available. Neither gate may alter the RBF or approve failed timing.

The existing build-policy suite can optionally exercise the Tcl sidecar in an
empty child interpreter using an already installed Quartus Tcl host:

```bash
MISTERPLEX_TIMING_TCL="quartus_sh -t" \
  python3 -m unittest discover -s tests/unit -p test_rbf_build.py
```

All netlist APIs in that fixture are mocks. It does not open a real timing
netlist, run a fit, or establish hardware acceptance.

Native Quartus multicorner headings such as
`Slow 1100mV 100C Model Setup Summary` and `Fast 1100mV -40C Model Hold Summary`
share the same parser as legacy unlabelled summaries. Model labels are retained
on slack and Fmax rows; malformed/truncated tables or missing tables declared in
the report contents refuse. The exclusion/clock-coverage gate uses those same
parsed rows and applies its existing clock names and minimum row floor to each
reported model, not just their union. Expected clock identifiers remain exact
matches, not implicit substring aliases.

### Serial, snapshot-only RBF builds

Only the designated lab operator may run these commands. `scripts/build_rbf.sh`
**still refuses by default** (exit 3); merely exporting
`MISTERPLEX_ALLOW_LOCAL_FIT=1` does not select a backend. The remote entrypoint
remains supported:

```bash
scripts/build_rbf_remote.sh slot-a
# Equivalent explicit dispatcher:
scripts/build_rbf.sh --backend remote slot-a
```

An approved local fit needs **both** explicit backend selection and the existing
local-fit permission. This backend directly uses the installed Docker image,
not a missing local `misterfpga-dev` checkout:

```bash
MISTERPLEX_ALLOW_LOCAL_FIT=1 \
MISTERPLEX_BUILD_REFERENCE_RBF=/path/to/approved/reference/Plex.rbf \
scripts/build_rbf.sh --backend local-container slot-a
```

The default local image is `ghcr.io/raetro/quartus:mister`; the inspected lab image
is `sha256:1fba8b9347973365e9f7851d73f7cb035e38fefb827cbf0ed2ea291b48bdf6dd`.
Its `/usr/bin/quartus-entrypoint` executes the supplied command, and its PATH
resolves `quartus_sh` to `/opt/intelFPGA/quartus/bin/quartus_sh`. The wrapper
inspects the installed image, pins that immutable image ID for the transaction,
and runs `quartus_sh --flow compile Plex.qpf` at `/build`, with the existing
container entrypoint and invoking UID/GID. It does not pull/install tools.
`MISTERPLEX_QUARTUS_IMAGE` is an explicit local image selection, not an automatic
fallback. Remote builds still source `MISTER_REMOTE_DEV/scripts/lib.sh`,
`load_env`, and `QUARTUS_IMAGE` (default dev directory:
`<remote-home>/misterfpga-dev`; default SSH host: `docker`).

Do not run Verilator/unit suites concurrently with a local fit: memory pressure
can produce false decode failures. The resource preflight is not bypassed.

#### New candidate: two serial fits of identical captured inputs

With approval for a configuration having no reference, the first candidate may
be explicitly unverified. Replay **its archive**, not the live worktree, for the
second fit:

```bash
MISTERPLEX_ALLOW_LOCAL_FIT=1 MISTERPLEX_BUILD_ALLOW_UNVERIFIED=1 \
scripts/build_rbf.sh --backend local-container p0-a

MISTERPLEX_ALLOW_LOCAL_FIT=1 \
MISTERPLEX_BUILD_REFERENCE_RBF="$PWD/fpga/Plex_MiSTer/local_out/p0-a/Plex.rbf" \
scripts/build_rbf.sh --backend local-container p0-b \
  --snapshot "$PWD/fpga/Plex_MiSTer/local_out/p0-a/inputs.tar"
```

For remote candidates use `MISTER_REMOTE_ALLOW_UNVERIFIED=1`, then
`MISTER_REMOTE_REFERENCE_RBF=.../remote_out/p0-a/Plex.rbf` with
`scripts/build_rbf_remote.sh p0-b --snapshot .../remote_out/p0-a/inputs.tar`.
An optional positional project directory is supported by both entrypoints.
Fresh slot names are required; existing artifacts are never silently replaced.

`source.tar`, `inputs.tar` and adjacent `inputs.json` are the replay unit.
`source.tar` is the immutable original; `inputs.tar` is the rendered compile
input. Replay rejects an image-ID mismatch, altered archive, or processor
override. The QSF seed and
`NUM_PARALLEL_PROCESSORS` remain unchanged (the pinned base uses seed 6 and two
processors). The legacy remote processor override still requires
`MISTER_REMOTE_ALLOW_PROCESSOR_OVERRIDE=1`; it alters **only a new snapshot**,
records different source/effective-input hashes, and cannot be applied to a
replay. Do not edit replay metadata to force unlike builds to compare.

The existing MiSTer `build_id.v` is a **legacy OSD date header**, not the FPGA
video capability ID. The wrapper never imports a generated/simulation copy of
that file into the original source snapshot. Instead it captures the pinned
image's current `YYMMDD` date using a shell-only probe, generates `build_id.v`
inside the rendered inputs, and replaces the wall-clock expression in the
**snapshot copy** of `sys/build_id.tcl` with that same frozen date. The existing
pre-flow then finds identical header contents and does not modify the read-only
input. This retains the usual first-build date behavior (the inspected local
image uses UTC) while making replay safe across midnight. The manifest and
`tool.json` record `legacy_build_date`; live Tcl/RTL and simulation-only headers
outside the project are untouched.

#### Opt-in FPGA video build identity

New FPGA-video ABI builds require a nonzero `VIDEO_BUILD_ID`; zero intentionally
refuses FPGA product playback. The wrappers **do not change oldbaseline defaults**.
For the new ABI, explicitly request identity rendering on the first capture:

```bash
MISTERPLEX_ALLOW_LOCAL_FIT=1 MISTERPLEX_BUILD_ALLOW_UNVERIFIED=1 \
scripts/build_rbf.sh --backend local-container abi-p0-a --derive-video-build-id

# Same opt-in for the existing remote backend:
MISTER_REMOTE_ALLOW_UNVERIFIED=1 \
scripts/build_rbf_remote.sh abi-p0-a --derive-video-build-id
```

These are alternative backend commands, not concurrent jobs. Source freeze and
an explicit lab fit grant are still required. The flag adds this assignment to
**only the rendered snapshot's** `Plex.qsf`:

```tcl
set_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_BUILD_ID=32'h<8hex>"
```

`<8hex>` is the first eight hexadecimal digits of the **original**
`source_sha256`: SHA-256 of the JSON-encoded, sorted mapping from original
relative source paths to their SHA-256 hashes (`json.dumps(..., sort_keys=True)`).
The original `source.tar` is completed and made read-only **before** deriving the
ID or rendering any processor override/identity assignment. Thus the generated
identity is never included in the digest from which it is derived: there is no
hash cycle. Zero-derived IDs and existing project assignments of
`FPGA_VIDEO_BUILD_ID` are refused in this mode.

`inputs.json` records the original `source_sha256`, original archive
`source_archive_sha256`, rendered `input_sha256`/`archive_sha256`, and eight-digit
`fpga_video_build_id`; `tool.json` also records the ID. The RTL integrator owns
mapping this macro to the `VIDEO_BUILD_ID` parameter with a zero fallback.
Neither live RTL nor live QSF is changed by the wrapper.

Replay the captured `inputs.tar` for the second fit, with its original
`source.tar` and manifest alongside it. Replay preserves the ID and both archives
byte-for-byte, even after the live worktree changes. Repeating
`--derive-video-build-id` during replay only verifies that the snapshot already
contains a derived ID; it cannot render an ID into an oldbaseline replay.
Omitting the flag on a new capture adds no define and preserves legacy seed,
processor, tool and compile-input behavior. A source-derived ID is not a
promotion approval and does not bypass RBF bans or bit-identity checks.

#### Ownership, snapshots, outputs, failure handling

* Two fixed Linux System V semaphore keys provide nonblocking host-wide
  ownership: controller key **`0x4d505843`** (`MPXC`) serializes all backend
  choices on the invoking host; execution key **`0x4d505845`** (`MPXE`) is the
  same mutex for local builds and SSH workers on the actual Docker host.
  They do not depend on Git directories, slots, remote bases, login homes, or
  Docker daemon identities. Permissions are `0666` for cross-login operation.
  There is no environment/CLI key override and **no `SEM_UNDO`**: process
  death does not silently release an unresolved transaction.
* The execution lease is acquired before snapshot/sync and held through
  compilation and collection; the controller lease covers the whole
  transaction, including validation. Docker must use a local Unix socket
  on the execution-lease host. TCP/SSH Docker contexts are refused; select
  the wrapper's SSH backend to run on another host. Existing Docker/Quartus
  process preflights remain defense for legacy flows, not substitutes for
  the atomic host mutex.
* The selected Unix endpoint is resolved **once** for the transaction. Every
  subsequent Docker command—including image/date queries, create/start,
  inspect/stop/remove and absence listings—uses an explicit `--host` bound to
  that endpoint and an environment without `DOCKER_CONTEXT`/`DOCKER_HOST`.
  Changing the default Docker context cannot redirect cleanup. The wrapper
  also records and checks the socket device/inode and Docker daemon ID before
  and after control queries. A changed socket, changed daemon, or unavailable
  identity is **uncertain**, never positive evidence that the owned container
  disappeared; inputs and ownership remain retained.
* The canonical Git `misterplex-build/single-fit.lock` and its persistent
  `.owner` marker additionally retain repository provenance. Its inode is
  never deleted. `controller-owner.json`, `execution-owner.json`, and
  `tool.json` retain transaction/container details with artifacts.
* Docker `create` captures the exact immutable container ID before
  `start --attach`. A dead or successful Docker CLI is **not** proof of a
  stopped container. The wrapper queries daemon state independently; on
  abnormal completion it stops and removes only that exact ID, then requires
  positive daemon-confirmed absence. Failed/degraded queries never mean
  “not running.” Unconfirmed execution retains the host/controller leases,
  repository marker, and extracted input tree.
* A remote worker sends a transaction-UUID-matched terminal acknowledgement
  only after confirmed container termination, collection and execution-lease
  release. Losing SSH after build dispatch—even when the local SSH process
  has exited—retains controller-wide ownership, so neither a new local fit
  nor a different remote fit can start. EOF during compilation cannot by
  itself release execution ownership.
* Unresolved leases have no timeout, PID-only reclamation, or force-unlock
  flag. The coordinator must reconcile the **exact** recorded remote
  transaction/container and establish that it cannot execute before any
  administrative recovery. A missing client PID or vanished SSH connection
  is insufficient. These kernel leases survive process death, not a host
  reboot; after controller-host reboot, reconcile outstanding remote
  transaction records before resuming fits.
* Before source copying, free space must cover an 8-GiB build reserve plus
  three times the input bytes, locally and remotely. Only git-listed,
  nonignored project source/configuration files are captured (including dirty
  and untracked source), not `db`, `incremental_db`, `output_files`,
  `remote_out`, `local_out`, `greybox_tmp`, or `build` trees. Sources must be
  self-contained inside the project; links and external dependencies are
  refused. The generated root `build_id.v` is explicitly excluded and rendered
  as described above. Stage other ignored required source explicitly before
  building.
* Capture hashes the file set before/after copying and refuses concurrent
  source edits during capture. The completed, read-only archive is independent
  of the live worktree. Original and rendered archives are retained separately.
  Compilation extracts a private clean project, never a
  live mount or hard link. Source hashes are rechecked after compilation.
  Live edits after capture cannot change the fit.
* Artifacts live in `PROJECT/local_out/SLOT/` or `PROJECT/remote_out/SLOT/`.
  `inputs.json` records source/effective-input/file/archive SHA-256 hashes,
  source Git pin, driver hash and image ID. `tool.json` records the container,
  pinned Docker endpoint/daemon/socket identities, exact command, seed and
  processor assignments. `result.json` records RBF
  SHA-256/MD5, `PASS` or `UNVERIFIED` bit identity, and `NOT_AUTHORIZED`
  promotion. An unverified candidate is never copied to `output_files`.
* Confirmed-terminal failed runs keep available archives/logs for diagnosis
  and remove extracted compile trees; **unresolved** runs preserve those trees
  and ownership as described above. Failed source capture removes partial
  archives. No result marker means validation did not finish. Remote run
  artifacts also remain under `<remote-base>/SLOT/<run-id>/`. With
  `MISTER_REMOTE_COPY_BACK=0`, reports/RBF are collected transiently for gates,
  then removed locally; reference comparison still requires copy-back.

Wrapper policy checks use isolated, test-owned IPC keys and fake independent
Docker client/container lifetimes. They do not acquire production leases,
invoke Quartus, SSH to the lab, or touch devices:

```bash
tests/unit/test_rtl_invariants.sh --build-wrappers-only
```
