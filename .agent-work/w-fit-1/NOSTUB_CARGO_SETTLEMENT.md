# Is `decode_stub` product cargo? — settlement (no fit)

**Branch:** `w-fit-ceiling-fd-min` · **No Quartus · no device.**  
Parent decision accepted: **do not pursue PLL bump** next. This answers the cheap question first.

---

## Executive answer

| Question | Answer (evidence-backed) |
|----------|---------------------------|
| Does stub drive product HDMI under `DDR_FRAME_STORE`? | **No** — `fs_wr_*` not connected to `ddr_frame_store` (`present_core.sv` DDR branch). |
| Cost when mapped (shipping-class t7b `8fdf440f`)? | Subtree **9,216.9 ALM / 268 M10K / 1 DSP**; chip totals **23,585 ALM · 465 M10K · 44 DSP**; Fmax sys **23.46 MHz**. |
| Cost when dropped (nostub `c74c6863`)? | Totals **14,354 ALM · 197 M10K · 43 DSP**; Fmax sys **32.59 MHz**; **0** `decode_stub` hierarchy rows. |
| Delta (measured, same reports) | **−9,231 ALM · −268 M10K · −1 DSP · Fmax +9.13 MHz** (chip-level; subtree quote −9,217 ALM matches entity row). |
| Can product **default** drop it? | **Technically yes** for pixels. **Policy today: no** until parent explicitly makes nostub the product default (gate + docs). |
| Why still default-on in netlist (macro off)? | **Intentional research keep** — not an accident. See §2. |
| PLL bump next? | **No** (parent). Nostub-as-default is the better slot *if* anything is fitted — but **c74c already measured nostub**; next slot should not re-burn pure nostub alone without shipping cargo (chrome live path / default flip + glass). |

---

## 1) Cost — quoted fit rows (not impressions)

### t7b / RBF prefix context `8fdf440f` — stub **in**

`fpga/Plex_MiSTer/remote_out/fit-t7b-prog480/Plex.fit.rpt`:

| Metric | Value |
|--------|-------|
| Logic utilization (ALMs) | **23,585 / 41,910 (56%)** |
| Total RAM Blocks (M10K) | **465 / 553** |
| Total DSP Blocks | **44 / 112** |
| Entity `decode_stub:stub` | **9216.9 (1922.1)** ALM subtree (own) |

`Plex.sta.rpt` Fmax Summary: general[0] **23.46 MHz**, general[2] **96.83 MHz**.

### nostub / RBF `c74c6863` — stub **out**

`fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.fit.rpt`:

| Metric | Value |
|--------|-------|
| Logic utilization (ALMs) | **14,354 / 41,910** |
| Total RAM Blocks (M10K) | **197 / 553** |
| Total DSP Blocks | **43 / 112** |
| `rg decode_stub` on fit.rpt | **0 hits** |

`Plex.sta.rpt` Fmax Summary: general[0] **32.59 MHz**, general[2] **97.43 MHz**.

### Pre-registered delta for “flip product default to nostub” (vs t7b stub-in)

| | Predicted | Basis | Miss rule |
|--|-----------|--------|-----------|
| ΔALM | **≈ −9,200 to −9,300** | Measured −9,231 chip; entity −9,216.9 | \|Δ\| < 8k = MISS (stub not fully gone) |
| ΔM10K | **−268** | 465→197 | free blocks must rise ~268 |
| ΔDSP | **−1** | 44→43 | |
| clk_sys Fmax | **≥ 30 MHz** (expect ~32.6 class) | nostub STA 32.59 | ≤25 or regress to 23-class = MISS (stub/limiter back) |
| clk_ddr related setup | **hold ≥0** at 20/90 (no PLL change) | nostub already closed | any negative = HARD_FAIL |
| CDC exposure | **none from this cargo alone** | no PLL change | N/A |

**Do not mix baselines:** parent sometimes quotes c5382bee-class **~21,095 ALM / 74 DSP** — different design; stub presence there is **unknown without that RBF’s hierarchy**.

**Chrome caveat (c74c):** PRODUCT_NO_STUB fit **also** carried `plex_chrome` with `list_we=0` + BOOT_DEMO → chrome RAM **elided** → **P1 unmeasured**. Pure nostub ALM/Fmax still valid; overlay benefit was NO-DATA.

---

## 2) Why default is still stub-in — who guarded, and why

### Commit that introduced scaffolding (default OFF by design)

```
722bd64c docs(rtl): PRODUCT_NO_STUB dark-silicon proof + fabric H.264 inventory
Author: flynnsbit <flynnsbit@gmail.com>
Date:   Sat Aug 1 13:39:30 2026 -0500

Prove decode_stub cannot drive product pixels under DDR_FRAME_STORE ...
Scope PRODUCT_NO_STUB ifdef (default off) to reclaim ~9.2k ALM / 268 M10K
for fabric scaler offload. ... No fit requested.
```

Added: `stream_path.sv` ifdef, QSF **commented** macro, `tests/unit/test_product_no_stub_dark_silicon.sh`, fabric inventory gate, `docs/phase3-decode.md` section.

### Gate rationale (quoted)

`tests/unit/test_product_no_stub_dark_silicon.sh` header:

> Static proof: under DDR_FRAME_STORE, decode_stub cannot drive product pixels;  
> **PRODUCT_NO_STUB scaffolding exists; research path keeps the instance.**

QSF check (after `aa565f0d` ALLOW escape hatch):

> fail "PRODUCT_NO_STUB is ACTIVE in QSF — **product default must stay commented until fit grant** (or set ALLOW_PRODUCT_NO_STUB_ACTIVE=1)"

`ALLOW_PRODUCT_NO_STUB_ACTIVE` added in:

```
aa565f0d feat(fit): PRODUCT_NO_STUB + plex_chrome ONE-fit cargo (pre-reg frozen)
```

So the guard is **w-fit / this lane + parent fit discipline**, not an external mystery:  
**default OFF = keep research netlist + prevent accidental product flip without an exclusive slot.**

### Doc rationale (quoted) — `docs/phase3-decode.md`

> **Do not delete decode RTL.** Research/STREAM leave `PRODUCT_NO_STUB` undefined so `decode_stub` stays in `files.qip` and gated. Verilator TBs reference `stub_busy`/`stub_frames` — **gate, never delete.**

> **Primary value is not throughput ms.** … **Primary value is M10K for user bug #2** (overlay …). Pair PRODUCT_NO_STUB with the OSD plane in **one** exclusive fit — **never alone.**

> Soft non-dark remains: fit cost; `stream_ddr_enable=1` → `ddr_bitstream_reader` poll-asserts `bus_want` (arbiter m1); status/LED/telemetry.

### RTL comment (`stream_path.sv` ~309–311)

> PRODUCT_NO_STUB: product RBF omits decode_stub (dark under DDR_FRAME_STORE —  
> fs_wr_* never reach ddr_frame_store). **Research / STREAM sim builds leave the  
> macro undefined** so decode_stub stays in files.qip and fully gated.

### Load-bearing summary

| Concern | Load-bearing if stub removed from **product** RBF? |
|---------|-----------------------------------------------------|
| Product HDMI pixels | **No** — dark; c74c P2 PASS on glass (parent). |
| Fabric-decode **research** / STREAM Verilator | **Yes** — needs macro **off** in research builds / TBs that elaborate stub. |
| Bit-exact 300/300, 1170/1170, dequant | Tests target stub/hybrid path — **must stay buildable**; product RBF need not map them. |
| Telemetry ABI `stub_busy` bit5 | **Must keep width** — tie `1'b0`, never delete (`stream_path` else already does). |
| Fabric inventory unit vs `8fdf` fixture | Fixture is **stub-in** inventory — nostub default needs fixture/doc policy update, not silent drift. |
| `ddr_bitstream_reader` / arbiter soft tax | **Separate** from stub instance; nostub does not automatically delete reader — check hierarchy if claiming full dark-tax gone. |

**Verdict:** Stub is **display-dead weight in product** and **intentionally retained by default** so research remains one ifdef away and so product flip requires parent-granted fit (ALLOW). It is **not** required for today’s ARM+DDR pixel path.

---

## 3) Dark-silicon proof (source, not only fit)

`present_core.sv` under `DDR_FRAME_STORE` (shipping QSF has macro on):

```systemverilog
`ifdef DDR_FRAME_STORE
	assign fs_wr_ready = 1'b1;
	ddr_frame_store #( ... ) fstore (
		// rd_*, doorbell, DDRAM_* — no wr_en
	);
`else
	frame_store #( ... ) fstore (
		.wr_en(fs_wr_en), ...
	);
`endif
```

Stub still drives `fs_wr_*` in `stream_path` when mapped; those ports **have no consumer** on the DDR compile. Gate `test_product_no_stub_dark_silicon.sh` enforces this statically (red-before-green strip test).

---

## 4) cy/MB **2,965.8** — worst case or mean? (parent scepticism)

### Provenance (quoted)

Commit `f5cafa7e` message:

> Measured (**paint_per_mb f0**): 4036.9 → **2965.8** clip1 (−1071);  
> clip2 2812.3. PRE 2700..3100 HIT; hard ≤2667 MISS ~1.11×.  
> Bit-exact 300/300 + 1170/1170; …

Definition from earlier evidence docs (`docs/evidence/cycles_per_mb_breakdown_788aa5f.txt`):

> `paint_per_mb = paint_cycles / mb_count`

### What that **is**

- **One frame type:** IDR / frame **0** paint window (wr_reset→fs_swap class), **not** a long multi-frame mean.  
- **Average over the frame’s MBs:** total paint cycles ÷ **300** (320×240) — so it is a **per-MB mean inside the expensive frame**, not max-over-MB.  
- Clip2 f0 was **2812.3** (easier than clip1).  
- At `788aa5f`, P-frames showed `paint_per_mb=256` with `parse_per_mb≈1484` — **different stage**, not folded into 2965.8.

### What that **is not**

- **Not** max-over-macroblock within the IDR.  
- **Not** full product path (MC + deblock + DDR writeback + present arb) — paint window composition includes I_RECON + DPB_FILL + diagnostic components (see `docs/throughput-budget-vs-4037.md`).  
- **Not** a 12-frame average (those averages **hide** IDR cost — exactly the long-window trap parent retracted on bitrate).

### Implication for “12% margin at 25 MHz”

| Claim | Status |
|-------|--------|
| 3334 / 2965.8 ≈ 12% vs **frame0 mean paint** | Arithmetic OK **for that metric only** |
| 2965.8 is hard worst MB | **Unknown — not established** |
| Full continuous decode cy/MB ≤ 2965.8 | **Unknown — here is the check:** instrument max `paint_cycles` per MB and full-frame `summary.cycles` including P parse+MC+deblock on tip; publish p50/p99/max, not only f0 mean |
| 25 MHz “closes throughput gate” for product | **Does not apply to product pixels** (ARM decode); research-only |

**Publish miss vs prior lane language:** treating 2965.8 as a **binding worst-case ceiling** was **over-strong**. It is a **specified-frame mean paint_per_mb** after RMW A+B.

---

## 5) What must be re-proven if product default becomes nostub

### Static / sim (agent, before any fit)

| Gate | Need |
|------|------|
| `make define-parity` | rc=0 |
| `make quartus-sv-subset` | rc=0 |
| `make unit` | rc=0 — **includes** updating or ALLOW-policy if QSF default flips on |
| `test_product_no_stub_dark_silicon.sh` | Must pass with **new** default (active + ALLOW, or gate rewritten to expect active) |
| freeze / shear / colour / sustained | rc=0, TB executed (already green on tip RTL) |
| Bit-exact research path | **300/300, 1170/1170, dequant miss=0** with macro **off** in STREAM/TB builds — product QSF nostub must not break research worktrees |
| fabric_decode_inventory | Update fixture **or** dual-profile (stub-in research vs nostub product) — do not leave gate green on stale 8fdf stub inventory while shipping nostub |
| telem_flags ABI | stub_busy still bit5, tied 0 |
| chrome elision | If chrome ships: guard must go **GREEN** on **new** fit report (still RED on c74c) |

### Parent-only (device)

| Check | Note |
|-------|------|
| Glass P2 playback | Already PASS on c74c nostub — reconfirm if sources drift |
| P1 overlay | **Unmeasured** on c74c; needs live `list_we` + non-elided RAM |
| Freeze-class on silicon | Parent scores; agent does not assert |

### Explicitly **not** required for nostub-only default flip

- PLL change  
- New SDC false_path  
- Path cut of `lat_p_mb_addr % mb_width` (that path **leaves with the stub**)

---

## 6) Recommendation (no fit requested)

1. **Treat stub as product cargo: YES for ALM/M10K/Fmax; NO for pixels.**  
2. **Do not silently flip default** — the gate/docs made default-off a **fit-grant** control. Flipping default **is** a product decision + gate change, not a drive-by.  
3. **c74c already paid for nostub measurement.** Burning another exclusive slot **only** to re-fit nostub without shipping chrome-live / default-policy change is low value.  
4. **Next high-value exclusive (when parent wants):**  
   - **Option A:** Make `PRODUCT_NO_STUB=1` the **documented product default** + fix unit gate/inventory fixtures + parent redeploy nostub as daily driver (glass).  
   - **Option B:** Pair nostub with **non-elided chrome** (`list_we` live, elision guard GREEN on new report) — original intent of `722bd64c` / OSD enabler docs.  
5. **Do not** use nostub Fmax 32.59 as “current shipping headroom” until default and device match.  
6. **Withdraw** any throughput story that treats 2965.8 as proven worst-case without max-over-MB evidence.

### Pre-reg table for Option A (nostub product default, 20 MHz PLL unchanged)

| Metric | Baseline stub-in (8fdf/t7b) | Expect after | HIT if |
|--------|----------------------------|--------------|--------|
| ALM | 23,585 | ~14,350 ±400 | ≤15,500 |
| M10K | 465 | ~197 ±10 | ≤220 |
| DSP | 44 | 43 ±1 | ≤45 |
| clk_sys Fmax | 23.46 | ≥30 (typ 32.6) | ≥28 |
| clk_ddr Fmax | 96.83 | ~97 class | setup/hold all ≥0 |
| decode_stub rows | many | **0** | 0 |
| freeze/shear sim | green | green | rc=0 |
| Product pixels | ARM+DDR | ARM+DDR | parent glass |

**CDC:** no change if PLL stays 20/90 — **no new related-edge risk** from nostub alone.

---

## 7) Gates this session (context)

Already captured on tip after QSF restore + chrome lint fix (`73c99c79`): define-parity / qsv / freeze / shear / unit all **true rc=0**. No additional gate run required for this **document-only** settlement unless parent wants a fresh stamp.
