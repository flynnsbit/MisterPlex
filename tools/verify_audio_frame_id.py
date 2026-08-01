#!/usr/bin/env python3
"""Verify self-checking audio markers: raw PCM + AAC re-encode survival.

No device. Labels measured | caller_supplied.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from audio_frame_id import (  # noqa: E402
    SR,
    checksum_nibble,
    decode_all,
    marker_times,
    synthesize_pcm,
    write_pcm_s16le_stereo,
)


def run(cmd: list[str]) -> int:
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode


def aac_roundtrip(pcm_mono: np.ndarray, br: str, sr: int = SR) -> np.ndarray:
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        raw_in = td / "in.s16"
        aac = td / "a.aac"
        raw_out = td / "out.f32"
        write_pcm_s16le_stereo(raw_in, pcm_mono)
        rc1 = run([
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "s16le", "-ar", str(sr), "-ac", "2", "-i", str(raw_in),
            "-c:a", "aac", "-b:a", br, "-ar", str(sr), "-ac", "1",
            str(aac),
        ])
        if rc1 != 0:
            raise SystemExit(f"aac encode failed true_rc={rc1} br={br}")
        rc2 = run([
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-i", str(aac), "-ac", "1", "-ar", str(sr),
            "-f", "f32le", str(raw_out),
        ])
        if rc2 != 0:
            raise SystemExit(f"aac decode failed true_rc={rc2} br={br}")
        return np.frombuffer(raw_out.read_bytes(), dtype=np.float32).astype(np.float64)


def extract_audio_from_mp4(path: Path, sr: int = SR) -> np.ndarray:
    with tempfile.NamedTemporaryFile(suffix=".f32", delete=False) as tmp:
        tp = Path(tmp.name)
    try:
        rc = run([
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-i", str(path), "-ac", "1", "-ar", str(sr), "-f", "f32le", str(tp),
        ])
        if rc != 0:
            raise SystemExit(f"mp4 audio extract true_rc={rc}")
        return np.frombuffer(tp.read_bytes(), dtype=np.float32).astype(np.float64)
    finally:
        tp.unlink(missing_ok=True)


def ffprobe(path: Path) -> dict:
    p = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "stream=codec_type,width,height,r_frame_rate,nb_frames,profile,has_b_frames,"
         "codec_name,sample_rate,duration",
         "-show_entries", "format=duration", "-of", "json", str(path)],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        raise SystemExit(f"ffprobe true_rc={p.returncode}")
    return json.loads(p.stdout)


def score_decode(pcm: np.ndarray, expect: list[tuple[int, float]], label: str) -> dict:
    pkts, meta = decode_all(pcm, SR)
    ok = [p for p in pkts if p.ok]
    # map expected n -> found
    found_n = {p.n for p in ok}
    expect_n = {n for n, _ in expect}
    missing = sorted(expect_n - found_n)
    extra = sorted(found_n - expect_n)
    # checksum spot
    bad = [p for p in pkts if not p.ok]
    return {
        "label": label,
        "n_expect": len(expect),
        "n_onsets": meta.get("n_onsets"),
        "n_ok": meta.get("n_ok"),
        "n_fail": meta.get("n_fail"),
        "missing_n_head": missing[:10],
        "extra_n_head": extra[:10],
        "n_missing": len(missing),
        "fail_reasons_head": [p.reason for p in bad[:5]],
        "ok_head": [{"n": p.n, "t": p.t_onset_s} for p in ok[:5]],
        "src": "measured",
        "pass": len(missing) == 0 and meta.get("n_ok", 0) >= len(expect),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--duration", type=float, default=20.0, help="synthetic PCM test length")
    ap.add_argument("--mp4", type=Path, default=None, help="optional fixture mp4 to score")
    ap.add_argument("--expect-offset-ms", type=float, default=0.0)
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args()

    report: dict = {"src_levels": "measured|caller_supplied"}
    fail = []

    # unit: checksum + bits roundtrip
    for n in [0, 1, 48, 2358, 14399, 65535]:
        from audio_frame_id import bits_for_frame_n, frame_n_from_bits
        ok, got, reason = frame_n_from_bits(bits_for_frame_n(n))
        if not ok or got != (n & 0xFFFF):
            fail.append(f"bits_rt n={n} {reason}")
    report["bits_roundtrip_fail"] = [f for f in fail if f.startswith("bits")]

    # raw PCM synthesize + decode
    pcm, markers = synthesize_pcm(args.duration, audio_delay_s=0.0)
    expect = [(m["frame_n"], m["t_video_s"]) for m in markers]
    r_raw = score_decode(pcm, expect, "raw_pcm")
    report["raw_pcm"] = r_raw
    print("RAW", json.dumps({k: r_raw[k] for k in r_raw if k != "ok_head"}))
    if not r_raw["pass"]:
        fail.append("raw_pcm")

    # AAC survival at 128k and 96k
    aac_results = []
    for br in ("128k", "96k"):
        rt = aac_roundtrip(pcm, br)
        # length may differ slightly — ok
        r = score_decode(rt, expect, f"aac_{br}")
        aac_results.append(r)
        print("AAC", br, "n_ok", r["n_ok"], "missing", r["n_missing"], "pass", r["pass"])
        if not r["pass"]:
            fail.append(f"aac_{br}")
    report["aac"] = aac_results

    # optional mp4
    if args.mp4:
        meta = ffprobe(args.mp4)
        vs = next(s for s in meta["streams"] if s.get("codec_type") == "video")
        aus = next(s for s in meta["streams"] if s.get("codec_type") == "audio")
        report["ffprobe"] = {
            "width": vs.get("width"), "height": vs.get("height"),
            "r_frame_rate": vs.get("r_frame_rate"), "nb_frames": vs.get("nb_frames"),
            "profile": vs.get("profile"), "has_b_frames": vs.get("has_b_frames"),
            "duration": meta.get("format", {}).get("duration"),
            "audio_codec": aus.get("codec_name"), "sample_rate": aus.get("sample_rate"),
            "src": "measured",
        }
        print("FFPROBE", report["ffprobe"])
        if report["ffprobe"]["r_frame_rate"] != "24/1":
            fail.append(f"rate={report['ffprobe']['r_frame_rate']}")
        audio = extract_audio_from_mp4(args.mp4)
        # expect markers from duration
        dur = float(report["ffprobe"]["duration"])
        expect_m = marker_times(dur)
        r_mp4 = score_decode(audio, expect_m, "mp4_aac")
        report["mp4_audio"] = r_mp4
        print("MP4_AUD", "n_ok", r_mp4["n_ok"], "missing", r_mp4["n_missing"], "pass", r_mp4["pass"])
        if not r_mp4["pass"]:
            fail.append("mp4_audio")

    report["fail"] = fail
    report["pass"] = len(fail) == 0
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2))
    if fail:
        print("AUDIO_FRAME_ID_FAIL", fail)
        return 1
    print("AUDIO_FRAME_ID_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
