# Encoding contract — real BBB + Glass ID + A/V markers

**Generator:** `scripts/gen_real_bbb_avsync_soak.py`  
**ID:** `tools/glass_frame_id.py` / `docs/glass_frame_id_contract.md`  
**Evidence report:** `.agent-work/w-asset480/REPORT.md`

## Designed lock

| quantity | value | label |
|----------|-------|--------|
| fps | `24/1` | caller_supplied; **must** match ffprobe `r_frame_rate` |
| marker times | `t_k = k * 2.000 s` | caller_supplied |
| video frame index | `n = 0,1,…` every frame | burned unconditionally |
| video event | body y ≥ `geometry.bar_y1` → RGB white for 2 frames at `round(t_k*24)` | ID band never whitened |
| audio event | 1 kHz beep, 50 ms, 1 ms linear attack at sample `round(t_k*48000)` | mixed with looped source @0.85 |
| designed A/V offset | **0.0 ms** | `(t_audio − t_video)*1000` by construction on content timeline |
| glass text | `G n=DDDDDD c=C`, `C = sum(digits) mod 10` | fixed width |
| bars | START\|GREY16\|PARITY\|STOP\|LOCK | authoritative index channel |

Post-AAC / device path: **not** sample-accurate — see `docs/AV_LOCK_UNCERTAINTY.md`.

## ffmpeg shape (from generator)

Decode: `-stream_loop -1 -i SRC -vf scale=W:H:flags=bicubic,fps=24 -f rawvideo -pix_fmt rgb24`  
Encode: libx264 baseline bf=0 cabac=0 + AAC 48 kHz amix(src,beep).
