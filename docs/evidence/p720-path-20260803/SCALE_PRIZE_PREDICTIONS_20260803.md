# (1) Pre-registered — make scale disappear

## Which FFmpeg owns 34.50

**Prediction P-role:** Parent 34.50 is the **STREAM=0 rawvideo present** child
(`media_player.cpp` ~3219: `-f rawvideo -pix_fmt … -vf … pipe:1`), **not**
`spawnStreamDemux` (~1595: `-c:v copy -f h264`) and not `spawnAudioOnly` (~1644).
Remux is bitstream/recon path; 34.50 is decode+pack+copy for continuous F1.

## PMS delivery

**P-pms-540:** With `videoResolution=960x540` + maxBR≥2000 + HD 16:9 source, PMS
delivers **exactly 960×540** display (SAR 1:1, CB L31). Ceiling traps: maxBR=1500→720×404; SD source cannot invent 540.

**P-pms-360:** `videoResolution=640x360` + maxBR≥1000 → **exactly 640×360**.

## Scale stage cost / prize

**P-force:** Product `DDR_YUV_FORCE_SCALE` default ON maps SkipIdentity→Always.
Play-time plan freezes **before** banner → `delivery_geometry_verified=0`.
Always+exact+unverified → reason `force_unverified_claim_scale_pad_coded` →
**`scale=WxH` still in -vf** even when PMS will deliver exact bank size.

**P-cost:** Same-size scale tax on device-class path is **small: 0.5–4 ms**,
**not** enough alone to flip 34.50→under 33.33 (−1.17 gap). Pack+decode+copy dominate.

**P-prize-close-gap:** Eliminating scale **will NOT** close −1.17 by itself.
