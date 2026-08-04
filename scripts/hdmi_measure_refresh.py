#!/usr/bin/env python3
"""Parent HDMI PTS refresh measure — distinguishes 24 vs 16.16 Hz."""
from __future__ import annotations
import argparse, statistics, subprocess, sys

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=2.0)
    ap.add_argument("--device", default="/dev/video0")
    args = ap.parse_args()
    dur = max(args.seconds, 1.5)
    cmd = ["ffmpeg","-hide_banner","-loglevel","info","-f","v4l2","-i",args.device,
           "-t",str(dur),"-vf","showinfo","-f","null","-"]
    print("PRE-REG bands: PASS 23.0-25.5 Hz; FAIL-trap 15.5-17.0 Hz")
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, timeout=int(dur)+30)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr); return 2
    pts=[]
    for line in (proc.stderr or "").splitlines():
        if "pts_time:" not in line: continue
        try: pts.append(float(line.split("pts_time:")[1].split()[0]))
        except Exception: pass
    if len(pts) < 8:
        print(f"FAIL: too few pts ({len(pts)})", file=sys.stderr); return 1
    pts = pts[5:]
    dts = [pts[i+1]-pts[i] for i in range(len(pts)-1) if pts[i+1]>pts[i]]
    if len(dts) < 4:
        print("FAIL: no dts", file=sys.stderr); return 1
    med = statistics.median(dts)
    fps = 1.0/med if med>0 else 0.0
    print(f"RESULT n_dts={len(dts)} median_dt={med:.6f}s fps={fps:.3f}")
    if 23.0 <= fps <= 25.5:
        print("PASS hdmi_measure_refresh: ~24 Hz"); return 0
    if 15.5 <= fps <= 17.0:
        print("FAIL hdmi_measure_refresh: ~16.16 Hz TRAP", file=sys.stderr); return 1
    print(f"FAIL fps={fps:.3f} outside bands", file=sys.stderr); return 1

if __name__ == "__main__":
    raise SystemExit(main())
