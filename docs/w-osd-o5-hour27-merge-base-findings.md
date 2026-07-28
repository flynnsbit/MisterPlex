# W-OSD-O5 — findings on the mandated merge base `w-decode-hour27` `2f165ed`

Measured 2026-07-28 by W-OSD-O5, on branch `w-osd-o5-hour27` (this branch),
which is `w-decode-hour27` `2f165ed` plus the build-identity port described
below. Everything here is **measured**, with the instrument named per claim.

---

## 1. A fit from this base would have shipped no build identity

The base carries the stock upstream MiSTer entry:

```systemverilog
"V,v",`BUILD_DATE      // Plex.sv:83 on 2f165ed
```

`BUILD_DATE` is a date. Two fits on the same day are indistinguishable by it,
and it is not derived from the sources. None of the build-identity work existed
on this base — `gen_build_stamp.py`, `rbf_provenance.py`,
`check_build_id_delivery.py`, `quartus_file_list.py` and
`tests/unit/test_build_identity.sh` were all **ABSENT**, and
`scripts/build_rbf_remote.sh` had no stamp generation or `nogit` refusal.

Since RULING 1 makes this the only viable base for product fits, a fit taken
from it as it stood would have reproduced exactly the condition the user
complained about: no way to tell from the screen which RBF is running.

**Ported here** (files only, no RTL cherry-picks, so nothing collides with the
decode convergence):

| file | note |
|---|---|
| `scripts/gen_build_stamp.py` | new |
| `scripts/rbf_provenance.py` | new |
| `scripts/quartus_file_list.py` | new |
| `scripts/check_build_id_delivery.py` | new |
| `tests/unit/test_build_identity.sh` | new, wired into `make unit` + rollcall |
| `scripts/build_rbf_remote.sh` | purely additive (+35 lines): stamp generation, `nogit` refusal, provenance record |
| `fpga/Plex_MiSTer/sys/build_id.tcl` | reads the stamp |
| `fpga/Plex_MiSTer/Plex.sv` | **one line**: `` `BUILD_DATE `` → `` `BUILD_ID `` |

Measured after the port: `check_build_id_delivery.py` rc=0 on all five links;
`test_build_identity.sh` rc=0 including all ten reds.

**The next fit must go through `scripts/build_rbf_remote.sh`**, or the stamp is
never generated and the identity degrades to `nogit`.

---

## 2. RULING 3 condition 1 is unconditionally green — the command cannot fail

The parent reported this for `parent/integ-hour27`. It is also true **here, on
the mandated base**, which matters more because this is where the next fit comes
from.

`scripts/check_rtl_module_instantiations.py` contains **no `add_argument` and no
`sys.argv` handling at all**. Every flag is ignored. Measured:

```
--root emu --require h264_decode_core
    -> RTL_MODULE_INSTANTIATION_OK ... root=emu     rc=0

--root this_root_does_not_exist --require this_module_does_not_exist
    -> RTL_MODULE_INSTANTIATION_OK ... root=emu     rc=0     <- identical

--help
    -> RTL_MODULE_INSTANTIATION_OK ... root=emu     rc=0
```

The `root=emu` in the output is a hardcoded string, not an echo of the flag.
So **RULING 3 condition 1, run as written, returns rc=0 without evaluating the
requirement.** Any fit authorised on that command is authorised on no evidence.
W-GATE-O5 owns the fix; this file only records that the defect reaches the
merge base.

### The substantive question, answered another way

`reachable_from()` inside that script is correct; only the CLI is inert. Calling
it directly (read-only, no modification to W-GATE-O5's tool):

```
PRODUCT_ROOT=emu   modules=133   reachable=55
  h264_decode_core             REACHABLE   (parent: stream_path)
  h264_decode_top              REACHABLE   (parent: h264_decode_core)
  h264_intra_nb_ctx            REACHABLE
  stream_path, present_core    REACHABLE
  decode_stub                  REACHABLE   (parent: stream_path)
```

So the **trunk really is connected on this base** — condition 1 is satisfied in
substance, just not by the command that was mandated to prove it.

---

## 3. RULING 3 condition 2 is already satisfied here for the two named files

`w-fit-o5`'s `NOT_COMPILED h264_decode_top.sv / h264_intra_nb_ctx.sv` is real,
but was measured against a 35-entry `files.qip`. Membership by branch:

| branch | `files.qip` entries | `h264_decode_top.sv` | `h264_intra_nb_ctx.sv` |
|---|---|---|---|
| `parent/integ-hour27` | 35 | ABSENT | ABSENT |
| `w-deblock-seam` | 35 | ABSENT | ABSENT |
| **`w-decode-hour27` `2f165ed`** | **37** | **present** | **present** |

Confirmed independently with `quartus_file_list.py --gate --require`, which
resolves the real file list (93 files, following `source` and `QIP_FILE`, not
just `files.qip`): both compile, rc=0.

**W-DECODE-O5's assignment to add these two to `files.qip` is already done on
the mandated base.** Remaining tracked-but-uncompiled RTL there is
`cos.sv` (MiSTer template leftover), `tb_arb_beat_conservation.sv` and
`tb_audio_fifo_cdc.sv` (testbenches), and `h264_decode_skeleton.sv` — see below.

---

## 4. ★ What blocks retiring `decode_stub` (RULING 2)

The parent asked for this explicitly. Measured three independent ways — the
instantiation graph, `grep` over `rtl/*.sv`, and `files.qip` membership — which
all agree.

| module | reachable from `emu` | under `h264_decode_core` | under `decode_stub` | instantiated in |
|---|---|---|---|---|
| `h264_deblock_bs` | **NO** | no | no | `h264_decode_skeleton.sv` only |
| `h264_deblock_edge_pipe` | **NO** | no | no | `h264_decode_skeleton.sv` only |
| `h264_deblock_edge` | **NO** | no | no | `h264_deblock_edge_pipe` |
| `h264_deblock_thresholds` | **NO** | no | no | `h264_deblock_edge` |
| `h264_deblock_writeback_ctrl` | yes | **no** | **yes** | `decode_stub.sv`, `h264_decode_skeleton.sv` |

`h264_decode_skeleton.sv` is **tracked in git and absent from `files.qip`**, so
it is not compiled. That gives a failure shape we have not named before:

> **a module that is compiled, but whose only instantiation site is itself
> uncompiled.**

`h264_deblock.sv` *is* in `files.qip`, so four of these five modules are handed
to Quartus and are still unreachable, because the only file that instantiates
them is not. A `files.qip` coverage check passes them. A subtree check rooted at
the skeleton would pass them. Only the trunk proof catches it.

**Consequences:**

1. **Retiring `decode_stub` orphans the deblock subsystem entirely.**
   `h264_deblock_writeback_ctrl` is reachable from `emu` *only* through the
   stub. Delete the stub without re-parenting, and 5/5 deblock modules become
   unreachable. This is the concrete blocker the parent asked for.
2. **The MC/DPB set has the same dependency.** `h264_dpb_one_ref`,
   `h264_inter_mc_16x16`, `h264_mv_pred_16x16`, `h264_luma_qpel_block_16x16`,
   `h264_chroma_epel_block_8x8`, `h264_ref_clamp` are all reachable from `emu`
   only via `decode_stub`, not via `h264_decode_core`.
3. **For W-DEBLOCK-O5:** rebasing onto `w-decode-hour27` does not by itself
   connect the seam work. On this base the subsystem lands with four modules
   unreachable and the fifth hanging off the very stub RULING 2 orders removed.

The ordering implied is that re-parenting under `h264_decode_core` has to happen
**with or before** stub retirement, not after.

### Caveat on the instrument

Source-level reachability is a pre-filter, not an oracle; w-audit measured that
it passes instantiations inside disabled `if (0)` generates and fails on escaped
identifiers. Every row above was therefore also confirmed by `grep` over
`rtl/*.sv`. `make post-fit-hierarchy` remains the only real oracle.

### A trap in reading these graphs

`h264_deblock`, `h264_dpb` and `h264_inter_pred` are **file names, not module
names**. Querying the graph for them returns "no parents", which reads exactly
like "orphaned" and is not. I made that mistake once here before checking, and
nearly reported a module-absence finding that did not exist. `h264_deblock.sv`
defines `h264_deblock_bs`, `_thresholds`, `_edge`, `_edge_pipe` and
`_writeback_ctrl`; there is no module called `h264_deblock`.

---

## 5. Mode 3 applied to the build identity — and it is clean

The parent's third failure mode (*instantiated, elaborated, then optimized away*)
applies to the build id as much as to the decoder: if the OSD compositor is
deleted by synthesis, no CONF_STR wiring can put a string on screen. Sections
1–4 of `tests/unit/test_build_identity.sh` were all source-level and therefore
blind to it by construction.

`check_build_id_delivery.py` now takes `--fit-rpt`, and without one it prints

```
NOTE source-level checks cannot detect optimize-away: ...
```

so a source-level green can no longer be mistaken for proof.

**Measured against a real Quartus 17.0.2 fit report**
(`fpga/Plex_MiSTer/remote_out/deploy2/Plex.fit.rpt`, RBF md5 `8eb01b79`):

```
OK survived synthesis: hps_io   (|hps_io:hps_io)
OK survived synthesis: osd      (|osd:vga_osd, |osd:hdmi_osd)
```

So the OSD render path **does** survive into real silicon; the build id is not a
mode-3 casualty. Stated honestly: that report is `8eb01b79`, not the deployed
`fb4bad84`, so this is strong evidence about framework code that has not changed
rather than a measurement of the deployed build. No Quartus run was needed — the
report already existed.

Reds shipped with it (synthetic reports, so the gate stays hermetic): `osd`
absent, `hps_io` absent, an unparseable report, and a missing report each give
rc=1 with their own message; and the source-only path is asserted to emit the
optimize-away warning.

### `confstr_rom` is absent from silicon, and that is correct

Worth recording because it is a live example of w-audit's disabled-generate
trap. `sys/hps_io.sv:244` has `if(CONF_STR_BRAM) begin ... confstr_rom ... end`,
and `Plex.sv` never sets `CONF_STR_BRAM`, so it defaults to 0. A source-level
reader sees `confstr_rom` instantiated; the fit report shows **zero** instances.
The design uses the combinational mux at `hps_io.sv:248` instead. Anyone
auditing OSD modules against the RTL by hand will otherwise read this as a
missing module.

### One bug found in my own red harness

The `missing report` red initially graded FAIL-for-the-wrong-reason. The expected
substring was `--fit-rpt not found`, and `grep -qF "$want"` parsed a pattern
beginning with `--` as an option rather than a pattern. Fixed with `grep -qF --`
in both red helpers. The red was real; my check of it was broken — which is the
same shape as everything else in this file, one level up.

### CONF_STR truncation: checked, not a risk

`hps_io` derives `STRLEN=$size(CONF_STR)>>3` and
`MAX_W=$clog2(max(64, STRLEN+2))-1`, and gates the transfer with
`if(byte_cnt <= STRLEN)`. The counter is sized from the string, so appending
CONF_STR entries cannot silently truncate the tail. This mattered to check
because the `V` entry is the **last** item in `CONF_STR`, so any truncation
would drop precisely the build id and nothing else.
