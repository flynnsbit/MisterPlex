# Route B vs fabric writer sizing (w-mem answer)

**Question (parent):** Under Route B (content DE @ 20 MHz, ascal → 1280×720 glass),
is `FAB_W/FAB_H = 1280×720` correct for the fabric writer, or should it emit
**content-sized** frames with the 720p bank only as capacity?

## Answer

**Product content path does not use the fabric writer.**  
`FAB_W/H = 1280×720` is only the **optional** `FABRIC_DDR_WRITER` fit/demo
plane (QSF default **OFF**). It is **not** the Route B content path.

| Path | Macro | What is written | Bank map |
|------|--------|-----------------|----------|
| **Product (Route B)** | writer **OFF** | Host / future fabric-decode at **source / storage** size (e.g. 624×480, 960×540, true 1280×720) via ARM push or decode | Capacity-selected: legacy usable vs Option-C |
| **Fit/demo writer** | `FABRIC_DDR_WRITER=1` | Internal moving pattern at **FAB_W×FAB_H** | Default Option-C 1280×720 banks |

### Quoted product default (`Plex.sv`)

```
// FABRIC_DDR_WRITER (default OFF): arbiter3 + credit-aware fabric_ddr_attach.
// Fit target = Option-C 720p moving pattern (ARM touches zero pixels).
`ifdef FABRIC_DDR_WRITER
  `else  // DEFAULT product branch under DDR_FRAME_STORE
    FAB_W = DDR_FRAME_720P_CODED_WIDTH   // only compiled when writer ON
    ...
  `else  // product: ddr_bus_arbiter_plxc — no fabric_ddr_attach
```

When writer is **OFF** (product QSF), `fabric_ddr_attach` is not instantiated.
Present banks are filled by **host** `sendDdrFrame` / native push at
**content storage** dims (`makeDdrFabricOwnedPresentPlan` → padded coded_w,
display = source). Glass 720p is **ascal**, not DDR content size.

### When 1280×720 bank **is** required

True **720p content** (direct-play 1280×720 or 1080p→720 storage):  
frame **1 382 400 B**, stride **0x180000**, doorbell **0x3047F000** — map
audit stands. Capacity select already chooses Option-C when
`payload > 520192`.

### What must **not** happen under Route B

Fabric writer (or ARM) must **not** upscale source → 1280×720 into DDR for
present. That duplicates ascal and burns bandwidth. Writer FAB_W=1280 is only
legitimate as:

1. Fit/smoke **pattern** (ARM zero pixels), or  
2. True 720p **content** producer filling Option-C storage 1:1.

### Residual if writer is later productized

If `FABRIC_DDR_WRITER` becomes a real content producer, size it from the same
storage geometry as PLXG (`coded_w/h` from content, not glass 1280), and keep
Option-C bank as **capacity ceiling**, not mandatory fill size.
