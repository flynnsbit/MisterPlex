# PARENT CARD — daemon_media_ledger (close the free ledger)

Branch: `w-instr-provenance`
Tool: `tools/daemon_media_ledger.py`
Fixture: `files/device-evidence/p480b_041855/daemon_media.txt` (your `/tmp/p480b_041855/`)

## What was broken
Pixel-blind soak printed `presents=null residual=NO-DATA` because the daemon
emits two differently-timed `media:` lines:

```
media: frames=699 vfps=23.7 ... drops=4 ...          # 1 Hz, no presents
media: fpga frame_tx ok via DDR presents=672 frames=676 ms=4
```

`frames` disagree (699 vs 676) — sampling lag, not two truths.

## What the tool does
1. **Prefer atomic** 1 Hz lines with frames+presents+drops (+residual) → `src=measured`
2. **Else reconstruct** each DDR `presents=` snapshot paired with nearest stats `drops=` → `src=reconstructed` (never measured)
3. `residual = frames - presents - drops`; unexplained non-zero → **LEDGER_RESIDUAL rc=2** (loud)
4. Session restart / epoch change / EXIT / frames_reset → **SESSION_INVALID rc=79** (w-avsync convention)
5. Prints **cross_line_naive** residual separately and warns it confounds lag with loss

## Honest daemon fix (you deploy)
Tip `media_player.cpp` already has atomic 1 Hz via `frameLedgerTelemetryFragment`.
Your fixture binary does **not** emit it. Minimal additive patch on the DDR heartbeat
(~`presentCount_ % 48 == 0`):

```cpp
log("media: fpga frame_tx ok via DDR"
    " presents=" + std::to_string(presentCount_) +
    " frames=" + std::to_string(frameIndex) +
    " drops=" + std::to_string(droppedFrames_.load()) +
    " publish_misses=" + std::to_string(publishMisses_.load()) +
    " residual=" + std::to_string(
          frameLedgerResidual(frameIndex, presentCount_, droppedFrames_.load())) +
    " residual_eq=frames-presents-drops tag=measured"
    " ms=" + std::to_string((int)fpga_.lastPushMs()));
```

After deploy, this tool scores residual as **measured**.

## Commands (direct rc, never pipe)

```bash
python3 tools/daemon_media_ledger.py --self-test
echo "true rc=$?"   # expect 0

python3 tools/daemon_media_ledger.py files/device-evidence/p480b_041855/daemon_media.txt
echo "true rc=$?"   # expect 0 LEDGER_OK residual=0 reconstructed
```

## RBG (this lane, true rc direct)

| Input | VERDICT | rc | notes |
|-------|---------|----|-------|
| `--self-test` | SELF_TEST_OK | **0** | atomic OK/RED, split OK/RED, rc=79, rc=77 |
| `p480b_041855/daemon_media.txt` | **LEDGER_OK** | **0** | presents=672 residual=0 **reconstructed**; series 14× residual=0 |
| synth residual gap | LEDGER_RESIDUAL | **2** | residual=20 loud |
| synth EXIT respawn | SESSION_INVALID | **79** | aligns w-avsync |

### p480b headline (measured artifact)
```
presents=672 src=measured_ddr_line
drops=4 src=reconstructed_nearest_stats_line
residual=0 src=reconstructed
cross_line_naive residual_cross=23 frames_skew=23  ← sampling lag, NOT loss
VERDICT=LEDGER_OK rc=0
```

**Interpretation for S2:** on this capture the free ledger **closes** (every
non-present is the 4 pacer drops). The ~16-frame soak gap vs wall×fps is a
**supply/rate** question, not `frames-presents-drops` residual. Quoting
`drops=4` as "full loss" remains wrong; quoting `presents=null` is fixed.

## Exit ladder
| rc | meaning |
|----|---------|
| 0 | LEDGER_OK |
| 2 | LEDGER_RESIDUAL (unexplained) |
| 79 | SESSION_INVALID (w-avsync) |
| 77 | NO-DATA (never pass) |
| 1 | usage |

Rule 0: no device touched. Archives only.
