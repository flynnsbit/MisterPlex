# Square-SAR legally filter-off color GOP12

Original local procedural artwork under GPL-2.0-or-later; no external media.
This is a **new ordinary x264 encoding**, with explicit square SAR and legally
signaled disabled filtering. It is not PMS, a patched SPS, or a decoder override.

`tests/unit/encode_gop12_color_sar1.py` records the complete encoder command,
source and tool hashes, and checks all VCL NAL payloads against the existing
filter-off color fixture. They must remain byte-identical; only admission
metadata changes. Neither historical fixture nor its expected pictures changes.
The original fixture's absent SAR remains outside the current AU frontend's
explicit-square-SAR admission contract.

No scaling, padding, cropping, or altered ordinary decoder behavior is used.
The source is translated textured color, intended to cover fractional P16
motion, fractional chroma, and borders; actual coverage must be checked using
the independent exported-vector gate, not inferred from the generator.
