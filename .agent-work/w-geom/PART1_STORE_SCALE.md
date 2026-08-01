# Part 1 — Does native 480p detail reach the glass?

**Branch tip:** see `git rev-parse --short HEAD`  
**Gate:** `build/test_present_store_scale_math` **true rc=0**

## Product FRAME_W / FRAME_H (quoted, not assumed)

`Plex.sv:262-269` only has **ifndef defaults** 320/240. Product build overrides:

```
fpga/Plex_MiSTer/Plex.qsf:82-84
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=640"
set_global_assignment -name VERILOG_MACRO "FRAME_H=480"
```

`Plex.sv` → `present_core #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H), ...)`

**CODED plane width is separate:**
```
ddr_frame_layout_params.svh: DDR_FRAME_CODED_WIDTH = 624, CODED_HEIGHT = 480
present_core.sv ddr_frame_store: .CODED_W(DDR_FRAME_CODED_WIDTH), .FRAME_W(FRAME_W=640)
```

Do **not** plug 624 into `STORE_X_SCALE` — that is CODED, not present FRAME_W.

## read_hc is hc

```
present_core.sv:181
  wire [9:0] read_hc = hc;
```

Identity. Parent’s horizontal chain is correct on that point.

## Scale math at product 640×480

```
H_DE    = 529
V_STORE = 240
STORE_X_SCALE = (FRAME_W * 39647) / 320 = (640 * 39647) / 320 = 79294
STORE_Y_SCALE = (FRAME_H * 65536) / 240 = (480 * 65536) / 240 = 131072  (= 2.0 in Q16)
```

Parent quoted `STORE_X_SCALE = 624*39647/320 = 77331` — that would be true **if** FRAME_W were 624.  
**Product FRAME_W is 640** → scale **79294**. Shape of claim still holds.

### Vertical (CONFIRMED)

- `py = scandouble ? (vc>>1) : vc`; content window `py < V_STORE` (240).
- `store_y = (py * 131072) >> 16 = py * 2` for py∈[0,239].
- Unique store rows: **240 values, all even: 0,2,…,478**.
- **Odd store rows 1,3,…,479 are never addressed.**
- Gate enumerates this; `OK test_present_store_scale_math`.

### Horizontal (CONFIRMED with corrected W)

- 529 DE columns (`hc < H_DE`) → 529 unique `store_x` in **0..638** of FRAME_W=640.
- ~15% of presented columns never sampled as a unique DE sample (529/640).
- HDMI period-null horizontal is consistent with non-integer 529→output resample (parent measure); not re-proven here.

## Verdict Part 1

**Parent claim stands with one correction (FRAME_W=640 not 624):**

Decoder may deliver 624×480 I420 into the bank, but **present_core only fetches 240 even store rows** and **529 of 640 X samples** before the pixel stream leaves the store path toward ascal/HDMI.

**Native 480-line vertical detail does not reach the display on current RBF.**  
Fix requires **RBF** (`V_STORE` / `STORE_Y_SCALE` / timing), **not** ARM-only.  
No fit authorised until parent opens the slot; this is a locked source+math finding only.

`scandouble`/`forced_scandoubler` only chooses `py=vc` vs `vc>>1`; it does **not** raise `V_STORE` above 240.
