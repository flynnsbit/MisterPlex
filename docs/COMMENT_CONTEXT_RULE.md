# Comment context + defect-retraction rules

**Binding for every agent and every gate that audits comments or retracts findings.**

## Two failure modes (both real)

| Mode | What happened | Wrong action |
|------|----------------|--------------|
| **A — Flag fixed note as live** | Current file has `HISTORICAL FAULT` / `FIXED` / `DO NOT REINTRODUCE` documenting a *past* pack bug | Grep one line, report "stale comment" as if product still lies |
| **B — Dismiss live defect as imaginary** | Parent read the *fixed* file, saw correct HISTORICAL text, retracted T5 | Ordered agents to treat the finding as bogus and undo the fix — which would **reintroduce** the present-tense lie |

**T5 was a real defect.** Pre-fix text (git):

```
$ git show 100b797d^:host/libmisterplex/ddr_bank_release_select.hpp | sed -n 13p
// frames_done field is actually bank_vsync_count so liveness never detects a
```

**Fix:** `100b797d` (w-geom) rewrote that into a `HISTORICAL FAULT` block. Product RTL packs real swap counters; do not reintroduce vsync-as-frames_done.

Parent ERROR 20 ("I manufactured the defect") is **itself retracted**. Running parent error tally standing: 18, 19, 21, 22 — not 20 as a false finding.

## Required procedure — comment audits

1. **Never flag a comment from a single line or bare `file:line` alone.**
2. Load the **entire contiguous comment block**.
3. If the block contains any of these markers (case-insensitive), treat the body as
   **documentation of past fault + current correct behaviour**, not a present-tense
   product claim:
   - `HISTORICAL` / `HISTORICAL FAULT`
   - `FIXED` / `FIXED in product`
   - `DO NOT REINTRODUCE`
   - `was a prior` / `older pack` / `no longer`
4. Only after (2)–(3) may you assert "stale" or "wrong comment". Prefer citing the
   **current** contract in code (`input_mailbox.hpp`, RTL pack site).
5. **Never strip or "simplify away" a HISTORICAL FAULT block** to "clean comments."
   That reintroduces mode B.

## Required procedure — before retracting a defect report

1. Check **`git log` / `git show`** for the file — **not only the working tree**.
2. A completed fix in history is **evidence the defect existed**, not that the
   report was imaginary.
3. Discriminator:
   - Working tree has HISTORICAL + `git show FIX^` has present-tense lie → **fixed real defect; keep fix; do not retract.**
   - Working tree has HISTORICAL and history never had the lie → documentation only; do not flag as live.
   - Working tree still has present-tense lie → **live defect; fix into HISTORICAL (or delete the false claim).**

## Gate encoding

`tests/unit/test_comment_context_guard.py`:

- Fails if `ddr_bank_release_select.hpp` loses `HISTORICAL FAULT` or
  `Do not reintroduce` / `NOT bank_vsync_count`.
- Fails if present-tense `frames_done … is actually bank_vsync_count` appears
  **outside** a HISTORICAL-marked block.
- Self-test: HISTORICAL block not flagged; bare present-tense flagged.
- RBG: reintroducing pre-`100b797d` wording → **rc=1**; restore → **rc=0**.
