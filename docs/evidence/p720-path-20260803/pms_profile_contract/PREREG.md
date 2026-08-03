# Pre-registered predictions (before measure)

1. `/identity` → HTTP 200
2. `/library/sections` with token → HTTP 200
3. Universal start with videoResolution=320x240, maxVideoBitrate=1000, videoQuality=40,
   protocol=http, directPlay=0, directStream=0 → HTTP 200 (or 302) and deliverable media
   (parent: v0.2.0 path works; earlier 400 was incomplete identity)
4. Same with 640x480 / 2500 / 60 → HTTP 200, delivered height ≤480
5. Same with 1280x720 / 3100 / 70 → HTTP 200 or measurable coded size
6. MISS policy: publish actual http codes and ffprobe WxH/bitrate

