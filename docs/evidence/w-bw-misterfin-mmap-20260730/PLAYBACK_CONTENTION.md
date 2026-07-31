# w-bw — sustained playback DDR access pattern (freeze angle)

**Lane:** w-bw (memory-system only; no device)  
**Gate:** `python3 tests/unit/test_ddr_playback_contention.py`  
**Context:** RBF `c5382bee` + daemon `e9f79de2` — idle animates; playback ~23.5 fps HDMI freezes (byte-identical captures) while `presents` climbs. w-fit=bank seq, w-geom=swap window; this card = multiport / write-burst.

---

## Pre-register → result

| ID | Prediction | Result |
|----|------------|--------|
| P1 | Default path is O_SYNC memcpy+fence; **no** `cleanDcacheRange` each frame | **HIT** — `ddrMemSync_=true`, `ddrMemFlush_=false`; flush gated on `!sync && flush` (`fpga_spi.cpp`) |
| P2 | `ddr_bus_arbiter` prefers m0 (scanout) over m1 (bitstream) | **HIT** — `m0_rd` first; `grant_m1` only if `!m0_cmd && m1_want_s2` |
| P3 | Even 90% bandwidth steal, Y-line fill stays ≪ 63.8 µs | **HIT** — worst 10.0 µs @624 steal=0.90 |
| P4 | Software banks address-disjoint; DRAM row/bank conflict | **HIT** disjoint; **UNKNOWN** DRAM map |
| P5 | Freeze+identical HDMI+presents++ is weak pure-BW class | **HIT** (classification) — `rd_miss_now` paints **black**, not sticky prior frame |

---

## 1. Write burst pattern @24 fps (product default)

Quoted hot path (`sendDdrFrame`):

```text
memcpy(ddrMap_ + bankOff, payload, len);
__sync_synchronize();
// cleanDcacheRange ONLY if !ddrMemSync_ && ddrMemFlush_
kickDdrDoorbell: dw[1]=hi; barrier; dw[0]=PLXK; barrier;
```

| quantity | 320×240 I420 | 624×480 I420 | source |
|----------|-------------:|-------------:|--------|
| frame_bytes | 115200 | 449280 | layout |
| period @24 fps | 41.667 ms | 41.667 ms | 1000/24 |
| copy-only @58.074 MiB/s | **1.892 ms** | **7.378 ms** | W-FEED class |
| parent push total mean | **4.06 ms** | **8.52 ms** | p480 A/B |
| duty (parent/period) | **9.7%** | **20.4%** | arithmetic |
| avg write MB/s over period | **2.77** | **10.8** | bytes×fps |

**Correction vs task wording:** continuous publishing is **not** `memcpy + cleanDcacheRange` every ~42 ms on product default. It is **memcpy + barrier + doorbell** under **O_SYNC**. Cacheflush is opt-in (`DDR_MEM_FLUSH` with `DDR_MEM_SYNC=0`).

Live log class (parent): `fpga frame_tx ok via DDR … ms=4` matches 240p parent mean — model still valid.

During the other ~80–90% of the frame period, ARM is **not** streaming full-frame writes into the frame-store window (decode/scale may use other DRAM).

---

## 2. Worst-case line fill under write pressure

| coded_w | steal_frac | Y fill_us (lat=12) | vs line 63.8 µs |
|--------:|-----------:|-------------------:|-----------------|
| 320 | 0.00 | 0.578 | OK |
| 320 | 0.90 | 5.778 | OK |
| 624 | 0.00 | 1.000 | OK |
| 624 | 0.90 | **10.000** | OK (6.4× under budget) |

Sequential 2Y+U+V pair @ steal 0.90, w=624: **31.3 µs** still under one line; `LINE_COUNT=8` amortizes further.

Pessimistic residual during HPS write at ~61 MB/s against 720 MB/s f2sdram-class ceiling: **~659 MB/s** left ≫ 27 MB/s (624@60 need).

### Architectural separation (critical)

`ddr_bus_arbiter.sv` header: **two FPGA masters** only — m0 frame store, m1 bitstream ring.  
**ARM `/dev/mem` writes do not appear as arbiter transactions.** Any ARM↔scanout fight is **SDRAM multiport (HPS port vs f2sdram)**, not “memcpy blocks m0 inside the arbiter.”

m1 cannot permanently starve m0: grant_m1 only when `!m0_cmd`.

**Verdict:** no evidence-backed model where sustained 24 fps publish bursts push line fill over the 63.8 µs budget. A fill that “occasionally exceeds the line budget under write pressure” is **not** supported at steal fractions up to 90%.

---

## 3. Bank aliasing / conflict

| item | value |
|------|------:|
| bank0 | `0x30000000` |
| bank1 (480p stride) | `0x30080000` |
| stride | `0x80000` (`kPlex480pYuv420pBankStride`) |
| 320 default align | `0x40000` → bank1 `0x30040000` |
| 480p payload end bank0 | base+449280; gap to bank1 | **0x12500** bytes |

Software banks are **address-disjoint** for payload.  
**UNKNOWN:** whether HPS MPFE maps those phys addresses onto the same DRAM bank/row in a way that causes activate thrash. **Not in tree.**

Check that would settle it (parent / w-fit tooling):

1. Confirm live layout stride from daemon banner / conf geometry (320→0x40000 vs 480→0x80000).  
2. PLXD free_bank_mask: publish always opposite `disp_bank` (same-bank overwrite would be correctness, not multiport theory).  
3. Optional: SoC interconnect / SDRAM efficiency counters if exposed; or A/B artificial same-bank vs opposite-bank stress (daemon flag) while capturing underrun mailbox.

---

## Freeze class (memory-system angle)

Parent symptom: **HDMI byte-identical across seconds** while **presents keep climbing**.

| mechanism | expected visual | match? |
|-----------|-----------------|--------|
| Scanout BW starve / `rd_miss_now` | black / left-miss / glitch | **weak** — RTL miss → RGB 0 |
| Multiport steal during memcpy window | transient glitch ~2–8 ms/frame | **weak** for multi-second identical frames |
| Stuck swap / wrong bank ownership / scanout not taking new bank | stable old frame, counters may still move | **stronger** → w-fit / w-geom |

Memory-system lane conclusion: **do not primary-root-cause this freeze as HPS write vs scanout bandwidth collision.** Hand back to bank-sequencing / swap-window owners with multiport BW cleared under stated models.

---

## Parent verify (no agent device)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-bw
python3 tests/unit/test_ddr_playback_contention.py; echo "true rc=$?"
python3 tests/unit/test_ddr_scanout_budget.py; echo "true rc=$?"
```

Device (optional, parent): confirm `DDR_MEM_SYNC` / `DDR_MEM_FLUSH` on live conf; confirm `ms=` on `frame_tx ok` stays ~4 @240p during freeze; sample `frame_underrun` mailbox before/after freeze — if underrun stays flat while HDMI frozen, BW starve further disfavored.

---

## Erratum (parent ERROR 13, 2026-07-31)

Parent withdrew the “playback freeze” instrument: identical HDMI md5 on mostly-black
RK clips is **expected**, not a freeze. Burned-in frame counter advanced on viewed
pixels. **Memory-system multiport negative remains valid as a model**; it is **not**
attached to a freeze RCA. DDR path now renders correct video on silicon
(`c5382bee` + `e9f79de2`, parent-viewed).
