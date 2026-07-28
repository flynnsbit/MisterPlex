# Handoff — W-DECODE-O5 (claude-opus-5)

**Branch:** `w-decode-o5` · **Head:** `2429514` · pushed twice to `origin`
**Worktree:** `.worktrees/w-decode-o5`
**Base:** `w-decode-hour27` (`ddb7c97`) + `w-deblock-seam` + `parent/integ-hour27` + `w-swap-o5-mc` (`4f4312b`)

---

## The one-line state

**Zero frames have ever been decoded and displayed by the FPGA. That is still
true after everything below.** `h264_decode_core` now contains real intra, real
CAVLC, real deblock writeback and real motion compensation — and it still drives
no pixels. `decode_stub` remains the sole driver of every frame-store write.

---

## 1. What I confirm from my predecessor

| Inherited claim | Verdict |
|---|---|
| `stream_path -> h264_decode_core` is THE product decoder | **Confirmed structurally.** `product_decode_core` is instantiated in `stream_path.sv`. |
| `h264_decode_top` is a leaf sub-engine `u_product_intra_mb` inside core | **Confirmed.** |
| `h264_intra_nb_ctx` is instantiated inside core | **Confirmed.** |
| `emu`-rooted reachability was inflated by `decode_stub` | **Confirmed and quantified.** `emu` reachable=50 but product_reachable was 42; the 8-module gap was `decode_stub` plus 7 stub-only MC/DPB modules. |
| The withdrawal of the overbroad MC/DPB claim | **Correct, and it was right to withdraw it.** |

## 2. What I found is NOT true

**Four inherited greens were in fact red.** All four are now fixed and each
shipped with a measured before/after.

1. **`make define-parity` was rc=1 at `ddb7c97`** — the commit that also claimed
   it rc=0. Proven in a clean detached probe worktree. `ddb7c97` added three
   `H264_INTRA_NB_CTX_FAULT_*` macros without declaring them.
2. **`tests/unit/test_stream_path_full_frame_compare.sh` was rc=1** with 46
   Verilator elaboration errors. `cd9fe29` renamed the generate block
   `gen_decode_stub` → `gen_diagnostic_present` while the testbench still probed
   the old hierarchy path in 22 places.
3. **`tests/unit/test_p3_stream_path_recon_rtl_sim.sh` was rc=1** — a missing
   line-continuation backslash after `h264_intra_pred.sv` truncated the
   Verilator source list, so the gate could never elaborate. Introduced by
   `ddb7c97`. Fixed in `8f17d3d`; now rc=0 with `residual_csum=0x14
   recon_sig=0x3b`.
4. **`make rtl-lint` was rc=2** — see §4, it was masking a real RTL bug.

**Lesson, stated plainly:** every one of these was a gate that had been *cited*
as green in a handoff and was red when run. Run the gate; do not quote it.

### And the finding that matters more than any of them

`h264_decode_core` is **instantiated but vacuous**. Instantiation is not
connection. Measured by the new `scripts/check_decode_core_seam.py`:

```
DECODE_CORE_SEAM_OK core_inputs=53 constant_inputs=29 synthetic_reg_inputs=2 \
    core_outputs=13 unobserved_outputs=13 presentation_driver=decode_stub
DECODE_CORE_SEAM_NOTE product pixels are NOT produced by h264_decode_core; \
    frame-store writes come from decode_stub
```

- 29 of 53 core inputs are tied to constants (`rbsp_byte`→0, `recon_y`→0,
  `recon_u/v`→128, all `p16_residual_*`→0, `recon_mb_valid`→0,
  `p16_zero_mv_valid`→0, `dpb_rd_data`→0, all MVs→0, `cbp_luma`→`4'hf`).
- **13 of 13 core outputs terminate in the synthesis `_keep` anti-prune wire.**
  `dpb_wr_*` goes nowhere — the core has no memory behind its DPB port.
- `decode_stub` is the sole driver of `fs_wr_en` / `fs_wr_pixel` /
  `fs_wr_reset` / `fs_swap` (`stream_path.sv:595–598`).

**The topology ruling is true structurally and must never be quoted as a
functional claim.** Any statement of the form "module X is in the product
decoder" is, today, a statement about a source graph and nothing more.

## 3. Can `decode_stub` be retired? — **No. It is contained instead.**

Three precise blockers, per instruction (recorded in
`docs/decode-stub-retirement.md` with the 6-step retirement order):

- **A.** It is the sole driver of `fs_wr_*` / `fs_swap`; the core's writeback
  outputs are dangling. Deleting it today blanks the display.
- **B.** ~~Seven real MC/DPB modules hang off it.~~ **Cleared this shift** — see §5.
- **C.** `tests/rtl/stream_path_full_frame_tb_top.sv` probes ~20 stub internals
  and prefills `stub.dpb_mem`. Those probes must move to the core first.

Since I could not remove it, I made it **structurally impossible for it to
satisfy a product reachability proof**, which was the explicit fallback in my
brief:

`fpga/Plex_MiSTer/rtl/diagnostic_only_modules.txt` declares `decode_stub` a
diagnostic root. `scripts/check_rtl_module_instantiations.py` now prunes
diagnostic subtrees *before* computing product reachability, and answers
`--require` **from the pruned graph only**. Nothing beneath a diagnostic root
can satisfy `--require` from any root.

The `[debt]` list is enforced **exact-match in both directions**: a new
stub-only module fails with `UNDECLARED_DIAGNOSTIC_ONLY_MODULE`, and a module
that has since been properly rooted fails with `STALE_DIAGNOSTIC_DEBT_ENTRY`
until the line is deleted. Debt can therefore only shrink, and progress cannot
be silently absorbed. **This gate immediately earned its keep — see §5.**

## 4. `h264_cavlc_residual_block` — and a real bug

**Answer to mission item 3:** it *is* now core-reachable (single instance
`u_product_p16_residual0`, `h264_decode_core.sv:495`), but it **cannot fire in
product**, double-gated: `.rbsp(rbsp_byte)` is the constant-zero window and
`.start` depends on `p16_zero_mv_valid`, tied to `1'b0`. Real intra residual
reaches the core through the `luma4x4_*` ports instead — all 16 blocks — but
with **synthetic `core_luma4x4_total_coeff <= 5'd16` and `trailing_ones <= 2'd0`**
(`stream_path.sv:430–431`) — a fabricated "all 16 coefficients present, no
trailing ones" wearing the costume of parsed CAVLC data.

**Blind spot now closed (`b7a4f13`).** The seam gate originally saw only literal
*port ties*, so a port that looks properly wired but is driven by a
constant-only register escaped it. It now has a `[synthetic_reg_inputs]`
section, restricted to multi-bit **data** ports so 1-bit strobes like
`luma4x4_valid` are not false-positived, and the genuinely wired `luma4x4_qp`
and `luma4x4_idx` are correctly not flagged. Reds both ways: making a real input
synthetic gives `UNDECLARED_SYNTHETIC_CORE_INPUT`; wiring the real value in
gives `STALE_SYNTHETIC_CORE_INPUT`, so **w-cast's landing forces the debt lines
to be deleted in the same commit.**

### The real bug (`7e470a8`)

Chasing `make rtl-lint` rc=2 found a genuine defect.
`h264_cavlc_residual_block` indexed its RBSP array as `rbsp[bit_pos[8:3]]` — a
**6-bit byte index that wraps at byte 64**. `slice_hdr_parser` instantiates it
with `MAX_BYTES=96` and advances `full_bit_off` across all 16 luma 4x4 blocks of
a macroblock inside that window, with `bit_len` up to 768. Any residual running
past bit 512 read the wrong bytes.

**The failure mode is silent: the block still asserts `ok=1` and returns
`total_coeff=0`.** That is exactly the long-standing "only the first block ever
has residual data" symptom and is a strong candidate for its cause.

Fixed by deriving the index width from `MAX_BYTES` via `$clog2`. New
shift-invariance cases decode an identical bit pattern at byte offsets
0/32/64/80 of a 96-byte buffer whose low bytes hold a decoy:

```
with rbsp[bit_pos[8:3]]     rc=1, 3 failures
  FAIL rbsp_window_shift start_byte=64 ok=1 tc=0/5 bits=513/534
  FAIL rbsp_window_shift start_byte=80 ok=1 tc=1/5 bits=644/662
with the fix                rc=0  roundtrip_cases=532
```

Offsets 0 and 32 pass either way, which localises the defect to the wrap.

**Scope honesty:** `residual_csum` on the real fixture is **unchanged at 0x14** —
that vector never crosses byte 64. So this is measured by directed RTL stimulus
and by lint, **not** by a change in real-content output. It is a latent bug that
would bite on denser macroblocks. Flagged to **w-cast**, who owns CAVLC.

## 5. Integration — and the gate catching a real divergence

Merged `origin/w-swap-o5-mc` (`4f4312b`) in `70f62e4`. Two conflicts, both
harness lists, resolved as the **union** of both gate sets.

```
root=h264_decode_core   reachable 16 -> 21, all 8 --require modules reachable
root=emu                product_reachable 42 -> 47, diagnostic_debt 7 -> 2
```

**The diagnostic-debt gate refused the merge** with seven
`STALE_DIAGNOSTIC_DEBT_ENTRY` lines until the manifest was updated — the MC
modules could not silently remain declared as stub-only debt. **Blocker B is
cleared.**

Then the same gate reported two *new* `UNDECLARED_DIAGNOSTIC_ONLY_MODULE`s and
that turned out to be the most important thing it did all shift:

> `h264_luma_qpel_sample` and `h264_chroma_epel_sample` were
> `h264_decode_core`'s `u_product_p16_luma_pred` / `u_product_p16_chroma_pred`
> **before** this merge. `4f4312b` replaced them with
> `h264_luma_qpel_block_16x16` / `h264_chroma_epel_block_8x8`, which
> **reimplement the 6-tap FIR with local functions** (`h264_dpb.sv:366,461`)
> rather than instantiating the sample modules. Their only remaining
> instantiations are in `decode_stub.sv` and the bench-only
> `h264_decode_skeleton.sv`.

So the product tree held **two independent H.264 quarter-pel implementations**,
the core had silently switched from one to the other, and nothing proved they
agreed. **That is the exact shape of the `DECODE_REAL_INTRA` failure** — two
configurations, each holding half a decoder, every unit test green throughout.

I did not leave that as a comment. `tests/unit/test_qpel_equivalence_verilator.sh`
(`2429514`) drives both DUTs from **one shared 25x25 reference plane**, so
neither can be advantaged by window framing:

```
QPEL EQUIVALENCE PASS compares=20480 patterns=5 frac_positions=16 block_positions=256
```

**They agree.** Red proofs in *both* directions, each restored to rc=0:
- perturb the **sample** side by 1 LSB → machine-checked against
  `tests/expected_red_manifest.json`
  (`EXPECTED_RED qpel_block_vs_sample_equivalence: rc=1 matched 2 substrings`).
  The script builds and runs this itself before the real comparison, so the
  gate cannot degrade into not comparing.
- perturb the **block** side — the implementation the core actually uses — by
  dropping the `avg2` rounding term → `QPEL EQUIVALENCE FAILED mismatches=3542
  compares=20480`, first mismatch at `frac=(1,0)`, the first fractional position
  that uses `avg2`, which localises the injected defect correctly.

Consequence: `h264_luma_qpel_sample` is now **provably redundant**, so W-SWAP can
delete it outright rather than reasoning about it. The manifest records that the
gate must be retired together with the module.

## 6. What `h264_decode_skeleton.sv` actually is

**Not a fourth decoder lineage.** Its own header says *"THIS IS NOT A
DECODER… exists solely to hold area in the fitter."* It is an area-estimation
harness. Owner w-rel, consumer w-cap.

**Measured: `grep -c h264_decode_skeleton fpga/Plex_MiSTer/files.qip` = 0** — it
is not compiled into the product project at all, and it is unreachable from
`emu`. It is only a *source-graph confuser*: it shows up in
`parents=decode_stub,h264_decode_skeleton` diagnostics and inflates
grep-based "who instantiates X" answers. **No action needed.**

## 7. One real vacuity reduction (`d8bb4fc`)

`h264_decode_core`'s `.pps_chroma_qp_index_offset` was hard-tied to `5'sd0`
even though `pps_parser` already walked past the `se(v)` field at state `ST_CHR`
and discarded it. Exported it (clamped to the legal `[-12,+12]`) and wired it
through. `constant_inputs` **30 → 29**. Plumbing, not behaviour — the parsed
offset is 0 in this stream.

---

## Evidence — 21/21 gates rc=0 on `2429514`

`rollcall · pipe_exit · define_parity · quartus-sv-subset · inst_all · inst_core
(8× --require) · mc_redgreen · seam · qpel_equiv · cavlc · level_width ·
recon_integ · real_intra · full_frame · p3_idct · p3_deblock · p3_recon ·
p3_dpb_mc · sp_deblock · writeback · rtl_lint`

**0 exit-77 skips, 0 `SKIP RTL SIM` lines.** Logs committed under
`build/w-decode-o5/`.

`make unit` is rc=2 and that is **expected and pre-existing**: `test_companion_eof`
(`/library/metadata/3` key mismatch) fails at `Makefile:64`, and the RTL gate
block is at lines 113–142 of the *same recipe*, so **`make unit` never reaches
the RTL gates at all**. Proven rc=1 on `parent/integ-hour27` too. I did not
override the guard. **Anyone relying on `make unit` to exercise the decode gates
is not exercising them — run the block standalone.**

## Caveats a successor must not drop

- `check_rtl_module_instantiations.py` and `check_decode_core_seam.py` are
  **source/regex-level, not elaboration-aware** (w-audit's finding). rc=0 is
  necessary, **not sufficient**. Corroborate with `make post-fit-hierarchy`.
- The seam gate now sees constant-only **registers** as well as port ties, but
  only for multi-bit data ports; a synthetic 1-bit control signal would still
  pass unnoticed.
- The qpel gate proves the two implementations agree **with each other**. It does
  **not** prove either matches the H.264 spec.
- Denominator: the frame is **1170 MBs (39×30)**. Nothing here decoded any of them.

## Recommended next moves, in order

1. **Give the core somewhere to write.** Blocker A is the whole ballgame: until
   `fs_wr_*` comes from `h264_decode_core`, every other green is structural.
2. **Kill the synthetic `total_coeff`/`trailing_ones` register defaults** — now
   declared debt and gated, and w-cast has the real values staged. This is the
   next concrete landing.
3. **Move the ~20 tb probes** off `dut.gen_diagnostic_present.stub.*` onto the
   core (blocker C), then delete `decode_stub` and its two remaining debt
   modules.
4. **w-swap:** delete `h264_luma_qpel_sample` / `h264_chroma_epel_sample` and
   retire the equivalence gate with them. Equivalence is proven; the duplication
   is pure risk now.
5. **w-cast:** the CAVLC wrap fix is latent-only on the current fixture. A denser
   macroblock fixture would convert it into a measured behaviour change.

## Do not do

- **Do not run Quartus** — sole exclusive slot, owned by `w-fit-o5`.
- **Do not touch the 128-bit `status_telem_r` word in `Plex.sv`** — protocol
  locked (sticky `0x14`, reject `+0x53`).
- **Do not let a macro become a topology switch again.**
- **Do not report BUILD_OK / DEPLOY_OK as success.** Only a moving picture counts.

---

## Addendum — the parent's revised two-direction standard (commit `4969d96`)

The parent withdrew the core-subtree gate as sufficient after `w-audit` broke it,
and assigned me the branch convergence. **Result: the assigned convergence was
already complete.** Measured on `w-decode-o5`:

| Direction | Command | rc |
|---|---|---|
| TRUNK | `--root emu --require h264_decode_core` | **0** |
| SUBTREE | `--root h264_decode_core --require h264_deblock_writeback_ctrl …` | **0** |

My merge `05934a9` had already landed w-deblock's work onto a base carrying
`stream_path -> h264_decode_core`. I reproduced w-audit's finding independently
on `w-deblock-seam`: TRUNK rc=1, `parents=<none>`, and zero references to
`h264_decode_core` in that branch's `stream_path.sv`.

**Peers should merge or rebase onto `w-decode-o5`, not onto `w-deblock-seam`.**
Work landing on `w-deblock-seam` lands in a disconnected core.

### I re-ran w-audit's four mutations myself rather than inherit them

| Mutation | Reproduces here? | Outcome |
|---|---|---|
| M1 disabled `if (0)` generate | **yes — and worse** | the fleet checker *and my own seam gate* both passed it |
| M2 escaped instance name `\name ` | **no** | returns the correct rc=0 on this branch; reported for the record |
| M3 file in git but absent from `files.qip` | **yes** | reachability rc=0 while the module is not compiled at all |
| M4 subtree-green-while-core-dead | already closed here | both directions rc=0 |

I got M1 wrong in my own instrument and only found it by attacking my own gate.
That is the second time this session that red-checking caught a gate of mine that
was reporting a green it had not earned.

### `files.qip` cross-check — measured, clean

- core subtree: **21 modules, 21 in `files.qip`, 0 missing**
- emu subtree: **49 modules, 0 missing**

Now enforced permanently by `core_subtree_qip_guard()` in the seam gate, and
independently cross-checked with a standalone scan written from scratch.

**Concrete fleet risk this surfaced:** every MC module w-swap landed
(`h264_inter_mc_16x16`, `h264_inter_mc_part`, `h264_dpb_one_ref`,
`h264_luma_qpel_block_16x16`, `h264_chroma_epel_block_8x8`) lives in
**`h264_dpb.sv`**. Deleting that one qip line removes the whole motion-compensation
subsystem from the design while every reachability check stays green. That single
line is now guarded.

### Harness changes

- Trunk proof is **mandatory**, running before the subtree proof (Makefile + rollcall).
- `tests/unit/test_decode_core_seam_audit_reds.sh` — 7 checks, mutate → red → restore
  → green, two reds machine-checked against `tests/expected_red_manifest.json`.
- That test mutates tracked RTL, so it **refuses with rc=1 if a Quartus fit is
  running in this tree** — the "never edit sources under a live compile" rule,
  mechanized. It refuses rather than skips, because a skip is not a pass. It
  matches `/proc/pid/exe`, not `pgrep -f`, which would false-positive on its own shell.

Sweep at `4969d96`: **36/36 rc=0, 0 exit-77 skips.** One earlier failure
(`test_resource_preflight.sh`) was the preflight guard **correctly refusing**
during w-fit-o5's live fit; it returned rc=0 once that fit ended. Not a regression,
and it was not overridden.

### Unchanged, and still the honest headline

```
DECODE_CORE_SEAM_OK core_inputs=53 constant_inputs=29 synthetic_reg_inputs=2
  core_outputs=13 unobserved_outputs=13 presentation_driver=decode_stub
  live_generate=yes core_subtree=21 core_subtree_in_qip=21
```

The core is now **provably in the design, provably reachable from `emu` in both
directions, and provably still vacuous**: all 13 outputs unobserved, `decode_stub`
still the sole driver of every frame-store pixel. Structural rooting is not
function. **Zero frames have been decoded and displayed by the FPGA.**
Denominator reminder: the frame is **1170 MBs**.

---

## Addendum 2 — capacity, and a defect class no existing oracle catches (`d599bd8`)

w-fit-o5 reported `decode_stub` holding **256 M10K = 46% of the device** and warned
that w-swap's MC may not fit until the stub is retired. Chasing that number found
something worse than a capacity squeeze.

### The stub's DPB is arithmetically impossible

| | |
|---|---|
| `decode_stub` declares | `dpb_mem [0 : 2*(W*H + 2*((W/2)*(H/2))) - 1]` |
| `WIDTH`/`HEIGHT` defaults | 320 × 240 |
| **as actually instantiated** (`Plex.qsf` `FRAME_W=640 FRAME_H=480` → `Plex.sv` → `stream_path` → stub) | **640 × 480** |
| declared array | **921,600 bytes = 7,372,800 bits** |
| device M10K (5CSEBA6) | 553 × 10,240 = **5,662,720 bits** |
| ratio | **1.30× the entire device** |
| w-fit measured in the fit | 256 M10K = 262,144 bytes = **28% of the declared array** |

The other 72% was never built. **Every gate we own was green** — reachability in
both directions, `files.qip` coverage, the seam gate — while the diagnostic frame
store was silently a fraction of its declared size.

**This is a new defect class.** Reachability proves it is in the graph; `files.qip`
proves it is compiled; post-fit hierarchy proves it survived fitting. All three are
true here. The array is simply impossible. `scripts/check_onchip_ram_budget.py`
closes it.

It required **real parameter propagation from `emu`**, not name-based seeding:
`decode_stub.WIDTH` is a frame width (640) but `async_fifo.WIDTH` is a bus width (8).
I got this wrong on the first cut in both directions and only found it because the
first run reported the stub as `UNEVALUATED` rather than over-budget.

### Consequence for W-SWAP-O5 — measured, not assumed

`h264_dpb_one_ref` is **memory-external by design**: it emits `mem_we/mem_waddr/mem_wdata`
and issues `dpb_rd_en/dpb_rd_addr`, and `BANK1_BASE = 898560/2` implies a two-bank
898,560-byte store. Backing that on-chip needs ~1.3× the device. **It must be
DDR-backed; it can never be on-chip.**

And today it has **no memory at all**: `stream_path.sv:548` ties `.dpb_rd_data(8'd0)`,
while `dpb_wr_en/addr/data` terminate only in the `_keep` anti-prune wire. **Every
reference pixel the product MC reads is `0x00`.** MC will motion-compensate from a
black frame even once it fits. This was already declared seam debt
(`decode_core_seam_debt.txt:51,64,74-76`); what was missing was stating its consequence.

### Adopted rather than rebuilt

w-fit-o5's `scripts/check_qip_coverage.py` (`ee2ed89`) taken verbatim. It passes
**rc=0 on this branch**: 36 qip entries vs 34 on `parent/integ-hour27`;
`h264_decode_top.sv` and `h264_intra_nb_ctx.sv` are compiled here and are not there.
This corroborates w-fit's ruling that **`w-decode-hour27`/`w-decode-o5` is the only
viable merge base**.

### One more resurrection route closed

`Plex.qsf:83` still passes `DECODE_REAL_INTRA=0`. Inert — no product RTL tests the
macro — but the QSF is precisely where someone flips it to 1 and deletes 14 modules
again. `=0` tolerated, anything else fails (`RETIRED_TOPOLOGY_MACRO_TESTED`). I did
**not** edit `Plex.qsf`; w-fit-o5 owns the fit window.

### Geometry note (not mine to fix)

The project **fits 640×480** while the content is **624×480 coded / 618×480 display**.
That is the derived-geometry contract defect already assigned to W-GATE-O5. I changed
no geometry.

### Sweep at `d599bd8`: 39/39 rc=0, 0 exit-77 skips

Reds: N1 new on-chip product DPB → `ONCHIP_RAM_ARRAY_EXCEEDS_DEVICE`; N2 stale entry;
N3 unevaluatable block RAM (no silent pass); N4 `FRAME_W` removed from QSF;
O1 `DECODE_REAL_INTRA=1` in QSF. All restore to green.

**Still zero frames decoded and displayed by the FPGA.** Denominator: 1170 MBs.

---

## Addendum 3 — the w-cast merge, and what it did and did not achieve

Branch `w-decode-o5`, merge commit **`1e7509b`** (pushed twice; `git rev-parse HEAD`
== `origin/w-decode-o5`). Merges `origin/w-cast-play-state` (`3d4607e..667a237`).

### The headline, stated at its true size

`h264_cavlc_residual_block` was reachable in **neither** historical config, and at
the seam it was **double-gated shut**: `.rbsp(rbsp_byte)` was tied `8'd0` and
`.start` depended on `p16_zero_mv_valid`, tied `1'b0`. Both gates are now open:

| | before | after |
|---|---|---|
| `rbsp_byte` | `8'd0` | `sl_rbsp` — real captured slice RBSP |
| enable | `p16_zero_mv_valid` (tied 0) | `p16_zero_mv_valid \|\| syntax_p16_launch` |

`p16_zero_mv_valid` is **still tied `1'b0`**. The path is opened solely by the new
syntax-driven term.

**Denominator — the part that must not be overstated.** At the seam,
`mb_type_valid` is `slice_valid & ~slice_valid_d`: a one-shot on the slice-header
valid edge. Every syntax input beside it is `sl_first_mb_*`. So CAVLC now runs for
the **first MB of each slice only — 1 of 1170 MBs per frame.** That is not a
decoded frame. **Zero frames have been decoded and displayed by the FPGA.**

What it *does* establish is the root cause of "only block0 ever has residual data":
it is **first-MB-only staging**, not unreachability. Reachability is fixed; the
per-MB walker is the remaining work and is the natural next task.

### Two things the merge tried to delete, and how they were caught

1. **w-deblock's controller.** `h264_decode_core.sv` theirs had
   `h264_deblock_writeback_ctrl` count **0**; mine had **1**. Taking theirs
   wholesale would have deleted landed peer work — the project's signature failure
   mode. Resolved as a union.
2. **My `gen_diagnostic_present` generate scope.** Taking theirs for
   `stream_path.sv` silently dropped the named generate scope containing
   `decode_stub`. Only `test_stream_path_full_frame_compare.sh` caught it, via a
   TB scope error (`Known scopes under 'dut': ... stub`). Restored.

Neither was reported by any reachability, qip, or RAM gate. **A green gate sweep
does not detect a merge that deletes work; only a diff against both parents does.**

### A false positive in my own seam gate

`synthetic_reg_inputs()` matched an indexed reg write with `\[[^\]]*\]`, which
cannot span a *nested* index. So `sl_rbsp[sl_rbsp_len[6:0]] <= sl_cap_data;` was
invisible, only the reset-loop `<= 8'd0` matched, and real data was reported as
synthetic. Fixed to `\[(?:[^\[\]]|\[[^\[\]]*\])*\]`.

Red/green pair (both measured): real data → rc=0 not flagged; mutate that
assignment to `8'd0` → rc=1 `UNDECLARED_SYNTHETIC_CORE_INPUT rbsp_byte`; restore →
rc=0. The fix removed a false positive **without** weakening the true positive.

### A false red in the fleet reachability checker — worth knowing about

Mid-merge, the trunk proof failed with:

```
RTL_MODULE_INSTANTIATION_FAIL: duplicate module h264_decode_core:
  fpga/Plex_MiSTer/rtl/h264_decode_core.sv and fpga/Plex_MiSTer/rtl/h264_decode_core.sv
```

**The same path on both sides.** There is exactly one `module h264_decode_core` in
the tree. Cause: `git ls-files` emits an **unmerged** path once per stage (1/2/3),
so the checker parsed the file repeatedly. Measured: one file, four emissions.

This matters because the trunk proof is now the measurement the fleet is *required*
to cite. A checker that cannot survive a mid-merge tree will be worked around.
Fixed with an order-preserving dedupe; permanent regression test
`tests/unit/test_rtl_instantiation_unmerged_paths.sh` recreates the condition with
a `git` shim, and still proves a **genuine** cross-file duplicate is rejected rc=1.

### decode_stub: NOT retirable, and precisely why

Re-measured on `1e7509b`:

- **Blocker A (hard).** `decode_stub` is the **sole** driver of `fs_wr_en`,
  `fs_wr_pixel`, `fs_wr_reset`, `fs_swap` (`stream_path.sv:539-542`).
  `h264_decode_core` has **no pixel-presentation output port at all** — its only
  write port is `dpb_wr_en` (DPB, not frame store). Retiring the stub today yields
  a frame store with no driver: no picture at all. **The core cannot paint pixels
  because the ports do not exist yet.** That is the blocker, stated exactly.
- **Blocker C.** 22 probes into the stub scope in `stream_path_full_frame_tb_top.sv`.

Per the mission's fallback, it is instead **structurally contained**, and that
containment is proven load-bearing rather than asserted:

```
--root emu --require h264_luma_qpel_sample        rc=1
  REQUIRED_RTL_MODULE_UNREACHABLE h264_luma_qpel_sample
  parents=decode_stub,h264_decode_skeleton reachable_only_via_diagnostic_root=1
--root emu --require h264_luma_qpel_block_16x16   rc=0   (control)
```

A module reachable **only** through the stub cannot satisfy a product proof.

### `h264_decode_skeleton.sv` — answered: NOT a fourth decoder lineage

887 lines, self-documented *"THIS IS NOT A DECODER... It exists solely to hold area
in the fitter so we get a real resource measurement."* It defines one module,
instantiated **nowhere** (measured), and is correctly `ALLOWED_ABSENT` from
`files.qip`. It is a resource-estimation scaffold.

It is, however, exactly the same hazard class as `decode_stub` — it instantiates
one of everything — and the red proof above confirms it is **already** treated as a
diagnostic root, so it cannot manufacture product greens either.

### Evidence on `1e7509b`

| gate | rc |
|---|---|
| `--root emu --require h264_decode_core --require stream_path` (**trunk**) | 0 |
| `--root h264_decode_core --require {deblock_writeback_ctrl, inter_mc_16x16, dpb_one_ref, cavlc_residual_block, luma_qpel_block_16x16, chroma_epel_block_8x8}` (**subtree**) | 0 |
| `check_qip_coverage.py` (w-fit's, unmodified) | 0 `product=37 compiled=35` |
| `check_onchip_ram_budget.py` | 0 |
| `check_decode_core_seam.py` | 0 `synthetic_reg_inputs=0 core_subtree=23/23 in qip` |
| `test_unit_rollcall.py` | 0 `expected_commands=100` |
| **RTL gate sweep** | **53/53 rc=0, 0 skips** |

Seam debt was updated **entry by entry**: deleted `rbsp_byte`,
`mb_residual_bit_offset`, `cbp_luma`, `cbp_chroma` (measured progress) and both
`[synthetic_reg_inputs]` entries (the fabricated `5'd16`/`2'd0` are gone because
those ports reversed direction and are now core **outputs**); added `dpb_rd_valid`,
`intra16x16_mode`, `intra4x4_modes`, `mb_qp_delta` as new honest debt.
`constant_inputs` 30 → 29.

### Still true, and still the reason nothing displays

- `stream_path.sv` ties `.dpb_rd_data(8'd0)` and now `.dpb_rd_valid(1'b0)`:
  **every reference pixel MC reads is 0x00.** Inter prediction cannot be correct.
- The product DPB must be **DDR-backed**. `decode_stub.dpb_mem` is 7,372,800 bits =
  **1.30× the whole device**; on-chip is arithmetically impossible.
- All 12→13 core outputs still terminate in the `_keep` anti-prune wire.

---

## Addendum 4 — decode_stub memory surgery (Ruling 2 satisfied)

**Branch `w-decode-o5`, commit `6949e7e`** (pushed twice; `HEAD == origin/w-decode-o5`).

### What changed
`decode_stub`'s private DPB/MC experiment is gone: the `dpb_mem` array and its
private instances of `h264_deblock_writeback_ctrl`, `h264_dpb_one_ref` and
`h264_inter_mc_part`. The painter is untouched and remains the sole driver of
`fs_wr_en/fs_wr_pixel/fs_wr_reset/fs_swap`.

| metric | before | after |
|---|---|---|
| on-chip block RAM | 7,458,816 bits | **86,016 bits** (1.5% of device) |
| `known_over_budget` | 1 | **0** |
| gate sweep | 53/53 *(truncated — see below)* | **100/100 rc=0, 0 skips** |

### The measurement that justifies it
`dpb_mem` was declared 921,600 bytes = 7,372,800 bits = **1.30x the entire
device** (553 M10K x 10,240 = 5,662,720). It could never be built as declared.
Quartus gave decode_stub 256 M10K = 327,680 bytes, but `DPB_BANK1_BASE` is
460,800 > 327,680 — **the reference bank never existed in silicon.** Any
hardware conclusion previously drawn from it was simulation-only. Recorded with
full arithmetic in `fpga/Plex_MiSTer/rtl/retired_measurements.txt`.

### Two liveness bugs I introduced and fixed — the transferable lesson
**A tie-off must preserve liveness, not just values.** Tying a handshake flat to
0 deadlocks the painter, which stops driving `fs_wr_*` — a black screen, not a
freed device.
1. `PH_DPB_FILL` exits only on `deblock_ref_ready_pulse` from the **terminal**
   `dpb_fill_sample_idx == 386` step. I keyed it off `dpb_frame_boundary`
   (idx == 385); the `else if` chain consumes 385 first, so the pulse was dead
   before the exit branch was reachable. Symptom: *"did not return idle after
   VCL frame 1"*, 5 gates red.
2. `dpb_fetch_done` is a **level** in `h264_dpb.sv` (cleared on accept :293, set
   on completion :318/326), not a pulse, and `dpb_fetch_start` is never cleared
   outside reset. Emulation is keyed on `p_fetch_launch_pending`.

I also briefly concluded `dpb_ref_ready=1` broke the painter. **That was wrong**
— I tested it before fixing bug 1, and blamed the wrong signal. Holding it HIGH
is correct and keeps the stub's inter diagnostic alive on neutral grey (128)
predictions at zero block-RAM cost. Holding it low makes `PH_FETCH` unreachable
and would have silently deleted that coverage.

### Pre-existing defect found and repaired
`tests/unit/test_h264_multinal_stream_path.sh` has three Verilator filelists.
The third (forced-MB-syntax-unsupported fault injection) omitted
`h264_intra_nb_ctx.sv`, `h264_intra_pred.sv` and `h264_decode_top.sv`, so it
died with `MODMISSING` at elaboration — **that red-check had never once run.**
Confirmed failing identically at `bd14632`, so not from this change. Repaired;
it now executes and passes.

### Correction to my own earlier record
My previously reported **"sweep 53/53 rc=0"** was measured on a **truncated gate
list**: I extracted the Makefile recipe lines without expanding `$(ROOT)`, so 47
gates failed with rc=127 (command not found) and were never counted. The real
denominator is **100**. The 53/53 figure is **withdrawn**.

### Status against parent Ruling 3 (conditions for the next fit)
| condition | status |
|---|---|
| 1. `--root emu --require h264_decode_core` rc=0 | **MET** (trunk REACHABLE) |
| 2. `check_qip_coverage.py` rc=0 | **MET** (product=37 compiled=35) |
| 3. `decode_stub` shrunk enough for M10K headroom | **MET** (46% of device freed) |
| 4. intended decode modules in a pre-fit elaboration check | **NOT MET — not mine to assert** |

Ruling 3 assignments 2 and 3 (add the two files to `files.qip`; converge
`w-deblock-seam`) were **already complete on this branch** before the ruling was
issued: `2f165ed` is an ancestor of HEAD, `7225e00` is merged, and `files.qip`
already carried both files.

### What still blocks full `decode_stub` retirement — unchanged
**Blocker A: `h264_decode_core` has no pixel-presentation output port at all.**
The stub is the only thing that can drive the frame store. Retiring it outright
requires adding presentation outputs to the core. That is the next mission, and
it is a design change, not a deletion.

---

## Addendum 5 — the dead core: confirmed on this branch, remedy attempted, and the precise blocker

**Branch `w-decode-o5`.** w-fit-o5's diagnosis (`a8aa8eb`, `parent/integ-hour27`) is
**CONFIRMED on this branch**, not merely inherited:

```
stream_path.sv  (* keep = 1 *) wire _keep = ... 80+ terms including every
                h264_decode_core output ...
grep for any READ of _keep  ->  no matches
```
**The anti-prune wire is assigned and never read, so it keeps nothing.** Same defect
w-fit measured at `h264_decode_core.sv:1309` (`_keep_decode_core_inputs`). This is
failure mode 3: *compiled, instantiated, elaborated, then optimized away as
zero-resource dead logic* — invisible to every source-level graph.

### What is NOT true of this branch (differs from `2f165ed`, which w-fit measured)
w-fit reported the core's inputs tied to constants (`core_rbsp_byte` all `8'd0`).
On this branch the input side is already real: `.rbsp_byte(sl_rbsp)`,
`.rbsp_bit_len(sl_rbsp_bit_len)`, real slice/cbp/i4 staging. The *output* side is
the remaining problem, exactly as w-fit said.

### ROOT CAUSE — two parallel CAVLC paths
`sl_place_*` (slice_hdr_parser's held registers) feeds the picture.
`luma4x4_*` (h264_decode_core) feeds **only** `_keep`. The core is a duplicate of a
path that already works, so it contributes nothing and is deleted.

### Remedy attempted, and why it is not shipped
I routed the painter's residual onto the core (`decode_stub.residual_*` <- core).
Port widths match **exactly** — this is plainly the seam the core was built for.
Five configurations were measured:

| # | residual_ok | data | clear policy | deblock | 3 recon gates |
|---|---|---|---|---|---|
| 1 | `luma4x4_source_ok` | raw pulses | n/a | **FAIL** | PASS |
| 2 | held reg | held, block0 | `reset\|flush\|vcl_pulse` | **FAIL** | PASS |
| 3 | held reg | held, every pulse | `reset\|flush` | PASS | **FAIL** |
| 4 | held reg | held, block0 | `reset\|flush` | PASS | **FAIL** |
| 5 | `luma4x4_source_ok` | held | `reset\|flush` | PASS | **FAIL** |

**Perfectly inverted, in every combination.** `test_stream_path_deblock_integration`
requires a *held level* (it samples `recon_dbg & 0x79` after the slice); the three
recon gates require the *raw pulse timing*. `decode_stub` level-samples `residual_*`
when it leaves `PH_WAIT`, while the core emits per-block pulses.

**Reverted. The tree is 102/102 rc=0, 0 skips.** I will not ship a change that
regresses a peer's gate on a hypothesis.

### Measurements worth keeping
- `recon_dbg=0x70` in config 2 is **entirely** the inter-flag OR term
  (`{1'b0, lat_inter_recon_ok, lat_p_inter, dpb_ref_ready, 4'd0}`); the residual path
  contributed nothing. Bits 4/5/6 of `recon_dbg` are **ambiguous** — they are driven
  by both `recon_dbg_comb` and the inter flags. Anyone reading them as residual
  evidence is reading a signal with two sources.
- The core produces **16** luma4x4 pulses on the multinal fixture but only **2** on
  the real-intra fixture, so any capture policy keyed on a specific block index is
  fixture-dependent.
- In config 5 the first 4x4 reached `non128_first4x4=16` — the core *can* drive real
  pixels; the obstacle is handshake shape, not data.

### PRECISE BLOCKER (as the house rule requires)
> `h264_decode_core` exposes its residual as a **per-block pulse stream**
> (`luma4x4_valid` + data valid only during the pulse). `decode_stub` consumes
> residual as a **held level**, sampled once per MB at `PH_WAIT` exit. Until one of
> the two changes shape — either the core gains a held per-MB residual output, or the
> painter gains a pulse-collecting input stage that satisfies both the deblock gate's
> post-slice sampling and the recon gates' pulse timing — consuming the core's
> residual regresses one gate set or the other. This is a **design change to the
> core's output interface**, not a wiring fix.

### NOT verified: pre-fit elaboration
`scripts/check_prefit_elaboration.sh` / `check_map_hierarchy.py` are imported here
from `parent/integ-hour27` `a8aa8eb`. **I did not run them.** The script states it
uses the remote Quartus slot and respects the one-at-a-time rule; Quartus is
w-fit-o5's sole exclusive token and I could not confirm the slot was free.
**Requested from w-fit-o5 rather than taken.** No A&S claim is made on this branch.

## Addendum 6 — failure mode 3 cured at the real dead end; first real-synthesis CAVLC

Branch `w-decode-o5`. Baseline `6ccb335`. All numbers below are **measured**, by
Quartus Analysis & Synthesis (no fit, no bitstream, no device).

### The dead end was one level above where everyone was looking

Parent and `w-fit-o5` located failure mode 3 correctly (core elaborated then
optimized away) and pointed at `stream_path`. The instantiation there is fine.
The actual dead end is in **`Plex.sv`**, which contains **zero occurrences of
`luma4x4`**: the core's outputs reach `stream_path`'s port boundary and are then
left **unconnected at the `emu` instantiation**. `(* keep *) wire _keep` cannot
save it because `_keep` is itself never read.

### The fix, and exactly what it is not

`decode_stub` drives `recon_dbg` bits 0,3,4,5,6,7 only (`recon_dbg_comb`), so
bits **2:1 are free by construction**. `stream_path` now publishes two sticky
core-liveness bits there:

    core -> recon_dbg[2:1] -> Plex.sv st_recon_dbg_sticky -> status_telem -> DDR

This is **INSTRUMENTATION, not presentation.** It publishes whether the product
core produced residual in silicon. **It does not put a pixel on screen. Zero
frames have been decoded and displayed by the FPGA.**

The `0x79` deblock mask and the `0x14` residual csum golden are untouched by
construction. Measured side effect: `recon_dbg` went `0x79` -> `0x7f` in
`test_stream_path_deblock_integration`, i.e. **both new bits set** — the core's
CAVLC really is producing nonzero coefficients on that fixture.

### Gate step 3 — before/after on the same toolchain (this IS the red/green pair)

| | `6ccb335` (before) | after |
|---|---|---|
| `check_prefit_elaboration.sh` | **rc=1** | **rc=0** |
| `h264_decode_core` | **ABSENT** | **PRESENT** `parents=stream_path` |
| entity rows | 786 | 789 |

Survivors under the product core (`--require`, same report):

    PRESENT h264_decode_core              subtree_rows=3  parents=stream_path
    PRESENT h264_luma4x4_residual_source  subtree_rows=2  parents=h264_decode_core
    PRESENT h264_cavlc_residual_block     subtree_rows=1  parents=h264_luma4x4_residual_source
    ABSENT  h264_decode_top / h264_dpb_one_ref / h264_inter_mc_part / h264_deblock_writeback_ctrl

**`subtree_rows=3`. Only the CAVLC chain that feeds my two bits survived.** A
consumer rescues exactly its own fan-in cone and nothing else. Every other
subsystem still needs its own consumer. This is a mechanism proof and a
template, not a decoder.

It does however settle mission item 3: `h264_cavlc_residual_block` — reachable
in *neither* historical config — is now **present in real synthesis under the
product core, not via `decode_stub`**. Denominator unchanged: this is first-MB
staging, 1 of **1170** MBs/frame.

### Ruling 3 condition 3 (capacity) — GREEN, measured

| | `2f165ed` | fitted `fb4bad84` | **`w-decode-o5`** |
|---|---|---|---|
| block memory bits | 2,969,677 | 2,970,061 | **872,909** |
| `decode_stub` subtree rows | 61 | — | **20** |

**−2,096,768 bits**, essentially exactly the 2,097,152 `w-fit-o5` attributed to
`decode_stub`. Quartus has now confirmed the surgery in `6949e7e`.

Caveat for `w-swap-o5`: 872,909 is still a *collapsed-decoder* number. The core
survives at `subtree_rows=3`. Capacity will rise as each subsystem gains a
consumer. **Do not capacity-plan MC/DPB against 872,909.** The DPB must be
DDR-backed regardless.

### Third harness correction — my sweep denominator was wrong AGAIN

I previously published **102/102**, having already withdrawn **53/53**. Both
were measured on truncated gate lists. The true denominator is **123**.

Two further bugs, both mine: `grep -E '^\t'` matched a literal backslash-t
(0 gates ran, and it exited *quietly*), and `UNIT_ANNEXB`'s own value contains
`$(ROOT)`, so substituting it re-introduced an unexpanded token.

The root cause of all three is the same: the sweep lived in gitignored `build/`,
so it was rewritten from memory each time. It is now committed as
**`scripts/sweep_gates.sh`**, derives recipe line ranges instead of hard-coding
them, and **fails when `total==0`** so a truncated list can never again read as
a pass. Current: **123/123, 0 fail, 0 skip.**

### Standing evidence

    gate1 check_qip_coverage.py                        rc=0  product=37 compiled=35
    gate2 --root emu --require h264_decode_core        rc=0  product_reachable=49 diagnostic_debt=2
          --root h264_decode_core --require cavlc      rc=0  product_reachable=23 diagnostic_debt=0
    RED   --root emu --require h264_luma_qpel_sample   rc=1  reachable_only_via_diagnostic_root=1
          check_onchip_ram_budget.py                   rc=0  block_ram_bits=86,016 known_over_budget=0
    gate3 check_prefit_elaboration.sh                  rc=0  h264_decode_core PRESENT

`h264_decode_skeleton` remains ALLOWED_ABSENT: retired lineage, not a product
module — the fourth dead lineage the parent asked me to identify.

### Still blocked

**Blocker A stands: `h264_decode_core` has no pixel-presentation output port.**
`decode_stub` remains the sole driver of `fs_wr_en/fs_wr_pixel/fs_wr_reset/
fs_swap`. It cannot be retired until the core can paint. Its cost is now 20
entity rows rather than 46% of the device, so it is no longer a capacity
emergency — but it is still the reason there is no picture.

**Blocker B (unchanged, Addendum 5): pulse-vs-level.** The core emits per-block
pulses; `decode_stub` level-samples `residual_*`. Five configurations inverted
perfectly between the deblock gate and the three recon gates. That is a design
change to the core's output interface, not a wiring fix.
