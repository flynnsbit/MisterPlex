#!/usr/bin/env python3
"""Grabber pre-flight: is the HDMI capture path alive?

Parent incident (2026-08-02): MacroSilicon unlocked (Active 0x0, Pixelclock 0 Hz)
produced uniform pixel=7 frames. An innocent daemon was rolled back on that dead
instrument. Run this BEFORE any cast/capture evidence is accepted for promote.

Exit codes:
  0  SIGNAL_OK — DV timings locked and/or sample frame is a real picture
  78 CAPTURE_NO_SIGNAL — unlocked or uniform no-signal frame (NOT device black)
  77 UNSCORED — device busy / missing tools / cannot assess (never promote PASS)
  2  usage / hard error / internal exception converted to VERDICT (never traceback)

CRITICAL (parent 2026-08-02 re-verify @ f9ad2797):
  --inject-stats BYPASSES sample_frame and load_png_rgb entirely.
  A green inject test does NOT prove the real capture path.
  Host proof of the PIL open path MUST use --png or --self-test (or real /dev/video0).
  On CAPTURE_NO_SIGNAL the ACTION line must appear so operators do NOT rollback
  device software on a dead-instrument symptom.

Does NOT touch the MiSTer device — host grabber only.
Does NOT depend on hdmi_motion_instrument (self-contained uniform check).
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

RC_OK = 0
RC_NO_SIGNAL = 78
RC_UNSCORED = 77
RC_ERR = 2

DEFAULT_DEV = os.environ.get("HDMI_DEV", "/dev/video0")


def _run(cmd: list[str], timeout: float = 8.0) -> tuple[int, str, str]:
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return int(p.returncode), p.stdout or "", p.stderr or ""
    except FileNotFoundError:
        return 127, "", f"missing binary: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def query_dv_timings(dev: str) -> dict:
    """Real-capture-only path (not exercised by --inject-*). Never raises."""
    try:
        rc, out, err = _run(["v4l2-ctl", f"--device={dev}", "--query-dv-timings"])
        text = out + err

        def _i(pat: str):
            m = re.search(pat, text)
            return int(m.group(1)) if m else None

        active_w = _i(r"Active width:\s*(\d+)")
        active_h = _i(r"Active height:\s*(\d+)")
        pix = None
        m = re.search(r"Pixelclock:\s*([0-9.]+)\s*([MGmu]?Hz)", text, re.I)
        if m:
            val = float(m.group(1))
            unit = m.group(2).lower()
            if unit.startswith("m"):
                pix = val * 1e6
            elif unit.startswith("g"):
                pix = val * 1e9
            else:
                pix = val
        locked = bool(
            active_w and active_h and active_w > 0 and active_h > 0 and pix and pix > 0
        )
        return {
            "rc": rc,
            "active_w": active_w,
            "active_h": active_h,
            "pixelclock_hz": pix,
            "locked": locked,
            "raw": text.strip()[:800],
        }
    except Exception as exc:  # noqa: BLE001 — verdict not traceback
        return {
            "rc": 2,
            "active_w": None,
            "active_h": None,
            "pixelclock_hz": None,
            "locked": False,
            "raw": "",
            "error": f"{type(exc).__name__}: {exc}",
        }


def fuser_busy(dev: str) -> str | None:
    """Real-capture-only path (not exercised by --inject-*). Never raises."""
    try:
        _rc, out, err = _run(["fuser", "-v", dev], timeout=3.0)
        text = (out + err).strip()
        return text or None
    except Exception:  # noqa: BLE001
        return None


def classify_rgb_array(rgb) -> dict:
    """Uniform min==max ⇒ NO_SIGNAL (dead grabber), not device black."""
    amin = int(rgb.min())
    amax = int(rgb.max())
    mean = float(rgb.mean())
    if rgb.shape[0] > 240 and rgb.shape[1] > 320:
        std = float(rgb[::8, ::8].std())
    else:
        std = float(rgb.std())
    uniform = amin == amax
    return {
        "no_signal": bool(uniform),
        "uniform": uniform,
        "pixel_min": amin,
        "pixel_max": amax,
        "pixel_mean": round(mean, 3),
        "pixel_std": round(std, 4),
        "signal_class": "NO_SIGNAL" if uniform else "REAL_PICTURE",
    }


def classify_from_stats(pixel_min: float, pixel_max: float, pixel_std: float) -> dict:
    """Host inject path (no device): same rule as live sample."""
    uniform = float(pixel_min) == float(pixel_max) or float(pixel_std) < 0.0001
    return {
        "no_signal": uniform,
        "uniform": uniform,
        "pixel_min": pixel_min,
        "pixel_max": pixel_max,
        "pixel_std": pixel_std,
        "signal_class": "NO_SIGNAL" if uniform else "REAL_PICTURE",
    }


def load_png_rgb(path: Path):
    """Load PNG → RGB ndarray via PIL *module* open (not Image.Image class).

    BEFORE (parent-measured crash on real dead grabber @ f9ad2797):
      broken = importlib-style PIL.Image module then .Image.open on the CLASS
      (MODULE.Image is the Image class — no .open → AttributeError)
      Concrete broken form was: dunder-import PIL.Image fromlist Image,
      then attribute Image.open on that result.

    AFTER:
      from PIL import Image
      Image.open(path)   # module-level open
    """
    import numpy as np
    from PIL import Image

    with Image.open(path) as im:
        return np.asarray(im.convert("RGB"))


def classify_png_file(path: str | Path) -> dict:
    """Classify on-disk PNG — exercises load_png_rgb (NOT bypassed by inject).

    Never raises: internal errors → ok=False classified dict.
    """
    path = Path(path)
    try:
        if not path.is_file():
            return {"ok": False, "error": f"png missing: {path}"}
        rgb = load_png_rgb(path)
        sig = classify_rgb_array(rgb)
        return {"ok": True, "path": str(path), "n_grabbed": 1, **sig}
    except Exception as exc:  # noqa: BLE001 — verdict not traceback
        return {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "exception_class": type(exc).__name__,
        }


def sample_frame(dev: str, size: str = "1920x1080") -> dict:
    """Grab frames from v4l2 and classify. Real-capture path only.

    Never raises — internal errors become ok=False classified dicts.
    --inject-stats BYPASSES this function entirely (parent 2026-08-02).
    """
    try:
        import numpy as np  # noqa: F401
        from PIL import Image  # noqa: F401
    except ImportError as exc:
        return {"ok": False, "error": f"numpy/PIL required for frame sample: {exc}"}

    try:
        with tempfile.TemporaryDirectory(prefix="grabber_preflight_") as td:
            cmd = [
                "ffmpeg",
                "-v",
                "error",
                "-f",
                "v4l2",
                "-input_format",
                "mjpeg",
                "-video_size",
                size,
                "-i",
                dev,
                "-frames:v",
                "3",
                "-y",
                str(Path(td) / "f_%02d.png"),
            ]
            rc, _o, err = _run(cmd, timeout=15.0)
            frames = sorted(Path(td).glob("f_*.png"))
            if rc != 0 or not frames:
                busy = "Device or resource busy" in (err or "")
                return {
                    "ok": False,
                    "ffmpeg_rc": rc,
                    "error": (err or "").strip()[:300] or "no frames",
                    "busy": busy,
                }
            # Prefer last frame. classify_png_file owns PIL open (fixed path).
            merged = classify_png_file(frames[-1])
            merged["n_grabbed"] = len(frames)
            merged["ffmpeg_rc"] = rc
            return merged
    except Exception as exc:  # noqa: BLE001 — verdict not traceback
        return {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "exception_class": type(exc).__name__,
        }


ACTION_NO_SIGNAL = (
    "ACTION: re-plug HDMI into grabber / power-cycle MS2109; "
    "do NOT rollback device software on this symptom alone"
)


def emit_no_signal(detail: str = "") -> int:
    """CAPTURE_NO_SIGNAL with the mandatory operator ACTION line."""
    print(
        f"VERDICT=CAPTURE_NO_SIGNAL rc={RC_NO_SIGNAL} "
        f"device_state=UNKNOWN capture_path=FAULT"
        + (f" — {detail}" if detail else "")
    )
    print(ACTION_NO_SIGNAL)
    return RC_NO_SIGNAL


def run_self_test() -> int:
    """Host self-test that MUST exercise load_png_rgb / classify_png_file.

    Injection-only coverage is NOT acceptable (parent): inject bypasses
    sample_frame. This writes a real uniform PNG and loads it through PIL.
    Also asserts classify_png_file never raises on a broken path.
    """
    failures: list[str] = []
    try:
        import numpy as np
        from PIL import Image
    except ImportError as exc:
        print(f"VERDICT=ERR rc={RC_ERR} reason=self_test_import {exc}")
        return RC_ERR

    with tempfile.TemporaryDirectory(prefix="grabber_selftest_") as td:
        td_path = Path(td)
        # Uniform pixel=7 — the real dead-grabber signature parent measured.
        uni = td_path / "uniform7.png"
        arr = np.full((64, 64, 3), 7, dtype=np.uint8)
        Image.fromarray(arr, mode="RGB").save(uni)

        got = classify_png_file(uni)
        if not got.get("ok"):
            failures.append(f"uniform_load_failed:{got.get('error')}")
        elif not got.get("no_signal"):
            failures.append(
                f"uniform_not_nosignal class={got.get('signal_class')} "
                f"min={got.get('pixel_min')} max={got.get('pixel_max')} "
                f"std={got.get('pixel_std')}"
            )
        else:
            print(
                f"self_test uniform_png signal_class={got.get('signal_class')} "
                f"min={got.get('pixel_min')} max={got.get('pixel_max')} "
                f"std={got.get('pixel_std')} no_signal=1 [png-path]"
            )

        # Varied frame must NOT be no_signal.
        realp = td_path / "realish.png"
        rarr = np.zeros((64, 64, 3), dtype=np.uint8)
        rarr[:32, :, 0] = 200
        rarr[32:, :, 2] = 180
        rarr[16:48, 16:48, 1] = 90
        Image.fromarray(rarr, mode="RGB").save(realp)
        rgot = classify_png_file(realp)
        if not rgot.get("ok"):
            failures.append(f"real_load_failed:{rgot.get('error')}")
        elif rgot.get("no_signal"):
            failures.append(f"real_false_nosignal std={rgot.get('pixel_std')}")
        else:
            print(
                f"self_test real_png signal_class={rgot.get('signal_class')} "
                f"std={rgot.get('pixel_std')} no_signal=0 [png-path]"
            )

        # Broken path must return ok=False, never raise.
        bad = classify_png_file(td_path / "missing.png")
        if bad.get("ok"):
            failures.append("missing_png_ok_true")
        else:
            print(
                f"self_test missing_png ok=0 error={bad.get('error')!r} "
                f"(no raise)"
            )

        # Static ban: executable broken PIL class-open must not exist.
        # Strip this function body + docstrings/comments so the checker and
        # BEFORE documentation cannot trip the ban.
        src = Path(__file__).read_text(encoding="utf-8")
        # Drop run_self_test body (contains the ban strings themselves).
        src_wo_self = re.sub(
            r"def run_self_test\([\s\S]*?\ndef main\(",
            "def main(",
            src,
            count=1,
        )
        code_only = re.sub(r'"""[\s\S]*?"""', '""', src_wo_self)
        code_only = re.sub(r"'''[\s\S]*?'''", "''", code_only)
        code_only = re.sub(r"#.*", "", code_only)
        # Rebuild forbidden token without embedding the full live call form
        # as a single literal in this checker.
        dunder = "__" + "import" + "__"
        pil_mod = "PIL" + "." + "Image"
        if dunder in code_only and pil_mod in code_only:
            failures.append("forbidden_pil_dunder_import_live")
        else:
            print("self_test forbidden_pil_pattern=absent")

    if failures:
        print(
            f"VERDICT=ERR rc={RC_ERR} reason=self_test_fail "
            f"detail={';'.join(failures)}"
        )
        return RC_ERR
    print(
        "VERDICT=SELF_TEST_OK rc=0 png_path_exercised=1 "
        "inject_bypasses_sample_frame=1"
    )
    return RC_OK


def main(argv: list[str] | None = None) -> int:
    try:
        return _main_inner(argv)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — gate exits on VERDICT, never traceback
        print(
            f"VERDICT=ERR rc={RC_ERR} reason=unhandled_exception "
            f"class={type(exc).__name__} msg={exc}"
        )
        print(
            "ACTION: grabber_preflight internal error — do NOT treat as device "
            "regression; fix the tool; capture_path=UNKNOWN"
        )
        return RC_ERR


def _main_inner(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--device", default=DEFAULT_DEV)
    ap.add_argument("--size", default="1920x1080")
    ap.add_argument("--skip-frame", action="store_true")
    ap.add_argument(
        "--inject-stats",
        metavar="MIN,MAX,STD",
        help=(
            "Host-only inject (no /dev/video0). RED: 7,7,0 → rc=78. "
            "WARNING: bypasses sample_frame and load_png_rgb entirely."
        ),
    )
    ap.add_argument(
        "--inject-dv",
        metavar="W,H,PIX_HZ",
        help="Host-only DV inject e.g. 0,0,0 or 1920,1080,148500000",
    )
    ap.add_argument(
        "--png",
        metavar="PATH",
        help=(
            "Classify an on-disk PNG through load_png_rgb (REAL PIL path). "
            "Use this to prove sample_frame's loader without /dev/video0. "
            "Uniform pixel=7 → rc=78 + ACTION."
        ),
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help=(
            "Write uniform+varied PNGs, load via PIL, ban broken import pattern. "
            "Fails RED if load path raises or mis-classifies."
        ),
    )
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        st = run_self_test()
        if st != RC_OK:
            return st
        # Also prove CLI --png → 78 + ACTION (end-to-end, not inject).
        with tempfile.TemporaryDirectory(prefix="grabber_selftest_cli_") as td:
            import numpy as np
            from PIL import Image

            uni = Path(td) / "u7.png"
            Image.fromarray(
                np.full((32, 32, 3), 7, dtype=np.uint8), mode="RGB"
            ).save(uni)
            rc = _main_inner(["--png", str(uni)])
            if rc != RC_NO_SIGNAL:
                print(
                    f"VERDICT=ERR rc={RC_ERR} reason=self_test_png_cli "
                    f"want={RC_NO_SIGNAL} got={rc}"
                )
                return RC_ERR
            print(f"self_test cli_png_rc={rc} ACTION_required=1 OK")
        print(f"VERDICT=SELF_TEST_OK rc={RC_OK}")
        return RC_OK

    # --- PNG path: exercises load_png_rgb (NOT bypassed by inject) ---
    if args.png:
        info = classify_png_file(args.png)
        if not info.get("ok"):
            print(
                f"sample_frame FAILED error={info.get('error')!r} "
                f"exception_class={info.get('exception_class')} [png]"
            )
            print(
                f"VERDICT=ERR rc={RC_ERR} reason=png_load_failed "
                f"error={info.get('error')!r}"
            )
            print(
                "ACTION: grabber_preflight could not load PNG — do NOT rollback "
                "device software; capture_path=UNKNOWN"
            )
            return RC_ERR
        print(
            f"sample_frame signal_class={info.get('signal_class')} "
            f"min={info.get('pixel_min')} max={info.get('pixel_max')} "
            f"std={info.get('pixel_std')} mean={info.get('pixel_mean')} "
            f"[png path={args.png}]"
        )
        if info.get("no_signal"):
            return emit_no_signal(
                f"sample uniform pixel={info.get('pixel_min')} std=0 "
                f"source=png (NOT a black screen)"
            )
        print(
            f"VERDICT=SIGNAL_OK rc={RC_OK} frame_real=1 capture_path=PNG "
            f"class={info.get('signal_class')}"
        )
        return RC_OK

    # --- host inject path (unit / promote gate without grabber hardware) ---
    # NOTE: inject BYPASSES sample_frame and load_png_rgb (parent finding).
    if args.inject_stats or args.inject_dv:
        unlocked = False
        frame_nosig = False
        frame_real = False
        locked = False
        if args.inject_dv:
            parts = args.inject_dv.split(",")
            if len(parts) != 3:
                print(f"VERDICT=ERR rc={RC_ERR} reason=bad_inject_dv")
                return RC_ERR
            w, h, pix = float(parts[0]), float(parts[1]), float(parts[2])
            locked = w > 0 and h > 0 and pix > 0
            unlocked = not locked
            print(
                f"dv_timings active={int(w)}x{int(h)} pixelclock_hz={pix} "
                f"locked={locked} [inject]"
            )
        if args.inject_stats:
            parts = args.inject_stats.split(",")
            if len(parts) != 3:
                print(f"VERDICT=ERR rc={RC_ERR} reason=bad_inject_stats")
                return RC_ERR
            mn, mx, sd = float(parts[0]), float(parts[1]), float(parts[2])
            sig = classify_from_stats(mn, mx, sd)
            print(
                f"sample_frame signal_class={sig['signal_class']} "
                f"min={sig['pixel_min']} max={sig['pixel_max']} "
                f"std={sig['pixel_std']} [inject — BYPASSES sample_frame]"
            )
            frame_nosig = bool(sig["no_signal"])
            frame_real = not frame_nosig
        if unlocked or frame_nosig:
            return emit_no_signal(
                f"source=inject dv_locked={locked} frame_nosig={int(frame_nosig)}"
            )
        if frame_real or locked:
            print(
                f"VERDICT=SIGNAL_OK rc={RC_OK} dv_locked={locked} "
                f"frame_real={frame_real} capture_path=LIVE source=inject"
            )
            return RC_OK
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason=inject_incomplete")
        return RC_UNSCORED

    dev = args.device
    if not Path(dev).exists():
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason=missing_device {dev}")
        return RC_UNSCORED

    busy = fuser_busy(dev)
    if busy and "ffmpeg" not in (busy or "").lower():
        print(
            f"VERDICT=UNSCORED rc={RC_UNSCORED} "
            f"reason=device_busy fuser={busy!r} — release exclusive holders "
            f"(OBS/nautilus/preview) before capture"
        )
        return RC_UNSCORED

    dv = query_dv_timings(dev)
    print(
        f"dv_timings active={dv.get('active_w')}x{dv.get('active_h')} "
        f"pixelclock_hz={dv.get('pixelclock_hz')} locked={dv.get('locked')} "
        f"[measured]"
    )
    if dv.get("raw"):
        for line in (dv["raw"] or "").splitlines():
            if any(
                k in line
                for k in ("Active width", "Active height", "Pixelclock", "Error")
            ):
                print(f"  | {line.strip()}")

    frame_info = None
    if not args.skip_frame:
        frame_info = sample_frame(dev, size=args.size)
        if frame_info.get("ok"):
            print(
                f"sample_frame signal_class={frame_info.get('signal_class')} "
                f"min={frame_info.get('pixel_min')} max={frame_info.get('pixel_max')} "
                f"std={frame_info.get('pixel_std')} mean={frame_info.get('pixel_mean')} "
                f"[measured]"
            )
        else:
            print(
                f"sample_frame FAILED error={frame_info.get('error')!r} "
                f"busy={frame_info.get('busy')} "
                f"exception_class={frame_info.get('exception_class')}"
            )

    unlocked = dv.get("locked") is False and (
        dv.get("active_w") in (0, None) or (dv.get("pixelclock_hz") or 0) == 0
    )
    frame_nosig = bool(
        frame_info and frame_info.get("ok") and frame_info.get("no_signal")
    )
    frame_real = bool(
        frame_info and frame_info.get("ok") and not frame_info.get("no_signal")
    )
    frame_failed = bool(frame_info is not None and not frame_info.get("ok"))

    if unlocked or frame_nosig:
        reason = []
        if unlocked:
            reason.append(
                f"DV unlocked active={dv.get('active_w')}x{dv.get('active_h')} "
                f"pixelclock={dv.get('pixelclock_hz')}"
            )
        if frame_nosig:
            reason.append(
                f"sample uniform pixel={frame_info.get('pixel_min')} std=0 "
                f"(MacroSilicon no-signal synthetic — NOT a black screen)"
            )
        if frame_failed:
            reason.append(
                f"sample_frame failed error={frame_info.get('error')!r} "
                f"(instrument fault, not device)"
            )
        return emit_no_signal("; ".join(reason))

    # No DV lock and sample failed → instrument fault, not device black.
    if frame_failed and not dv.get("locked"):
        return emit_no_signal(
            f"sample_frame failed without DV lock "
            f"error={frame_info.get('error')!r}"
        )

    if frame_real or dv.get("locked"):
        print(
            f"VERDICT=SIGNAL_OK rc={RC_OK} "
            f"dv_locked={dv.get('locked')} frame_real={frame_real} "
            f"capture_path=LIVE"
        )
        return RC_OK

    print(
        f"VERDICT=UNSCORED rc={RC_UNSCORED} "
        f"reason=could_not_confirm_signal dv_locked={dv.get('locked')} "
        f"frame={frame_info}"
    )
    return RC_UNSCORED


if __name__ == "__main__":
    sys.exit(main())
