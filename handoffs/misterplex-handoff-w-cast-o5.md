# Handoff — W-CAST-O5 (successor to `w-cast`)

Branch `w-cast-o5` (worktree `.worktrees/w-cast-o5`), based on `w-cast-play-state`.
Commits: `0793556` (CORS preflight fix + gates), `e3e56d8` (Plex Web cast E2E gate).
Everything below is **measured on hardware unless marked assumed**.

## What I confirm

- **The predecessor's two product fixes are real code but are NOT on `main`.**
  `git merge-base --is-ancestor` says no for both `7fe899c` (playMedia uri parse)
  and `f801829` (zero-offset progress release).
- The deployed daemon does cast correctly when driven by `curl`
  (`state="playing"`, 20676 → 42287 ms at ~1.0x).
- `h264_cavlc_residual_block` **is** instantiated under `h264_decode_core` on this
  branch (`h264_decode_core.sv:637`, `u_product_p16_residual0`), and its outputs
  are consumed (`h264_dequant4x4` → `h264_idct4x4` → writeback).

## What I find is NOT true

1. **`tests/unit/test_companion_eof` does not fail.** Built and ran it on three
   trees — `w-cast-o5`, repo-root `w-decode-real-intra`, and `w-cast-play-init`.
   rc=0 on all three. Denominator 3/3. The "path callback key mismatch on
   `/library/metadata/3`" in the brief is not reproducible on those branches.
2. **The MiSTer was not offline.** The brief said ping 100% loss; the device
   answered and was `up 0:02` when I started.
3. **"`h264_cavlc_residual_block` is reachable in NEITHER decode config" is not
   true on this branch.** `scripts/check_rtl_module_instantiations.py` passes here
   and enforces the edge `h264_decode_core -> h264_cavlc_residual_block`.
   It **is** true on `origin/main`: there `h264_decode_core.sv` mentions the module
   only in comments (lines 12, 118) and never instantiates it, and `main` does not
   even carry the instantiation gate (`ABSENT_ON_MAIN`). So this is a live
   *merge-boundary* risk, not a wiring bug on the worker branch.
4. **CORS is real but is probably not the reported symptom.** Measured: this Plex
   Web build (4.160.0) relays player commands through the **PMS**
   (`/player/playback/playMedia` on the server origin), not directly to
   `192.168.1.183:3005`. Do not sell the CORS fix as "the" cast fix.

## The two product bugs, and where they stand

| Bug | Status |
|---|---|
| `playMedia` uri/path parse (`7fe899c`) | in the deployed binary, **not on main** |
| zero-offset progress release (`f801829`) | in the deployed binary, **not on main** |
| CORS preflight drops `X-Plex-Target-Client-Identifier` (mine, `0793556`) | fixed, gated, deployed |

The CORS defect was proved by a real-Chromium A/B from the PMS origin with web
security **enabled**: control headers → HTTP 200; adding
`X-Plex-Target-Client-Identifier` → blocked in preflight. Before/after on the same
device with only the daemon build varied: blocked → allowed.
Note for `w-e2e-o5`: `observe_cast_protocol.js` launches Chromium with
`--disable-web-security`, so it structurally cannot see this class of bug.

## The reported symptom, reproduced and scored

`tests/hw/test_cast_play_web.sh` drives the user's literal path in real Chromium.
Measured pass rates, **excluding runs where the shared daemon restarted mid-run**
(the runner brackets each run with pid + `/proc/<pid>/stat` start ticks):

- daemon `3318`: **4/5 pass**; the failure was `web player stuck at 0:00 — timeline
  time never left zero`, i.e. the user's exact report.
- a separate run showed the other half of the report: Plex Web **dropped the
  selected player and transcoded locally** (43 transcode requests) instead of
  casting. That run was CONFOUNDED — the daemon pid changed `3318 -> 3823`.
- fresh daemon `3823`: **6/6 pass**, then 2 further single runs green.

Combined scored: **10/11 with one stuck-at-0:00 failure**. The failure therefore
exists and is intermittent; it did **not** reproduce on a freshly started daemon,
which points at accumulated daemon state rather than a fixed code path. **Root
cause is NOT established.** Do not claim it is.

## Idle-timeline observations (measured, not yet acted on)

`GET /player/timeline/poll?wait=1&commandID=0` returns in **0.44 s** — `wait=1` is
ignored, so Plex Web hot-loops at ~2 polls/second. Real players hold the
connection. Also, only one `<Timeline type="video">` is emitted where real players
emit three (`music`, `photo`, `video`), and idle is
`state="buffering" location="navigation"`.

I deliberately did **not** change the idle state machine: `companion.cpp` carries
explicit comments that pure `stopped` idle polls freeze the Web scrubber and idle
the dialog, so `prePlayHold_`/`buffering@navigation` is a deliberate, empirically
tuned choice. Changing it needs an A/B with the rate runner, not a guess.

## Assets left behind

| Path | What it is |
|---|---|
| `tests/hw/test_cast_play_web.sh` | the user's acceptance path, scored. red: bogus `MISTERPLEX_NAME` → rc=1; green → rc=0 |
| `tests/hw/e2e/cast_play_web_e2e.js` | the Playwright driver |
| `tests/hw/cast_play_web_rate.sh` | repeats the gate N times, excludes daemon-restart-confounded runs |
| `tests/hw/test_cast_cors_browser.sh` + `tests/hw/e2e/cast_cors_browser.js` | hermetic 4-case real-browser CORS gate with a legacy-server red control |
| `tests/unit/test_companion_http.sh` | now asserts the preflight allow-list, browser-free |

### Plex Web automation recipe (hard-won)

- This PMS runs **Plex Home**: the app shows a "Select User" picker and the shell
  never renders until a user is clicked (`shawnhenderson`, no PIN). This is why
  earlier workers' selectors "did not exist".
- Inject `localStorage.myPlexAccessToken` before boot, otherwise a fresh context
  is redirected to `app.plex.tv/auth` and the page stays empty.
- Cast button `[aria-label="Select Player"]`; menu entry `role=menuitem` containing
  `MiSTerPlex`; play button `[data-testid="preplay-play"]`.
- The details URL needs the explicit server id, not `auto`.
- Navigate to the item **before** picking the player — `page.goto` to a new hash is
  a full reload and drops the selected cast target.
- Partially watched items open a **Resume Playback** dialog that blocks the play
  command until dismissed; take "Start from the beginning" for a deterministic 0.

## Next

1. Chase the stuck-at-0:00 intermittency with `tests/hw/cast_play_web_rate.sh` and
   a long-lived daemon (it did not reproduce on a fresh one). Vary one thing at a
   time; the runner already refuses to score confounded runs.
2. Implement a real `wait=1` long poll (hold ~25 s or until state change) and A/B
   the pass rate before/after with the same runner.
3. Get the CAVLC instantiation onto `main` — this is the merge-boundary risk, and
   `main` carries neither the edge nor the gate that would catch its absence.
   Owner: `w-decode-o5`. Ship `scripts/check_rtl_module_instantiations.py` with it.
4. Mode 3 (elaborated then optimized away) is still **UNSEEN** on this branch:
   `scripts/check_prefit_elaboration.sh` does not exist here (it is on `a8aa8eb`).
   I did not run it, so I make no claim about it.

## Correction from w-swap-o5 (accepted in part, `d12087f`)

`w-swap-o5` red-proved that `scripts/check_rtl_module_instantiations.py` had no
argument parsing, so `--root`/`--require` were silently discarded and a module
that exists nowhere in the repo exited 0. **Confirmed on this branch.** Fixed in
`d12087f`: argparse added, `--require` scored against `--root`, unknown module or
unknown root now rc=1.

What the correction does **not** overturn: my Mission-2 claim never rested on
those flags. The gate carries hardcoded `REQUIRED_PRODUCT_EDGES` including
`h264_decode_core -> h264_cavlc_residual_block`, and I shipped the mutation red
for exactly that edge. The edge check is root-independent, so it was never
vacuous. Additionally measured: `decode_stub` does not instantiate any of the
three producers (`--root decode_stub --require h264_cavlc_residual_block` -> rc=1),
so the emu-rooted result was not in fact confounded by the stub -- though the gate
no longer depends on that.

Also for the record: the "wire it into `stream_path -> decode_stub`" framing was
never mine. `stream_path.sv:497` does instantiate `decode_stub` on this branch,
but the producers sit under `h264_decode_core`.

## Denominators, stated

- Plex Web cast gate: 10 pass / 11 scored runs, 1 stuck-at-0:00, 1 excluded as
  daemon-restart-confounded.
- `test_companion_eof`: 3/3 branches pass.
- RTL instantiation gate: `rtl_modules=70 reachable=48 bench_only=22`, green at
  both `root=emu` and `root=h264_decode_core`,
  red-proved by renaming the instantiation → `RTL_MODULE_INSTANTIATION_FAIL:
  required product topology edge(s) missing: h264_decode_core->h264_cavlc_residual_block`.
- H.264 content, unchanged from the predecessor: Baseline `profile_idc=66`
  `level_idc=30`, CAVLC, coded 624x480 / display 618x480, **1170 MBs/frame (39x30)**,
  measured real P-frame 928 skipped / 197 P16x16 / 45 intra.

**Zero frames have still been decoded and displayed by the FPGA.** Nothing here
changes that.

---

# Stage C — CAVLC residual in the product core

Branch `w-cast-o5`, commits `6d58971` (RTL) and `f0d698a` (oracle). Everything
below is measured on that branch unless it says assumed.

## What landed

`h264_decode_core`'s own 24-block residual traversal now decodes CAVLC the way
H.264 Baseline codes it. Three defects fixed:

1. **`coeff_token_table` was hardcoded `3'd0`.** H.264 9.2.1 selects the
   coeff_token VLC from nC, derived from the left and upper 4x4 neighbours'
   `total_coeff`. `h264_cavlc_nc_predictor` already existed in
   `h264_cavlc_residual.sv` but was parked in `bench_only_modules.txt` "until
   product residual scheduling is integrated" — that was this job. It is now
   instantiated in the product core (`u_product_res_nc`) and removed from the
   bench-only list.
2. **No nC context existed.** Added current-MB `total_coeff` (16 entries), a
   left-MB column, and a per-column top line buffer, following the existing
   `mv_top_*` convention. Slice/frame-edge availability is handled by the
   predictor's own guards.
3. **No cbp gating.** The traversal walked all 24 blocks regardless of
   `cbp_luma`/`cbp_chroma`. On a real stream that desynchronises the whole
   macroblock's bit chain the moment an 8x8 group is uncoded. Uncoded blocks now
   launch no CAVLC decode and do not advance `bit_offset`.

## Evidence — every green ships its red

| result | check |
|---|---|
| green | `test_h264_decode_core_p16z_rtl_sim.sh` rc=0 — **60 coded + 12 cbp-uncoded CAVLC blocks over 3 P16 macroblocks**, all fault injections still red |
| red | force `.coeff_token_table(3'd0)` → rc=1 |
| red | drop the cross-macroblock left nC context → rc=1 |
| red | force `res_block_coded = 1'b1` (ignore cbp) → rc=1, `mb=(3,0) sample 128 plane=Y got=249 want=227 residual=0` |
| green | restore → rc=0, core file byte-identical to HEAD |
| green | `check_rtl_module_instantiations.py --root h264_decode_core` → `REQUIRED_RTL_MODULE_REACHABLE h264_cavlc_nc_predictor`, reachable 48 → 49, bench_only 22 → 21 |
| green | `check_decode_core_syntax_feed.py`, `check_define_parity.py`, `test_bench_rtl_filelists.py` |
| pre-existing | `scripts/rtl_lint.py` rc=1 on the baseline commit too; `h264_decode_core` contributes no lines to its report |

**Denominator: 3 macroblocks, not 1170.**

## What I found is NOT true

- **`test_h264_decode_core_real_slice_rtl_sim.sh` is not Stage C evidence.** It
  drives `p16_residual_y/u/v` directly and bypasses CAVLC entirely
  (`h264_decode_core_real_slice_tb.cpp:266-269`). It is still rc=0, which only
  shows Stage C did not regress MC/recon. I had earlier framed it as real-content
  validation of the residual path; that was wrong.
- **The p16z fixture was not a valid oracle for conformant nC.** Its bit strings
  were hand-authored against table 0 for every block. Re-encoding was mandatory,
  not optional; each substitution was verified against the product RTL itself
  through `h264_cavlc_residual_tb_top` (table 1, tc=2: t1=2 `011`, t1=1 `00111`,
  t1=0 `000111`) and decodes to the same coefficients as before.

## ★ Blocking limitation found, NOT fixed — the 128-byte slice ceiling

`stream_path.sv:273-286` captures **only the first 128 bytes of a slice**
(`sl_rbsp_len < 8'd128`, then it stops), `rbsp_window_base` is hardcoded `16'd0`
(line 390), and the core's `rbsp_request_offset` / `rbsp_request_valid` outputs
are consumed **only** by the `_keep_decode_core_inputs` sink (line 557).

So the product decoder can never see residual bytes past byte 127 of a slice. A
real 624x480 P slice is far larger than that, so at most the first handful of
macroblocks can ever have residual — measured cause, not speculation, and it is
a plausible explanation for the long-standing "only block0 ever has residual
data" symptom.

I did **not** fix it, deliberately. The core's interface is a 128-byte parallel
`rbsp_byte [0:127]` array, so a sliding window means either a 4096:1 mux per
window byte or a redesign to a narrow on-demand fetch backed by BRAM/DDR. That
is an architecture decision owned by `w-decode-o5` (Stage A) and `w-swap-o5`
(DDR path), and per the pivot's "steal, do not invent" mandate it should follow
whatever ring-buffer/arbitration pattern jtframe already ships rather than being
invented here. Half-landing it would have been worse than reporting it.

## Merge instructions

- Take `w-swap-o5`'s P16 block MC region **wholesale** and re-anchor Stage C on
  top. Stage C's anchors (`u_product_res_nc` and the residual context wires) sit
  above the MC region, so this is tractable. Resolving the other way silently
  reinstates the per-sample MC lineage and loses their 1170/1170-macroblock proof.
- Keep exactly **one** `MAX_BYTES` RBSP index fix. This branch uses `RBSP_IDX_W`
  + the `CAVLC_FAULT_BYTE_INDEX_WRAP` fault define, already allowlisted in
  `define_parity_allowlist.json`; `w-swap-o5` sized it via `$clog2`.
- `bench_only_modules.txt` loses its `h264_cavlc_nc_predictor` line. If a merge
  restores it, the instantiation gate will go red — that is the gate working.

## Remaining Stage C work, honestly scoped

- **Chroma is still non-conformant.** The traversal has no chroma DC blocks at
  all, `max_coeff` is fixed at `5'd16` for every block, and chroma AC still uses
  table 0. These must land together: consuming AC-only chroma without also
  consuming the DC blocks would desynchronise the chain, so `max_coeff=15` alone
  is not a coherent increment. The design that avoids renumbering — and therefore
  avoids breaking `expected_red_manifest.json` ordinals and the chroma latch
  mapping — is to add two chroma-DC micro-states ahead of the chroma AC blocks
  with their own counter, leaving `p16_res_block_idx` 0..23 untouched, then apply
  the 2x2 inverse Hadamard and inject each DC into the matching AC block's
  coefficient 0.
- cbp gating for chroma currently treats only `cbp_chroma == 2'd2` as AC-coded.
  That is correct for AC, but becomes wrong the moment chroma DC exists
  (`cbp_chroma == 2'd1` codes DC only).

**Zero frames have still been decoded and displayed by the FPGA.** Stage C
changes nothing about that; Stage A must land first, and "screen or it didn't
happen" is the only acceptance criterion that counts.
