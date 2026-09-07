# Coherent H.264 V13 — reviewed experimental source

**Source review only. Not physically fitted, timing-qualified, deployed, or
accepted for playback.** This directory does not replace the repository's
canonical FPGA tree.

## Exact reviewed change

V13 source ID:
`439200e0923d1756538825621e7ee5bab1f475bc9ce1287cf2ba3e8c16bcdc01`

Release manifest:
`574e670fa6446bf2d853da5c18cd54a5f2bc3483adf1aade1a881db183a6166b`

Source archive:
`a21e30d3d4ef11a6a7db7f473957ef705df752294f2584c672f1906c0f95a4be`

Independent review found **no significant source correctness issues** in the
exact two-file delta from V12 `a793593b` / archive `07ff4fa4`. The complete
149-source/150-effective maps were verified. The review receipt is pinned in
`source-publication.json`; it does not approve physical execution or deployment.

- `h264_cavlc_residual.sv`: registered, nonwrapping placement prefix sums and
  destination validity before the existing coefficient scatter.
- `h264_dpb.sv`: accepted-request row/column context replaces division/modulo in
  the reference-address path; backpressure and cancellation ownership remain.

`critical-cones.patch` is the unchanged reviewed delta against the frozen V12
source, **not a patch against the development branch's canonical files**.

## Why this is isolated

At public base `4fc20531`, the canonical FPGA tree matches only 126 of the
149 frozen V12 members; 20 differ and 3 are absent. Its CAVLC and DPB preimages
are different cohorts. Overwriting two canonical files would mix those cohorts
and discard existing branch work.

Following the existing experimental-directory convention, this directory
contains the two exact V13 leaves, four unchanged direct RTL dependencies, and
fourteen frozen direct leaf-validation source dependencies. Each copied file
has an origin member and hash in `source-publication.json`.

The complete core source/input archives, maps, full-picture results, validation
archive, fixture hashes and bound independent review are retained in the private
engineering recovery package. This focused public project is **not** a complete
ready-to-fit MiSTer core.

## Source-level validation

The included tests are unchanged files from the frozen V13 validation archive:

```sh
cd experimental/coherent-v13/project
bash tests/unit/test_h264_cavlc_timing.sh 1 2 3
bash tests/unit/test_h264_inter_reference.sh
```

They use generated coefficient/pixel vectors and the frozen renamed V12 CAVLC
reference; no library media is supplied. The wrappers require Verilator and a
C++ toolchain and create ignored local `project/build/` outputs. In the shared
lab, obtain a fresh serial RTL-work grant before running them; publication does
not provide that grant.

The preserved owner results report 10,548 paired CAVLC blocks, 38 picture
checks, and 48 additional DPB boundary/cancellation cases with original
correctness budgets. Those results were not rerun by the publisher. Publication
validation checked exact archive/member/patch identities, source dependencies,
and shell syntax; no simulation, build or physical operation was performed.

## Unresolved physical and product limits

V13 area and timing are unmeasured. V12 fails setup in all four models; its
RBF `58ecc69f` remains **UNAPPROVED_DO_NOT_DEPLOY**. DDR/HDMI routing failures
remain unresolved; retain zero-logic/top-level/self paths in timing evidence.
The failed timing-observer/gate release needs separate review and repair.

No clock/constraint relaxation, precision/feature reduction, new capability,
24-fps/A-V claim, or deployment permission follows from this source publication.
