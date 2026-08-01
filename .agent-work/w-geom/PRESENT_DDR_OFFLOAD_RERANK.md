# Present/DDR offload — re-ranked (post parent correction)

**Branch:** `w-avsync-hdmi-measure` · static/sim only · no Quartus  
**Supersedes priority framing in** `FABRIC_CONTENT_WINDOW_DESIGN.md` §0–5  
**Does not withdraw** content-window design — **re-ranks why and what is primary**

---

## 0. Withdrawn / do not use

| Withdrawn | Why |
|-----------|-----|
| “Scaler ~50 of 69 %onecpu vs ~6 decode” | Cumulative vs marginal / occupancy vs wall — retracted by parent |
| Sizing from `fpga/Plex_MiSTer/output_files/Plex.fit.*` | **Wrong RBF** (see §1) |
| “M10K is the binding constraint” (unquantified) | 84% blocks / 53% bits = shallow packing; free **bits** exist; not proven wall |

---

## 1. Fit artifact for deployed RBF `8fdf440f`

| Path | RBF md5 | Role |
|------|---------|------|
| **`/home/flynnsbit/mplex-builds/fit-t7b-prog480/Plex_MiSTer/output_files/`** | **`8fdf440fbf4b8b51f5f98df559cc20e5`** | **DEPLOYED — size from here** |
| `fpga/Plex_MiSTer/output_files/` | `2890baac70c29425790638d648dc5980` | **Other** fit (2026-07-30) — **do not size against** |

**From `…/fit-t7b-prog480/…/Plex.fit.summary` (paired with 8fdf440f):**

| Resource | Value | Artifact |
|----------|------:|----------|
| ALM | **23,585 / 41,910 (56%)** | fit.summary |
| M10K blocks | **465 / 553 (84%)** | fit.summary |
| Block memory **bits** | **2,997,709 / 5,662,720 (53%)** | fit.summary |
| Impl. bits (fit.rpt) | **4,761,600 (84%)** | fit.rpt ~4337 |
| DSP | **44 / 112 (39%)** | fit.summary |
| Free blocks | **88** | 553−465 |
| Free raw bits | **~2.66 Mbit** | 5.66−3.00 Mbit |

Repo `output_files` reports ALM **21,252** / DSP **74** — **different bitstream**. Parent’s “nearly double DSP” is that other fit, not 8fdf440f.

**M10K reading (corrected):** design uses many shallow blocks (84% blocks for 53% bits). Free **88 blocks** can vanish under more small RAMs; free **~2.66 Mbit** is reachable if new stores are **deep/wide consolidated**. Neither is “the” hard wall without a specific design. DSP **44/112** on 8fdf is not tight.

**decode_stub reclaim:** write port unconnected under shipping `DDR_FRAME_STORE` (`present_core` `wr_en` only in `` `else ``). ~9.2k ALM / ~268 M10K reclaimable — **firmer** than latch argument. Coordinate one fit with w-fit-1.

---

## 2. Justification — wall ms/f (only comparable table)

Source: `docs/evidence/p480/p720-bus-and-bitrate-margin.md:100-116`  
Sample: **624×480**, 1412 kb/s CB, 1800 frames.

| bucket | wall ms/f |
|--------|----------:|
| decode_null | 21.562 |
| **product present/DDR** | **10.411** |
| +pipe delta | 5.263 |
| +scale delta | **2.954** |
| **sum** | **40.190** |

| budget | full-stack margin |
|--------|------------------:|
| 24 fps (41.667) | **+1.476 ms** |
| 25 fps (40.000) | **−0.190 ms** |
| 30 fps (33.333) | **−6.857 ms** |

**ARM is out of budget at 480p25 and badly out at 30.** That justifies offload — not the withdrawn %onecpu split.

**Rank by measured wall:**

| Rank | Lever | ms/f in table | Notes |
|-----:|-------|--------------:|-------|
| **1** | **Present/DDR path** | **10.411** | **3.5× scaler** |
| 2 | Pipe | 5.263 | demux/read path — other lane |
| 3 | Scale | 2.954 | still real; secondary |
| — | decode_null | 21.562 | cumulative baseline; not “decode only” |

---

## 3. PRIMARY (a) — cut present/DDR cost

### 3.1 Source path today (`fpga_spi.cpp` sendDdrFrame)

```
prep_wait (PLXD bank-select poll + optional kDdrBankReuseMinUs=40000 same-bank floor)
→ memcpy(ddrMap_ + bankOff, payload, len)     // len = 449280 both tiers
→ cleanDcacheRange(...)                         // unless ddrMemSync_
→ kick doorbell / SPI
→ post_wait
```

Instrumented fields: `copy_us`, `flush_us`, `prep_wait_us`, `doorbell_us`, `bank_reuse_wait_us`, `total_us` (FEED 10.411 is the **aggregate** present bucket — not copy alone).

**Confirmed:** both tiers push **449280** (`DDR_FRAME_YUV420P_BYTES`) because store is synthesis-fixed 624×480.

### 3.2 Lever A1 — fewer bytes (content window) — **owned, highest leverage on copy/flush**

| | Today | After native content window |
|--|------:|----------------------------:|
| Bytes/frame | 449280 | **115200** (320×240 I420) |
| Ratio | 1.0 | **0.256** (÷3.9) |

**Pre-register ms/f (copy+flush only, linear in bytes — honest bound):**

Assume copy+flush are ~proportional to `len` (memcpy + D-cache clean).  
Unknown fraction of 10.411 is copy+flush vs prep/PLXD/doorbell.

| Assumption | copy+flush today | after ÷3.9 | **saved ms/f** |
|------------|-----------------:|----------:|---------------:|
| copy+flush = 30% of 10.411 | 3.12 | 0.80 | **~2.3** |
| copy+flush = 50% of 10.411 | 5.21 | 1.34 | **~3.9** |
| copy+flush = 70% of 10.411 | 7.29 | 1.87 | **~5.4** |

**Pre-register for planning:** **−2.5 … −5.5 ms/f** on present bucket from bytes alone at **320 tier**.  
At **native 480** content=624×480: **0 ms/f** from this lever (already full bank).

**Must measure on device after land:** `PRESENT_PROFILE` / `copy_us`+`flush_us` histograms — do not claim a point estimate without that.

**RTL:** same content-window + runtime `y_stride` as prior design (`FABRIC_CONTENT_WINDOW_DESIGN.md`).  
**Scaler side-effect:** NN stretch of content→DE falls out — secondary prize (§4).

### 3.3 Lever A2 — no ARM memcpy into bank (scope + cost)

| Option | ARM still writes frame bytes? | Saves | Cost / risk |
|--------|------------------------------:|-------|-------------|
| **A2-0 status quo** | Yes → bank | — | baseline |
| **A2-1 Fabric DMA bank←ring** | Yes → **ring** (same size) | ARM still pays write+clean on ring; FPGA copies ring→bank | **New RTL** (bitstream ring pattern exists: `ddr_bitstream_reader.sv`); **does not remove** ARM byte cost; adds FPGA DDR read bandwidth contention with scanout |
| **A2-2 Decode/raw into `ddrMap_`** (zero-copy publish) | **Once** into bank (no second memcpy) | Eliminates **daemon** memcpy if ffmpeg/pipe already landed elsewhere — need custom buffer pool pointing at `ddrMap_` | **ARM-only** major; pipe reader complexity; FORCE_SCALE/identity still apply; **no new M10K** |
| **A2-3 FPGA decode to bank** | Bitstream only | Maximum offload | Decode RTL — long pole, not this slice |

**Honest finding:**  
A2-1 (FPGA DMA from ring) **is not the prize** for ARM wall ms — ARM still touches every byte. Pattern is proven for **bitstream**, wrong primary for **present**.  

**Real “no second copy” path is A2-2:** publish buffer **is** the mmap bank (or splice pipe → bank). Scope as **ARM follow-on** after A1; estimated save = remaining `copy_us` after A1 (not double-count ÷3.9).

**Pre-register A2-2 (after A1, 320 tier):** additional **−0.5 … −2 ms/f** if a second full-frame memcpy still exists in the daemon path beyond sendDdrFrame (pipe assemble → publish). **Unknown without call-graph count** — gate: count `memcpy` of frame-sized buffers per frame in media_player publish path before claiming.

### 3.4 Other present costs (do not ignore)

| Mechanism | Source | Effect on 10.411 |
|-----------|--------|------------------|
| `kDdrBankReuseMinUs = 40000` | fpga_spi.cpp | Same-bank floor 40 ms; ping-pong should avoid; if broken → dominates |
| PLXD bank-select poll | sendDdrFrame prep | Can add ms under stall |
| Doorbell / first-kick usleep(3000) | first frame only | Amortized small |

**Pre-register:** audit prep_wait vs copy on device **before** building DMA. If prep_wait ≫ copy, **bytes lever still helps** but **mailbox/wait RTL/ARM** may outrank A2.

---

## 4. SECONDARY (b) — fabric scaler (~2.954 ms/f)

- Still worth doing; **falls out of A1 content window** (NN in `present_core`).  
- **ascal alone: NO** (prior note stands): scales full core DE→HDMI; won’t enlarge a 320 island inside 480 DE.  
- Prize **2.954 ms/f** only when ARM stops scale (320 path). Native 480 already `arm_rescale=0` → **0** from this lever.  
- **Do not** build in-core polyphase; ascal keeps HDMI.

**Pre-register saved ms/f:** **~2.5 … 3.0** at 320 tier if FEED scale delta transfers; **0** at identity 480.

---

## 5. Combined pre-register (320 tier, full stack)

| Lever | ms/f saved (pre-reg band) | Depends on |
|-------|--------------------------:|------------|
| A1 fewer bytes (÷3.9 copy/flush) | **2.5 – 5.5** | content window RTL + ARM native publish |
| B drop ARM scale | **2.5 – 3.0** | same window + ARM vf off |
| A2-2 zero-copy publish | **0.5 – 2.0** (conditional) | ARM allocator; after A1 |
| A2-1 fabric DMA ring | **~0 ARM** (not primary) | — |
| **Stack toward 25/30 fps** | **~5 – 10** if A1+B land | still need measure |

FEED full-stack at 25 fps is **−0.190 ms** under.  
**A1+B pre-reg ~5–8 ms** would open **25 fps** and approach **30** only if decode_null doesn’t grow — **30 still needs decode work** (other lanes).

**480 native tier:** A1/B ≈ 0 on bytes/scale; present still 10.411 class until A2-2 / wait-path / decode.

---

## 6. Resource pre-register (V1 A1+B only) — artifact `8fdf440f` fit

| Resource | Δ pre-reg | Fits? |
|----------|----------:|-------|
| ALM | +80 … +250 | yes (18k free ALM) |
| M10K blocks | +0 … +2 | yes vs 88 free blocks; prefer no new shallow RAMs |
| M10K bits | ~0 | uses free bit pool trivially |
| DSP | +0 … +2 | yes (68 free on 8fdf) |
| Timing | hold 20 MHz video; STA hard gate post-fit | unknown Fmax delta |

**Does not require stub reclaim.** Stub reclaim remains valuable for decode, not for this V1.

---

## 7. `DDR_YUV_FORCE_SCALE`

**Unchanged policy intent:** pin pipe producer bytes == reader bytes.  
After A1: reader = `content_w×content_h×3/2` (115200 or 449280).  
FORCE_SCALE=1 still forces match when delivery ≠ window. **Do not remove conf key.**

---

## 8. ~475 V-resample

- 320 path: **subsumed** when B drops ARM scale.  
- 480 path: already ARM crop_pad fix (`150718b4` lineage).  
No second fix.

---

## 9. Work order (this lane)

1. **Done:** design + math gate content window (`dce73e89`, `test_fabric_content_window_math` rc=0).  
2. **Next (RTL, w-fit-1 fit slot):** content_w/h/stride + present_core SX/SY from regs; default legacy.  
3. **ARM with same RBF:** native publish bytes; FORCE_SCALE retarget; scale off when window matches.  
4. **Measure:** `copy_us`/`flush_us`/`prep_wait_us` vs FEED 10.411 split — publish artifact pair.  
5. **Then** decide A2-2 zero-copy vs wait-path work from measured split.  
6. **Do not** prioritize fabric frame DMA (A2-1) unless measure shows ARM write is cheap and FPGA copy helps elsewhere.

---

## 10. One-line priority for parent

**Primary: cut 10.411 ms/f present/DDR via ÷3.9 bytes (content window) + later zero-copy publish; secondary: 2.954 ms/f scaler falls out of the same window; ascal is HDMI-only; size only against `mplex-builds/fit-t7b-prog480` (RBF 8fdf440f).**
