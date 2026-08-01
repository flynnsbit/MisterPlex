# Post-scale chrome plane — pointer

**Canonical costed RTL design lives with w-fit:**

`../w-fit-integ/docs/chrome-post-scale-plane-design.md`

(also expected under `docs/` once promoted to main)

**This worker (w-osd-hires) conclusion:** see `docs/osd-240-ceiling-verify.md`.

- Overlay **does not** bypass `present_core` `store_y` (T1).
- User fix is **(b) RTL post-ascal**, not ARM-only F1 paint (T3).
- Do **not** invent a second architecture; implement ARM writer against w-fit’s tap
  (ascal → shadowmask → **plex_chrome** → osd) and M10K budget (banded N≤8 or glyph).
