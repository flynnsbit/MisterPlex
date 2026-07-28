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

---

## 12. WITHDRAWAL and re-proof, after W-FIT's dead-fabric finding

W-FIT deployed `fb4bad84` and then demonstrated that **the fabric writes nothing
to DDR** under it: poking all four mailbox words to `0xA5A5A5A5` left them
unrestored after 6 s. DDR survives FPGA reconfiguration, so any "live" mailbox
value read after that deploy may be residue from the previous bitstream.

That lands directly on two things I wrote in §11. One of them was wrong. I am
withdrawing it.

### 12.1 WITHDRAWN: the §11.4 "hardware oracle" as applied to `fb4bad84`

I claimed:

> Those magics are readable in live DDR with an advancing heartbeat:
> `PLXF lo=0x504C5846 hi=0xFFFF10D5` ⇒ `ddr_frame_store` is in the resident
> bitstream. Measured, not inferred.

**That claim is withdrawn.** It is the house failure mode and I committed it.
Three separate defects in one sentence:

1. **PLXF is `fpga_to_arm`** (`mailbox_abi_spec.hpp:118`). Under a fabric that
   writes no DDR, its contents are residue from `00eebd5e`, not evidence about
   `fb4bad84`.
2. **The heartbeat was not advancing and I never checked that it was.** Every
   sample I ever took post-deploy read the identical word. Re-measured
   deliberately, 12 samples over 60 s:
   ```
   t=0..11  PLXF_hi=0xFFFF10D5  underrun=65535 debug=0x10 seq=213   (frozen)
            PLXD_hi=0x00000000  frames_done=0                       (zeroed)
   ```
   `seq=213` is constant across all 12. I inherited "advancing" from the
   pre-deploy `00eebd5e` observation and attached it to a post-deploy reading
   that was static. A true number (`0x504C5846` really is the PLXF magic) about
   the wrong thing (whether *this* bitstream wrote it).
3. **"Stronger than post-fit hierarchy" was wrong.** A DDR read cannot be
   stronger than post-fit hierarchy when DDR is not reset by reconfiguration.

What survives: the oracle was sound **for `00eebd5e`**, where W-FIT independently
reproduced `free=0 disp=1 swap=1` with `frames_done` advancing +681/10 s. So the
§11.2 reachability green retains hardware corroboration **for the old build
only**. For `fb4bad84` I have no hardware evidence about which `ifdef` branch is
resident, and the §11.3 false-reachable blind spot is therefore unresolved on the
current build. Post-fit hierarchy (W-FIT's `4757 ALUT / 2298 reg / 96 M10K` for
`ddr_frame_store`) is now the best available oracle, not mine.

### 12.2 NOT withdrawn, and now proven properly: the ARM-side result

The same ambiguity applies in principle to my byte-exact bank comparison — a
match could be residue from a pre-deploy paint. §11.5 asserted the result was
"reproduced on a second bitstream"; strictly, what I had shown was that the bytes
were correct, not that they were *fresh*. That gap is real and I have now closed
it by measurement instead of argument.

**Poison-and-heal probe** (`tests/hw/test_idle_ddr_freshness.sh`):

```
ORIGINAL          0x2D2D2D2D x4  at 0x30000000
poison            devmem <4 words> = 0xDEADBEEF
POISON_LANDED     4/4 words read back as 0xDEADBEEF
full-payload gate rc=1  luma_mismatch_bytes=16/299520     <- poison detected
...wait...
RESTORED_AFTER_S  51   (timeout 100s)
full-payload gate rc=0  luma_mismatch_bytes=0/299520 u=0/74880 v=0/74880
```

The ARM overwrote a deliberate corruption and restored the byte-exact product
payload in 51 s, under RBF `fb4bad84`, with no fabric participation. Therefore:

- The bank is a **live ARM write, not DDR residue.** §11.5 now stands on
  measurement.
- **The ARM write path is correct and active on the current build.** The idle
  artifact is not on the ARM side. Unchanged conclusion, better evidence.
- Bonus sensitivity datum: the gate resolved a **16-byte** corruption in 299520
  luma bytes — 1 part in 18720. "Can you make it fail" is answered at fine
  granularity, not just by the blunt whole-frame red.

### 12.3 New finding: the doorbell is not a liveness instrument for idle

Measured across the poison/heal cycle:

```
before heal   DOORBELL_hi=0x200097D5  db_seq=38869
after  heal   DOORBELL_hi=0x200097D5  db_seq=38869
```

The ARM **rewrote the entire bank without bumping PLXK seq.** `db_seq` was also
static across the full 60 s watch. So a stalled doorbell does **not** imply the
ARM has stopped publishing, and anyone using PLXK seq as an ARM-liveness signal
will get a false negative on a static idle screen. Only content comparison
distinguishes them. (PLXK is `arm_to_fpga` and so is *not* void under the dead
fabric — it is simply the wrong instrument for this question.)

### 12.4 Consequences I accept for my own gates

`tests/hw/test_idle_ddr_frame.sh` prints PLXD/PLXF lines. Those lines are now
**decoration, not data** — they are informational output and are *not* part of
the grade, which is purely the positional byte comparison. No result of mine
depends on a `fpga_to_arm` mailbox. I have left the lines in because seeing
frozen residue in the log is useful context, but no claim may be built on them
while the fabric is silent.

### 12.5 On W-FIT's two notes about `3798793`

Both are correct and I am not contesting either.

- `(void)plannedBank;` does widen behaviour: the caller's ping-pong plan becomes
  advisory on both stuck paths, not merely on the one being fixed. That is a
  behavioural change, not a pure bug fix, and it should be reviewed as one.
- **The fallback is flattered by the current broken device.** With `free_mask=0`
  permanently, the timed fallback is the *only* live path, so any measurement of
  it taken now is measuring a degenerate case. On a healthy fabric
  (`free_mask != 0`) the ARM never reaches it and the change is dead code.

Given §1 and §12.2 — the ARM writes byte-exact correct payload, fresh, on the
current build — `3798793` is **not** the fix for the idle artifact and should not
be integrated as if it were. Sequencing it after a graded RBF, as W-FIT has done,
is the right call. I am not asking for it to be integrated.

### 12.6 Gate inventory delta

| Gate | Scope | Green | Red | Skip |
|---|---|---|---|---|
| `tests/hw/test_idle_ddr_freshness.sh` | 4 words poisoned, full 449280-byte payload verified | rc=0, restored in 51s | `IDLE_FRESH_NO_RESTORE=1 IDLE_FRESH_TIMEOUT_S=10` -> rc=1, originals restored by the probe | unreachable host -> rc=77 |

The probe is reversible by construction: it records the original words before
poisoning and writes them back on every failure path, so a red leaves the bank as
it found it. Verified — the full-payload gate was rc=0 immediately after the red
run.

### 12.7 What I still cannot say

Unchanged: I have never observed the artifact's pixels. No claim here is about
what is on the screen. With the fabric writing no DDR at all, the underrun-rate
measurement in §11.9 is not merely blocked on a core reset — the counter itself
is a dead instrument on this build.

---

## 13. Compliance with the REVISED reachability standard (supersedes §11.2/§11.3)

The parent's revised ruling makes a subtree proof without a trunk proof vacuous.
**§11.2 as originally written was exactly that**, so it is restated here. I also
reproduced w-audit's mutations against my own path rather than assuming their
result transfers.

### 13.1 Both directions, as now required

```
TRUNK     --root emu          --require present_core      rc=0  reachable=44
TRUNK     --root emu          --require ddr_frame_store   rc=0  reachable=44
SUBTREE   --root present_core --require ddr_frame_store   rc=0  reachable=11
```

`rtl_modules=68 bench_only=24` throughout. The subtree red proof from §11.2
stands unchanged (rename the instantiation -> rc=1, `parents=<none>`, restore ->
rc=0).

Trunk red proof, performed in a **disposable linked git worktree** so the shared
RTL was never touched (`git diff --name-only` = 0 tracked files after teardown):

```
rename Plex.sv:699 present_core -> present_core_RENAMED
  --root emu --require present_core   rc=1
  UNINSTANTIATED_RTL_MODULE present_core file=.../present_core.sv parents=<none>
```

### 13.2 w-audit's mutations, reproduced against the PRESENT path

I did not take these on faith. Measured, same disposable worktree:

| # | Mutation on my path | Checker says | Truth |
|---|---|---|---|
| M1 | rename `present_core` instantiation in `Plex.sv:699` | rc=1 | not instantiated — **correct** |
| M2 | wrap that instantiation in `generate if (0)` | **rc=0 REACHABLE** | not instantiated — **FALSE GREEN** |
| M3 | delete `present_core.sv` from `files.qip` | **rc=0 REACHABLE** | not compiled — **FALSE GREEN** |

**w-audit's finding replicates on the present path.** My §11.2 green was
vulnerable to M2 and M3, and would have been reported as evidence.

### 13.3 A fourth defect: `--require` is unreachable code under `--root emu`

New, not in w-audit's list. `check_rtl_module_instantiations.py`:

```python
if args.root == PRODUCT_ROOT:          # emu only
    ...
    fail("RTL modules must be product-reachable from emu or ...")   # exits here
unknown_required = ...                  # never evaluated
unreachable_required = ...              # never evaluated
```

So with `--root emu`, whenever *any* module is unreachable-and-not-bench-listed,
the blanket rule calls `fail()` and the `--require` clause never runs. Measured
in M1: `REQUIRED_RTL_MODULE_UNREACHABLE` count = **0**, despite `present_core`
being precisely the required-and-unreachable module. The failure surfaced only as
a generic `RTL_MODULE_INSTANTIATION_FAIL`.

**Severity, stated honestly: this is a diagnostic defect, not a false green.**
`rc` is still 1. I checked the genuine-hole case (module disconnected *and*
bench-listed, so the blanket rule passes) and the `--require` clause does fire
there, so it remains a real safety net. But a reviewer grepping for
`REQUIRED_RTL_MODULE_UNREACHABLE` to confirm a red will find nothing and may
conclude the require passed. **For W-GATE-O5: evaluate `--require` before the
blanket sweep, or accumulate rather than short-circuit.**

### 13.4 Closing M2 and M3 for the present path: new gate

`scripts/check_present_path_synthesis.py`, registered in `make unit` and rollcall
(`expected_commands=91`). For `present_core` and `ddr_frame_store` it checks what
the instantiation graph structurally cannot:

```
QIP_OK            present_core     rtl/present_core.sv
GENERATE_DEPTH_OK present_core     depth=0  Plex.sv:699
IFDEF_OK          present_core     guards=none
QIP_OK            ddr_frame_store  rtl/ddr_frame_store.sv
GENERATE_DEPTH_OK ddr_frame_store  depth=0  present_core.sv:239
IFDEF_OK          ddr_frame_store  guards=['ifdef:DDR_FRAME_STORE'] (qsf satisfies)
RESULT PASS checks=8 failures=0
```

`--self-test` ships **1 green + 4 reds**, one per mutation class: missing
`files.qip` entry, disabled generate block, guarding macro not defined in
`Plex.qsf`, instantiation removed. All four caught, in-memory, no file mutation.

### 13.5 The ifdef ambiguity of §11.3 is resolved — without my withdrawn oracle

§11.3 reported that the checker calls **both** branches of
`` `ifdef DDR_FRAME_STORE `` reachable (`--require ddr_frame_store` rc=0 *and*
`--require frame_store` rc=0), and §11.4 used a hardware oracle to break the tie.
That oracle is withdrawn (§12.1). The tie is nevertheless broken, by a better and
purely static instrument:

```
Plex.qsf:82   set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
```

The macro is defined for the Quartus build, so the then-branch is compiled and
`frame_store` is not. This is stronger than my DDR read because it cannot be
residue, and it is now enforced by the `IFDEF_OK` check above rather than being a
one-off observation.

### 13.6 The real oracle — and why I am not claiming it

Per the ruling, `make post-fit-hierarchy` is the only real oracle. Both my
modules **are** in the critical list (`tests/fixtures/critical_fit_hierarchy.json`
= `ddr_frame_store, present_core, stream_path, ddr_bitstream_reader`), so a
post-fit run would directly confirm the present path.

**I cannot run it for `fb4bad84`.** I scanned every `Plex.rbf` on this machine
modified since 2026-07-27 and **none** has md5 `fb4bad849ad2db782a5004ce5a3471ce`,
so I cannot bind any local fit report to the resident bitstream. Running
`post-fit-hierarchy` against an unbound report and presenting it as evidence
about `fb4bad84` would be precisely the "true number about the wrong thing" this
project keeps producing. That evidence is W-FIT's to produce; their reported
`ddr_frame_store = 4757 ALUT / 2298 reg / 96 M10K` is one of my two modules
already confirmed, and `present_core` is still outstanding.

### 13.7 Restated claim

**`ddr_frame_store` is in the present path of the design as described in source,
and the present path is connected to `emu`.** Supported by: trunk reachability
(both modules), subtree reachability, `files.qip` membership, generate-depth 0 at
both instantiation sites, `DDR_FRAME_STORE=1` in `Plex.qsf`, and W-FIT's post-fit
resource figures for `ddr_frame_store`.

**Necessary, not sufficient.** Outstanding: post-fit hierarchy evidence for
`present_core` bound to `fb4bad84`. And none of this touches the actual defect —
whether `ddr_frame_store`'s miss-to-black policy is what the user sees remains
unobserved, because no one has captured the pixels.

---

## 14. Two landmines found in the mandated evidence path

Triggered by the parent's note that `check_rtl_module_instantiations.py` on
`parent/integ-hour27` silently ignores unknown args. I checked my own branch
first, then the mandated merge base. Raw numbers first.

### 14.1 The landmine was on MY branch, and my own §13 published the command lines

`w-arm-idle-edge` shipped the argument-ignoring checker (6919 bytes, no
`argparse`, `def main() -> int:` taking no argv). Measured before the fix:

```
scripts/check_rtl_module_instantiations.py --root emu --require h264_decode_core
  rc=0   RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=44 bench_only=24 root=emu

scripts/check_rtl_module_instantiations.py --help
  rc=0   RTL_MODULE_INSTANTIATION_OK ... root=emu
```

`h264_decode_core` is **ABSENT from the fitted silicon of `fb4bad84`**. So my
branch would hand a reviewer a confident rc=0 for the single module that the
strongest oracle proves is not in the chip. My §13 quotes those exact command
lines, so I published the instructions for generating that false green.

**My own measurements are unaffected.** I ran every reachability check through
`build/check_rtl_core_rooted.py`, the argparse version extracted from
`w-deblock-seam`, and the differential proves the flag was honoured:
`--root emu` reports `reachable=44` while `--root present_core` reports
`reachable=11`. An ignored flag cannot produce two different numbers. The
argparse version also rejects unknown args with rc=2.

Fixed by adopting the argparse version on this branch. After the fix:

```
--bogus                                  rc=2  unrecognized arguments
--root emu --require h264_decode_core    rc=1
  REQUIRED_RTL_MODULE_UNREACHABLE h264_decode_core parents=<none>
```

rc=1 with `parents=<none>` now **agrees with post-fit hierarchy**. Three oracles
concur on this branch, where before the tool disagreed with silicon.

This is convergence with the version already on `w-deblock-seam`, not a
competing change; **W-GATE-O5 owns the canonical fix.**

### 14.2 New gate: `scripts/check_reachability_tool_integrity.py`

Registered in `make unit` and rollcall (`expected_commands=92`). Proves the
checker is *listening*, which is prior to whether its answer is right:

```
OK unknown argument rejected rc=2
OK --root honoured differentially: emu reachable=44 vs present_core reachable=11
OK --require honoured for a nonexistent module rc=1
RESULT PASS reachability tool integrity 3/3
```

The red is **not synthetic** — it restores the actual defective file from
`origin/w-decode-hour27` and re-runs:

```
FAIL unknown argument was silently accepted (rc=0); flags may be ignored
FAIL --root appears ignored: emu and present_core both report reachable=44
FAIL --require accepted a nonexistent module (rc=0); flag may be ignored
RESULT FAIL reachability tool integrity failures=3/3
```

The differential `--root` check is the load-bearing one: it cannot be satisfied
by a tool that discards the flag, because two roots must yield two counts.

### 14.3 The mandated merge base ships the defective checker

Measured on `origin/w-decode-hour27` `2f165ed`, in a disposable worktree:

```
scripts/check_rtl_module_instantiations.py = 6919 bytes, no argparse
mandated command line -> rc=0  reachable=50 bench_only=18 root=emu   (VACUOUS)
```

**Ruling 3 condition 1 cannot be verified using the merge base's own script.**
Anyone confirming it from `w-decode-hour27` gets rc=0 unconditionally.

**The parent's Ruling 1 conclusion is nevertheless CORRECT.** Re-measured on the
same sources with the strict checker:

```
--root emu --require h264_decode_core   rc=0  REQUIRED_RTL_MODULE_REACHABLE
--root emu --require decode_stub        rc=0  REQUIRED_RTL_MODULE_REACHABLE
```

The core genuinely is connected to `emu` on `2f165ed`. The ruling stands; only
the means of re-verifying it is broken. Use a strict checker, not the branch's.

### 14.4 Ruling 3 condition 2 is ALREADY satisfied on the merge base

Ran `w-fit-o5`'s `check_qip_coverage.py` (`ee2ed89`, from
`origin/parent/integ-hour27`) against `2f165ed`:

```
Scope: 36 files in files.qip; 39 .sv tracked under rtl/; product RTL 37
tracked but NOT compiled: 2 / 37
  ALLOWED_ABSENT cos.sv
  ALLOWED_ABSENT h264_decode_skeleton.sv
QIP_COVERAGE_OK product=37 compiled=35        rc=0
```

`h264_decode_top.sv` and `h264_intra_nb_ctx.sv` are **both already in
`files.qip` on `2f165ed`**. The `NOT_COMPILED` failure was a property of the
deployed branch, not the merge base. **W-DECODE-O5: that part of your assignment
may already be done — verify before editing `files.qip`, or you will add
duplicate entries.** Note `check_qip_coverage.py` does not exist on `2f165ed`
and must be carried over to run condition 2 from there.

### 14.5 Sequencing hazard between Ruling 2 and Ruling 1

Core-subtree membership on `2f165ed`, strict checker, **denominator 16 modules**:

```
UNDER_CORE  8/16   h264_decode_top, h264_intra_nb_ctx, h264_mv_pred_16x16,
                   h264_mv_pred_part, h264_luma_qpel_sample,
                   h264_chroma_epel_sample, h264_dpb_i420_addr,
                   h264_dpb_mb_write_addr

NOT_UNDER   8/16   h264_inter_mc_part          parents=decode_stub
                   h264_inter_mc_16x16         parents=h264_inter_mc_part
                   h264_luma_qpel_block_16x16  parents=h264_inter_mc_16x16
                   h264_chroma_epel_block_8x8  parents=h264_inter_mc_16x16
                   h264_dpb_one_ref            parents=decode_stub,h264_decode_skeleton
                   h264_luma_ref_tap_addr      parents=decode_stub,h264_decode_skeleton
                   h264_ref_clamp              parents=h264_luma_ref_tap_addr
                   h264_deblock_writeback_ctrl parents=decode_stub,h264_decode_skeleton
```

**Every one of the 8 NOT_UNDER modules traces back to `decode_stub`**, directly
or transitively. Ruling 2 orders `decode_stub` retired for M10K capacity, and
Ruling 1 requires the core connected. Done in the wrong order these conflict:

> **Retiring `decode_stub` before re-parenting these 8 under `h264_decode_core`
> will orphan all 8 at once.** They move from "reachable via the wrong parent" to
> `parents=<none>`, the blanket sweep fails, and the tempting repair —
> bench-listing them — makes them vanish from the product silently, which is the
> exact failure class we are trying to stop.

**Recommended order: re-parent first, retire second, re-run both directions
after each step.** For W-DECODE-O5 and W-SWAP-O5.

Also note `h264_deblock_writeback_ctrl` is NOT under the core on `2f165ed`
(`parents=decode_stub,h264_decode_skeleton`) — the mirror image of w-audit's
finding on `w-deblock-seam`, where it was under the core but the core was
orphaned. **Neither branch currently has both properties**, which is precisely
why the convergence is necessary rather than cosmetic.

### 14.6 Scope limits of everything in §14

All of §14 is source-level, measured on `2f165ed` and on this branch. It is
necessary, not sufficient. I hold no post-fit evidence for any of it, and
`present_core` post-fit confirmation for `fb4bad84` remains outstanding from
W-FIT. Nothing in §14 changes any conclusion in §1-§13: the ARM write path is
correct and live, and the idle artifact remains RTL-side and unobserved.

---

## 15. Post-fit evidence bound to the RESIDENT bitstream, and a correction to §14

Branch `w-arm-idle-edge`. Parent message of 2026-07-28 12:41 established a third
product-absence mode — **instantiated, elaborated, then optimized away** — that no
source-level tool can detect. Everything I claimed in §11–§14 about the present path
is source-level, therefore *all of it was mode-3 blind*. This section closes that.

### 15.1 CORRECTION: I was wrong that no local report binds to `fb4bad84`

In §14 I reported: *"No local `Plex.rbf` has md5 `fb4bad84…`, so I cannot bind any
local fit report to the resident bitstream."*

**That was false.** Measured now — enumerate every `Plex.fit.rpt` on the host and md5
its sibling RBF:

```
2026-07-28_09:47  fb4bad84  mp-wt-integ/.../remote_out/wfit-hour27-sdc-a/Plex.fit.rpt
2026-07-28_10:01  fb4bad84  mp-wt-integ/.../remote_out/wfit-hour27-sdc-b/Plex.fit.rpt
2026-07-28_10:23  fb4bad84  mp-wt-integ/.../remote_out/wfit-hour27-bdiag-a/Plex.fit.rpt
2026-07-28_10:36  fb4bad84  mp-wt-integ/.../remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt
2026-07-28_01:51  00eebd5e  mp-wt-time/.../remote_out/wtime4/Plex.fit.rpt
```

Full md5 of the bdiag-b sibling: `fb4bad849ad2db782a5004ce5a3471ce` — **identical to
the on-device md5 W-FIT read from `/media/fat/_Utility/Plex.rbf`.**

Cause of my error: my earlier scan looked for `Plex.rbf` under paths I had already
decided were mine to read, and I had excluded `mp-wt-integ` as parent-only. Reading a
report is not editing a tree. **A self-imposed scope limit silently became a claim
about the world.** That is the same failure class as everything else in this document,
committed by me, and it cost a day of "no post-fit evidence available".

### 15.2 The present path IS in the resident silicon (denominator 827)

`scripts/check_map_hierarchy.py` from w-fit-o5 `a8aa8eb`, run against the report bound
to `fb4bad84`:

```
Scope: 827 entity rows parsed from Plex.fit.rpt [fit (post-fit)]
PRESENT present_core     instances=1 subtree_rows=487 parents=emu
PRESENT ddr_frame_store  instances=1 subtree_rows=482 parents=present_core
ABSENT  frame_store
```

Corroborated independently of that tool, by raw indent in the entity table (indent is
the only nesting encoding Quartus emits):

```
line   66  ;    |emu:emu|                    indent 4
line  206  ;       |present_core:present|    indent 7   -> child of emu
line  211  ;          |ddr_frame_store:fstore| indent 10 -> child of present_core
line  693  ;       |stream_path:spath|       indent 7
line  700  ;          |decode_stub:stub|     indent 10
```

Three consequences:

1. **The present path is not a mode-3 victim.** Unlike `h264_decode_core`, it survives
   synthesis and fitting, with resources: `present_core` 4939 ALUT / 2514 reg /
   225,280 block bits / 103 M10K / 7 DSP; `ddr_frame_store` 4757 / 2298 / 159,744 /
   96 / 6. The trunk `emu -> present_core` and subtree `present_core ->
   ddr_frame_store` are both proved **in silicon**, not in a regex.
2. `frame_store` is **ABSENT**, so the `` `ifdef DDR_FRAME_STORE `` else-branch was not
   taken. §13 resolved that tie *statically* from `Plex.qsf:82`. It is now confirmed
   post-fit. The static resolution was right; it is no longer the only evidence.
3. Identical results on `00eebd5e` (819 rows), the previous resident build. The present
   path did not change across the regression W-FIT reported.

### 15.3 Prefetch depth in silicon is 8 lines — derived, then confirmed arithmetically

New gate `scripts/check_fitted_line_buffer.py`. It does not ask "is the module there";
it asks **"is the line buffer the size the sources say"**, which is the number the
artifact actually depends on.

Prediction, every term read from a file, nothing restated as a literal:

```
Plex.qsf:85                     VERILOG_MACRO "FRAME_LINES_8=1"
present_core.sv:19-25 ladder    FRAME_LINES_8 -> FRAME_LINE_COUNT = 8
ddr_frame_store.sv:81           LINE_SLOTS = LINE_COUNT * 2      -> 16
ddr_frame_layout_params.svh     luma 78 qwords, chroma 39 qwords
ddr_frame_store.sv:138-140      3 per-slot buffers, 64 bits wide

predicted = 16 * (78 + 39 + 39) * 64 = 159,744 bits
```

Measured, from the report bound to `fb4bad84`:

```
Scope: 827 entity rows in Plex.fit.rpt
BOUND report -> Plex.rbf md5=fb4bad84
MATCH  159744 bits  |ddr_frame_store:fstore|
LINE_BUFFER_OK predicted=159744 instances=1 rows=827
```

Exact, to the bit. And the four source files that feed the prediction are
**byte-identical (`git hash-object`) to `origin/parent/integ-hour27`**, the branch
checked out in the fit worktree, so the prediction is about the deployed design and not
about my branch.

**So: the resident silicon prefetches 8 lines per set.** Not 4, not 16 — measured.

Red/green pair: `--self-test` = 1 green + 4 reds + 1 skip, all passing —
half-size buffer FAIL(1), module optimized away FAIL(1), zero entity rows REFUSE(2),
unsatisfiable RBF binding FAIL(1), missing report SKIP(77).

**The binding is the point.** W-FIT's tool takes a report path; nothing in the fleet
checked that the report describes a bitstream anyone is running. There are 40 fit
reports on this host and 35 of them describe builds that were never deployed. Without
`--expect-rbf-md5` this gate prints `UNBOUND` rather than a clean pass.

### 15.4 The artifact mechanism, now structurally complete

```
ddr_frame_store.sv:312   hit search iterates vi < LINE_COUNT over ONE set
                         (disp_buf ? SECOND_SET_BASE : 0), so 8 of 16 slots
                         are searchable at any instant
ddr_frame_store.sv:332   rd_miss_now = rd_active && rd_visible && has_frame
                                       && (!y_hit_now || !c_hit_now)
ddr_frame_store.sv:1105  y_valid[fill_idx] <= 1'b1   -- set ONLY when the whole
                         line has landed, never incrementally
ddr_frame_store.sv:422   miss_d -> rd_r/rd_g/rd_b <= 0
```

Because validity flips **mid-scanline**, a line whose refill completes part-way through
the active region produces **black pixels from `PRESENT_X` up to the completion point,
then correct pixels**. Per-line variation in completion point gives a ragged edge;
per-frame variation makes it move. `rd_visible` already blacks `x < 11`, so the band
starts exactly at the pillar boundary. All four of the user's particulars — left,
jagged, moving, needs a fresh core reset (empty prefetch pipeline) — fall out of this.

**Not claimed:** I have still never observed the artifact's pixels, and I have not
measured the refill *rate*. Capacity is measured; sufficiency is not. This is a
mechanism consistent with the report, not a proof of it.

### 15.5 The underrun counter saturates by construction — it can never be a rate

`ddr_frame_store.sv:413` increments `underrun_count` once per **missed pixel**, and
`ddr_frame_store.sv:864` does the same for `frame_underrun_ddr`, both saturating at
`16'hFFFF`. The visible region is 618 x 480 = 296,640 pixels/frame. Even a 5% miss rate
saturates 65,535 in under 5 frames.

I previously described this counter as "a dead instrument on this build". **That was
wrong in an important way**: it is not broken, it is *the wrong instrument*. `0xFFFF`
means "at least one miss since reset", nothing more. Anyone who reads it as a severity
or rate is reading a true number about the wrong thing. **A useful instrument would be
missed pixels per frame, latched at vsync — that does not exist.** [RTL owner]

### 15.6 Renamed a gate of my own that was lying by its name

`scripts/check_present_path_synthesis.py` -> `scripts/check_present_path_compiled.py`.

The old name implied it knew whether the modules survive synthesis. It does not — it
checks `files.qip` membership, generate-nesting depth and `ifdef` macro definition,
i.e. modes 1 and 2 only. Anyone grepping the roll-call for "synthesis" would have
believed the mode-3 question was already covered on this path. It now prints, before
any verdict:

```
WARNING this gate CANNOT detect optimize-away (mode 3): a module may pass every
check here and still contribute zero logic to the bitstream. Use
check_fitted_line_buffer.py or make post-fit-hierarchy.
```

This is the same warning the parent assigned to W-GATE-O5 for the two cheap fleet
gates; I applied it to mine rather than waiting.

### 15.7 Capacity datum that reframes Ruling 2

From the same `fb4bad84` entity table:

```
emu                              2,585,536 bits  394 M10K  41 DSP
stream_path                      2,360,256 bits  291 M10K  34 DSP
  decode_stub                    2,097,152 bits  256 M10K  33 DSP
    altsyncram:dpb_mem_rtl_0     2,097,152 bits  256 M10K   0 DSP   <-- ALL of it
present_core                       225,280 bits  103 M10K   7 DSP
  ddr_frame_store                  159,744 bits   96 M10K   6 DSP
```

**100% of `decode_stub`'s 256 M10K is a single `altsyncram:dpb_mem` instance.** It is
not painter logic — it is a DPB. A real decoder needs a DPB too. So retiring the stub
does not straightforwardly hand 46% of the device to W-SWAP-O5's seven modules; it
frees a buffer that the replacement will substantially want back, unless the product
DPB lives in DDR. [parent / W-SWAP-O5 / W-DECODE-O5]

### 15.8 Device unreachable — my hardware gates degrade correctly

Measured myself rather than inheriting the parent's report:

```
ping -c 3 192.168.1.183   -> 3 transmitted, 0 received, 100% loss,
                             "Destination Host Unreachable"
ssh                       -> rc=255 "No route to host"

tests/hw/test_idle_ddr_frame.sh      rc=77  SKIP-NOT-PASS ... unreachable (ssh rc=255)
tests/hw/test_idle_ddr_freshness.sh  rc=77  SKIP-NOT-PASS ... unreachable
```

Both exit **77**, neither exits 0. That is the behaviour I claimed for them in §9 and
it is now demonstrated against a genuinely absent device rather than a simulated one.

### 15.9 What is still not evidence

* Refill *rate* versus scanline time — unmeasured, needs a live device.
* Artifact pixels — never observed. [W-E2E-O5]
* Whether raising `FRAME_LINES_8` to `FRAME_LINES_16` in `Plex.qsf:85` fixes it. That
  is a one-line `.qsf` change, not an RTL redesign, but it is an FPGA build artifact
  and **I am not touching it**. Cost estimate: the buffer doubles in *depth*, and at
  159,744 bits across 96 M10K the current packing is only 16% efficient, so the M10K
  delta is very likely well under +96. **That is an estimate, not a measurement** — the
  only way to know is to run `check_prefit_elaboration.sh` on the change, which costs
  4m23s and no fit token. [W-FIT-O5 / RTL owner]

---

## 16. The SDC A/B, measured — and a vacuity guard built from w-fit-o5's lesson

Branch `w-arm-idle-edge`. w-fit-o5 (`5882781`) refuted "the SDC change is netlist
neutral": `wfit-hour27-a` (`3b1e8435`) and `wfit-hour27-bdiag-b` (`fb4bad84`) differ in
`Plex.sdc` and **nothing else**, yet produce different bitstreams. The original
exoneration compared four slots that all carried the *same* new SDC, so it demonstrated
fitter determinism, not neutrality — a control that never varied its independent
variable.

Both fit reports and both STA reports are on this host beside their RBFs, so the
following is measured, not inferred. I own the present path, so I measured what the
constraint change did to it.

### 16.1 What the SDC change did to the netlist — denominator 827 entity paths

```
Scope: A=3b1e8435 (old SDC, set_false_path)  B=fb4bad84 (new SDC, set_max_delay 50.0)
       827 vs 827 entity paths, 827 common, 0 present on one side only

Combinational ALUTs        IDENTICAL in every path
Block Memory Bits          IDENTICAL in every path
M10Ks                      IDENTICAL in every path
DSP Blocks                 IDENTICAL in every path
Dedicated Logic Registers  39/827 paths differ, net +21
    +16  ascal:ascal
    +12  sys_top (top level)
     -8  emu|hps_io
     +7  osd:hdmi_osd
     -6  audio_out
     +5  emu|present_core            (2509 -> 2514)
     +5  emu|present_core|ddr_frame_store  (2293 -> 2298)
     -2  emu|stream_path|decode_stub
```

So the constraint change moved **register placement only**, design-wide, in both
directions, with **no combinational, memory or DSP change anywhere**. `ddr_frame_store`
moved +5 registers = **+0.22%**, which is smaller than `ascal`'s +16 and
indistinguishable from the global jitter.

### 16.2 My own near-miss, caught before publishing

My first pass printed *"130 differing paths touching present/ddr/stream"* and I was one
step from concluding **"the SDC delta is concentrated in `ddr_frame_store`'s clock-domain
crossing"**. That would have been a compelling, wrong story pointing straight at the
dead-DDR regression.

It is wrong because of the denominator. `ddr_frame_store` contains **467 of the design's
`mplex_hold_lcell` instances**. Any global placement jitter therefore lands mostly
inside it by sheer instance count:

```
mplex_hold_lcell instances                467
  with an ALM packing delta                91   (48 up, 43 down)
  of those, inside ddr_frame_store         90
```

48 up and 43 down is a **redistribution with no net direction**, and the values flip
between 0.5 and 0.7 ALM — packing, not function. A count without its denominator turned
noise into a headline. Same failure class as everything else here; caught this time
because I asked for the denominator before writing the sentence.

### 16.3 Both builds close timing — which does NOT exonerate the constraint

From the two `Plex.sta.rpt` files:

```
                       3b1e8435 (old SDC)   fb4bad84 (new SDC)
Setup WNS                  +0.185               +0.289
Hold WNS                   +0.248               +0.245
Recovery WNS               +0.676               +0.375
Removal WNS                +0.902               +1.090
End Point TNS, all         0.000                0.000
Unconstrained Clocks       0                    0
```

Every slack is positive in both, TNS is zero in both. **"Timing closed" is green on the
build whose fabric writes nothing to DDR.** Read as "timing is fine", that is a true
number about the wrong thing: `set_false_path` means a path is *not analysed at all*, so
a green under the old SDC never covered the crossing, and a green under the new one is
a different question answered.

One measured asymmetry I can report but not explain, and am not attributing:

```
Restricted Fmax, every clock, is LOWER in the new-SDC build
  emu|pll general[0]   24.45 -> 23.73 MHz
  emu|pll general[2]   93.63 -> 92.40 MHz
  FPGA_CLK1_50         82.80 -> 81.87 MHz
```

Fmax fell on every clock while reported setup slack improved. Both can be true — they
are different metrics — and the drop is consistent with previously false-pathed logic
now being analysed. **Hypothesis, not a finding.** [W-FIT-O5 owns timing/SDC]

### 16.4 The present path is a valid A/B partner

`3b1e8435` scores exactly as `fb4bad84` does on my gate: 827 entity rows, `present_core`
under `emu`, `ddr_frame_store` under `present_core`, line buffer `MATCH 159744 bits`,
`BOUND report -> Plex.rbf md5=3b1e8435`. So whichever way the deploy goes, the present
path is identical in both and cannot be a confounder for the PLXD question.

### 16.5 Vacuity guard shipped, red-proved on the real artifacts

w-fit-o5 asked for a permanent check of the generalisable form *"does this comparison
actually differ in the thing it claims to test?"*. Since the vacuous control was over
fit reports, I put the guard in my own report gate:

```
check_fitted_line_buffer.py A.fit.rpt --compare B.fit.rpt
```

* refuses **rc=2 VACUOUS CONTROL** when both reports bind to the same RBF md5
* refuses **rc=2** when either side has no sibling `Plex.rbf` to bind to
* otherwise prints per-column deltas with the common-path denominator

The red is **not synthetic** — it is w-fit-o5's original comparison, re-run:

```
A=wfit-hour27-sdc-a  rbf=fb4bad84
B=wfit-hour27-bdiag-b rbf=fb4bad84
REFUSED: VACUOUS CONTROL -- both reports bind to the SAME RBF md5=fb4bad84.
rc=2
```

and the green is the genuine pair (`3b1e8435` vs `fb4bad84`, `COMPARE_OK paths=827`).
Self-test is now 2 greens + 6 reds + 1 skip.

### 16.6 What I did not measure

* Which SDC line changed, and whether the crossing it constrains is the one carrying
  PLXD. I read the STA summaries, not the constraint file diff. [W-FIT-O5]
* Anything about `3b1e8435`'s runtime behaviour — it has never been deployed.
* Whether register placement can, by itself, kill the fabric's DDR writes. Resource
  equality does **not** exonerate a timing constraint; it only says the failure, if it
  is the SDC, is a timing failure rather than a structural one, and the instrument for
  that is STA on the specific crossing, not the entity table.

---

## 17. I applied w-audit's three attacks to my own gate. Two of them landed.

Branch `w-arm-idle-edge`. `w-audit` (`a9eac7e`) broke w-fit-o5's pre-fit gate three
ways. Rather than treat that as someone else's bug, I ran the same three attacks
against `scripts/check_fitted_line_buffer.py`, which is the gate my entire §15/§16
present-path evidence rests on.

### 17.1 UNBOUNDED TABLE — the defect was real in my gate

A Quartus fit report has ~15 further tables after the entity table (`Fitter RAM
Summary`, `DSP Block Details`, `Routing Usage Summary`, …). Measured red, against the
**real** `fb4bad84` report with one entity-shaped row spliced into a later table:

```
BEFORE FIX
  Scope: 828 entity rows        <- absorbed a row from a different table
  2 ddr_frame_store instance(s)
  MISMATCH 999999 bits (predicted 159744, 6.260x)  |bogus
```

The poisoned value was scored. Here it happened to fail, but only because I chose an
absurd number: a poisoned row carrying the *correct* 159,744 under a bogus parent would
have produced a clean green.

```
AFTER FIX
  Scope: 827 entity rows        <- identical to the clean report
  1 ddr_frame_store instance(s)
  MATCH  159744 bits  |sys_top|emu:emu|present_core:present|ddr_frame_store:fstore
```

The table now terminates at the first row that is not a `|node|` row, including short
prose/header rows — verified against the real reports, where **every** in-table row
leads with `|node|`. Re-checked all four reports afterwards: `fb4bad84` 827,
`3b1e8435` 827, `00eebd5e` 819, poisoned 827.

### 17.2 ANCESTOR HIDING — also real, and it was in my published evidence

w-audit's point was that `parents=` summaries and direct-parent checks let an ancestor
such as `decode_stub` disappear. **My §15 evidence cited the short form**, because a
preference bug always picked the bare node cell:

```
BEFORE   MATCH 159744 bits  |ddr_frame_store:fstore|
AFTER    MATCH 159744 bits  |sys_top|emu:emu|present_core:present|ddr_frame_store:fstore
```

The gate now keys on the report's own `Full Hierarchy Name` column and **refuses rc=2
if that column is absent**, because a bare node name cannot prove an ancestor is not
there. Added `--forbid-ancestor` and `--require-ancestor`, both walking the **entire
chain** rather than the direct parent — that is exactly the fix the parent asked
w-fit-o5 to make, applied here. Red-proved with a **nested** mask
(`emu -> decode_stub -> wrapper -> ddr_frame_store`), which a direct-parent check would
miss and which this catches.

**The §15.2 conclusion is unchanged and now better evidenced.** Re-run with the trunk
and stub checks explicit, against the resident bitstream:

```
python3 scripts/check_fitted_line_buffer.py <fb4bad84 report> \
    --expect-rbf-md5 fb4bad84 \
    --require-ancestor emu --require-ancestor present_core \
    --forbid-ancestor decode_stub
rc=0
BOUND report -> Plex.rbf md5=fb4bad84
MATCH 159744 bits  |sys_top|emu:emu|present_core:present|ddr_frame_store:fstore
```

Independently corroborated straight from the report's own `Full Hierarchy Name` column:

```
|sys_top|emu:emu|present_core:present
|sys_top|emu:emu|present_core:present|ddr_frame_store:fstore
```

No hidden ancestor at any depth. Trunk and subtree in one citation.

### 17.3 The third attack did not land

w-audit's `--forbid-only-under` direct-child defect has no analogue here: this gate
never had a direct-parent check to get wrong — it had **no** ancestor check at all,
which is why I added one that walks the chain from the start.

### 17.4 Self-test is now 3 greens + 10 reds + 1 skip, all passing

```
green  fitted size equals predicted size
red    half-size buffer must FAIL
red    optimized-away module must FAIL
red    Scope 0 rows must REFUSE (2)
red    entity-shaped row in a LATER table must be excluded
red    NESTED forbidden ancestor must FAIL
red    absent required ancestor must FAIL
green  real chain satisfies trunk and forbids stub
red    missing Full Hierarchy column must REFUSE (2)
red    unsatisfiable RBF binding must FAIL
red    same-RBF A/B must REFUSE as vacuous (2)
red    unbindable A/B side must REFUSE (2)
green  differing-RBF A/B compares
skip   missing report must be 77
```

Three of those reds are reproductions of defects that were genuinely present in this
gate an hour ago. A gate that has never failed for a real reason is not a gate.

### 17.5 What this does not change

None of §15's or §16's numbers moved. The line buffer is still 159,744 bits, the
prefetch depth is still 8 lines, the SDC delta is still register-placement-only across
827 paths, and the artifact is still RTL-side and still unobserved. What changed is
that the evidence now cites full hierarchy chains and survives the three attacks that
broke the equivalent fleet instrument.

---

## 18. The HDMI capture of `fb4bad84`, checked against my own code

W-FIT-O5 (`fc9d23d`, §27) relayed W-E2E's capture of the resident bitstream and
attributed the result to my timed bank fallback:

```
Scope: 40 frames over 120 s (interval 3 s), fb4bad84 resident, misterplexd pid 7518
CONTENT_PRESENT   2/40   t=27.1 s sha 871cb502 luma 36.50 std 22.17
                         t=69.1 s sha 04e8975a luma 36.50 std 22.16
BLACK_SIGNAL     37/40   sha 2358782e luma  7.00 std  0.00
NO_SIGNAL         0/40
CAPTURE_ERROR     1/40
```

Three claims were made about my code. I checked all three. **One is confirmed
and worse than stated; two are refuted by the capture's own numbers.**

### 18.1 CONFIRMED, and worse: `3798793` cannot execute on this build

`sendDdrFrame` reaches `timedFallback` by three routes:

| route | condition | bank chosen |
|---|---|---|
| 1 | `readBankRelease()` fails — no `PLXS` magic (`fpga_spi.cpp:1474`) | `plannedBank` |
| 2 | magic present, `frames_done` never advances for 10 reads (`:1402`) | `plannedBank` |
| 3 | magic present, `frames_done` advances, `free_bank_mask` stays 0 (`:1426`) | `chooseDdrPresentBankFromRelease` |

`displayAvoidingFallbackBank()` — the entire content of `3798793` — is called
**only from `chooseDdrPresentBankFromRelease`**, i.e. only on route 3. Route 3
requires `frames_done` to advance, which requires a **live** fabric. Routes 1
and 2 set `timedFallback` and jump straight past the call.

**A permanently silent fabric takes route 1 or 2. `3798793` is unreachable
exactly where it was needed.** Integrating it would not have moved 2/40.

Second defect: even on route 3 it derives the bank to avoid from
`BankReleaseStatus::disp_bank` — a field read from the mailbox that the same
code path has just declared untrustworthy.

**Fixed in `423eaae`.** The interlock now sits where all three routes converge,
and the scanned bank is derived from host state:

- `ddr_frame_store.sv:208` — `disp_bank <= 1'b0` at reset
- `ddr_frame_store.sv:238` — `disp_bank <= pending_bank`, its **only** other assignment

So the scanned bank is the last bank the host doorbelled, or 0 before any
doorbell — knowable with the mailbox permanently dead. Gated on
`!plxdLivenessProven_`, so a live mailbox still outranks the inference. This is
structural, not timing: `kDdrBankReuseMinUs` (40 ms) is a floor, and no elapsed
time makes overwriting the scanned bank safe. Red-proved: reverting to
`plannedBank` fails 15 assertions.

### 18.2 REFUTED: "~42 s is the signature of your timed bank fallback"

**There is no 42 s anything in the ARM, and no timer that cycles banks.** The
complete set of cadences:

| constant | value | site |
|---|---|---|
| static idle repaint | **30 000 ms** | `media_player.cpp:701` |
| screensaver step | 100 ms | `media_player.cpp:701` |
| `kDdrBankReuseMinUs` | 40 ms (a floor, not a period) | `fpga_spi.cpp:38` |

The bank is chosen **per publish**, not on a timer. 42 s is not 30 s, not a
multiple of it, and not a beat of anything in the list.

**And two events cannot establish a period.** n=2 yields exactly one interval;
a period needs at least three events. With a content window narrower than the
3 s sample interval, 42 s is equally consistent with 21 s, 14 s, or aperiodic.

### 18.3 REFUTED: the ping-pong-vs-frozen-bank model predicts ~100 % content

The model is: display scans one fixed bank forever, ARM alternates banks, so
content shows only when they coincide. **DDR is persistent** — proven in §12,
poison-and-heal, and by the fact that DDR survives FPGA reconfiguration.

So once any paint lands on the scanned bank, that bank holds a complete frame
**and keeps holding it**. Painting the *other* bank does not erase it. The
model therefore predicts content becomes permanent after at most one
alternation (≤ 60 s) — never reverting.

Observed: content at t=69.1 s, then **BLACK from t=72 s through t=120 s**.
Content going black again refutes it directly.

The obvious rescue — "the ARM overwrote the scanned bank mid-scan" — is refuted
by the pixels: a partial overwrite produces a torn frame, which has **nonzero
variance**. Every black frame is `luma 7.00 std 0.00`, a uniform raster,
identical hash `2358782e` 37 times.

### 18.4 What the numbers do fit: §15's starvation mechanism at full severity

`std 0.00` uniform black is what `ddr_frame_store.sv` emits when it forces
black, not what a corrupted buffer looks like:

- `:332` `rd_miss_now = rd_active && rd_visible && has_frame && (!y_hit_now || !c_hit_now)`
- `:422` `miss_d` → `rd_r/rd_g/rd_b <= 0`

This is the **same mechanism** as the user's artifact, at a different severity:

| refill outcome | pixels |
|---|---|
| completes mid-scanline | black from `PRESENT_X` to the completion point → **jagged moving left-edge bars** |
| never completes | **every** visible pixel black, `std 0.00` |

Same code path, same knob: `Plex.qsf:85 FRAME_LINES_8=1`, 8 of 16 slots
searchable at any instant (`:312`). It requires no new mechanism and no
livelock to explain 37/40.

Corroboration in the capture: both content frames report `luma 36.50` to the
same two decimals with `std 22.17 / 22.16` but **distinct hashes** — the same
picture twice with MJPG noise, i.e. the static idle logo presented correctly,
not a moving or partially-drawn image.

### 18.5 Status of the claims

| claim | verdict |
|---|---|
| `3798793` is unreachable on a silent fabric | **measured, confirmed** (source trace) |
| host-doorbell interlock is correct under silence | **measured** (RTL `:208`/`:238`), red-proved |
| 42 s ↔ ARM fallback timer | **refuted** — no such cadence exists |
| ping-pong vs frozen bank explains 5 % duty | **refuted** — predicts ~100 %, and `std 0.00` excludes tearing |
| §15 starvation explains 37/40 black | **consistent, NOT proven** — needs `FRAME_LINES_16` A/B |

**Not claimed.** I have still never observed the artifact's pixels. 18.4 is a
mechanism that fits the numbers, not a demonstration. The discriminating
experiment is unchanged and cheap: `check_prefit_elaboration.sh` on
`FRAME_LINES_16` (4m23s, no fit token) to price it, then one fit.

### 18.6 Consequence for the `3b1e8435` A/B read-out

Per §16, the present path is **identical in both bitstreams** across all 827
entity paths (ALUTs, block bits, M10Ks, DSP), so it cannot confound the result.
But note 18.4: if the display path blacks out from refill starvation, then
"black screen" is **not** evidence against the SDC either. The A/B's only sound
read-out is the PLXD/PLXS mailbox advancing, not what the screen shows.

---

## 19. Rate, measured — the gap the parent named ("capacity was measured, not rate")

§15 answered *how many lines fit*. It did not answer *can a line be fetched in
less time than the raster takes to cross one*. That distinction decides whether
`FRAME_LINES_16` can work at all:

- **bandwidth bound** → extra slots buy nothing; the store falls behind at a
  fixed rate no matter how deep the buffer is, and a fit spent on
  `FRAME_LINES_16` is six hours wasted;
- **bandwidth headroom** → the failure is lead/scheduling, and slots buy
  exactly the thing that is short.

Shipped `scripts/check_ddr_refill_rate.py`. Nothing is restated: geometry and
video timing are derived from the RTL, and both clock frequencies are read from
the STA report **bound to `Plex.rbf` md5 `fb4bad84`**.

### 19.1 Result

```
Scope: 1 refill-rate budget (macro=FRAME_LINES_8 LINE_COUNT=8 CODED_W=624 ...)
  report      build/rpt/bdiag-b/Plex.sta.rpt  BOUND md5=fb4bad849ad2db782a5004ce5a3471ce
  clk_ddr     90.0 MHz   clk_sys 20.0 MHz  ce_pix 20.0 MHz
  per line    y=78 u=39 v=39 qwords -> slot=156 qwords (CODED_W/8, CODED_W/16)
  line time   638 ce_pix clocks / 20.0 MHz = 31.900 us
  refill      156 qwords = 1.733 us
  headroom    18.40x
```

Sensitivity, because the ideal figure is not the interesting one:

| burst latency (clk_ddr cyc) | src lines per output line | refill | headroom |
|---|---|---|---|
| 0 | 1 | 1.733 us | **18.40x** |
| 50 | 1 | 3.400 us | 9.38x |
| 100 | 1 | 5.067 us | 6.30x |
| 100 | 2 | 10.133 us | 3.15x |
| 200 | 2 | 16.800 us | **1.90x** |

200 cycles is 2.2 us of latency **per burst**, far beyond anything the f2h
bridge plausibly costs, combined with double the fetch rate the vertical
scaling implies. **Even there the budget closes.**

**Conclusion: DDR read bandwidth is not the binding constraint.** A starvation
fault in this path is a lead/scheduling problem, so `FRAME_LINES_16` is not
excluded by bandwidth — it addresses the quantity that is actually short.

Corroboration that the timing derivation is sound: 638 clocks/line at 20 MHz
over 524 lines (`vc` wrap, scandouble) = 16.72 ms = **59.8 Hz**, which matches
the 60 Hz mode the capture harness sees. The arithmetic reproduces a number
nobody fed it.

### 19.2 Two ambiguities the gate refused rather than guessed

Both were found on the **real** resident report, not synthetically, and both
are now non-synthetic red cases.

1. **Unbounded table, again.** `general[2].gpll~PLL_OUTPUT_COUNTER` appears in
   the Clocks table at 90.0 MHz **and** in the later Fmax Summary at 92.4 MHz —
   restricted Fmax, a different quantity. An unbounded scan returns whichever
   it meets first. Same defect class w-audit found in
   `check_fitted_line_buffer.py`: a table that does not know where it ends.
   Now bounded to the Clocks section *and* required to match the row's first
   cell (in Fmax Summary the clock name is the third).

2. **Hierarchy names are not unique by suffix.** `pll_audio` also instantiates
   an `altera_pll`, so `general[0].gpll~PLL_OUTPUT_COUNTER` matches the core
   PLL (20.0 MHz) **and** the audio PLL (24.58 MHz). Selecting on the suffix
   would have silently used the audio clock as the pixel clock and reported a
   line time 19% wrong. Now anchored on the full `emu|pll|pll_inst|...` prefix.

Neither produced a wrong answer, because in both cases the gate **refused**.
That is the whole value of refusing on ambiguity instead of taking the first
match: had either resolved silently, the headroom figure would have looked just
as authoritative and been wrong.

### 19.3 Why the clock frequencies were not taken from source

`Plex.sdc:8` says in a comment that `clk_ddr` runs at 90 MHz. It happens to be
right, but a comment is not a measurement. The PLL wrapper's own metadata
(`rtl/pll.v`) claims **every** output is `20.0` MHz with
`gui_actual_output_clock_frequency = "0 MHz"` — stale generator output that
would have given a 4.5x wrong DDR budget. The STA report is the only source
that describes the silicon, and it is bound to the RBF md5.

### 19.4 Declared limits

Steady-state average-rate bound. It does **not** model DDR refresh, arbiter
contention with the HPS writer, page misses, or real f2h burst latency — none
of which exist in any source file, which is why `--latency-cycles` charges
latency **explicitly** so it appears in the printed arithmetic instead of
hiding in a fudge factor. A PASS means bandwidth is not the constraint. It is
**not** evidence that the present path works, not evidence about any frame,
and it cannot see optimize-away.

`Scope: 24` self-test cases, including 4 measured against the real resident
report and 13 reds.

---

## 20. w-audit broke my binding gate. They were right, and I had already
## shipped the same defect a second time.

The parent ruled that RBF-md5 binding is mandatory and held
`check_fitted_line_buffer.py` up as the model of it. `w-audit` (`7b0aa64`) then
ran that gate with no `--expect-rbf-md5`:

```
UNBOUND: no --expect-rbf-md5 given; this report may describe a build ...
LINE_BUFFER_OK predicted=159744 instances=1 rows=827
rc=0
```

**It announced it could not be cited and returned success.** The word `UNBOUND`
went into a log nobody greps; the exit code — the only thing Makefiles, CI and
wrappers read — said green. The exemplar of the binding ruling did not
implement the binding ruling.

### 20.1 I shipped it again, an hour later

`check_ddr_refill_rate.py` (§19, committed `376ade5`) had the **identical**
shape: `WARNING report is UNBOUND ...` followed by `REFILL_RATE_OK`, rc=0. I
wrote it *after* the binding ruling was published and after I had described
UNBOUND-vs-BOUND as a virtue of my own gate. Knowing the rule and restating it
did not stop me reproducing the bug — which is the parent's point about
mechanical checks over remembering.

### 20.2 Fix: three states, no overlap

| condition | before | after |
|---|---|---|
| no `--expect-rbf-md5` | **0** + `LINE_BUFFER_OK` | **77**, no verdict line |
| binds to expected RBF | 0 | 0 |
| given but does not bind | 1 | 1 |

Both gates now suppress the verdict line entirely on an unbound run. Printing
`UNBOUND` is not a substitute for refusing to answer — if the string
`LINE_BUFFER_OK` never appears, no downstream grep can find it.

### 20.3 The auditor's own attack, before and after

Run with the pre-fix file placed **in `scripts/`** so only the code differs:

```
--- BEFORE (e828f71) ---
LINE_GATE unbound        rc=0  flags=UNBOUND,LINE_BUFFER_OK
LINE_GATE bound_expected rc=0  flags=BOUND,LINE_BUFFER_OK
LINE_GATE bound_wrong    rc=1  flags=BINDING_FAIL,LINE_BUFFER_FAIL

--- AFTER ---
LINE_GATE unbound        rc=77 flags=UNBOUND
LINE_GATE bound_expected rc=0  flags=BOUND,LINE_BUFFER_OK
LINE_GATE bound_wrong    rc=1  flags=BINDING_FAIL,LINE_BUFFER_FAIL
```

**My first attempt at this before/after was itself vacuous** and I discarded it.
I copied the old gate to the repo root, where `ROOT = parents[1]` resolves one
directory too high, and every case returned rc=2. That would have read as "the
old gate was broken in three ways" when all I had actually varied was the
file's location, not the fix. Exactly the control defect `w-fit-o5` caught in
the parent's SDC exoneration, committed by me, twenty minutes after I wrote a
gate to detect that class.

### 20.4 The fixtures were not exempted

Tightening the rule turned all nine synthetic self-test fixtures 77, because
none had a sibling `Plex.rbf`. The tempting fix is a self-test bypass flag.
That is how the hole comes back. Instead each fixture now gets a real sibling
RBF and a real md5 (`bound()` helper), so the self-test exercises the same
contract as production.

Regression cases added so this cannot return:

- `check_fitted_line_buffer.py`: *unbound must be 77, not 0* and *unbound must
  not print `LINE_BUFFER_OK`*. Scope 16 (3 green, 12 reds, 1 skip).
- `check_ddr_refill_rate.py`: the full 77/0/1 matrix driven as a **subprocess**,
  so it measures real exit codes rather than an in-process return value.
  Scope 29.

The stale hand-written `(3 green, 10 reds, 1 skip)` label in the Scope line is
now computed from the case names — a hardcoded count in a Scope line is itself
a small instance of the same disease.

### 20.5 What this does not fix

Only the two gates I own. The class sweep across `scripts/` is W-GATE-O5's.
Nothing here changes any measurement: line buffer 159,744 bits, prefetch depth
8 lines, refill headroom 18.40x all stand, and all were produced by **bound**
runs, so none of them were resting on the defect.
