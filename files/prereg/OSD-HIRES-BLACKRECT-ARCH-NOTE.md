# Pre-reg — deploy black-rect only; architecture is write-up not “font fixed”

## Binary
- tip includes `4ed6a096` + feasibility doc commit
- ARM md5: run `md5sum build/arm/misterplexd` after build — was **`14b00f600aa62ac0948e24273e7030a1`** pre-doc (header-only doc may keep md5)

## Score on silicon (viewed pixels)

| ID | PASS | FAIL |
|---|---|---|
| **P1 black-rect** | panel empty-centre mean luma **50–70** grey | ≤35 solid black void |
| **P3 sticky PAUSED** | panel visible at pause+6s | wiped |
| **Font / “hi-res chrome”** | **NOT scored as fixed** — still bank-stretched; see feasibility doc | do not PASS resolution bug on 12×16 alone |

## Architecture (parent confirmed)
User wants output-raster chrome. Feasibility: **needs RTL (c)**. No fit this cycle.

```bash
# A1 live mode
grep -E 'video_mode' /media/fat/MiSTer.ini; echo "true rc=$?"
```
