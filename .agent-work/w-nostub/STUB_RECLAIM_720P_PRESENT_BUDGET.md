# w-nostub — decode_stub reclaim vs 720p present M10K budget

**Branch tip (this work):** see `git rev-parse HEAD`  
**Main at start of task:** `e953d6b1` (parent tree)  
**Fit source (HELD — no new fit):** `fpga/Plex_MiSTer/output_files/Plex.fit.rpt` (2025-07-30)  
**RBF md5 of that fit tree artifact:** `2890baac70c29425790638d648dc5980`  
**Scope of numbers:** hierarchy that **includes** `decode_stub` painter + `ddr_frame_store` present path.  
**Explicitly excluded:** unbuilt `h264_decode_{top,core,skeleton}` / full fabric decoder (0 in netlist today).

## PREREG → MEASURE (M10K)

| | M10K | ALM |
|---|---:|---:|
| **PREREG** (prior lane estimate) | **268** | ~9200 |
| **MEASURE** fit L7275 `decode_stub:stub` | **268** | **6761.4** |
| **delta** | **0 HIT** | −2438.6 (ALM overestimated) |

Stub breakdown (same fit):
- `dpb_mem` altsyncram: **256 M10K / 2_097_152 bits** (exactly 2^18 bytes — matches 18-bit index span)
- remainder (MC/deblock/etc.): **12 M10K**
- ALUTs **10736**, regs **5064**, DSP **33**

Chip (fit summary L80/L5292): ALM **21082/41910**, M10K **465/553**, bits **2_997_709**.

## Safe removal order (do not skip)

Product glass today (`DDR_FRAME_STORE=1` in `Plex.qsf`):

1. `present_core.sv:532` `assign fs_wr_ready = 1'b1;` — write ready faked  
2. `ddr_frame_store` fstore instance has **no** `.wr_en` / pixel write ports — scanout/doorbell only  
3. `present_core.sv:674` `use_ext = has_frame && !use_frame_store` — glass = DDR has_frame  
4. `Plex.sv:612-615` `ddr_swap = 1'b0` (and ddr_wr_* zero) — SPI frame_store path idle under DDR_FS  
5. Stub still **instanced** at `stream_path.sv:289` and burns **268 M10K**, but cannot update fstore pixels  

**Order:**

| Step | Action | Why |
|---:|---|---|
| 0 | Parent fits **new** RBF from current main (deployed `dfebf2bf` predates `ddr_frame_store`) | Device cannot validate present path on stale G-VID1 |
| 1 | Parent proves multi-frame HDMI + PLXD/doorbell on that RBF | Idle/logo must come from ARM→DDR, not stub paint |
| 2 | Gate `PRODUCT_NO_STUB` or `ifndef` around `stream_path` stub instance under `DDR_FRAME_STORE` | Keep non-DDR_FS / sim paths until retargeted |
| 3 | Drop `decode_stub.sv` from `files.qip` only after unit/sim retarget | Avoid black elaborations |
| 4 | Do **not** claim reclaim from `h264_decode_*` / cavlc-via-skeleton | They are already **0 logic** (absent or pruned) |

**What breaks if stub is deleted before step 1:** unknown on device (stale RBF). Statically: residual/stub_frames diag, any sim that elaborates stub, non-`DDR_FRAME_STORE` builds that still mux stub into `frame_store` wr ports (`present_core` else arm `.wr_en(fs_wr_en)`).

## 720p present linebuf budget

RTL (`ddr_frame_store.sv:19,77-81,166-176`):
- `LINE_COUNT=8` → `LINE_SLOTS=16`
- `Y_LINE_QWORDS = CODED_W/8`, `C_LINE_QWORDS = CODED_W/16`
- per slot: yram + uram + vram `@64b`, WIDTH scaled by geometry

| Geometry | Ideal linebuf bits | Measured / est M10K |
|---|---:|---:|
| 640 (fit) | 163_840 | **96 measured** (all linebufs; packing shallow) |
| 1280 | 327_680 (=2×) | **est 192–197** (width-double or bit-scale) |

### Budget table (conservative est_720 = 197)

| Item | M10K |
|---|---:|
| Device total | 553 |
| Current used (fit w/ stub) | 465 |
| Free now | 88 |
| Stub reclaim | **268** |
| Used after stub remove (same 480p present) | 197 |
| 480p fstore linebufs | 96 |
| 720p fstore linebufs (est) | 192–197 |
| **720p WITHOUT stub reclaim** | used ≈ 465−96+197 = **566** → margin **−13** |
| **720p WITH stub reclaim** | used ≈ 197−96+197 = **298** → margin **+255** |

### Verdict

- **Without** `decode_stub` reclaim: 720p present linebufs are **M10K-negative (~−13)** under conservative packing — **do not fit-blind**.  
- **With** reclaim: **large positive margin (~+255 M10K)** — area is not the blocker.  
- Exact 720p linebuf M10K remains **ESTIMATE until a fit** (marked in tests). ALM headroom after stub remove ≈ 21k−6.8k ≈ 14k used — not tight.

## Present-path bank alias (720p layout)

Constants (`ddr_frame_layout_params.svh`):
- base `0x30180000`, stride `0x180000`, doorbell `0x3047F000`, I420 `1_382_400`
- slack `190_464`; bank0/bank1/doorbell **disjoint**  
- **RED twin:** stride `0x80000` under 720p payload → neighbour overflow (gate fails)

On-chip stub DPB is **not** the product bank path; product banks live in external DDR. Stub’s 18-bit index still **aliases at 480p and 720p** if that painter path is ever trusted — live silent-corruption class for stub-internal DPB only.

## Negative tests (direct rc)

| Test | GREEN | RED |
|---|---|---|
| `test_720p_present_m10k_budget_static.py` | rc=0 | yram `.WIDTH(80)` → rc=1 |
| `test_ddr_720p_bank_no_alias_static.py` | rc=0 | built-in 0x80000 twin |
| `test_decode_stub_removal_prereq_static.py` | rc=0 | fstore gains `.wr_en` |

## Unknowns

- Exact M10K after simultaneous nostub+FRAME_1280 fit — **UNMEASURED** (fit HELD).  
- Whether LINE_COUNT must rise at 720p for refill margin — unknown without timing/BW sim; bandwidth claim is w-clock’s 33.18 MB/s vs ~180 MB/s budget.  
- Live device behaviour of current RTL — blocked on new RBF (stale `dfebf2bf`).
