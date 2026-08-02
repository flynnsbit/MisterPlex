# Host instrument ceiling — rk27 bank480 fullbleed (post-H.264)

**File:** `assets/avsync/bank480_fullbleed_vres_av_24_1200s.mp4`  
**Live:** `/library/metadata/27` on `YOUR-PLEX-SERVER:32400`  
**Frames measured (non-flash):** [100, 200, 500, 1000, 2358]  
**Noise floor:** std ≥ **8.0** (`caller_supplied`) on column-mean vertical profile  
**Decode:** `ffmpeg` frame extract → luma (**post-encode**, what ARM feeds after decode)  
**240 model:** `y_out[2k]=y_out[2k+1]=y_in[2k]` (`store_y=py*2` class). Host bound only.

## Zone survival (measured mean over 5 frames)

| zone | designed P | H.264 std | even/odd sep | acf lag | survives H.264? | usable instrument? |
|------|------------|-----------|--------------|---------|-----------------|--------------------|
| `left_1row_alt` | 2 | **126.24** | 252.44 | 2 | **Y** | **Y** |
| `mid_period_2` | 2 | **124.56** | 249.12 | 2 | **Y** | **Y** |
| `mid_period_4` | 4 | **125.73** | 0.01 | 4 | **Y** | **Y** |
| `mid_period_8` | 8 | **126.76** | 0.01 | 8 | **Y** | **Y** |
| `mid_period_16` | 16 | **125.81** | 0.01 | 16 | **Y** | **Y** |
| `chirp_p2_9.5` | 5.8 | **88.19** | 5.38 | 1 | **Y** | **Y** |
| `chirp_p9.5_17` | 13.2 | **89.28** | 0.68 | 1 | **Y** | **Y** |
| `chirp_p17_24.5` | 20.8 | **89.10** | 1.66 | 1 | **Y** | **Y** |
| `chirp_p24.5_32` | 28.2 | **88.25** | 0.26 | 1 | **Y** | **Y** |
| `chirp_full` | — | **88.81** | 1.52 | 1 | **Y** | **Y** |

### P_INSTRUMENT = **2**
- Finest left/mid designed period with std ≥ floor on **decoded** frames.
- Zone: `left_1row_alt` (also `mid_period_2`).
- **Survives H.264:** yes — std≈**126**, even/odd sep≈**252** (not destroyed).
- Why this differs from the old INCONCLUSIVE spectral test: those used **band-limited natural/cast content** or thin features. This zone is a **large-area** pure period-2 field (≈208×392 px). CB @ ~3 Mbps keeps it.

Under host even-cull, period-2 **collapses**: std≈**0.4**, sep≈**0.0**.

## Theory (duty-50 square waves)

| designed P | after even-row cull | discriminates 240 vs 480? |
|------------|---------------------|---------------------------|
| **2** | **solid field** (one phase kept) | **YES** |
| 4, 8, 16 | **same period** (invariant) | **NO** on this pattern family |
| chirp | std almost unchanged | **NO** as primary |

Do **not** expect mid P=4/8/16 to “halve” under `store_y=py*2` with the fixture’s 50% bars.

## Pre-registration table (commit before glass)

| zone | metric | predict if **240-row ceiling** | predict if **480-row (fixed)** | discriminates? |
|------|--------|--------------------------------|--------------------------------|----------------|
| `left_1row_alt` | colmean profile_std AND even_odd_sep (left/mid period-2) | SOLID collapse: std≈0.4 (meas host cull), even_odd_sep≈0.0 | STRIPES: std≈126.2, even_odd_sep≈252.4, acf_lag≈2 | **Y** |
| `mid_period_2` | colmean profile_std AND even_odd_sep (left/mid period-2) | SOLID collapse: std≈0.0 (meas host cull), even_odd_sep≈0.0 | STRIPES: std≈124.6, even_odd_sep≈249.1, acf_lag≈2 | **Y** |
| `mid_period_4` | acf_best_lag / std (designed P=4) | SAME period P=4: std≈125.7, lag≈4 (theory: duty-50 P multiple of 4 invariant under even cull) | std≈125.7, lag≈4 | **N** |
| `mid_period_8` | acf_best_lag / std (designed P=8) | SAME period P=8: std≈126.8, lag≈8 (theory: duty-50 P multiple of 4 invariant under even cull) | std≈126.8, lag≈8 | **N** |
| `mid_period_16` | acf_best_lag / std (designed P=16) | SAME period P=16: std≈125.8, lag≈16 (theory: duty-50 P multiple of 4 invariant under even cull) | std≈125.8, lag≈16 | **N** |
| `chirp_p2_9.5` | profile_std (chirp band) | std≈90.4 (similar) | std≈88.2 | **N** |
| `chirp_p9.5_17` | profile_std (chirp band) | std≈89.0 (similar) | std≈89.3 | **N** |
| `chirp_p17_24.5` | profile_std (chirp band) | std≈89.5 (similar) | std≈89.1 | **N** |
| `chirp_p24.5_32` | profile_std (chirp band) | std≈88.4 (similar) | std≈88.2 | **N** |
| `chirp_full` | profile_std (chirp band) | std≈89.4 (similar) | std≈88.8 | **N** |

## What you should score on glass (rk=27)

1. **Primary:** left third (and/or mid top period-2 band) on a **non-flash** frame  
   - **H240:** solid (std near 0, no even/odd stripes) — matches parent DDR even/odd card  
   - **H480:** strong horizontal stripes, even/odd sep large, vertical period ≈ 2 source rows (after scale, map carefully)
2. **Do not** use mid P=4/8/16 or chirp as ceiling discriminators on this encode.
3. Glass still has ascal + grabber — treat host numbers as **bounds**, not pixel-identical predictions. The **qualitative** solid vs striped call is the load-bearing one.
4. Flash frames (body white every 2 s) are **not** for V-res — skip them.

## Rebuild?
**Not required for P=2 discrimination.** Instrument ceiling is period-2 and it survives.  
Optional later: add a duty pattern that makes P=4 change under cull (e.g. `1010` repeating at 4-row superstructure) if you want a second independent metric — not blocking.

## Artifacts
- `.agent-work/w-asset480/vres_ceiling/instrument_ceiling.json`
- profiles: `prof_*_n100.npy`, `prof240_*_n100.npy`
