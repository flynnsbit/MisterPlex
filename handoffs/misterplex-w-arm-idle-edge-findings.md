# W-ARM — idle-logo left-edge artifact: ARM-side vs RTL-side determination

Status: **RTL-side. Not ARM-side.** Reported to parent; no RTL edited.

Everything under "Measured" was produced by a command whose exit code was read
directly (`cmd > file 2>&1; echo rc=$?`), never through a pipe. Everything under
"Derived" is read from source and is explicitly *not* a measurement.

---

## 1. The decisive measurement — ARM DDR write path is byte-exact

The parent's hypothesis was a line stride / pitch mismatch: a write or read
using `CODED_W`(624) / `DISPLAY_W`(618) where `FRAME_W`(640) is required, or
`PRESENT_X`(11) applied twice, or an unmasked partial first burst per line.

A byte-value spot check cannot see any of those. So the whole payload was
compared **positionally**.

Method:
* `tools/gen_idle_frame.cpp` renders the reference with the *product* renderer
  (`host/libmisterplex/idle_screen.hpp`) at the *product* geometry
  (`plex480pDdrFrameGeometry()` → coded 624x480, Y stride 624). The reference is
  therefore the exact byte sequence `MediaPlayer::paintIdle()` hands to
  `publishDdrFrame()`, which reaches DDR as a single `memcpy`
  (`arm/misterplexd/fpga_spi.cpp:1501`).
* `scripts/ddr_frame_dump_device.py` reads the live bank back out of the MiSTer.
  `read(2)` on `/dev/mem` returns `EFAULT` on this kernel, so the dump goes
  through `mmap`. The same mapping decodes PLXK/PLXD/PLXF at their spec
  addresses, which corroborates that the physical window being read is the one
  the RTL is parameterised with (`PHYS_BASE=0x3000_0000`).
* `scripts/check_idle_ddr_frame.py` grades every byte by position.

Result, live device `192.168.1.183`, resident RBF md5 `00eebd5e...`,
`PRESENT=fpga`, `IDLE_SCREEN=logo`:

```
Scope: 299520 luma bytes (624x480) + 149760 chroma bytes; denominator = full
       449280-byte I420 payload, compared positionally
BANK 0 base=0x30000000 len=449280
luma_mismatch_bytes=0/299520 chroma_u_mismatch=0/74880 chroma_v_mismatch=0/74880
RESULT PASS bank matches product-rendered payload byte-for-byte
```

```
BANK 1 base=0x30080000 len=449280
luma_mismatch_bytes=0/299520 chroma_u_mismatch=0/74880 chroma_v_mismatch=0/74880
RESULT PASS bank matches product-rendered payload byte-for-byte
```

**Both banks, all 449280 bytes each, exact.** Not "statistically close" — exact
equality, so a stride of 618/640/656, a ±11 or ±16 px shift, or a damaged run at
any line start would all have produced a non-zero mismatch count.

Conclusion: **the ARM write path (stride 624, plane offsets 0 / 299520 / 374400,
bank bases 0x30000000 / 0x30080000) is correct.** The parent's stride hypothesis
is refuted on the ARM side.

## 2. The RTL instantiation is also not a stride mismatch

Read from source, not measured:
* `fpga/Plex_MiSTer/rtl/present_core.sv:239` instantiates `ddr_frame_store` with
  `CODED_W=624`, `DISPLAY_W=618`, `CROP_LEFT=0`, `PRESENT_X=11`, `FRAME_W=640`.
* `FRAME_STRIDE` is passed in but is **never referenced** inside
  `ddr_frame_store.sv` (only `frame_store.sv`, the SDRAM path, uses it). DDR
  addressing is derived from `CODED_W`: `Y_LINE_QWORDS = CODED_W/8 = 78`,
  `C_LINE_QWORDS = CODED_W/16 = 39`, matching the host header exactly.
* `PRESENT_X` is applied exactly once: `display_x = rd_x - PRESENT_X_L`, then
  `src_x = display_x + CROP_LEFT_L`, so `rd_x=11 → src_x=0`.

So candidates (a) and (b) are dead on both sides.

## 3. What does produce black at the left edge — the miss path

`fpga/Plex_MiSTer/rtl/ddr_frame_store.sv`:

```systemverilog
wire rd_miss_now = rd_active && rd_visible && has_frame && (!y_hit_now || !c_hit_now);
...
end else if (!has_frame || !rd_visible_d || miss_d) begin
        rd_r <= 8'd0;
        rd_g <= 8'd0;
        rd_b <= 8'd0;
end
```

On a **line-buffer miss during visible scanout the output pixel is forced to RGB
(0,0,0) — pure black — regardless of what is in DDR.** The same event increments
`underrun_count` / `frame_underrun_ddr`, which is the counter published in PLXF.

Measured on the live device (`scripts/ddr_frame_dump_device.py --watch 6`):

```
t=0 PLXF_hi=0xFFFF101A underrun=65535 debug=0x10 seq=26  PLXD_hi=0xA149000C frames_done=41289 free_mask=0 disp=1 swap=1 DOORBELL_hi=0x200097A1 db_bank=0 db_seq=38817
t=5 PLXF_hi=0xFFFF10A5 underrun=65535 debug=0x10 seq=165 PLXD_hi=0xA274000C frames_done=41588 free_mask=0 disp=1 swap=1 DOORBELL_hi=0x200097A1 db_bank=0 db_seq=38817
```

Raw numbers:
* `underrun_count = 65535` = `0xFFFF` — **saturated**.
* `frames_done` 41289 → 41588 over 5 samples at 1 s ≈ **59.8 swaps/s**, i.e. the
  frame store is actively scanning out at display rate.
* `debug_state = 0x10` = `{LINE_COUNT[2:0]=000, |y_valid=1, state_ddr=S_IDLE}`.
* PLXF `seq` heartbeat changes every sample → the FPGA mailbox writer is live,
  so these are current values, not a frozen mailbox.
* Doorbell `db_seq` static at 38817, `db_bank=0` → the ARM is not publishing
  during idle (the 30 s Logo repaint cadence), so the ARM is not contending for
  DDR bandwidth while these misses accumulate.

**Derived, not measured:** a miss is not a whole-line drop. It clears the moment
the line's data lands in a slot, so it occupies a *prefix* of the scan line —
a black run starting at the first visible column, of a length that varies per
line and per frame with DDR arbitration jitter. Composited against the 11-px
`PRESENT_X` pillar, that reads exactly as *"jagged black lines on the left side,
moving"*. It is invisible on a black frame, which is why the reporter had to
enable the logo and reset the core to see it.

Corroborating model already in the tree:
`tests/unit/test_frame_store_ddr_prefetch_sim.cpp` models precisely this failure
("line not ready at the moment scanout starts that line") and already asserts
that 640x480@60 coded=624 with `line_count=8` **underruns** at 20/80/85/90/100
MHz DDR clocks. The shipped failure is the one the sim already predicts.

## 4. What I am NOT claiming

* I have **not** shown the miss rate is non-zero *right now*. `underrun_count`
  saturates at `0xFFFF` and only clears on core reset, so 65535 proves at least
  65535 misses since the last reset, not a current rate. To turn it into a rate,
  someone with core-reset authority (W-FIT) must reset and then run
  `scripts/ddr_frame_dump_device.py --watch N`, which prints the counter each
  second. The probe is committed and ready; I did not reset the core.
* I have **not** measured the pixel positions of the black runs. That requires
  HDMI capture, which W-E2E owns. §3's left-edge localisation is derived from
  the RTL, not observed.
* I have **not** captured HDMI at all. The resident RBF is `00eebd5e`, on the
  banned/known-black-screen list, so a before/after capture against *this*
  bitstream cannot settle anything about the artifact either way. That is a
  precondition the parent needs to resolve through W-FIT before any capture
  gate on this defect can mean anything.

## 5. Correction to my predecessor's conclusion

My predecessor concluded the likely visual cause was the ARM's stuck-PLXD
fallback overwriting the displayed bank, and shipped
`3798793 fix(arm): avoid display bank on stuck PLXD fallback` for it.

The PLXD observation is **true** (`free_mask=0 disp=1 swap=1` while
`frames_done` advances — reconfirmed above). But it is a true number about the
wrong thing for *this* defect:

* In `IDLE_SCREEN=logo` the painted frame is **static**, and measurement §1 shows
  **both banks hold byte-identical content**. Overwriting the displayed bank
  therefore rewrites each byte with the value already there. A concurrent reader
  cannot observe a difference, so it cannot produce a visible artifact.
* The idle repaint cadence is ~1 publish / 30 s (`media_player.cpp` `stepMs`,
  corroborated by the static doorbell seq above), while the artifact is
  continuous at ~60 Hz scanout.

`3798793` remains a **correct defensive fix for playback**, where consecutive
banks genuinely differ and a mid-scanout overwrite would tear. It should not be
credited with fixing, or blamed for, the idle-logo left edge. Its unit gate
(`Scope: 1`, `test_input_mailbox`) is still green on this branch.

## 6. Gates added (all with a red/green pair)

### `scripts/check_idle_ddr_frame.py --self-test`
Registered in `make unit` and in `tests/unit/test_unit_rollcall.py`
(`expected_commands` 88 → 89).

```
Scope: 4 synthetic detector cases (1 must-pass, 3 must-fail)
OK   identity_must_match
OK   stride640_must_fail_and_be_identified      best_stride=640
OK   shift_plus11_must_fail_and_be_identified   best_shift=11
OK   leading_black_run_must_fail_at_left_edge   min_first_bad_col=0
RESULT PASS detector distinguishes stride, shift and left-edge damage
```
rc `0`. It literally compares a synthetic non-uniform I420 reference against
three deliberately damaged copies. It does **not** touch hardware; it only
proves the detector is capable of failing in the three hypothesised shapes.

### `tests/hw/test_idle_ddr_frame.sh`
Live device gate. Green rc `0` on bank 0 and bank 1 (§1). Red check
`IDLE_DDR_RED=1` grades the live bank against the wrong idle mode:
rc `1`, `luma_mismatch_bytes=299520/299520`. Skips exit 77 (`hw_skip_not_pass`)
when `IDLE_SCREEN` is `lastframe`/`screensaver` (no well-defined reference) or
when the device is unreachable — never exit 0.

What it does not cover is stated in the script header and in §4.

## 7. Recommended next actions (owner in brackets)

1. **[W-FIT / parent]** The resident RBF `00eebd5e` is banned/black-screen. No
   visual gate on this defect can mean anything until a non-banned bitstream is
   resident. `READY_TO_DEPLOY` is not mine to set.
2. **[W-FIT]** After the next core reset, run
   `ssh root@$MISTER_HOST 'python3 - --watch 30 --interval 1' < scripts/ddr_frame_dump_device.py`
   and report `underrun` growth per second. Non-zero growth converts §3 from
   derived to measured.
3. **[RTL owner, not W-ARM]** The fix is in `ddr_frame_store.sv`, and there are
   two independent parts:
   * *Prefetch depth / earliness* — raise `FRAME_LINE_COUNT` (the resident build
     reports `LINE_COUNT[2:0]=000`, i.e. 8 or 16) and/or start the fill earlier
     in the blanking interval so the first visible column is never a miss.
     `test_frame_store_ddr_prefetch_sim.cpp` already scores this.
   * *Miss policy* — forcing RGB(0,0,0) on a miss makes a bandwidth hiccup look
     like torn geometry. Holding the last good pixel, or repeating the previous
     line, degrades far more gracefully and would make the artifact
     near-invisible even if a miss survives.
4. **[W-E2E]** Once (1) is resolved, capture the idle logo and grade the left
   edge with `scripts/check_edges.py` (its synthetic `hwrap` case is the right
   shape). The gate must distinguish no-signal / valid-but-black /
   valid-with-content, because with the current resident RBF "capture succeeded"
   and "the screen is black" are simultaneously true.

## 8. Two gate defects found while validating (both fixed / reported)

### `tests/unit/test_companion_eof` was 30% flaky — a false-red generator
`make unit` failed on my branch at `test_companion_eof` with
`FAIL: path callback key mismatch: /library/metadata/3`. My changes do not touch
`companion.cpp`, so I measured it instead of assuming:

| binary | runs | failures |
|---|---|---|
| pre-fix | 30 | 9 |
| pre-fix (repeat) | 40 | 14 |
| post-fix | 60 | **0** |

Root cause: the two `playMedia` callbacks are dispatched asynchronously, but the
test asserted on `captured[0]` / `captured[1]` by vector position. The order is
not guaranteed, so ~1 run in 3 saw them swapped. Fixed by selecting each request
by its metadata key instead of its index; every field assertion is unchanged, so
no coverage was dropped — only the incidental ordering assumption.

This matters beyond the flake: a gate that fails 1 run in 3 for a reason
unrelated to the product is exactly how a real regression gets waved through as
"just the flaky one".

### `make build/<target>` silently does nothing
Every build rule in the Makefile names its target as `$(ROOT)/build/<x>`, an
absolute path. `make build/test_companion_eof` is a *different* target name, so
make prints `Nothing to be done` and **exits 0 without building**. I lost one
measurement cycle to this: I "rebuilt" after editing the test, re-ran 40 times,
and got 14 failures from the unchanged binary. Use `make "$PWD/build/<x>"` or a
phony target. Not changed here (it would touch every rule), but worth knowing.

## 9. Validation run on this branch

```
make unit                                          rc=0   (full suite)
  UNIT_ROLLCALL_OK expected_commands=89 (was 88)
  Scope: 4 synthetic detector cases ... RESULT PASS
  test_companion_eof: OK
  test_input_mailbox: Scope: 1 ... OK
  GATE_SKIP_SUMMARY total=2 critical=1 high=1 advisory=0
    (both declared: live PMS baseline needs PLEX_BASE/PLEX_TOKEN/BASELINE_KEY,
     and the red-check that proves the wrapper returns 77 — neither silent)
python3 scripts/check_pipe_exit_safety.py          rc=0  PIPE_EXIT_SAFETY_OK
python3 tests/unit/test_no_conflict_markers.py     rc=0
./tests/unit/test_no_private_data.sh               rc=0
tests/hw/test_idle_ddr_frame.sh --bank 0           rc=0  (live, green)
tests/hw/test_idle_ddr_frame.sh --bank 1           rc=0  (live, green)
IDLE_DDR_RED=1 tests/hw/test_idle_ddr_frame.sh     rc=1  (live, red)
```

No RBF built, no RBF deployed, no `load_core`, no core reset, no capture device
opened, no daemon deployed. Nothing outside this worktree was modified.

## 10. Assignment 2 — ARM→FPGA bitstream feed

Unchanged on `w-arm-bitstream-feed` (`a9d6d73`). The interface agreed with
W-CAST (raw Annex-B out of `ddr_bitstream_reader.out_valid/out_byte`,
`out_flush` on Begin/Flush/End/reset, EOF = End + inactive, backpressure via
`out_full`) is honoured; I did not change it and did not renegotiate it.

---

## 11. Addendum — reachability red proof, second-bitstream reproduction, two self-caught defects

Added after the parent's REACHABILITY EVIDENCE STANDARD ruling. Raw numbers
first.

### 11.1 Nothing to withdraw

The ruling requires withdrawing any product-completeness claim resting on plain
`emu`-rooted reachability. I audited every claim in this document: **I made no
`emu` reachability claim.** Nothing to withdraw.

### 11.2 Reachability green *and* its red, core-rooted

Instrument: `scripts/check_rtl_module_instantiations.py` from `w-deblock-seam`
`7225e00` (my branch's copy predates `--root`/`--require`; I used the newer one
verbatim without modifying it).

```
GREEN   --root present_core --require ddr_frame_store   rc=0
        REQUIRED_RTL_MODULE_REACHABLE ddr_frame_store root=present_core
        rtl_modules=68 reachable=11 bench_only=24

RED     rename the instantiation at present_core.sv:239 to
        ddr_frame_store_RENAMED                          rc=1
        REQUIRED_RTL_MODULE_UNREACHABLE ddr_frame_store
        file=fpga/Plex_MiSTer/rtl/ddr_frame_store.sv parents=<none>

RESTORE git checkout -- present_core.sv                  rc=0 (green returns)
```

The mutation was performed in a **disposable linked git worktree**
(`git worktree add --detach build/redproof HEAD`, removed afterwards), never in
the shared tree. Verified after teardown: `git diff --name-only fpga/` returned
**0 files**. This satisfies hard rule 3 (no mid-fit edits to sources under a
live compile) unconditionally, rather than by checking whether a fit happened to
be running.

### 11.3 The checker's false-reachable blind spot, demonstrated concretely

The parent's caveat is not theoretical here. `present_core.sv:225` is
`` `ifdef DDR_FRAME_STORE ``, with `ddr_frame_store` instantiated in the then-branch
(line 239) and `frame_store` in the else-branch (line 293). Measured:

```
--root present_core --require ddr_frame_store   rc=0
--root present_core --require frame_store       rc=0
```

**Both branches of a mutually exclusive `ifdef` report reachable.** Only one can
be in any bitstream, so `reachable=11` over-counts the present path by at least
one module. Source-level reachability cannot settle which is in the product.

### 11.4 Hardware oracle that settles it

Stronger than post-fit hierarchy, because it interrogates the running device:

- `ddr_frame_store.sv` is the **only** RTL file that defines the PLXF
  (`0x504C5846`) and PLXD (`0x504C5844`) magics and the `FRAME_MAILBOX_PHYS` /
  `BANK_MAILBOX_PHYS` writers. `ddram_frame_rd.sv` mentions them in comments
  only.
- Those magics are readable in live DDR with an advancing heartbeat:
  `PLXF lo=0x504C5846 hi=0xFFFF10D5`.

⇒ `ddr_frame_store` is in the resident bitstream. Measured, not inferred, and it
resolves the `ifdef` ambiguity that the regex checker cannot.

Caveat carried: source-level reachability is **necessary, not sufficient**. The
hardware oracle is what makes this claim safe, not the checker.

### 11.5 The ARM-side result reproduces on a second, different bitstream

The resident RBF changed under me during this session (W-FIT deployed):

```
was  00eebd5e...  (banned / known black screen)
now  fb4bad849ad2db782a5004ce5a3471ce   NOT on the banned list
core = Plex, from /media/fat/_Utility/Plex.rbf
```

Re-ran the gate unchanged against the new bitstream:

```
bank 0  rc=0  luma_mismatch=0/299520  u=0/74880  v=0/74880   compared=449280/449280
bank 1  rc=0  luma_mismatch=0/299520  u=0/74880  v=0/74880   compared=449280/449280
```

I previously *asserted* the ARM-side result was RBF-independent. It is now
**demonstrated** across two different bitstreams. The ARM write path is correct;
the artifact is not on the ARM side.

Note for whoever owns the visual gate: the precondition I flagged in §7 — that no
HDMI before/after capture can mean anything while a banned black-screen build is
resident — **may now be satisfied**. `fb4bad84` is not on the banned list. That
is a fact about the md5, not a claim that the display shows content; only a
capture that distinguishes no-signal / valid-but-black / valid-with-content can
say that.

### 11.6 Defect I introduced and caught: a false skip

While hardening this gate I added a daemon-liveness precondition using
`pgrep -x misterplexd`. It reported `DAEMON_DOWN` and the gate returned 77.

That was wrong. Measured on the device:

```
pgrep -x misterplexd   ->  bash: pgrep: command not found   rc=127
ps w                   ->  6091 root /media/fat/misterplex/bin/misterplexd ...
```

The MiSTer userland is busybox and has **no `pgrep`**; rc=127 is falsy, so the
`||` branch fired and the check declared the daemon dead while it was running as
PID 6091. This is the house failure mode — a true number (`rc=127`) about the
wrong thing (daemon liveness). Its damage class is a **false skip**: less
dangerous than a false green, but it would have silently disabled this gate
forever while looking disciplined. Fixed to use `ps`, plus an explicit skip if
process enumeration itself fails. Found by re-measuring the device instead of
trusting the gate I had just written.

### 11.7 Defect I introduced and caught: my earlier `make unit` green did not cover my own files

`make unit` was rc=0 in §9. It then went rc=2 with no relevant source change:

```
FAIL: runtime DDR frame layout literals must route through ddr_frame_layout
derivation; found scripts/ddr_frame_dump_device.py:28: BANK_STRIDE = 0x00080000;
:29: FRAME_BYTES = 449280; :31: DOORBELL_PHYS = 0x300FF000
```

Cause: `runtime_ddr_layout_literal_offenders()` iterates
`tracked_product_relevant_files()`. When I ran §9 the file was still
**untracked**, so the sweep never looked at it. Committing it is what made it
visible.

**Generalisation worth carrying fleet-wide: a `make unit` green taken before you
`git add` does not cover the files you are adding.** Any gate keyed on
`git ls-files` is blind to your work-in-progress. Re-run `make unit` *after*
staging, not before. (The sweep's untracked-blindness is deliberate — there is a
`check_runtime_ddr_layout_literal_ignores_untracked_debris` test asserting it —
so this is a property to know, not a bug to fix.)

Fix, and why it is better than silencing the regex: the device script is piped
to the MiSTer over bare stdin and cannot import the repo's layout helpers, which
is why the addresses had been restated. They are now **derived** instead. New
`scripts/ddr_layout_consts.py` parses the single source of truth
(`host/libmisterplex/ddr_frame_layout.hpp`, plus `mailbox_abi_spec.hpp` for the
mailbox addresses) and emits them as argv; `ddr_frame_dump_device.py` now has
**no layout literals and no layout defaults** — the six address arguments are
`required=True`, so a caller that forgets them gets an error rather than a
plausible-looking dump of the wrong memory.

**And it caught me a second time, immediately.** My first fix put the mutation
strings for the `--self-test` red cases in the source as literal C++ text --
which restates `449280` and `0x00080000`. The sweep was green while the file was
untracked and went rc=1 the moment I committed it. The self-test now derives its
mutations from whatever the header currently says (regex-capture the value,
transform it) so no layout literal appears in my sources at all. Verified with an
independent scan of the banned-literal regex over all four of my files:
`banned_literals=0` in each.

Verified the derived values equal the ones I had hardcoded:

```
--ddr-base 0x30000000 --bank-stride 0x80000 --frame-bytes 449280
--doorbell-phys 0x300ff000 --plxd-phys 0x3007f128 --plxf-phys 0x3007f118
```

This is also independent confirmation that the readback in §1 addressed the
memory the layout contract specifies.

### 11.8 Gate inventory after this addendum

| Gate | Scope | Green | Red |
|---|---|---|---|
| `scripts/check_idle_ddr_frame.py --self-test` | 4 synthetic cases | rc=0 | 3 of the 4 are must-fail cases |
| `scripts/ddr_layout_consts.py --self-test` | 8 parsed constants, 3 mutations | rc=0 | 3 must-fail header mutations, header restored (`git diff` = 0 lines) |
| `tests/hw/test_idle_ddr_frame.sh` | 449280 bytes/bank, both banks | rc=0 on `fb4bad84` | `IDLE_DDR_RED=1` -> rc=1, 480/480 lines bad from col 0 |
| `tests/hw/test_idle_ddr_frame.sh` unreachable host | — | — | `MISTER_HOST=192.0.2.1` -> **rc=77**, not 1 |
| core-rooted reachability | `rtl_modules=68 reachable=11` | rc=0 | renamed instantiation -> rc=1 `parents=<none>` |

`make unit` after all of the above: **rc=0**, 2 declared skips (live PMS
baseline needs credentials, plus its own 77 red-check). Rollcall:
`actual_commands=93 protected_commands=90 expected_commands=90`.

### 11.9 Still not mine, still blocked

Unchanged from §7: the underrun **rate** needs a core reset (W-FIT) then
`ddr_frame_dump_device.py --watch`; the left-edge **pixel positions** need W-E2E
capture; the fix itself (prefetch depth `FRAME_LINE_COUNT`, and/or changing the
miss policy from black to last-good-pixel in `ddr_frame_store.sv`) is RTL-owned.
The underrun counter still reads saturated (`0xFFFF`), which proves ">=65535
misses since reset", **not** a current rate.
