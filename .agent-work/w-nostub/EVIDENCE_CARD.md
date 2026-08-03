# w-nostub evidence card — fab-nostub / PRODUCT_NO_STUB product default

**Worker:** w-nostub  
**Branch:** w-nostub-reclaim  
**Base:** w-fit-ceiling-fd-min @ fab34b23  
**Worktree:** /home/flynnsbit/Projects/MisterPlex-wt-nostub  
**No device access. No PLL change. No arm/host edits.**

---

## (a) Dark-silicon verdict — CONFIRMED on tip

Under shipping `DDR_FRAME_STORE=1`, `decode_stub` **cannot drive product HDMI pixels**.

### present_core.sv — DDR branch does not wire fs_wr into ddr_frame_store

```
239:`ifdef DDR_FRAME_STORE
240:	assign fs_wr_ready = 1'b1;
...
253:	ddr_frame_store #( ... ) fstore (
... no .wr_en(fs_wr_en) / .swap_banks(fs_swap) ...
304:	);
305:`else
306:	frame_store #( ... ) fstore (
317:		.wr_en(fs_wr_en),
```

Only the legacy `` `else `` consumer maps `.wr_en(fs_wr_en)`. Shipping QSF compiles the DDR branch.

### Plex.sv — host_owns_fs / stub_allow are inert for product DDR present

```
478:`ifdef DDR_FRAME_STORE
479:assign ddr_wr_en = 1'b0;
482:assign ddr_swap = 1'b0;
...
682:reg host_owns_fs;
686:	else if (f1_swap | ddr_swap)
687:		host_owns_fs <= 1'b1;
692:wire stub_allow = ~host_owns_fs & ~ingest_dl & ~ddr_busy & product_recon_ok_w;
```

Even when `stub_allow=1`, stub writes land on `fs_wr_*` ports that `present_core` does **not** connect to `ddr_frame_store`.

### stream_path.sv — PRODUCT_NO_STUB omits the instance

```
312:`ifndef PRODUCT_NO_STUB
313:	decode_stub #(...) stub ( ... .wr_en(fs_wr_en) ... );
367:`else
380:	assign fs_wr_en = 1'b0;
384:	assign stub_busy = 1'b0;
386:`endif
```

**No path remains that can put stub pixels on product HDMI under DDR_FRAME_STORE.** Soft non-dark: fit cost only (until PRODUCT_NO_STUB).

---

## (b) Before/after fit resources + Fmax (hard evidence)

| Metric | Baseline stub-in `8fdf440f` | This nostub `d1b24e0c` | Δ |
|--------|---------------------------:|----------------------:|--:|
| ALM | 23,585 / 41,910 | **14,390 / 41,910 (34%)** | **−9,195** |
| M10K blocks | 465 / 553 (84%) | **197 / 553 (36%)** | **−268** |
| M10K bits | (53% class) | **872,913 / 5,662,720 (15%)** | — |
| DSP | 44 / 112 | **43 / 112 (38%)** | **−1** |
| `decode_stub` fit.rpt rows | many | **0** | elided |
| clk_sys Fmax | 23.46 MHz | **32.04 MHz** (STA L128) | **+8.58** |
| clk_sys setup slack | — | **+1.188 ns** (STA L153) | — |
| clk_sys hold slack | — | **+0.243 ns** (STA L168) | — |
| clk_ddr Fmax | — | 94.56 MHz (L131) | — |

Sources:
- `fpga/Plex_MiSTer/remote_out/fit-nostub-reclaim/Plex.fit.rpt` L80–86
- `.../Plex.sta.rpt` Fmax Summary L124–136; Setup L153; Hold L168
- `rg decode_stub Plex.fit.rpt` → 0 hits

Prediction check (docs Tier A): ALM ~14,368 / M10K ~197 / DSP ~43 — **match within fit noise** (ALM 14,390).

---

## (c) RBF + log

| Field | Value |
|-------|--------|
| RBF md5 | **d1b24e0cd5d480fc9a4242172fd4c2d9** |
| Path | `fpga/Plex_MiSTer/remote_out/fit-nostub-reclaim/Plex.rbf` |
| Slot | remote `fit-nostub-reclaim` via `scripts/build_rbf_remote.sh` |
| Log (worktree) | `.agent-work/w-nostub/plex_quartus_nostub.log` |
| Log (task path) | `/tmp/plex_quartus_nostub.log` (copy if permitted) |
| Wall | 481 s; exit_code=0 |
| Bit-identity | UNVERIFIED (first nostub product-default candidate; `MISTER_REMOTE_ALLOW_UNVERIFIED=1`) |
| Banned md5 | not in {8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0} |

### Source freeze at start-of-fit

```
FREEZE_UTC=2026-08-03T04:17:56Z
HEAD=fab34b23b0dc0ae175f474c2d4d86666e7471447 (+ uncommitted QSF/test/doc at fit)
Plex.qsf        566379a2c65d082655a958fd36165ebd  (PRODUCT_NO_STUB=1 ACTIVE)
Plex.sv         af8686ee885ddb59adcb1a3e324c78e3  (untouched)
stream_path.sv  eeac8f2c728518eca927db70fc44b3b5  (untouched)
present_core.sv 9e6f42ddd1d4a17d65de2edb6777013d  (untouched)
decode_stub.sv  34e03f25a85ae8f53637d9cb4dfe2bd8  (untouched; gated out)
```

DDR present path untouched (present_core.sv / ddr_frame_store.sv md5 unchanged from base).

---

## (d) Commands + true rc

| Command | true rc |
|---------|--------:|
| RED: commented QSF + `test_product_no_stub_dark_silicon.sh` | **1** |
| GREEN: active QSF + same test | **0** |
| `make define-parity` | **0** |
| `make quartus-sv-subset` | **0** |
| `make unit` (after restoring local freeze + avsync symlink) | **2** (see unknown) |
| `tests/unit/test_product_no_stub_dark_silicon.sh` | **0** |
| `scripts/build_rbf_remote.sh fit-nostub-reclaim` | **0** |
| `make post-fit-hierarchy FIT_RPT=.../fit-nostub-reclaim/Plex.fit.rpt` | **0** |
| `make post-fit-timing STA_RPT=.../fit-nostub-reclaim/Plex.sta.rpt` | **0** |

---

## (e) Unknown / not proven

1. **Device HDMI / black-screen:** no deploy, no capture — parent only.  
2. **Full `make unit` green in this worktree:** rc=2 due to missing `tests/fixtures/fabric_decode_fit_hierarchy_8fdf440f.excerpt.rpt` (also absent on main tree). Pre-existing fixture gap; not caused by PRODUCT_NO_STUB. product_no_stub gate itself **rc=0**.  
3. **Bit-identity vs prior nostub `c74c6863`:** not compared this lane (chrome/path-cut base differs). New md5 is intentional product-default nostub candidate.  
4. **PLL bump safety at 25/30 MHz:** owned by w-clock; this lane only provides headroom (Fmax 32.04).

---

## Code changes

1. `fpga/Plex_MiSTer/Plex.qsf` — `PRODUCT_NO_STUB=1` **ACTIVE** (product default).  
2. `tests/unit/test_product_no_stub_dark_silicon.sh` — inverted gate: active=green; commented needs `ALLOW_PRODUCT_STUB_IN=1`; red-before-green for both scaffolding strip and commented QSF.  
3. `docs/phase3-decode.md` — document new default + Fmax headroom note.

## Parent next steps

1. Deploy `d1b24e0c` with ONE menu bounce (`DEPLOY_LOAD=menu`).  
2. FBAR + residual as parent protocol.  
3. Hand Fmax headroom to **w-clock** (do not thrash PLL here).  
4. Spend M10K (~356 free) on OSD hi-res / 720p path cargo.

---

## 720p mandate framing (parent directive)

> "the whole point is to move as much into the fpga so we can do 720p"

### What PRODUCT_NO_STUB removes from the ARM (ms/frame)

| Claim | Value | How known |
|-------|------:|-----------|
| ARM ms/frame removed by this change | **0** | Direct: `decode_stub` never drove product pixels under `DDR_FRAME_STORE` (quoted dark-silicon proof above). ARM still owns H.264 decode, scale/pad, overlay, idle paint, pacing, DDR memcpy. Shipping path unchanged at the ARM boundary. |
| ARM %onecpu removed | **0** | Same reason — no host/arm/ edit; no ioctl/SPI path deleted. |

**Do not claim otherwise.** An offload that leaves ARM doing a reduced job is not this commit; this commit deletes **unreachable FPGA logic** so the next offloads have room.

### What it *enables* for 720p (fabric budget, not ARM ms)

Parent tonight (device, measured): 1080p CB blip decode **32.4 ms/f**; archived 624×480 real decode_null **21.56 ms/f**. Decode cost is content/bitrate-dominated → **720p decode on ARM is plausible inside 41.7 ms/f @24fps if non-decode ARM work is evacuated.**

| Resource | Before (stub-in) | After nostub `d1b24e0c` | 720p relevance |
|----------|----------------:|------------------------:|----------------|
| Free M10K blocks | **88** | **356** (553−197) | **1280 B luma line = exactly 1 M10K** → line buffers/OSD/scaler become fit-feasible |
| Free ALM | ~18.3k | ~27.5k | room for fabric scaler / OSD plane / partial decode |
| clk_sys Fmax | 23.46 MHz | **32.04 MHz** | headroom for w-clock; more cycles/line at 1280 px |
| decode_stub cargo | 9.2k ALM dark | **gone** | no longer starves 720p cargo |

### Design rule this lane obeyed

1. **Remove dead fabric first** so real fabric can take ARM jobs entirely (prefer ARM-out over ARM-cheaper).
2. **Do not raise PLL here** — provide Fmax; w-clock spends it.
3. **Do not touch DDR present path** — black-screen regressions on record.
4. **720p sizing note for follow-on (not implemented this lane):** line buffers, strides, counters should be parameters with `CODED_W=1280` / `CODED_H=720` as first-class targets; one M10K per 720p luma line is the packing unit.

### Follow-on offloads that *do* remove ARM ms (ranked; not this commit)

From inventory (measured where cited):

| Offload | ARM ms/f class removed when complete | Needs this reclaim? |
|---------|--------------------------------------|---------------------|
| Fabric scale/pad (w-geom) | native-480 scale delta ~**2.95 ms/f** measured; 240p upscale **much larger** (CONTESTED until parent A/B/C) | M10K yes |
| Fabric OSD plane (w-osd-hires) | overlay CPU — **NO-DATA ms/f** until parent soak; removes ARM blend into content buffer | M10K yes |
| Fabric decode (phase-3 product) | decode_null **21.56 ms/f** @624×480 measured — full ARM decode out | M10K+ALM yes; stub reclaim was prerequisite |
| DDR DMA / no raw pipe | present **10.41 ms/f wall** measured class | partial |

**Measurement that would settle ARM ms for *this* change alone:** none needed — RTL proves stub cannot present; host path identical.  
**Measurement parent should run next for 720p plan:** real 720p content decode_null + full product pipeline ms/f (parent said in flight).

### Choice made

Elegant-but-ARM-still-in vs ugly-but-ARM-out does **not** apply inside this lane's scope: the stub was already out of the product pixel loop. Choosing **default-on PRODUCT_NO_STUB** is the ARM-out *enabler* (max free M10K/ALM/Fmax for the next lane that actually evacuates ARM), not an ARM participation tweak.
