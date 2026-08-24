# 720p Constrained Baseline I+P golden

Phase 1a encode. 4 frames, 1280x720 4:2:0, QP 25, 1 ref, no B, CAVLC, no 8x8, partitions none (P_16x16 + skip; I still has I16/I4).

```
ffmpeg -f lavfi -i testsrc=size=1280x720:rate=30 -frames:v 4 -pix_fmt yuv420p src_4f_1280x720.yuv
x264 --profile baseline --level 3.1 --preset medium --bframes 0 --no-cabac --no-8x8dct \
  --weightp 0 --ref 1 --qp 25 --partitions none --fps 30 --input-res 1280x720 \
  -o cbp_720p_ip_qp25.264 src_4f_1280x720.yuv
ffmpeg -i cbp_720p_ip_qp25.264 -pix_fmt yuv420p gold_4f_1280x720.yuv
```

| File | SHA256 |
|---|---|
| cbp_720p_ip_qp25.264 | 37f8c0c1b04846477ce2e5aab30f95642891208d33e9876d90ad9fe3babbef34 |
| gold_4f_1280x720.yuv | 15a873424e0267a4a4f67913e4964733f63e09122a861f6590e9528bdc9fc3e6 |
| src_4f_1280x720.yuv | f8e231c25ec9169c0e52dbe2485efaaed6c5cfdf045e016b62e747be925cb183 |

Pass: FPGA YUV bit-exact vs `gold_4f_1280x720.yuv` (libavcodec). Not SSIM.

sat9 is the fixture IQ path. s16 dequant is after FIT_GO / real Plex titles.
