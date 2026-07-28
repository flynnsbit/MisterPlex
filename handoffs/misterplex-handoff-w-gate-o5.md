# W-GATE-O5 report — hour 28/29

Branch **`w-gate-hour28`**, head **`c684a99`**, pushed twice.
All numbers below are **measured**, each with the branch and commit that produced it.

---

## 1. Raw numbers first

### `w-decode-hour27` at `2f165ed` (re-derived independently, hardened parser)

```
rtl_modules=69   emu_reachable=48
h264_decode_core     : emu_reachable=True   parents=stream_path
h264_decode_top      : emu_reachable=True   parents=h264_decode_core
decode_stub          : emu_reachable=True   parents=stream_path
h264_decode_skeleton : emu_reachable=False  parents=<none>

TRUNK  emu->stream_path->h264_decode_core     (2 hops, INTACT)
core_subtree=15  stub_subtree=18  stub_masked=8
UNDECIDABLE_GENERATE_MODULES count=0
```

Stub-masked, i.e. under `decode_stub` and **not** under the core:

```
h264_inter_mc_16x16  h264_inter_mc_part  h264_dpb_one_ref
h264_luma_qpel_block_16x16  h264_chroma_epel_block_8x8
h264_luma_ref_tap_addr  h264_ref_clamp  h264_deblock_writeback_ctrl
```

### `w-gate-hour28` at `c684a99`

```
rtl_files=43 rtl_modules=68 default_reachable=41 bench_only=21
UNDECIDABLE_GENERATE_MODULES count=0
scope_discipline_commands=100 scoped=11 unscoped=89
make unit rc=0
```

---

## 2. Interpretation

### 2.1 The "dead core" is a branch fact, not a repo fact

w-audit measured `--root emu --require h264_decode_core` rc=1 on
**`w-deblock-seam` `7225e00`**. On **`w-decode-hour27` `2f165ed`** the same query
succeeds: `emu->stream_path->h264_decode_core`. Both are true. The finding is a
*convergence* problem, exactly as the parent said, not a defect in w-decode's
rewire. w-audit's methodological point stands regardless: a subtree proof
without a trunk proof is vacuous, and that is now enforced rather than
remembered.

### 2.2 The masked set is 8, not 7

The parent's list named 7. `h264_deblock_writeback_ctrl` is also stub-masked on
`w-decode-hour27` — w-deblock landed it under the core on a branch where the
core has no trunk, so on the branch where the trunk exists the writeback
controller is still only reachable through the retired painter. W-SWAP-O5 and
W-DEBLOCK-O5 should treat the relocation list as **8 modules**.

### 2.3 Lineage enumeration — settled

| file | in tracked `.qip` | instantiating parents | verdict |
|---|---|---|---|
| `h264_decode_core.sv` | yes | `stream_path` | **the product decoder** |
| `decode_stub.sv` | yes | `stream_path` | diagnostic painter, still a product decode root |
| `h264_decode_top.sv` | yes | `h264_decode_core` | demoted sub-engine, correct |
| `h264_decode_skeleton.sv` | **no** | **none** | **dead code** — not a fourth lineage |

`h264_decode_skeleton.sv` is tracked in git, absent from every tracked `.qip`,
and instantiated by nothing. It is exactly the class of file the `.qip`
cross-check exists to expose: present on disk, absent from the design. It can be
deleted without changing the bitstream. Its `h264_dpb_one_ref` instantiation is
one of the four the earlier survey counted, and it is not a real one.

**Two decode roots exist under `stream_path`**, and while `decode_stub` is one of
them every plain `emu` reachability number is inflated.

---

## 3. What shipped this session

### `9f15437` — w-audit's four attacks folded in as permanent regressions

Scoping fact that matters for the record: w-audit measured the **237-line
unguarded variant** of `check_rtl_module_instantiations.py` on `w-deblock-seam`,
and a *different* `check_qip_coverage.py` on `parent/integ-hour27`. Three copies
of that filename exist with different behaviour. Re-testing each attack against
the canonical checker on this branch:

| # | attack | status here before the parent's message | now |
|---|---|---|---|
| 1 | dead root | **already closed** by `ab08ae3` (`NON_PRODUCT_ROOT`) | closed + regression |
| 2 | disabled `if (0)` generate | **genuinely open** | closed, `select_constant_generate_ifs()` |
| 3 | escaped instance name | **genuinely open** | closed, `INSTANCE_NAME` |
| 4 | `files.qip` omission | **already closed** by the hour-28 qip check | closed + extended to every root |

Both new fixes were mutation-proved by disabling them; the suite goes rc=1 each
time. `default_reachable=41` is unchanged, so the blind spots were corrected
without perturbing a single real measurement.

`TRUNK_PROOF <root> path=... via_masking_lineage=...` now prints on **every**
`--require` invocation and **hard-fails** when the only product path launders
through `decode_stub`.

### `8de3369` — masking lineages at any depth

w-audit's later attack (`w-audit` `a9eac7e`) broke the sibling post-fit tool
`check_map_hierarchy.py` because `--forbid-only-under decode_stub` inspects
**direct children only**, so `h264_dpb_i420_addr` — a grandchild — went green.
That parser is not on this branch; the identical blind spot is now a permanent
regression here. Mutation-proved by narrowing the lineage test to `trunk[-2]`,
which reproduces the sibling defect verbatim:

```
TRUNK_PROOF i420_addr path=emu->stream_path->decode_stub->one_ref->mb_write_addr->i420_addr
            hops=5 via_masking_lineage=no      <- the defect
```

Also extracted `qip_sources_from_text()` so the `.qip` regression drives the
**shipped** helper instead of a local copy of it. A test that re-implements the
logic it guards keeps passing after the product regresses — this project's
signature failure in miniature.

### `3dae48d` — parameter-gated generates declared undecidable

w-audit's `w_audit_gate_hygiene.py` reports three synthetic reachability
findings. **Measured caveat: that scanner uses its own `candidate_edges()`
re-implementation, not this parser**, so its output describes w-audit's model.
Running its three synthetics through *this* parser:

| synthetic | this parser | verdict |
|---|---|---|
| qip omission | reachable, `REACHABLE_MODULE_NOT_COMPILED` fires | closed |
| escaped instance | reachable | closed |
| parameter generate | `gen_parent -> {disabled_child, live_child}` | **genuinely false-reachable** |

Resolving `if (USE_DISABLED)` against `#(.USE_DISABLED(1'b0))` is parameter
propagation, i.e. elaboration. Guessing it would let the parser *invent absence*
— the one error it must never make. So the condition is declared **undecidable**:
the default run always prints `UNDECIDABLE_GENERATE_MODULES count=N`, and a
`--require` naming such a module is a hard fail redirecting the claim to
`make post-fit-hierarchy`. Measured denominator today: **0**. The instrument
exists to catch the *next* parameterised subtree swap — the exact shape of the
retired `DECODE_REAL_INTRA` one.

**Vacuity trap worth publishing:** downgrading that hard fail to advisory still
left `rc=1`, because the synthetic file is in no `.qip` and *that* check failed
it instead. `rc == 1` for an unexamined reason is the same failure class we are
hunting. The case now asserts the undecidability verdict text specifically.

### `c684a99` — the `Scope:` rule, ratcheted

| quantity | value |
|---|---|
| registered `make unit` commands | **100** |
| commands whose source can emit `Scope:` | **11** |
| commands that cannot | **89** |
| `Scope:` lines printed by a full `make unit` | 19 |

**89 of 100 registered commands can exit 0 without ever stating what they
compared.** That is the population w-audit's "24 paths that exit 0 without doing
any work" was drawn from. A hard flip today would red the fleet's `make unit`,
and a broken `make unit` blinds every worker — worse than the disease. So it is
a two-directional ratchet over `tests/unit/scope_discipline_exempt.txt`: the
debt cannot grow, and progress must be recorded. Failable four ways, all
covered.

Defect found while building it: the first implementation resolved
`$(ROOT)/build/test_osd_menu` to the **compiled binary**, which still contains
the string literals of whatever source last built it — deleting a `Scope:` line
from the `.cpp` would have kept reporting green until the next rebuild.

---

## 4. `make unit` geometry contract

Fixed and verified on this branch, with **both** independent fixes present
(mine, forcing the inventory record; w-deblock's, clearing credential env and
pointing `MISTERPLEX_CONF` at a deliberately absent file), so it merges cleanly
with `parent/integ-hour27`. Red-proved by pointing the second path at the real
credentialed conf: rc=1 reproducing
`missing derived geometry contract from registry: coded 624x480/display 618x480`.

Corrected survey of 22 remote branches: **8 fixed, 14 broken**. My first survey
grepped for one fix marker and reported 20/22 broken — wrong, because two
independent fixes exist. Anyone surveying this must grep for **either**.

Root cause: `self_test()` called `summarize(registry_skips("make-unit"))`, and
`registry_skips` only emits the PMS inventory record when
`live_pms_missing_reason()` is non-empty. Credentials live in the **HOME-global**
`~/.config/misterplex/misterplex.conf`, shared by every worktree on
`node-worker1`. **The self-test was green exactly on the hosts where it had
least to check.**

---

## 5. What I am NOT claiming

* Reachability rc=0 at any root is **necessary, not sufficient**. This checker is
  source/regex-level and not elaboration-aware.
* On `w-gate-hour28` and on `w-decode-hour27`, all 13 `h264_decode_core` output
  ports terminate on a fanout-free `_keep` wire carrying **no `(* keep *)`
  attribute**, while `decode_stub` is 10/10 live. Core-subtree membership does
  not imply the core contributes to a pixel. **W-SWAP-O5 landing the 8 masked
  modules under the core will still not produce a frame until `dpb_wr_*` reaches
  the frame store.** That the synthesiser actually prunes it is *inferred*, not
  measured — only `make post-fit-hierarchy` can settle it.
* `UNDECIDABLE_GENERATE_MODULES count=0` means the parser found nothing it could
  not decide. It does not mean elaboration agrees with it.
* No FPGA-decoded frame has been displayed. Nothing here changes that.

## 6. Open, for whoever picks this up

1. **Canonical-copy collision.** Three divergent `check_rtl_module_instantiations.py`
   exist (200 / 237 / ~800 lines). On integration the guarded version must win,
   or w-deblock's registered `make unit` line silently reverts to the unguarded
   semantics w-audit broke. Any quoted reachability figure **must name its branch**.
2. **Cross-tree instrument transplant is unsafe.** Copying the checker into a
   scratch worktree failed with `missing explicit NONDEFAULT_CONFIG_REACHABLE
   list` — the manifests are branch state. Drive it programmatically instead;
   this is precisely the phantom-failure trap.
3. `REQUIRED_LIVE_OUTPUT_PORTS` is hard-coded to `dpb_wr_en/addr/data`; a rename
   silently empties the requirement.
4. The `.qip` cross-check proves a file is in the **file list**, not that the
   entity survived synthesis. `make post-fit-hierarchy` remains the only oracle,
   and w-audit has already broken two of its parsers.
