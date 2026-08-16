#!/usr/bin/env python3
"""Measure flash vs beep offset in an HDMI capture. No official-gate claim."""
import json, subprocess, sys
from pathlib import Path
import numpy as np

def run(cmd):
    return subprocess.check_output(cmd, stderr=subprocess.DEVNULL)

def main():
    cap = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else cap.with_suffix(".sync.json")
    rawv = cap.with_suffix(".gray")
    rawa = cap.with_suffix(".s16")
    # 60 Hz capture typical for MS2109
    w, h, fps = 1280, 720, 60.0
    subprocess.check_call([
        "ffmpeg","-y","-hide_banner","-loglevel","error","-i",str(cap),
        "-vf","fps=60,scale=1280:720,format=gray","-f","rawvideo",str(rawv),
        "-vn","-ac","1","-ar","48000","-f","s16le",str(rawa),
    ])
    pix = np.fromfile(rawv, dtype=np.uint8)
    nfr = pix.size // (w*h)
    pix = pix[:nfr*w*h].reshape(nfr, w*h)
    mean = pix.mean(axis=1)
    thr = max(140.0, float(np.median(mean)+40))
    flashes = []
    i = 0
    while i < nfr:
        if mean[i] >= thr:
            j = i
            while j < nfr and mean[j] >= thr:
                j += 1
            flashes.append(i / fps)
            i = j
        else:
            i += 1
    pcm = np.fromfile(rawa, dtype=np.int16).astype(np.float64)
    hop = 240  # 5 ms
    rms = []
    for s in range(0, len(pcm)-hop, hop):
        rms.append(np.sqrt(np.mean(pcm[s:s+hop]**2)))
    rms = np.array(rms)
    rthr = max(800.0, float(np.median(rms)*8 + 400))
    beeps = []
    i = 0
    while i < len(rms):
        if rms[i] >= rthr:
            j = i
            while j < len(rms) and rms[j] >= rthr:
                j += 1
            beeps.append(i * hop / 48000.0)
            i = j + 2
        else:
            i += 1
    pairs = []
    used = set()
    for ft in flashes:
        best = None
        for k, bt in enumerate(beeps):
            if k in used:
                continue
            d = (bt - ft) * 1000.0
            if best is None or abs(d) < abs(best[1]):
                best = (k, d)
        if best and abs(best[1]) < 800:
            used.add(best[0])
            pairs.append(best[1])
    med = float(np.median(pairs)) if pairs else None
    report = {
        "cap": str(cap),
        "frames": nfr,
        "flashes": len(flashes),
        "beeps": len(beeps),
        "pairs": len(pairs),
        "offsets_ms": [round(x,1) for x in pairs],
        "median_ms": None if med is None else round(med,1),
        "sign": None if med is None else ("audio_late" if med>0 else "audio_early"),
        "note": "positive=beep after flash (audio late); negative=audio early",
    }
    out.write_text(json.dumps(report, indent=2))
    print(json.dumps(report))
    return 0 if pairs else 2

if __name__ == "__main__":
    raise SystemExit(main())
