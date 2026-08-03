# Pre-registered (before measure)
P1: decision DP rk=36 → decision="directplay", profile CB in XML (untrusted)
P2: ffprobe Part bytes rk=36 → Constrained Baseline, has_b_frames=0
P3: decision xcode rk=2 1280x720 → decision=transcode; bytes Main has_b_frames=2
P4: thin headers → empty/400 body (not silent xcode success)
