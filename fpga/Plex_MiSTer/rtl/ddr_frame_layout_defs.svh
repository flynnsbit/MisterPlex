// DDR frame geometry defines — safe to include outside module bodies.
// Single source of truth for coded frame dimensions used as parameter defaults.
// Mirrored to host/libmisterplex/ddr_frame_layout.hpp — enforced by
// tests/unit/test_rtl_invariants.py.
`ifndef DDR_FRAME_LAYOUT_DEFS_SVH
`define DDR_FRAME_LAYOUT_DEFS_SVH

`define DDR_FRAME_CODED_W  624
`define DDR_FRAME_CODED_H  480

`endif
