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
