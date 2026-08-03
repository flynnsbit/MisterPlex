# Test mutation taxonomy

Use mutation audits to prove that a green test is load-bearing. Mutate the code the row claims to protect, run the smallest relevant test, quote the diagnostic, then restore the mutation. A passing run under a real fault is evidence that the check is hollow, not that the product is safe.

## Failure modes

| Mode | What it looks like | How to detect it | MiSTerPlex example |
| --- | --- | --- | --- |
| Vacuous | The check stays green when the protected property is broken. | Run a product-side mutation that breaks the property. For fixture quality, run a fixture-side mutation that makes the fixture degenerate. | DPB/MC row 10 originally passed `chroma_windows=81/81` while U carried V data because the U/V fixtures aliased. |
| Misattributing | The suite goes red, but the first diagnostic names the wrong subsystem or a downstream symptom. | Break the local contract and inspect the exact failure string, not only the exit code. | A DPB read-valid fault surfaced as `decode_stub did not consume multiple VCL pulses` until a local `decode_stub DPB read latency contract` diagnostic was added. |
| Over-tight | The check encodes a current implementation detail as if it were an external contract. | Apply a behavior-preserving refactor/reorder. If it fails, the guard may be a snapshot and must say so. | The DPB/MC fetch-order guard documents current `luma→U→V` order; a legitimate reordered implementation must update the scoreboard rather than treat it as an H.264 contract. |

## Mutation patterns

1. **Fixture degeneracy:** make supposedly distinct fixture values equal. A good fixture guard fails before product checks can draw false confidence.
2. **Product discrimination:** leave fixtures healthy and route the product to the wrong source. The diagnostic should name the broken plane, field, bank, or phase.
3. **Local attribution:** break the local handshake/contract. The first failure should name that local contract, not a later consumer.
4. **Refactor pressure:** rename, reorder, or factor code without changing behavior. A failure here is not necessarily bad, but the check must be documented as a source-shape guard.

## `test_rtl_invariants.py` sample audit

Recent samples showed one real vacuity, one over-tight source-shape guard, and several load-bearing checks:

- **Vacuous, fixed here:** inserting `std::fill(yuv.begin(), yuv.end(), 0);` after `renderIdleYuv420p(...)` left the invariant suite green, even though logo/screensaver idle DDR output would be overwritten with black. The invariant now rejects common full-buffer black overwrites and self-mutates that pattern.
- **Load-bearing:** changing FFmpeg rawvideo width from `ddrGeometry.coded_width` to `ddrGeometry.display_width` fails with `present geometry/stride contract: FFmpeg rawvideo width must be the coded stride width (624) for FPGA-presented 480p`.
- **Load-bearing:** publishing the DDR doorbell magic before the bank/format/seq token fails with `DDR bank handoff contract: doorbell must publish the bank/format/seq token before PLXK magic...`.
- **Over-tight:** renaming `async_fifo`'s registered `wr_full_now` signal without changing behavior fails the literal source guard. That guard protects a real Quartus failure mode, but it is source-shape-sensitive.
