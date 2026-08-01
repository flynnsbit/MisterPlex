# Three-line pre-retraction check (mandatory)

**Before retracting any defect report, answer all three in writing.**

## 1. Name both artifacts

| | |
|--|--|
| **Finding artifact** | What the original report measured or quoted (device md5, log line, `git show COMMIT:path`, HDMI frame, …) |
| **Retraction evidence artifact** | What you are using to claim the finding was wrong |

If these **differ** (e.g. finding = device RBF `c5382bee`, retraction = tip `ddr_frame_store.sv` after a source fix), the retraction is **INVALID** unless you explicitly bridge them:

- source fix commit SHA, **and**
- whether that fix is **live on the artifact the finding named**

A completed fix in the working tree looks identical to “never broken.” That is not a retraction.

## 2. Device claims need device evidence

A claim about **device behaviour** (freeze, skip rate, live PLXD pack, daily-driver core) may only be retracted on **device-derived** evidence (md5 of `/media/fat/.../Plex.rbf`, live log, capture). Tip source alone cannot retract a silicon measurement.

## 3. “Fixed” in a comment is a claim, not evidence

Text under `HISTORICAL FAULT` / `FIXED` / `DO NOT REINTRODUCE` must cite:

1. the **commit** that changed source, **and**
2. the **artifact where the fix is live**, or the explicit phrase  
   **`fixed in source, NOT YET FITTED`** (or `NOT YET DEPLOYED`).

Example (correct):

> HISTORICAL FAULT on c5382bee silicon (still shipping). Tip packs `frames_done_d2`
> since `<sha>`; **fixed in source, NOT YET FITTED** to daily-driver RBF.

Example (invalid retraction):

> Tip comment says FIXED → defect was imaginary.

## Worked case (ERROR 20 / T5 / c5382bee)

| Finding | `git show 100b797d^:...` present-tense `frames_done is actually bank_vsync_count`; device c5382bee packs vsync |
| Fix source | `100b797d` + tip RTL `frames_done_d2` |
| Daily driver | **still c5382bee** → fault **LIVE on device** until new RBF |
| Invalid move | Read tip HISTORICAL block only → order revert of the fix |

## Related

- `docs/COMMENT_CONTEXT_RULE.md` — enclosing block + git history
- `host/libmisterplex/plxd_liveness.hpp` — runtime defence when label≠derivation on silicon
