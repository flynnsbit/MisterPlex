# Multi-agent orchestration (lab)

> **Start here:** [`agent-fleet-playbook.md`](agent-fleet-playbook.md) — the durable
> structure for running a worker fleet (token protocol, worker prompt anatomy, evidence
> standards, tick loop, anti-patterns). **This** document holds the run-specific lab
> gates and deploy bans, which change from build to build.

**Default harness (all projects):** `~/.grok/rules/00-multi-agent-build.md` + skill `/multi-agent-build`  
(`~/.grok/skills/multi-agent-build/SKILL.md`). Repo entry: root `AGENTS.md`.

**Expert roster (max 10):** [`AGENT_EXPERT_ROSTER.md`](AGENT_EXPERT_ROSTER.md) — FPGA, ARM, Memory, FPGA Fit, Builds, Tests, Rubber duck, Clock, Path/DMA, Integration.  
Bucket example: [`agent-bucket.example.json`](agent-bucket.example.json).

## Goal
Keep **4–10 specialist agents** busy (target **6**) until `docs/PHASE_BACKLOG.md` gates are green.
Parent (top-level) verifies count and **refills the bucket** every tick. Prefer roster IDs over ad-hoc names.

## Every orchestrator tick
1. Read `docs/PHASE_BACKLOG.md` + `/tmp/misterplex-agent-bucket.json` + roster
2. Count open TODO/IN_PROGRESS items
3. Detect Quartus: if `pgrep -f quartus` or docker `*quartus*` → **RBF slot occupied** (`w-fit` only when FREE)
4. Spawn workers until **target 6 concurrent** (min 4, **max 10**):
   - If RBF slot free and intentional fit needed → at most **1** `w-fit`
   - Always keep **rd-duck** available for high-risk claims
   - All other slots → non-RBF phase work mapped to roster experts
5. Write `/tmp/misterplex-loop-status.txt` with: time, agent goals spawned, RBF state, next gaps
6. Update PHASE_BACKLOG statuses when workers report DONE

## Safe deploy only
`DEPLOY_LOAD=none|menu ./scripts/deploy_plex_core.sh` — never thrash load_core.

## MiSTer claim / soft-bounce (mandatory)

The lab MiSTer may be in active user playback. **Any agent that needs to
observe or use the MiSTer must acquire the claim and soft-bounce first, so the
user sees it.** Silent SSH, status probes that load cores, or background
`load_core` without a visible Menu flash are forbidden.

```bash
# Acquire exclusive claim + visible Menu → Plex bounce, run work, auto-release:
./scripts/mister_soft_bounce.sh claim \
  --agent "H-gate-rcsum" --reason "hard residual sticky probe" \
  -- ./tests/hw/test_fbar_fast.sh

# Status / emergency release (override):
./scripts/mister_soft_bounce.sh status
MISTER_CLAIM_FORCE=1 ./scripts/mister_soft_bounce.sh release
```

| Rule | Detail |
|------|--------|
| Mutual exclusion | Atomic `mkdir` lock at `build/mister-claim.lock` (override path: `MISTER_CLAIM_LOCK`). Owner pid + agent id + timestamp recorded. Stale lock: dead pid and age ≥ `MISTER_CLAIM_STALE_S` (default 7200), or `MISTER_CLAIM_FORCE=1`. |
| Visible signal | Reuses **only** `DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1 ./scripts/deploy_plex_core.sh` (Menu → wait → Plex). Never flashes a different RBF. Never thrash `load_core`. Never `kill -9` from the claim path. |
| Post-bounce CORENAME | **Required.** After every bounce, read `/tmp/CORENAME` (SSH banner-filtered). Must be `Plex` (case-insensitive). On mismatch print `CORENAME_NOT_PLEX` with the observed name and exit **rc=5**. A successful menu bounce is **not** proof the FPGA stayed on Plex. |
| Third-party seizure | This lab host runs `MiSTer_Physical-CD` / `superdrive_*` automation that can auto-load `CDPlayer.rbf` (`CORENAME=CD-CDPlayer`) at any time. Treat non-Plex CORENAME as a hard stop — do not thrash `load_core` to “fix” it. |
| Audit | Append who/when/why **and corename** to local `build/mister-claim-audit.log` and on-device `/media/fat/misterplex/claim-audit.log`. Timeline questions (“who took it?”) must be answerable from this log, not inference. |
| Release | EXIT/INT/TERM trap always releases the lock and soft-bounces back to Plex so the device returns usable. |
| Conf | Do **not** edit `/media/fat/misterplex/misterplex.conf` from this path. If a separate task must edit conf, take a timestamped backup first. |
| Local test | Lock + CORENAME seizure logic unit-tested with `MISTER_CLAIM_SKIP_BOUNCE=1` / `MISTER_CLAIM_FAKE_CORENAME` (no device). Do not bounce the live device without telling the user. Device freeze: no agent touches the host until parent lifts it in writing. |

### READY_TO_DEPLOY gate (R-csum4 era — H-proto-rcsum4f)

**READY_TO_DEPLOY=NO** while **either**:
1. **R-csum4 LIVE** — exclusive Quartus still running (map/fit/asm/sta/sh or docker compile up), **or**
2. **DRIFT_CRITICAL** — live WT `Plex.sv` / `slice_hdr_parser.sv` md5 ≠ claim freeze
   (`/tmp/plex_quartus_rcsum4.claim/src_md5.txt`) and parent has **not** written an
   explicit **accept-ambiguous** flag for that bitstream.

Do **not** invent READY_TO_DEPLOY=YES from partial log growth, process exit alone, or
fitmon “ready for deploy” while claim LOCK_OK is missing.

**After BUILD_OK only** (Full Compilation success + exit 0 + exclusive idle):
1. Require **NEW_RBF ∉ banned**
   `{4d6ee356,4deaf6cc,dabdaeb0,820484a6,6db3a4d8,aa146c17}` (prefix8 or full).
2. Prefer claim **LOCK_OK** (live md5s == claim freeze at end-of-fit). If AMBIG /
   DRIFT_CRITICAL → deploy only with **explicit parent accept-ambiguous** note; never
   invent product PASS from ambiguous provenance.
3. **ONE** `DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh` only (owner H-deploy-rcsum4).
4. **Never** `killall -9` thrash / load_core storms; **never** thrash-redeploy **`4d6ee356`**.
5. Hard residual expect **`e8 14 xx`** class for DIAG sticky proof (`raw[13]==0x14` ≥2);
   **reject +0x53/push** family; soft-skip ≠ hard PASS.
6. **DIAG ≠ product PASS**; **3l2 BLOCKED** until non-DIAG product sticky 0x14.

Canonical post–BUILD_OK card: `/tmp/misterplex-agent-H-proto-rcsum4f.txt` (and prior
`H-proto-rcsum4e`). Living residual detail: `docs/phase3-3l-idct.md`.

### After lab 75da8bb1 (H-proto-rcsum4g)

Lab **LOADED `75da8bb1`** (H-deploy-rcsum4 ONE menu). Card:
`/tmp/misterplex-agent-H-proto-rcsum4g.txt`. Detail: `docs/phase3-3l-idct.md` §
*Post–lab 75da8bb1 branch protocol*.

**H-gate class (probes ~13:25):** FBAR PASS; res_dc PASS; hard csum **HARD_FAIL** —
**never sticky 0x14**; **+0x53/push** (0x40→0x93→0xe6). **NOT PACK_PROVEN.**

| Branch | Trigger | Next (serial) |
|--------|---------|----------------|
| **A PACK_PROVEN** | sticky raw[13]==0x14 ≥2 | Strip DIAG (`residual_csum<=csum_acc`); new freeze md5s LOCK_OK; sole **R-csum5** product; ONE menu; hard product sticky 0x14 — **only then 3l2 may unblock** |
| **B still +0x53** (**ACTIVE**) | never 0x14; +0x53/push | Pack multi-drive RCA (`Plex.sv` telem / hps_io); **not** re-DIAG thrash; **no thrash-redeploy** same RBF 75da8bb1 or **4d6ee356**; no re-menu storm |

**Always:** soft-skip ≠ PASS; DIAG ≠ product PASS; 3l2 BLOCKED until non-DIAG product
sticky 0x14. Protocol agents do not deploy/fit/edit RTL.

### Post HARD_FAIL 75da8bb1 → R-csum5 (H-proto-rcsum5)

Canonical card: `/tmp/misterplex-agent-H-proto-rcsum5.txt`. Detail:
`docs/phase3-3l-idct.md` § *Post–HARD_FAIL 75da8bb1 R-csum5 serial protocol*.

**H-gate-rcsum4 final:** **MULTI_DRIVE_OR_STILL_FAIL** / **NOT PACK_PROVEN**
(sticky0x14=0/7; +0x53/push; DIAG `e8 14` never). Lab stays on **`75da8bb1`** for
read-only probes only.

| Rule | Value |
|------|--------|
| Thrash-redeploy | **FORBIDDEN** for **`75da8bb1`** and **`4d6ee356`** |
| RTL next | **R-csum-rtl5** intentional sticky residual-pair latch → **FIT_GO** + **new md5s** |
| Sole | **R-csum5** exclusive only; wall **>420s**; log `/tmp/plex_quartus_rcsum5.log` |
| NEW_RBF banned | ∉ `{75da8bb1,4d6ee356,4deaf6cc,dabdaeb0}` (abort promote if match) |
| Deploy | **ONE** menu after BUILD_OK (**H-deploy-rcsum5**); never second for luck |
| Hard gate | sticky **raw[13]==0x14** ≥2; reject **+0x53/push**; soft-skip ≠ PASS |
| 3l2 | **BLOCKED** until non-DIAG **product** sticky 0x14 |
| READY_TO_DEPLOY | **NO** until BUILD_OK **new** + LOCK_OK (or accept-ambiguous) |

**READY_TO_DEPLOY=NO** at protocol write (no R-csum5 BUILD_OK yet). Do not invent YES.
Protocol agents do not deploy/fit/edit RTL.

### Post–R-csum5 BUILD_OK trust + single safe deploy (H-proto-rcsum5c)

Canonical card: `/tmp/misterplex-agent-H-proto-rcsum5c.txt`. Detail:
`docs/phase3-3l-idct.md` § *Post–R-csum5 BUILD_OK trust + single safe deploy*.

**READY_TO_DEPLOY=NO** while sole **LIVE** and until terminal **BUILD_OK + trust**.
Do not invent YES. Protocol agents do not deploy/fit/edit RTL. Never kill LIVE sole.

**Mid-fit thrash SoT:** launch MAP product **`6422fb9a`/`8e6af3bb` DIAG=ABSENT**;
live+claim thrash **`6a5dcaaa`/`7d4a1d8b` DIAG=PRESENT** → **PROVENANCE_UNTRUSTED**.
**LOCK_OK** requires live==claim==**map** (triple). Lab **`75da8bb1`** thrash forbidden.

| Branch | Trigger | Action |
|--------|---------|--------|
| **A LOCK_OK** | BUILD_OK + live==claim==map + NEW_RBF ∉ banned | ONE promote + ONE `DEPLOY_LOAD=menu` → **H-gate-rcsum5** sticky raw[13]==0x14 ≥2; reject +0x53; res_dc=-24 |
| **B UNTRUSTED** | BUILD_OK + DRIFT/PROVENANCE_UNTRUSTED | **NO auto-deploy**; parent accept-ambiguous **or** abort refreeze + re-sole |
| **C FIT_DEAD/FAIL** | no BUILD_OK | free exclusive; refreeze; re-sole only |
| **D after gate** | sticky 0x14 DIAG only | PACK_PROVEN maybe; strip DIAG → product sole before 3l2 |

**Always:** never thrash **`75da8bb1`/`4d6ee356`**; never kill-9 storms; soft-skip ≠ PASS;
**DIAG ≠ product PASS**; **3l2 BLOCKED** until non-DIAG product sticky 0x14.
Default after thrash: **B**.

### R-csum5 endgame deploy-trust (H-proto-rcsum5d)

Canonical card: `/tmp/misterplex-agent-H-proto-rcsum5d.txt`. Detail:
`docs/phase3-3l-idct.md` § *R-csum5 endgame deploy-trust protocol*.

**READY_TO_DEPLOY=NO** while exclusive **LIVE** or until **BUILD_OK + trust**.
Do not invent YES. Protocol agents do not deploy/fit/edit RTL.

**POST-TERMINAL ~13:40 BUILD_OK → ~13:42 DEPLOY → ~13:44 HARD_FAIL (L-csum-note33):**
R-csum5 **BUILD_OK** wall **441s** NEW_RBF **`8832824e`** full
`8832824e483cf6613f82ee3ba3e592b3`; mid-fit **PROVENANCE_UNTRUSTED**; parent
accept-ambiguous → **H-deploy-rcsum5 DEPLOY_OK** lab **LOADED `8832824e`**.
**H-gate-rcsum5 HARD_FAIL MULTI_DRIVE / NOT PACK_PROVEN** — sticky0x14=**0**/7;
**+0x53 multi-drive continues after sticky-pack sole**; **res_dc PASS**;
**BUILD_OK+DEPLOY_OK ≠ hard residual PASS**. thrash **`8832824e`/`75da8bb1`/
`4d6ee356` forbidden**. **Next = multi-drive RCA (not redeploy)**. soft-skip ≠ PASS;
**3l2 BLOCKED**. Detail: `docs/phase3-3l-idct.md` § *L-csum-note33 stamp*.


**NEW_RBF banned:** `{75da8bb1,4d6ee356,4deaf6cc,dabdaeb0}` (+ older
`820484a6,6db3a4d8,aa146c17`). Abort promote if match.

**Intentional freeze (LOCK_OK target):** Plex **`6a5dcaaa`** / slice **`7d4a1d8b`**
(DIAG PRESENT). Launch poison risk: map may have seen **`6422fb9a`/`8e6af3bb`**.

| Branch | Trigger | Action |
|--------|---------|--------|
| **A LOCK_OK** | BUILD_OK + live==claim freeze **6a5dcaaa/7d4a1d8b** + clean NEW_RBF ∉ banned | ONE promote + ONE `DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh` → **H-gate-rcsum5** sticky **raw[13]==0x14** ≥2; reject **+0x53/push** |
| **B PROVENANCE_UNTRUSTED** | BUILD_OK but map may have seen **6422fb9a** / LOCK_OK unproven | **NO auto-deploy**; parent **accept-ambiguous** (named md5) **or** abort refreeze + re-sole |
| **C FAIL/FIT_DEAD** | no BUILD_OK | free lock; refreeze; re-sole only; READY_TO_DEPLOY stays NO |

**Always:** thrash **`8832824e`/`75da8bb1`/`4d6ee356` forbidden**; soft-skip ≠ PASS;
never kill-9 thrash; **DIAG ≠ product PASS**; **3l2 BLOCKED** until non-DIAG product sticky 0x14.
**Next after H-gate-rcsum5 HARD_FAIL:** multi-drive **RCA** (not redeploy).

**R-csum5 endgame closed HARD_FAIL (L-csum-note33):** lab **`8832824e`** H-gate-rcsum5
sticky0x14=0 **+0x53 multi-drive continues after sticky-pack sole**; **res_dc PASS**;
**NOT PACK_PROVEN**. Mid-fit historical: launch **`6422fb9a`/`8e6af3bb`** → thrash
**`6a5dcaaa`/`7d4a1d8b`** **PROVENANCE_UNTRUSTED**. Evidence:
`/tmp/misterplex-agent-H-gate-rcsum5.txt`, `/tmp/misterplex-agent-H-gate-rcsum5b.txt`,
`/tmp/misterplex-agent-H-deploy-rcsum5.txt`, `/tmp/misterplex-agent-L-csum-note33.txt`.
Detail: `docs/phase3-3l-idct.md` § *L-csum-note33 stamp*.

### After HARD_FAIL 8832824e (H-proto-rcsum6)

Canonical card: `/tmp/misterplex-agent-H-proto-rcsum6.txt`. Detail:
`docs/phase3-3l-idct.md` § *Post–HARD_FAIL 8832824e branch protocol*.

**H-gate-rcsum5 final:** **MULTI_DRIVE_OR_STILL_FAIL** / **NOT PACK_PROVEN**
(sticky0x14=0/7; +0x53/push ×6; series `16 69 bc 0f 62 b5 08`; ideal `e8 14`
never). Lab **LOADED `8832824e`** full `8832824e483cf6613f82ee3ba3e592b3` after
H-deploy-rcsum5 **ONE** menu (accept-ambiguous). FBAR soft PASS; res_dc PASS −24;
**BUILD_OK+DEPLOY_OK ≠ hard residual PASS**.

| Rule | Value |
|------|--------|
| Thrash-redeploy | **FORBIDDEN** for **`8832824e`**, **`75da8bb1`**, **`4d6ee356`** |
| READY_TO_DEPLOY | **NO** until new intentional **BUILD_OK + LOCK_OK** |
| Next RTL | Multi-drive telem isolation RCA → intentional freeze md5s → sole only; **mid-fit thrash FORBIDDEN** |
| Deploy after next sole | **ONE** menu only (`DEPLOY_LOAD=menu`) |
| Hard expect | sticky **raw[13]==0x14** ≥2; reject **+0x53/push** |
| 3l2 | **BLOCKED** until non-DIAG **product** sticky 0x14 |
| soft-skip | ≠ PASS |

| Branch | Trigger | Next (serial) |
|--------|---------|----------------|
| **A PACK_PROVEN** | sticky raw[13]==0x14 ≥2 | **Not this silicon** (never on 8832824e). If future RBF: strip DIAG → freeze LOCK_OK → sole product → ONE menu → product sticky 0x14 — only then 3l2 may unblock |
| **B still multi-drive** (**ACTIVE**) | never 0x14; +0x53/push | Multi-drive telem isolation RCA (`Plex.sv` / hps_io status); **no thrash-redeploy** 8832824e/75da8bb1/4d6ee356; no re-menu storm |
| **C re-sole clean** | intentional multi-drive RTL freeze ready + exclusive FREE | New freeze md5s LOCK_OK → sole **R-csum6** (no mid-fit thrash) → NEW_RBF ∉ banned `{8832824e,…}` → ONE menu → H-gate sticky 0x14 ≥2 |

**Always:** soft-skip ≠ PASS; DIAG ≠ product PASS; 3l2 BLOCKED until non-DIAG product
sticky 0x14. Protocol agents do not deploy/fit/edit RTL. Do not invent READY_TO_DEPLOY=YES.

### Post–R-csum6 deploy-trust (H-proto-rcsum6 → … → H-proto-rcsum6e)

Canonical cards:
- authorize stamp: `/tmp/misterplex-agent-H-proto-rcsum6.txt` (~14:00)
- residual WAIT while LIVE: `/tmp/misterplex-agent-H-proto-rcsum6c.txt` (**PROTO_OK**)
- post-terminal H-deploy checklist (LIVE-era): `/tmp/misterplex-agent-H-proto-rcsum6d.txt` (**PROTO_OK**)
- **post BUILD_OK+DEPLOY stamp:** `/tmp/misterplex-agent-H-proto-rcsum6e.txt` (**PROTO_OK**)
- prior LIVE refresh: `/tmp/misterplex-agent-H-proto-rcsum6b.txt` (Branches A/B/C/D detail)
Detail: `docs/phase3-3l-idct.md` § *Post–R-csum6 deploy-trust* + § *Post BUILD_OK+DEPLOY 94bbfe43*.

**@ write (H-proto-rcsum6d residual WAIT):** Parent **FIT_GO=YES**; exclusive **R-csum6 LIVE**
(`R-csum6 LIVE 2026-07-24T14:02:42-05:00`; lock `/tmp/plex_quartus.lock`; docker +
`quartus_sh` + **`quartus_fit`**). Claim freeze **MATCH** live (mid-fit only):
`Plex.sv c7a847f7…` / `slice ca62d02b…` / `stream 904e9b2e…`; **DIAG=ABSENT** product
path (STRIPPED — hard PASS is **product** sticky 0x14 real XOR, not DIAG force).
Log `/tmp/plex_quartus_rcsum6.log` (A&S ok; fit placement ok; **Full Compilation success
count=0** — do **not** invent BUILD_OK). Host/lab still **`ec21e133`**. Authorization +
LIVE sole **≠ BUILD_OK**. Mid-fit MATCH **≠** terminal LOCK_OK.
**READY_TO_DEPLOY residual still NO while LIVE fit.**

**Background waiter caveat:** a waiter **may auto-deploy after real Full Comp**. Parent
must **still** verify **LOCK_OK** (live==claim). **soft-skip ≠ PASS**.
**BUILD_OK+DEPLOY ≠ residual PASS**. Prefer ONE **H-deploy-rcsum6** menu after trust; if
waiter already did ONE clean menu on LOCK_OK NEW — do **not** second for luck.

**Residual HARD_FAIL (cite):**
- **`8832824e`** — **H-gate-rcsum5d** DEFINITIVE MULTI_DRIVE +0x53 (**16/69/bc/0f/62/b5/08**); sticky0x14=0
- **`ec21e133`** wide reconfirm — **H-res-ec21** / **H-gate-ec21** MULTI_DRIVE +0x53 still; sticky0x14=0; res_dc PASS

**Wide orthogonal:** lab LOADED **`ec21e133`** WIDTH FAIL 0.605 (**H-gate-sf2**) ≠ residual gate.

| Rule | Value |
|------|--------|
| READY_TO_DEPLOY | **NO** until residual **BUILD_OK** Full Comp exit0 + **LOCK_OK** (live==claim) + NEW_RBF ∉ banned (incl **ec21e133**) |
| While LIVE | READY stays **NO**; mid-fit RTL thrash **FORBIDDEN**; ZERO second Quartus; ZERO deploy |
| NEW_RBF banned | `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0,820484a6,6db3a4d8,aa146c17,ec21e133}` |
| After trust YES | **ONE** **H-deploy-rcsum6** `DEPLOY_LOAD=menu` only — never second for luck |
| Hard gate | sticky **raw[13]==0x14** ≥2 independent F3 pushes; reject **+0x53/push**; res_dc=−24 |
| Hard gate runbook | **`docs/hard-residual-gate-rcsum6.md`** (H-gate-rcsum6-prep) — post ONE menu only; soft residual / FBAR ≠ PASS |
| Product path | DIAG already **ABSENT**; hard PASS = product sticky **real XOR 0x14** (not DIAG pack proof) |
| thrash | **FORBIDDEN** `8832824e`/`75da8bb1`/`4d6ee356`; no luck redeploy same NEW / `ec21e133` residual |
| soft-skip | ≠ PASS; FBAR EXIT=0 ≠ residual PASS; BUILD_OK+DEPLOY ≠ residual PASS |
| Waiter | auto-deploy after Full Comp still requires parent **LOCK_OK**; soft-skip ≠ PASS |
| 3l2 | **BLOCKED** until **product** sticky 0x14 ≥2 |
| Protocol agent | ZERO Quartus / deploy / load_core / RTL |

| Branch | Trigger | Next (serial) |
|--------|---------|----------------|
| **A LOCK_OK deploy** | BUILD_OK + live==claim freeze (`c7a847f7`/`ca62d02b`/`904e9b2e`) + NEW_RBF ∉ banned | READY=YES → **ONE** promote + **ONE** H-deploy-rcsum6 menu → H-gate sticky 0x14 ≥2 reject +0x53; res_dc=−24 |
| **B UNTRUSTED no auto** | BUILD_OK + live≠claim / mid-fit thrash / PROVENANCE_UNTRUSTED | **NO auto-deploy**; parent accept-ambiguous (named md5, ONE menu) **or** abort refreeze + re-sole only |
| **C FAIL free** | no Full Comp success / exit≠0 / FIT_DEAD | free exclusive; refreeze Rank1 product md5s; re-sole only; READY stays **NO** |
| **D after gate** | post H-gate-rcsum6 | product sticky 0x14 ≥2 → may consider **3l2** unblock; still +0x53 / never 0x14 → MULTI_DRIVE still ACTIVE → RCA **not** thrash redeploy; soft-skip ≠ PASS |

**Post-terminal H-deploy-rcsum6 serial (T0–T7; card H-proto-rcsum6d):**
T0 BUILD_OK harvest → T1 LOCK_OK claim freeze → T2 NEW∉banned → T3 READY YES named →
T4 PROMOTE once → T5 **ONE** `DEPLOY_LOAD=menu` → T6 lab md5 MATCH + CORENAME=Plex →
T7 H-gate sticky **0x14≥2** reject **+0x53** res_dc=−24. thrash banned FORBIDDEN;
soft-skip≠PASS; **3l2 BLOCKED** until product sticky 0x14.

**Terminal harvest (H-proto-rcsum6d ~14:12):** Phase A while LIVE held READY residual
**NO**. Phase B: BUILD_OK wall 438s + LOCK_OK + NEW **`94bbfe43`** ∉ banned → READY
residual **YES** Branch A. Peer DEPLOY_OK lab LOADED **94bbfe43**. **BUILD_OK+DEPLOY ≠
hard residual PASS** — serial continues at **H-gate-rcsum6** / H-proto-rcsum6e.
Card: `/tmp/misterplex-agent-H-proto-rcsum6d.txt`.

**Always:** never invent BUILD_OK / HARD PASS / PACK_PROVEN / product PASS / 3l2 UNBLOCK;
WIDE track orthogonal (WIDTH FAIL 0.605 ≠ residual).

### Post BUILD_OK+DEPLOY `94bbfe43` (H-proto-rcsum6e) — serial = hard residual

Canonical card: `/tmp/misterplex-agent-H-proto-rcsum6e.txt` (**PROTO_OK**). Detail:
`docs/phase3-3l-idct.md` § *Post BUILD_OK+DEPLOY 94bbfe43 serial*.

**@ write (~14:11 CDT):** Branch **A path TAKEN**. Exclusive **FREE**. R-csum6 **BUILD_OK**
lock `DONE … 2026-07-24T14:10:26-05:00` wall **438s** Full Comp **0e/40w** exit **0**.
NEW_RBF full **`94bbfe433feb562fabe0798e16b378c5`** prefix8 **`94bbfe43` ∉ banned**.
**LOCK_OK** live==claim freeze **`c7a847f7` / `ca62d02b` / `904e9b2e` DIAG=ABSENT**.
Host output + releases + out MATCH. **READY_TO_DEPLOY=YES** path taken: **ONE**
`DEPLOY_LOAD=menu` (background **waiter**); lab **LOADED `94bbfe43`** CORENAME=Plex.
**Do not second menu.**

| Field | Value |
|-------|--------|
| BUILD_OK | **YES** wall 438s; log `/tmp/plex_quartus_rcsum6.log`; exit file 0 |
| LOCK_OK | **YES** Rank1 product freeze DIAG=ABSENT |
| NEW_RBF | **`94bbfe43`** full `94bbfe433feb562fabe0798e16b378c5` size 3506356 |
| DEPLOY | **ONE menu DONE** (waiter); thrash second menu **FORBIDDEN** |
| Serial now | **H-gate-rcsum6** hard residual (critical) |
| Hard expect | sticky **raw[13]==0x14 ≥2**; reject **+0x53/push**; res_dc=−24; ideal `e8 14 xx` |
| BUILD_OK+DEPLOY_OK | **≠ hard residual PASS** — do not invent PASS / PACK_PROVEN |
| soft-skip / FBAR | ≠ residual PASS |
| 3l2 | **BLOCKED** until product sticky 0x14 ≥2 |
| If HARD_FAIL multi-drive | **RCA not thrash** — no luck redeploy `94bbfe43` / banned set |
| thrash banned | **FORBIDDEN** `8832824e`/`75da8bb1`/`4d6ee356` (+ no luck `ec21e133`) |
| WIDE / Q-SF3 | **orthogonal** FAIL 0.605 open; **Q-SF3 only after residual gate done or parent prioritizes** |
| Protocol agent | ZERO Quartus / deploy / load_core / RTL |

| Branch | Trigger | Next (serial) |
|--------|---------|----------------|
| **A taken** | BUILD_OK + LOCK_OK + NEW `94bbfe43` + ONE menu | **H-gate-rcsum6** sticky 0x14 ≥2 reject +0x53; res_dc=−24 |
| **D after gate** | post H-gate-rcsum6 | product sticky 0x14 ≥2 → may consider **3l2**; still +0x53 / never 0x14 → MULTI_DRIVE ACTIVE → **RCA not thrash**; soft-skip ≠ PASS |

**Always:** never invent HARD PASS / PACK_PROVEN / product PASS / 3l2 UNBLOCK;
**BUILD_OK+DEPLOY_OK ≠ hard residual PASS**; WIDE track orthogonal (WIDTH FAIL 0.605).

### Post H-gate-rcsum6 HARD_PASS `94bbfe43` (L-csum-note41) — 3l2 residual hard-block lifted

Canonical docs stamp: `docs/phase3-3l-idct.md` § *L-csum-note41*. Report:
`/tmp/misterplex-agent-L-csum-note41.txt` (**DOCS_OK**).

| Fact | Value |
|------|--------|
| product residual | **HARD_PASS** / **HARD_PASS_PRODUCT_STICKY** / **PACK_PROVEN** on lab **`94bbfe43`** |
| sticky0x14 / plus53 / res_dc | **7/7** / **0** / **PASS 7/7** ideal **e8 14 xx** |
| DIAG / claim | **ABSENT**; LOCK_OK **c7a847f7/ca62d02b/904e9b2e** |
| DEPLOY | **DEPLOY_OK** ONE menu (`/tmp/misterplex-agent-H-deploy-rcsum6.txt`) |
| Gate SoT | `/tmp/misterplex-agent-H-gate-rcsum6.txt` + `/tmp/misterplex-H-gate-rcsum6-summary.txt` |
| **3l2 residual hard-block** | **LIFTED** — may start 3.3l-2 product IDCT wire-up / gate |
| Not claimed | **≠ WIDE PASS** (still FAIL **0.605** on historical **ec21e133**); **≠ full 3l2 product DONE** |
| Do not | re-run residual gate; thrash-redeploy **94bbfe43**/banned; invent WIDE/3l2 DONE |

**Next serial:** 3l2 product IDCT wire-up / gate; WIDE Fix-3 orthogonal/separate.

### Dual-track: Q-SF2 LIVE + residual HARD_FAIL 8832824e (H-proto-dual1)

Canonical dual-track card: `/tmp/misterplex-agent-H-proto-dual1.txt`. Detail:
`docs/phase3-3l-idct.md` § *Dual-track protocol (H-proto-dual1)*. Peers: wide
`/tmp/misterplex-agent-H-proto-qfix2.txt`; residual `/tmp/misterplex-agent-H-proto-rcsum6.txt`.

**@ write (~13:51 CDT):** exclusive **Q-fix2 LIVE** (wide Fix-2; lock
`Q-fix2 2026-07-24T13:45:49-05:00`; `quartus_fit` active; **NOT BUILD_OK** — do not invent).
Lab residual **LOADED `8832824e` HARD_FAIL** multi-drive (H-gate-rcsum5d). Tracks **orthogonal**.

| Track | State | READY_TO_DEPLOY |
|-------|-------|-----------------|
| **W** wide Fix-2 | sole LIVE map→fit; colorbars freeze `f1d9666a` | **NO** until BUILD_OK + NEW_RBF clean |
| **R** residual | CLOSED FAIL on **8832824e**; thrash FORBIDDEN | **NO** until FREE + multi-drive LOCK_OK sole **R-csum6** |

**While Q-fix2 LIVE:** ZERO second Quartus; ZERO mid-fit RTL thrash (docker `-v`);
ZERO residual thrash-redeploy **8832824e**/`75da8bb1`/`4d6ee356`; soft-skip ≠ PASS;
**3l2 BLOCKED**.

**After Q-fix2 BUILD_OK (wide only):** NEW_RBF ∉ banned → **ONE** promote + **ONE** menu →
wide eyes-on gate **separate** from residual. **WIDE PASS ≠ residual PASS ≠ 3l2**.

**R-csum6:** only after exclusive FREE + intentional multi-drive fix LOCK_OK + FIT_GO —
not luck redeploy of **8832824e**. Protocol agents do not deploy/fit/edit RTL.

**POST-TERMINAL (~13:52:56 CDT H-proto-dual1 amend):** Q-fix2 **BUILD_OK** Full Comp
0e/38w exit 0; NEW_RBF **`ec21e133`** ∉ banned; colorbars freeze **f1d9666a** LOCK_OK.
**READY_TO_DEPLOY_WIDE=YES** → ONE menu wide only (H-deploy-fix2). Residual READY still
**NO**; thrash **`8832824e`/`75da8bb1`/`4d6ee356` FORBIDDEN**. WIDE PASS ≠ residual PASS;
**3l2 BLOCKED**. soft-skip ≠ PASS. Card amend §10 in `/tmp/misterplex-agent-H-proto-dual1.txt`.

### L-csum-note37 — dual-track after Q-SF2 BUILD_OK+deploy+WIDE FAIL (exclusive FREE)

Detail: `docs/phase3-3l-idct.md` § *L-csum-note37*. Report:
`/tmp/misterplex-agent-L-csum-note37.txt`.

| Track | Fact | Gate |
|-------|------|------|
| **W** wide Fix-2 | BUILD_OK **`ec21e133`** wall **415s**; SRC **`f1d9666a`**; lab LOADED (H-deploy-qSF2); PACKAGE_OK embeds ec21e133 | FBAR soft PASS; **WIDE FAIL 0.605** pillar **PILLAR_320_of_529** (W-wide-gate-SF2/SF2b) — FAIL open |
| **R** residual | **HARD_FAIL both** product **`8832824e`** (H-gate-rcsum5d sticky0x14=0/12 +0x53) **and** LOADED **`ec21e133`** (H-gate-ec21 / H-res-ec21 sticky0x14=0 +0x53 **54…46**) | HARD_FAIL; thrash FORBIDDEN |

**Exclusive FREE.** Competing next soles (parent picks **ONE**): **Q-SF3** (wide Fix-3 after design) **OR** **R-csum6** (residual multi-drive).  
**R-csum-rtl6-plan FIT_GO=NO** until parent authorize.  
**READY_TO_DEPLOY residual=NO** — do not invent YES until intentional LOCK_OK product sole BUILD_OK.  
Rules: **ZERO second Quartus**; mid-fit thrash **FORBIDDEN**; after next BUILD_OK → **ONE** menu only; thrash ban residual **`8832824e`/`75da8bb1`/`4d6ee356`** + **no thrash-redeploy luck on `ec21e133` for residual green**; **WIDE gate ≠ residual PASS ≠ 3l2**; hard expect sticky **raw[13]==0x14 ≥2** reject **+0x53**; soft-skip ≠ PASS; **3l2 BLOCKED**.



### Q-fix2 wide track while residual HARD_FAIL 8832824e (H-proto-qfix2)

Canonical card: `/tmp/misterplex-agent-H-proto-qfix2.txt`. Detail:
`docs/phase3-3l-idct.md` § *Q-fix2 wide track dual-path protocol*. Residual branch card:
`/tmp/misterplex-agent-H-proto-rcsum6.txt`.

**Dual track @ write:** exclusive **Q-fix2 LIVE** (wide Fix-2 map→fit; lock
`Q-fix2 2026-07-24T13:45:49-05:00`; log `/tmp/plex_quartus_fix2.log`; claim
`SRC_colorbars=f1d9666a…`). Lab residual **LOADED `8832824e` HARD_FAIL** multi-drive
(H-gate-rcsum5). Tracks are **orthogonal** — do not conflate gates.

| Rule (while Q-fix2 LIVE) | Value |
|--------------------------|--------|
| Second Quartus | **ZERO** |
| Mid-fit RTL thrash | **ZERO** (`Plex.sv` / slice_hdr / colorbars under docker `-v`) |
| Residual thrash-redeploy | **FORBIDDEN** **`8832824e`/`75da8bb1`/`4d6ee356`** |
| Residual re-sole | **BLOCKED** until exclusive FREE |
| BUILD_OK invent | **NO** until Full Comp + exit 0 + NEW_RBF |
| soft-skip / 3l2 | ≠ PASS; **3l2 BLOCKED** |

**After Q-fix2 BUILD_OK (wide serial only):**
1. NEW_RBF ∉ banned `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0,…}`
2. Prefer colorbars freeze LOCK_OK (`f1d9666a…` or intentional Fix-2 claim)
3. **ONE** promote + **ONE** `DEPLOY_LOAD=menu` only
4. **Wide eyes-on gate separate** from residual hard gate (frac≥0.95; ≠ PILLAR_320_of_529;
   FBAR still green). **WIDE PASS ≠ residual PASS ≠ 3l2 unblock**

**Residual sole R-csum6:** only after **Q-fix2 FREE** + intentional multi-drive fix
**LOCK_OK** (not luck redeploy of **8832824e**). Hard expect sticky raw[13]==0x14 ≥2;
reject +0x53. Protocol agents do not deploy/fit/edit RTL.

## Post–R-csum1 hard residual gate (status)

**R-csum1 BUILD_OK** md5 **`dabdaeb0`** (full `dabdaeb0c5ae708c4fdbba388ba275b6`). Sources committed **`7bee0a6`**.

**H-deploy-rcsum1 / H-rcsum-gate DONE (2026-07-24):**
- Promote + **one** `DEPLOY_LOAD=menu` → lab md5 match **PASS**
- FBAR **PASS** (m1=82.9 m2=94.4)
- res_dc=-24 **PASS** (raw[12]=0xE8 stable)
- **res_csum HARD FAIL** — raw[13] unstable (139/222/49) ≠ 0x14; soft-skip EXIT=0 **≠ hard PASS**
- Park bars **PASS**
- Report: `/tmp/misterplex-agent-H-rcsum-gate.txt`, `/tmp/misterplex-agent-H-deploy-rcsum1.txt`

**Later path (not R-csum1-era only):** R-csum2 BUILD_OK → lab **`4deaf6cc` PACK_FAIL** (stream24 alias +0x53; H-gate-rcsum2). R-csum-rtl3 128b pack claim **`eb6b8541`/`6ce28d6e`**. **R-csum3 FIT_DEAD_MID** ~12:49 CDT (docker SIGTERM exit=1; no BUILD_OK). **R-csum3b BUILD_OK ~13:00 CDT** (Full Compilation **0e/33w**; wall **~438s** exit 0; log `/tmp/plex_quartus_rcsum3b.log`; freeze **`ce1ef26c`/`e45f98c4` LOCK_OK**; NEW_RBF **`4d6ee356`** full `4d6ee35645c399f5036db220c3d4b07b` size ~3461412). **M-fitmon-rcsum3e BUILD_OK.** Exclusive **FREE**. **Next serial:** promote **`4d6ee356`** → **ONE menu** (H-deploy) → FBAR → hard csum (H-gate) expect **`e8 14 53 1a`** not `e8 53 1a 00`. Lab still **`4deaf6cc` PACK_FAIL** until that deploy. Zero thrash **`4deaf6cc`**. Soft-skip ≠ PASS. **3l2 BLOCKED until hard green.** **BUILD_OK ≠ hard residual PASS.** Living detail: `docs/PHASE_BACKLOG.md`.

**Do not invent hard PASS.** Do **not** thrash-redeploy **`dabdaeb0`** / **`4deaf6cc`**. 3.3l-2 paint stays **BLOCKED** until lab hard green on product RBF.

Tools: `tests/parse_res_csum_status.py` (A-csum-host2); lab `push_frame --status`/`--raw` (A-arm-csum). Full protocol (historical + contingency): `docs/phase3-3l-idct.md` § *Post–R-csum1 sole-deploy + hard-gate protocol*.

## Non-RBF work pool (always fill from here first when RBF busy)
- P3-3l1 residual RCA prep (no full fit unless sole build + authorized)
- P3-WIDE Fix-2 RTL when authorized (colorbars only; design READY)
- P3-DDR product path (misterplexd prefers DDR with new verify)
- Unit tests, package
- P4 scrubber / companion
- P5 soak (no core reload)
- Docs backlog updates
- Commit uncommitted safe deploys scripts

## Stop condition
All PHASE_BACKLOG gates checked + unit green + key HW tests green + package OK.
