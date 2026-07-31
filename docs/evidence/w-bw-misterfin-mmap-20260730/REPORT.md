# w-bw — MiSTerFin mmap bandwidth + PMS scale audit

**Lane:** w-bw  
**Branch:** `w-bw` (worktree `.worktrees/w-bw`)  
**Licence note:** MiSTerFin (`puddingstudio/MiSTerFin` @ `20b71d56…`) is **not** copied into this tree. Their `vo_fbdev.c` claim is cited as **third-party measured text only**. Do not treat their MB/s as ours until parent remeasures.

---

## 1. Product mmap (quoted)

`arm/misterplexd/fpga_spi.cpp` `FpgaSpi::ensureDdrMap`:

```cpp
int flags = O_RDWR | O_CLOEXEC;
if (ddrMemSync_)
    flags |= O_SYNC;
ddrMemFd_ = ::open("/dev/mem", flags);
void* p = mmap(nullptr, kLen, PROT_READ | PROT_WRITE, MAP_SHARED, ddrMemFd_,
               static_cast<off_t>(ddrLayout_.phys_base));
```

- **fd:** `/dev/mem`
- **phys:** `ddrLayout_.phys_base` ← `kDdrFramePhysBase = 0x30000000` (`ddr_frame_layout.hpp`)
- **prot:** `PROT_READ|PROT_WRITE`, **map flags:** `MAP_SHARED` only (no `MAP_LOCKED` etc.)
- **O_SYNC:** default **on** — `fpga_spi.hpp` `ddrMemSync_ = true`

Hot push (`sendDdrFrame`): `memcpy(ddrMap_ + bankOff, …); __sync_synchronize();` then doorbell.

**fb0 path (NOT frame store):** `fb_present.cpp` mmaps `/dev/fb0` at offset 0; phys is `finfo.smem_start` (device-specific), **not** `0x30000000`.

### Cache policy — what is *known* vs *unknown*

| Claim | Status |
|-------|--------|
| Mapping is via `/dev/mem` + default `O_SYNC` | **EVIDENCED** (code quote) |
| Resulting PTE is uncached / device / WC / WT | **UNKNOWN until parent smaps + bench** |
| MiSTerFin “/dev/mem ~60 MB/s, fb WT ~1.5 GB/s” | **THEIR** measurement on **their** mapping — **NOT ours** |
| Archive W-FEED 624×480 O_SYNC **58.074 MiB/s** | Prior device artifact (class ~60); needs fresh parent confirm |

Kernel policy for `/dev/mem` on this DE10 image is **not** asserted here without `VmFlags` from a live map. Bench prints `/proc/self/smaps` for the mapping; look for `VmFlags` token **`dc`** (don't cache) as a **hint**, not a sole verdict. Bandwidth class is the primary measurement.

---

## 2. Bandwidth arithmetic (YUV420p = 1.5·W·H)

| WxH | bytes/frame | @60 MB/s | @1.5 GB/s | @30 fps need | uncached fatal? |
|-----|------------:|---------:|----------:|-------------:|-----------------|
| 320×240 | 115200 | ~1.92 ms | ~0.077 ms | 3.46 MB/s | **No** (≪ budget) |
| 624×480 | 449280 | ~7.49 ms | ~0.30 ms | 13.48 MB/s | **Tight** at 60 fps (~45%); OK at 30 |
| 1280×720 | 1382400 | ~23.0 ms | ~0.92 ms | 41.47 MB/s | **Yes @30fps** (~69% of frame); **fatal @60** |

Parent table used RGB565 153600 for 320×240 — **that is not** the C3 YUV420p product path byte count.

---

## 3. Microbenchmark

**Source:** `tools/ddr_write_bench.cpp`  
**Build:** `make arm-ddr-bench` → `build/arm/ddr_write_bench` (static armhf)  
**Parent recipe:** `docs/evidence/w-bw-misterfin-mmap-20260730/PARENT_RUN.md`  
**Helper (parent only):** `scripts/parent_ddr_cache_probe.sh`

### Pre-registration (printed by binary before timed work)

```
prereg_devmem_mibps_lo=50 prereg_devmem_mibps_hi=70
prereg_writethrough_mibps_lo=800
prereg_source=W-FEED-arm-profile-ORIGINAL_624x480
misterfin_claim_NOT_ours=1
```

**HIT uncached-class:** measured MiBps ∈ [50, 70] on product path.  
**HIT WT-class surprise:** MiBps ≥ 800.  
**MISS:** publish actual vs band.

Host-only smoke (`--host-copy`) exercises printing only — **not** a device result.

---

## 4. Write-through feasibility (static)

- Userspace **cannot** call kernel `memremap(..., MEMREMAP_WT)`.
- Product HDMI path is **PRESENT=fpga** → DDR at `0x30000000`, **not** fb0 scanout of decoded frames.
- fb0 `mmap` is a **different physical region** (`smem_start`). Even if fb0 is WT, that does **not** make the frame-store map WT.
- Achieving WT/WC on `0x30000000` would need a **kernel driver** that maps that CMA/reserved range with the desired `pgprot_*`. **No such driver exists in this tree** (static search / product path is `/dev/mem` only).
- Dropping `O_SYNC` alone: archive showed ~same MiBps as O_SYNC (~58–60) — **not** a 25× win in that artifact. Fresh A/B still required.

---

## 5. PMS / ffmpeg scale (definitive from code)

- Universal URL sets `videoResolution=<weak profile>` (`plex_resolve.cpp` `buildUniversalTranscodeUrl`).
- `ddrFrameGeometryForFpgaPresent` always returns silicon **624×480** for PRESENT=fpga.
- With live `DECODE=320x240` (effective), arm residual scale **always on** (`FFMPEG_SCALE=skip_identity` still builds scale when coded ≠ canvas).
- **Whether PMS honors `videoResolution` and delivers 320-coded bitstream:** **UNKNOWN** without device HTTP/ffmpeg log probe (parent).
- Knobs from code: `FFMPEG_SCALE`, `FFMPEG_SWS_FLAGS`, `FFMPEG_SCALE_ASSUME_MATCH`, `DECODE`, weak profile — see contracts test.

---

## 6. Doorbell ordering

`kickDdrDoorbell`: write **hi (word1)** → `__sync_synchronize()` → write **PLXK magic (word0)** → barrier. Matches “metadata before counter/magic latch” intent. (Correctness audit only.)

## 7. ffmpeg process group

`setpgid` + `kill(-pid, …)` — process group kill **present** in media_player path.

---

## Ranked expected wins (pending parent measure)

1. **If** parent MiBps ≥800 on `/dev/mem` — transport not the 320 ceiling; look elsewhere.  
2. **If** MiBps ~50–70 — uncached-class confirmed; **720p push is transport-bound**; 320 still not explained by push alone (~2 ms). Biggest win would be a **kernel WT/WC map of 0x30000000**, not userspace O_SYNC flip (archive).  
3. **PMS true source geometry** — if server sends large coded + we scale, that is likely larger CPU than push; parent must log ffmpeg GEOM / probe URL.  
4. Doorbell / pgkill — correctness, not thruput.

---

## Gates (worker)

```
python3 tests/unit/test_ddr_bw_contracts.py; echo "true rc=$?"
python3 tests/unit/test_unit_rollcall.py; echo "true rc=$?"
make arm-ddr-bench; echo "true rc=$?"
```
