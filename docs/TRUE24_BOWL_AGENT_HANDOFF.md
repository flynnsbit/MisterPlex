# True24 glass bowl — agent handoff (2026-09-10)

**Audience:** next agent picking up MisterPlex true24 startup-bowl work.  
**Lane:** `single-rbf-glass`  
**Entry:** `Memory/lab/fpga-h264-30ff2997/RESUME.md`  
**This file:** recent wins, exact live pair, root cause, R14 design, stuck point, how to resume.  
**Not acceptance:** nothing here claims true24 fixed until glass metrics prove it.

---

## One-line status

Real LAN Web→MisterPlex→HDMI **plays moving picture** on qualified native-copy RBF **a365 lineage**, but **true24 open still bowls ~20 fps for ~700 ms** at start. DDR mux fairness (R10–R12) and within-frame `PIPELINED_COPY` (R13) **did not move the bowl**. **R14** (`OVERLAP_DISPLAY_COPY`: copy next frame during present wait) is implemented, unit-tested PASS, first fit **timing-failed** on unrelated `ascal` HDMI path (−0.133 ns); **SEED 12 re-fit was running** at handoff.

---

## Hard constraints (do not relearn the hard way)

1. **Hardware first.** Glass + real Plex Web cast is the product. `make unit` / cards are not acceptance.
2. **Sign-off path:** LAN Plex Web → cast MisterPlex → play library title → HDMI grabber shows content (not idle chevron) while Web shows playing.
3. **Sole Quartus fit** at a time. Image `sha256:1fba8b93…`, tool  
   `.../build/coherent-functional-sys20-frac-5754/staged/timing-tool-r4`.
4. **Shell host filter:** never invoke the process-terminate builtin name in any bash script/string (including signal-0 probes). Use `ps -p "$PID"` only. Remote stop via SSH+Python `os` module or `docker stop`.
   See `Memory/lab/.../true24-bowl-rootcause-20260910/SHELL_NO_KILL.md`.
5. **Never overwrite fit `Plex.sv` with raw fleet copy** without diffing `VIDEO_FUNCTIONAL_FEATURES` / stream_path params (R13a wiped caps → session ACK fail).
6. **Live Plex tokens** never into store/chat.
7. Durable progress: `checkpoint.py progress --lane single-rbf-glass ...` + ROOTCAUSE.json.

---

## Live pair at handoff (unless seed12 deployed)

| Piece | Value |
|-------|--------|
| RBF (on box) | **1523** = R13b PIPELINED_COPY, sha256 `15230cc9…`, md5 `8ef6bf98…` |
| Companion | **cc7** (`cc7d7d1e…` traced ARM) |
| Config | **e273** |
| Candidate dir | `/media/fat/misterplex/candidates/bab9d55b-889db417a7b840d98fcfbb4ef242fb4d/` |
| Rollbacks on box | `Plex.rbf.d6ae` (R12), `.8c3e` (R11), `.4aa2` (R10), `.1523` after any newer deploy |
| Host | `MISTER_HOST` default `192.168.1.183`, pass default `1` |

**1523 glass (still bows):** peak_late ~**703.7 ms**; fps bins ~**21.4 / 26.9 / 24.1**; settled ~**23.97**; host gap_med ~**49.0 ms**; submit→commit med ~**34.7 ms**; VideoPace med ~**40.3 ms** (AV_PRESENT_LEAD_MS=40 by design).

Capture dir pattern:  
`Memory/lab/fpga-h264-30ff2997/true24-bowl-remeasure-{2bd6,4aa2,8c3e,d6ae,1523}-20260910/`

---

## Recent successes (keep these; do not redo)

### Product path proven
- Qualified single-RBF **a365** exact-reference + timing gates previously PASS; real Web cast shows **moving library content** on HDMI (not black/silent when capture window is correct — see capture-correction notes).
- Controls (Play/Pause/Resume/Stop/seek UI) exercised on cc7/e273 lineage with HDMI+stereo evidence in earlier lanes.
- Full PMS body **1535396 bytes / 384 AUs / SHA 484f3a13** captured on good sessions; intermittent short responses are PMS-side (separate notes).

### Bowl campaign R9→R13 (negative results = knowledge)

| Rev | Change | Glass peak_late | Verdict |
|-----|--------|-----------------|---------|
| R9c2 | always-auth present | still ~700 ms class | bowl remains |
| R10 | m1_credit in `ddr_bus_arbiter` | ~same | flat |
| R11 | transport mux `choose_b` publish absolute | ~same | flat |
| R12 | `m1_boost` while `publish_want` + 2FF CDC | ~721 ms | flat |
| R13a | bad fleet Plex.sv overwrite | N/A | **rejected** (VIDEO_FEATURES=0); rolled to d6ae |
| R13b | product `.PIPELINED_COPY(1'b1)` surgical on r12 tree | ~704 ms | **still bowls**; submit→commit still ~35 ms |

**Conclusion:** bowl is **not** m1/publish DDR fairness and **not** within-frame RAM∥DDR copy. Host gap ~50 ms + FPGA submit→commit ~35 ms serialize behind **DISPLAY_WAIT / present / decode**, not transport credit.

### R13b engineering wins
- Fit RBF **1523** timing PASS (setup≥0.246, hold≥0.113), build_id nonzero (ARM `supportsVideo` needs build_id≠0).
- Unit publish TB accepts WRITE_WORD=6 **or** PIPE_COPY=17.
- Product had PIPELINED_COPY **off** until R13b (offline notes wrongly claimed on).

### R14 engineering (in progress at handoff)

**Intent:** multi-frame overlap — accept/copy **next** frame into free bank while previous swap awaits `frames_done` / STATUS.

**RTL:** `fpga/Plex_MiSTer/rtl/fpga_video_publish.sv`  
**Param:** `OVERLAP_DISPLAY_COPY` (default 0; product 1 with PIPELINED).

Design summary:
1. At **SWAP**, latch `present_*` identity (session/pts/seq/num/den/nonce), `pending_display_bank <= swap_bank`, `present_display_before <= frames_done`, `present_pending=1`.
2. If OVERLAP: next state **IDLE** (not DISPLAY_WAIT) so `frame_ready` can fire.
3. Accept bank: `accept_write_bank = present_pending ? !pending_display_bank : !displayed_bank` (must **not** write the bank on glass).
4. **STATUS** words always read `present_*` (so next accept can overwrite `session_hold`).
5. **FRAME_WAIT** while `present_pending`: if display already acked → STATUS then `copy_done_pending` → SWAP; else **COPIED_WAIT_PRESENT**.
6. IDLE also retires `present_pending` via display_ack before clear/new work.
7. Codec-error STATUS path latches `present_*` from the failed AU.

**Unit:** `./tests/unit/test_fpga_video_publish.sh` → **PASS** after TB updates:
- wait `publish_state==10 || present_pending` (no longer only DISPLAY_WAIT)
- write cancel `state==6 || state==17`
- expose `present_pending` from TB top

**Product enable:**  
`Plex.sv` publisher: `.PIPELINED_COPY(1'b1), .OVERLAP_DISPLAY_COPY(1'b1)`

**Fit trees:**
- Work:  
  `.worktrees/fpga-h264-fleet-30ff2997/build/true24-r14-overlap-display-fit-20260910/`
- Sources under `.../project/fpga/Plex_MiSTer/` (publish + Plex OVERLAP + QSF seed).

**Seed 11 fit (`native-copy-r14-overlap`):**
- RBF produced: sha256 `226fb252ddcf3e59e229cb81eef94341e82bbd62b212f83e1dd377d34e04142c`  
  md5 `59b04d585d0d3097b035e15a67e1938d`
- **TIMING REJECT:** Slow 1100mV **−40C** HDMI clk setup **−0.133 ns** (TNS −0.433), 8 paths.
- **Failing path is NOT publish FSM** — `ascal|o_vpix_inner[1].g[*] → ascal|o_poly_lum[*]` (scaler poly). Placement noise vs R13 seed11 (+0.246 HDMI setup).
- Do **not** deploy 226f under normal gates.

**Seed 12 fit (`native-copy-r14b-seed12`):** launched to recover ascal slack; QSF `SEED 12`. Log: `fit-seed12.log`, pid file `fit-seed12.pid`. Poll with `ps -p $(cat fit-seed12.pid)` only.

---

## What you are stuck on (precise)

### Stuck A — true24 startup bowl (~700 ms / ~20 fps)
**Symptom:** unique frame-id fps after bars_ok shows slow bins then settles ~24.  
**Not fixed by:** USB/media spool ideas (bowl is present/swap/bandwidth path, not bitstream starvation), R10–R12 DDR priority, R13 within-frame pipeline.  
**Best remaining structural lever:** R14 multi-frame overlap (copy ∥ DISPLAY_WAIT), then if still flat: **decode-time / always-auth / frames_done / swap_authorize / host pace interaction**.  
**Metric recipe (do not invent another):** unique n_id after bars_ok; geom origin_x=160 pitch=48; strip y=90 h=32 bars 0..32; lag = 24*wall − (n−n0); late_ms = lag*1000/24.

### Stuck B — R14 not on glass yet
R14 logic is unit-green but **no timing-clean RBF deployed**. Seed11 blocked on **ascal HDMI −0.133 ns**. Need seed12 (or seed13) **all-model setup/hold ≥ 0**, then menu deploy + glass remeasure vs 1523 baseline.  
If seed spam fails: either accept tiny ascal risk only with explicit user waiver (not default), or temporarily disable OVERLAP and pursue non-fit levers (host lead, decode), or micro-pipeline ascal (out of bowl scope).

### Stuck C — canonical restart pair mismatch (pre-existing)
Official bin/conf restart files may not match live **cc7/e273** pair; activation often uses candidate dir + manual `./misterplexd` with `ARM_PLEXD_AV_TRACE=1`. Known-pair recovery bundle exists from earlier prep; do not thrash `load_core`.

### Stuck D — dirty git / dual trees
- Fleet worktree `implement/fpga-h264-fleet-30ff2997` has **large unrelated dirty set** (audio MPX, many RTL files) plus R14.
- Primary `ship/v0.4.0` also dirty.
- R14 **publish.sv + TB** were untracked in fleet until this handoff commit attempt.
- Fit project copies under `build/true24-r14-…` are the **authoritative compiled inputs** for the running fit; fleet `fpga/` should stay byte-synced for publish + OVERLAP lines.

### Stuck E — checkpoint reseal
`checkpoint.py progress` may say checkpoint must be resealed; coordinator owns full snapshot seal. Lane progress text is still useful.

---

## Do next (ordered)

1. **Finish seed12 fit**  
   - `ps -p $(cat .../fit-seed12.pid)`  
   - On exit: grep `QUARTUS_TIMING` / negative slack in `fit-seed12.log`  
   - Need **PASS** all four models setup/hold (no negative HDMI ascal).

2. **If PASS:** hash RBF; soft-stop daemon; scp into candidate `bab9d55b-…`; keep `Plex.rbf.1523` backup; `DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh` style menu bounce; start candidate misterplexd with AV_TRACE; **real Web cast** true24 title; run bowl remeasure script; compare to 1523 JSON.

3. **If still bows:**  
   - Confirm host CSV: type11 commit, 12 submit, 13 pace; gap_med / submit→commit.  
   - If submit→commit drops but glass still bowls → present/vsync/authorize.  
   - If submit→commit unchanged → overlap not engaging (check `present_pending` path / frame_ready during present) or **decode** dominates.  
   - Next RTL: instrument presentation path or triple-buffer if 2-bank free-bank race; avoid more m1 mux tweaks.

4. **If seed12 FAIL again on ascal:** try SEED 13 once; then stop seed lottery and document; keep 1523 live.

5. Update `ROOTCAUSE.json` `r14_result` + `checkpoint.py progress --lane single-rbf-glass`.

---

## Key file map

| Path | Role |
|------|------|
| `fpga/Plex_MiSTer/rtl/fpga_video_publish.sv` | R14 OVERLAP FSM |
| `fpga/Plex_MiSTer/Plex.sv` | PIPELINED+OVERLAP product params; m1_boost(publish_want) |
| `fpga/Plex_MiSTer/rtl/ddr_bus_arbiter.sv` | R10 credit + R12 m1_boost |
| `fpga/Plex_MiSTer/rtl/ddr_transport_mux.sv` | R11 publish choose_b |
| `tests/rtl/fpga_video_publish_tb_{top.sv,cpp}` | R14 TB |
| `tests/unit/test_fpga_video_publish.sh` | unit runner |
| `Memory/lab/.../true24-bowl-rootcause-20260910/ROOTCAUSE.json` | narrative R9–R14 |
| `Memory/lab/.../true24-bowl-remeasure-*-20260910/` | glass numbers |
| `build/true24-r13b-pipelined-copy-fit-20260910/` | live 1523 fit tree |
| `build/true24-r14-overlap-display-fit-20260910/` | R14 fits seed11/12 |
| `build/true24-r9-unit-20260910/` | earlier unit sandbox if present |

### Fit recipe (copy-paste)

```bash
WT=.../fpga-h264-fleet-30ff2997
OUT=$WT/build/true24-r14-overlap-display-fit-20260910
TOOL=$WT/build/coherent-functional-sys20-frac-5754/staged/timing-tool-r4/source/scripts/build_rbf.sh
IMG=sha256:1fba8b9347973365e9f7851d73f7cb035e38fefb827cbf0ed2ea291b48bdf6dd
env -u MISTERPLEX_BUILD_REFERENCE_RBF PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0 \
  GIT_DIR=/home/flynnsbit/Projects/MisterPlex/.git GIT_WORK_TREE=$OUT/project \
  MISTERPLEX_ALLOW_LOCAL_FIT=1 MISTERPLEX_BUILD_ALLOW_UNVERIFIED=1 \
  MISTERPLEX_QUARTUS_IMAGE=$IMG \
  bash $WT/scripts/run_with_resource_preflight.sh \
  bash $TOOL --backend local-container native-copy-r14b-seed12 \
  $OUT/project/fpga/Plex_MiSTer --derive-video-build-id --retain-project
```

### Deploy sketch

```bash
# soft-stop companion; scp Plex.rbf → candidate dir; keep .1523 backup
# menu core bounce then load Plex; run candidate ./misterplexd with ARM_PLEXD_AV_TRACE=1
# glass: scripts/hdmi_capture_idle.sh (discard warmup); bowl remeasure notebook/scripts used for 1523
```

---

## What not to do

- Do not claim true24 fixed without peak_late/bins proof.
- Do not thrash load_core / kill-9 storms.
- Do not start a second Quartus while one fits.
- Do not redeploy seed11 **226f** as “good enough” without timing PASS or explicit waiver.
- Do not chase more DDR arbiter priority for this bowl.
- Do not use USB/SD spool as the primary bowl fix.
- Do not paste live tokens into git or handoff.

---

## Coordinator blurb (short)

R13 live 1523 still ~704 ms bowl. R14 overlap coded+unit PASS; seed11 RBF timing fail ascal −0.133 ns; seed12 fitting. Next: timing-clean R14 → menu deploy → glass vs 1523.

*Generated: 2026-09-11T03:51:23Z*
