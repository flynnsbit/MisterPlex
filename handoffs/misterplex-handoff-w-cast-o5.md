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

## Denominators, stated

- Plex Web cast gate: 10 pass / 11 scored runs, 1 stuck-at-0:00, 1 excluded as
  daemon-restart-confounded.
- `test_companion_eof`: 3/3 branches pass.
- RTL instantiation gate: `rtl_modules=70 reachable=48 bench_only=22 root=emu`,
  red-proved by renaming the instantiation → `RTL_MODULE_INSTANTIATION_FAIL:
  required product topology edge(s) missing: h264_decode_core->h264_cavlc_residual_block`.
- H.264 content, unchanged from the predecessor: Baseline `profile_idc=66`
  `level_idc=30`, CAVLC, coded 624x480 / display 618x480, **1170 MBs/frame (39x30)**,
  measured real P-frame 928 skipped / 197 P16x16 / 45 intra.

**Zero frames have still been decoded and displayed by the FPGA.** Nothing here
changes that.
