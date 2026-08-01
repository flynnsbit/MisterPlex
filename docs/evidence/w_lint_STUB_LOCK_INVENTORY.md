# w-lint — stub-locking test inventory

**Date:** 2026-07-31  
**Lane:** w-lint  
**Rule:** inventory only — no behaviour change in this note.  
**Method:** scan `host/libmisterplex/*.hpp` for constant-return / unused-param
functions; cross-ref `tests/unit` CHECK/static_assert/authority_red shape locks.

Parent exemplar: `adelayCancelledByPrefillMs` returns hardcoded 0 with params
commented out; unit test asserts 0.

## Inventory (four)

### 1. `adelayCancelledByPrefillMs` → always 0

| | |
|--|--|
| **Stub** | `host/libmisterplex/audio_delay.hpp:45` |
| **Code** | `inline int adelayCancelledByPrefillMs(int /*confDelayMs*/, int /*prefillTargetMs*/) { return 0; }` |
| **Pins** | `tests/unit/test_audio_delay.cpp:49-51` `CHECK(... == 0)` |
| | `tests/unit/test_audio_delay_authority_red.sh:33` source-shape `return 0` |
| | `tests/unit/test_audio_delay_authority_red.sh:67-68` mutant replaces body → must go RED |
| **Class** | **(a) intentional policy**, stub-shaped. Header comments (lines 5–14, 42–44): HW showed prefill does **not** cancel adelay; model is full content shift. Authority_red **freezes** the `return 0` shape so a “real” cancel implementation fails CI by design. |
| **Gap?** | Not a hidden unfinished feature — it is a killed hypothesis locked as API. If product later needs non-zero cancel, tests + docs must change first. |

### 2. `ddrFrameFormatCode` → always 1

| | |
|--|--|
| **Stub** | `host/libmisterplex/ddr_frame_layout.hpp:91-93` |
| **Code** | `inline uint32_t ddrFrameFormatCode(DdrFrameFormat) { return 1; }` (enum arg unused) |
| **Pins** | `tests/unit/test_frame_store_math.cpp:282` `CHECK(...Yuv420p) == 1` |
| | `tests/unit/test_frame_store_math.cpp:58` doorbell_format == formatCode |
| **Class** | **(a) single-format ABI**. `enum class DdrFrameFormat { Yuv420p }` only. Format argument ignored today. |
| **Gap?** | Mild lock: adding a second format without updating code+tests fails. Not hiding multi-format support that exists elsewhere. |

### 3. `kStubDcPaintY` / stub RGB565 goldens

| | |
|--|--|
| **Stub** | `host/libmisterplex/h264_residual_gold.hpp:103` `kStubDcPaintY = kPred + kDc` // 104 |
| | `:120` `kStubDcPaintRgb565`; `:124-125` `static_assert` 0x6B4D / 104 |
| **Pins** | `tests/unit/test_idct_quant.cpp:129-137` pins stub=104 and rgb565 0x6B4D |
| **Class** | **(a) named diagnostic contrast golden** for `decode_stub` DC paint vs true recon (`kY00=73`). Comment: “NOT true recon”. |
| **Gap?** | Locks stub paint constants so eyes-on / sim dumps stay comparable. Product recon path is pinned separately (`kY00`, `kMean4x4`). Replacing stub paint in RTL without updating goldens is intended RED. |

### 4. `ddrFrameGeometryForFpgaPresent` ignores decode WxH

| | |
|--|--|
| **Stub** | `host/libmisterplex/ddr_frame_layout.hpp:239-241` |
| **Code** | params `/*decodeWidth*/` `/*decodeHeight*/`; body `return productDdrFrameStoreGeometry();` |
| **Pins** | `tests/unit/test_native_480p_ddr_publish.cpp:54-61` 320x240 and 624x480 both → coded 624x480 |
| | `tests/unit/test_frame_store_math.cpp:338` tier loop |
| | `tests/unit/geometry_type_ok.cpp:47` |
| | `tests/unit/test_rtl_invariants.py:1683,1847` must ignore DECODE; identity-DECODE revert is RED |
| **Class** | **(a) intentional anti-shear policy**, not an unfinished scaler. Comments: returning identity-320 is the shear defect (ARM line_bytes vs RTL CODED_W=624). |
| **Gap?** | Multi-canvas product would need deliberate redesign + test rewrite. Not a silent “TODO implement per-tier geometry”. |

## Not counted (looked like stubs, are not)

| Item | Why excluded |
|------|----------------|
| `selectDdrWriteBankLegacyForce(..., int /*last_published*/, ...)` | Legacy RED policy helper; product path is `selectDdrWriteBank`. |
| `audioClockPpm_ = -638` default | Live conf/default asymmetry (parent fleet note); not a unit-pinned placeholder return. |
| Normal `CHECK(f(0)==0)` on real math (`audioClockMs(0)`, etc.) | Zero is correct domain edge, not a frozen unimplemented body. |

## Summary for parent

| # | Stub site | Test pin(s) | (a) intentional / (b) hidden gap |
|---|-----------|-------------|----------------------------------|
| 1 | `audio_delay.hpp:45` | `test_audio_delay.cpp:49-51` + authority_red | **(a)** killed prefill-cancel hypothesis |
| 2 | `ddr_frame_layout.hpp:91-93` | `test_frame_store_math.cpp:282` | **(a)** single format code |
| 3 | `h264_residual_gold.hpp:103-125` | `test_idct_quant.cpp:129-137` | **(a)** named stub contrast golden |
| 4 | `ddr_frame_layout.hpp:239-241` | native_480p + rtl_invariants | **(a)** anti-shear fixed canvas |

No **(b) hidden gap** found in this pass. Strongest process smell remains **#1**: authority_red locks the *source shape* `return 0`, so a future real implementation is a test failure until the red test is rewritten.

## expected_commands / fix/gate-liveness

| Branch | `EXPECTED_COMMANDS` count | Disposition |
|--------|---------------------------|-------------|
| `fix/gate-liveness` (`323c14f1` / tip `478e7dbf`) | **102** (measured) | **CLOSE / do not merge** — superseded by w-lint liveness + identity work; rollcall would collide |
| `w-lint-gate-integrity` (this lane) | **125** protected (= Makefile reality via `test_unit_rollcall.py --write-expected`) | **authoritative for this branch** |
| main | no `EXPECTED_COMMANDS` list in tree at audit time (structure differs / absent) | merge must re-derive with `--write-expected`, never hand-edit a bare integer |

Correct number is **whatever `python3 tests/unit/test_unit_rollcall.py` derives from the Makefile on the integration branch** — today on w-lint that is **125**. Clobbering to 99/101/102/103 is the UNREGISTERED_COMMAND failure mode.
