# Display output resolution

MiSTerPlex has two separate resolutions:

- **Output resolution** — the HDMI/VGA signal MiSTer sends to your display. This is controlled by
  MiSTer's scaler (`ascal`) and `/media/fat/MiSTer.ini`.
- **Content/native resolution** — the picture MiSTerPlex decodes and presents internally. Today that
  remains **320×240** by default.

Raising the output mode gives a higher-resolution **signal**, not a higher-resolution decoded picture.
For example, `video_mode=8` gives a 1920×1080@60 HDMI signal, but the current MiSTerPlex content path is
still a 320×240 picture scaled up by MiSTer.

## Change the MiSTerPlex output mode

Output mode is **not** a `misterplex.conf` setting. Edit the `[Plex]` section of
`/media/fat/MiSTer.ini`, then soft-reboot MiSTer so the core reloads with the new mode.

1. Back up the ini:

   ```sh
   ssh root@<mister-ip>
   cp /media/fat/MiSTer.ini /media/fat/MiSTer.ini.before-misterplex-video
   ```

2. Edit only the `[Plex]` section:

   ```sh
   vi /media/fat/MiSTer.ini
   ```

   Example: 1920×1080@60 HDMI output:

   ```ini
   [Plex]
   video_mode=8
   video_mode_ntsc=8
   video_mode_pal=8
   vsync_adjust=0
   refresh_min=0
   refresh_max=0
   direct_video=0
   vscale_mode=0
   vga_scaler=1
   ```

   Example: return to the VGA/LCD-safe default, 800×600@60:

   ```ini
   [Plex]
   video_mode=5
   video_mode_ntsc=5
   video_mode_pal=5
   vsync_adjust=0
   refresh_min=0
   refresh_max=0
   direct_video=0
   vscale_mode=0
   vga_scaler=1
   ```

   Before rebooting, verify the anti-retune pins are still active:

   ```sh
   python3 scripts/check_mister_ini_plex_guard.py path/to/MiSTer.ini
   ```

   The reference keys live in `assets/MiSTer.ini.Plex.required`, and `make unit`
   exercises the checker against good and intentionally broken examples. Do not
   comment out `video_mode`, `video_mode_ntsc`, or `video_mode_pal` in `[Plex]`
   unless you are deliberately changing the reference with lab evidence.

3. Reboot:

   ```sh
   reboot
   ```

## Recommended modes

These recommendations come from the 2026-07-26 output-mode sweep in
[`crt-lcd-matrix.md`](crt-lcd-matrix.md). The test held each mode for 120 seconds with existing
320×240 content. HDMI sync locked for every recommended mode below, drops stayed in the same range as
baseline, A/V drift stayed in the same band, and CPU remained **0% idle** in every row.

| `video_mode` | Output signal | Recommendation | Sweep evidence |
|---:|---|---|---|
| 5 | 800×600@60 | **Default**; safest LCD/VGA choice | HDMI PASS; VGA baseline envelope; drops 0; drift −32…−21 ms; 0% idle |
| 6 | 640×480@60 | Conservative VGA fallback | HDMI PASS; within VGA envelope; retest drops 2; drift −40…−20 ms; 0% idle |
| 1 | 1024×768@60 | Supported HDMI mode | HDMI PASS; drops 1; drift −40…−20 ms; 0% idle |
| 0 | 1280×720@60 | Supported HDMI 720p60 | HDMI PASS; drops 0; drift −40…−20 ms; 0% idle |
| 7 | 1280×720@50 | Supported HDMI 720p50 | HDMI PASS; drops 0; drift −35…−24 ms; 0% idle |
| 8 | 1920×1080@60 | Supported HDMI 1080p60 | HDMI PASS; drops 0; drift −38…−25 ms; 0% idle |
| 9 | 1920×1080@50 | Supported HDMI 1080p50 | HDMI PASS; drops 1; drift −40…−20 ms; 0% idle |
| 4 | 1280×1024@60 | **Not recommended / inconclusive** | Playback was OK, but HDMI capture failed to relock on retest |

Modes 12 (1920×1440@60) and 13 (2048×1536@60) also passed the lab sweep, but they are above the
1080p user-facing target and are not default recommendations.

## VGA guidance

The lab VGA panel is rated only to **800×600@60**. With `vga_scaler=1`, VGA follows the same scaler
mode as HDMI. If you use VGA, stay at:

- `video_mode=5` for 800×600@60, or
- `video_mode=6` for 640×480@60 fallback.

Higher HDMI modes can work well over HDMI, but they also push VGA to that same higher mode. If your VGA
display cannot sync above 800×600@60, choosing a high HDMI mode may make the VGA output unusable.

## Native/content resolution selector

The Plex core now exposes a runtime OSD selector for the **native content resolution**:

```text
F12 → Content resolution → 320x240 or 640x480
```

This is deliberately separate from `video_mode`. For example:

- `video_mode=8` + `Content resolution=320x240` = a 1080p output signal carrying the proven
  320×240 content path scaled by MiSTer.
- `video_mode=8` + `Content resolution=640x480` = a 1080p output signal carrying a 640×480
  native frame, once the 480p pipeline pieces are present.

The selector is one core, not a separate "480p build". `320x240` is still the default so existing
installs keep the proven path. The ARM daemon reads the same OSD status word (`O[4]`) that the RTL
uses, via the DDR OSD mailbox, before starting playback. That keeps Plex server resolution,
ARM decode size, and the core's native-resolution selector tied to one source of truth instead of
separate ARM/RTL copies.

### Native-resolution frame-store status

Choose `640x480` only for 480p test builds that include all three required pieces:

1. DDR-backed YUV420p frame store in the core, so the frame buffer is not limited to the old
   BRAM-sized 320×240 path and does not depend on the unvalidated SDRAM stick path.
2. ARM YUV420p DDR frame writes sized for 640×480, using the shared
   `host/libmisterplex/ddr_frame_layout.hpp` layout.
3. Plex weak-ladder resolve requesting a 640×480 stream.

Current claim level: **fits and closes timing / within modelled bandwidth**. The DDR-backed native
path is not hardware-validated yet, so do not describe it as supported until a lab run proves playback
on silicon. The output-mode sweep above remains valid: output signal resolution is effectively free;
native content resolution is the part that needs validation.

#### DDR frame-store bandwidth model

The legacy DDR bridge clock was `clk_sys = 20 MHz`; this is our PLL choice, not an HPS DDR3 bridge
limit. In-tree framework evidence shows the core supplies `DDRAM_CLK` (`sys/sys_top.v` connects it to
`ram_clk`) and `sys/sys_top.sdc` constrains the HPS user clock at 100 MHz. This branch therefore adds a
dedicated DDR PLL output instead of raising `clk_sys` wholesale. The YUV420p frame-store RTL currently
closes at the fitted DDR clock below; 100 MHz remains a framework target, not a claim for this build.

Model assumptions:

- DDRAM port width is 64 bits, so peak bridge bandwidth is `DDRAM_CLK × 8 bytes`.
- The continuously safe FPGA read budget is pessimistically capped at **25% of peak** to leave room for
  ARM writes, Linux, MiSTer's scaler, and decoder traffic.
- The table counts full read plus write DDR traffic. The FPGA-read column is the pressure on the core's
  `DDRAM_CLK` port; the ARM-write column is simultaneous HPS DDR fabric traffic.
- YUV420p is 1.5 bytes/pixel; RGB565 is 2 bytes/pixel. At 640×480, this is 460,800 bytes/frame vs
  614,400 bytes/frame.

**Current 20 MHz baseline** — peak 160 MB/s; pessimistic FPGA-read budget 40 MB/s:

| Native mode | Format | FPGA read | ARM write | Total DDR fabric | Model result |
|---|---|---:|---:|---:|---|
| 640×480@30 | YUV420p | 13.824 MB/s | 13.824 MB/s | 27.648 MB/s | within modelled bandwidth |
| 640×480@30 | RGB565 | 18.432 MB/s | 18.432 MB/s | 36.864 MB/s | within modelled bandwidth |
| 640×480@60 | YUV420p | 27.648 MB/s | 27.648 MB/s | 55.296 MB/s | within modelled bandwidth, but latency-sensitive |
| 640×480@60 | RGB565 | 36.864 MB/s | 36.864 MB/s | 73.728 MB/s | near the pessimistic read budget; not comfortable |
| 1280×720@30 | YUV420p | 41.472 MB/s | 41.472 MB/s | 82.944 MB/s | just over the 20 MHz read budget |
| 1280×720@30 | RGB565 | 55.296 MB/s | 55.296 MB/s | 110.592 MB/s | over the 20 MHz read budget |

**Fitted DDR clock for this YUV420p branch: 80 MHz** — peak 640 MB/s; pessimistic FPGA-read budget
160 MB/s:

| Native mode | Format | FPGA read | ARM write | Total DDR fabric | Model result |
|---|---|---:|---:|---:|---|
| 640×480@30 | YUV420p | 13.824 MB/s | 13.824 MB/s | 27.648 MB/s | comfortable within modelled bandwidth |
| 640×480@30 | RGB565 | 18.432 MB/s | 18.432 MB/s | 36.864 MB/s | comfortable within modelled bandwidth |
| 640×480@60 | YUV420p | 27.648 MB/s | 27.648 MB/s | 55.296 MB/s | comfortable by bandwidth; use 16-line prefetch for the blackout model |
| 640×480@60 | RGB565 | 36.864 MB/s | 36.864 MB/s | 73.728 MB/s | comfortable by bandwidth; higher ARM conversion cost |
| 1280×720@30 | YUV420p | 41.472 MB/s | 41.472 MB/s | 82.944 MB/s | viable by bandwidth; needs 16-line prefetch and a separate fit |
| 1280×720@30 | RGB565 | 55.296 MB/s | 55.296 MB/s | 110.592 MB/s | viable by bandwidth; less fabric/ARM margin than YUV420p |

**100 MHz framework target** — peak 800 MB/s; pessimistic FPGA-read budget 200 MB/s. The same rows
remain within modelled bandwidth with 25% more margin than 80 MHz, but this YUV420p branch has
not closed timing there yet. Treat 100 MHz as a future optimization target, not current evidence.

Latency modelling uses a recurring 500 µs DDR blackout and a conservative 128-cycle response latency
before burst data. Under that model, 640×480@30 is clean with 8 prefetched lines, while 640×480@60 and
1280×720@30 need 16 lines at 80 MHz. The implemented first rung is therefore **YUV420p 640×480@30, 8-line
prefetch**.

## What this does and does not mean

The sweep shows that **output resolution is effectively free** for the current path: MiSTer's scaler does
the output enlargement in HPS DDR3, so moving HDMI from 800×600 to 1080p did not measurably cost ARM CPU
or A/V lock.

It does **not** mean MiSTerPlex decodes native 1080p content today. Native/content resolution is still
limited by:

- the current frame-store path, which is moving from BRAM to SDRAM under ongoing work, and
- the ARM decode/transcode path, which was already at **0% idle** even with 320×240 content.

So: 1080p output signal is supported today; 1080p native picture quality is future work.
