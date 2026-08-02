#!/usr/bin/env python3
"""Grabber pre-flight: is the HDMI capture path alive?

Parent incident: MacroSilicon unlocked (Active 0x0, pixelclock 0 Hz) produced
uniform pixel=7 frames. A new daemon deploy was nearly blamed. Run this BEFORE
any cast/capture session.

Exit codes (capture DIRECTLY: cmd; echo "true rc=$?" — never through a pipe):
  0   SIGNAL_OK — DV timings locked and/or sample frame is a real picture
  78  CAPTURE_NO_SIGNAL — unlocked or uniform no-signal frame
  77  UNSCORED — device busy / missing tools / cannot assess
  2   usage / self-test fail
  1   reserved — MUST NOT mean "grabber dead"; that is 78

CRITICAL: a dead grabber must print ACTION "do NOT rollback device software"
and exit 78. A traceback / rc=1 is a tool defect (parent 2026-08-02).

Does NOT touch the MiSTer device — host grabber only.

Self-test (host, no /dev/video0 required):
  python3 tools/grabber_preflight.py --self-test
  echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path
from typing import Any, Optional

RC_OK = 0
RC_NO_SIGNAL = 78
RC_UNSCORED = 77
RC_ERR = 2

DEFAULT_DEV = os.environ.get("HDMI_DEV", "/dev/video0")

ACTION_NO_SIGNAL = (
    "ACTION: re-plug HDMI into grabber / power-cycle MS2109; "
    "do NOT rollback device software on this symptom alone"
)


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


def query_dv_timings(dev: str) -> dict[str, Any]:
    rc, out, err = _run(["v4l2-ctl", f"--device={dev}", "--query-dv-timings"])
    text = out + err

    def _i(pat: str) -> Optional[int]:
        m = re.search(pat, text)
        return int(m.group(1)) if m else None

    active_w = _i(r"Active width:\s*(\d+)")
    active_h = _i(r"Active height:\s*(\d+)")
    pix: Optional[float] = None
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
        active_w is not None
        and active_h is not None
        and active_w > 0
        and active_h > 0
        and pix is not None
        and pix > 0
    )
    return {
        "rc": rc,
        "active_w": active_w,
        "active_h": active_h,
        "pixelclock_hz": pix,
        "locked": locked,
        "raw": text.strip()[:800],
        "src": "measured",
    }


def fuser_busy(dev: str) -> Optional[str]:
    _rc, out, err = _run(["fuser", "-v", dev], timeout=3.0)
    text = (out + err).strip()
    return text or None


def classify_png_path(path: Path) -> dict[str, Any]:
    """REAL capture-path core: PIL.Image.open + classify. NEVER raises.

    Parent bug: wrong import bound PIL.Image.Image *class* then called .open
    (class has no .open). Correct: `from PIL import Image` then Image.open.
    """
    try:
        import numpy as np
        from PIL import Image
    except ImportError as e:
        return {"ok": False, "error": f"numpy/PIL required: {e}"}

    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from hdmi_motion_instrument import classify_frame_signal  # noqa: WPS433
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"classify_import_fail: {e!r}"}

    try:
        rgb = np.asarray(Image.open(path).convert("RGB"))
        sig = classify_frame_signal(rgb)
        return {"ok": True, "path": str(path.name), **sig}
    except Exception as e:  # noqa: BLE001
        return {
            "ok": False,
            "error": f"classify_png_fail: {type(e).__name__}: {e}",
            "traceback": traceback.format_exc()[-500:],
        }


def sample_frame(dev: str, size: str = "1920x1080") -> dict[str, Any]:
    """Grab frames via ffmpeg; classify last. NEVER raises."""
    try:
        with tempfile.TemporaryDirectory(prefix="grabber_preflight_") as td:
            td_path = Path(td)
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
                str(td_path / "f_%02d.png"),
            ]
            rc, _o, err = _run(cmd, timeout=15.0)
            frames = sorted(td_path.glob("f_*.png"))
            if rc != 0 or not frames:
                busy = "Device or resource busy" in (err or "")
                return {
                    "ok": False,
                    "ffmpeg_rc": rc,
                    "error": (err or "").strip()[:300] or "no frames",
                    "busy": busy,
                }
            result = classify_png_path(frames[-1])
            result["n_grabbed"] = len(frames)
            result["ffmpeg_rc"] = rc
            return result
    except Exception as e:  # noqa: BLE001
        return {
            "ok": False,
            "error": f"sample_frame_uncaught: {type(e).__name__}: {e}",
            "traceback": traceback.format_exc()[-500:],
        }


def decide(
    *,
    dv: dict[str, Any],
    frame_info: Optional[dict[str, Any]],
    inject: Optional[dict[str, Any]] = None,
) -> tuple[str, int, str]:
    if inject is not None:
        amin = int(inject["min"])
        amax = int(inject["max"])
        std = float(inject["std"])
        nosig = amin == amax and std == 0.0
        if nosig:
            return (
                "CAPTURE_NO_SIGNAL",
                RC_NO_SIGNAL,
                f"inject uniform pixel={amin} std=0 (MacroSilicon no-signal synthetic "
                f"— NOT a black screen)",
            )
        return (
            "SIGNAL_OK",
            RC_OK,
            f"inject real-looking min={amin} max={amax} std={std}",
        )

    active_w = dv.get("active_w")
    active_h = dv.get("active_h")
    pix = dv.get("pixelclock_hz")
    unlocked = (
        dv.get("locked") is False
        or active_w == 0
        or active_h == 0
        or pix == 0
        or pix == 0.0
    )
    if active_w is None and active_h is None and pix is None and dv.get("rc", 0) != 0:
        unlocked = False

    frame_nosig = bool(frame_info and frame_info.get("ok") and frame_info.get("no_signal"))
    frame_real = bool(
        frame_info and frame_info.get("ok") and not frame_info.get("no_signal")
    )
    frame_failed = bool(frame_info and not frame_info.get("ok"))

    if unlocked or frame_nosig:
        parts = []
        if unlocked:
            parts.append(
                f"DV unlocked/zero active={active_w}x{active_h} pixelclock={pix}"
            )
        if frame_nosig:
            parts.append(
                f"sample uniform pixel={frame_info.get('pixel_min')} std="
                f"{frame_info.get('pixel_std')} (MacroSilicon no-signal synthetic "
                f"— NOT a black screen)"
            )
        return ("CAPTURE_NO_SIGNAL", RC_NO_SIGNAL, "; ".join(parts))

    if frame_real or dv.get("locked"):
        return (
            "SIGNAL_OK",
            RC_OK,
            f"dv_locked={dv.get('locked')} frame_real={frame_real}",
        )

    if frame_failed:
        return (
            "UNSCORED",
            RC_UNSCORED,
            f"frame_sample_failed error={frame_info.get('error')!r} "
            f"dv_locked={dv.get('locked')}",
        )

    return (
        "UNSCORED",
        RC_UNSCORED,
        f"could_not_confirm_signal dv_locked={dv.get('locked')} frame={frame_info}",
    )


def print_verdict(verdict: str, rc: int, reason: str) -> int:
    if verdict == "CAPTURE_NO_SIGNAL":
        print(
            f"VERDICT=CAPTURE_NO_SIGNAL rc={rc} "
            f"device_state=UNKNOWN capture_path=FAULT — {reason}"
        )
        print(ACTION_NO_SIGNAL)
    elif verdict == "SIGNAL_OK":
        print(f"VERDICT=SIGNAL_OK rc={rc} {reason} capture_path=LIVE")
    else:
        print(f"VERDICT={verdict} rc={rc} reason={reason}")
    return rc


def run_preflight(
    *,
    device: str,
    size: str,
    skip_frame: bool,
    inject_stats: Optional[str],
) -> int:
    """Full preflight. Never raises to caller."""
    try:
        if inject_stats:
            parts = [p.strip() for p in inject_stats.split(",")]
            if len(parts) != 3:
                print(
                    f"VERDICT=ERR rc={RC_ERR} reason=inject_stats_need_min_max_std",
                    file=sys.stderr,
                )
                return RC_ERR
            inj = {
                "min": float(parts[0]),
                "max": float(parts[1]),
                "std": float(parts[2]),
            }
            for k in ("min", "max"):
                if inj[k] == int(inj[k]):
                    inj[k] = int(inj[k])
            v, rc, reason = decide(dv={}, frame_info=None, inject=inj)
            return print_verdict(v, rc, reason)

        dev = device
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
        if not skip_frame:
            frame_info = sample_frame(dev, size=size)
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
                    f"(tool continues — DV timings still decide when unlocked)"
                )

        v, rc, reason = decide(dv=dv, frame_info=frame_info)
        return print_verdict(v, rc, reason)
    except Exception as e:  # noqa: BLE001
        print(
            f"VERDICT=UNSCORED rc={RC_UNSCORED} "
            f"reason=preflight_uncaught {type(e).__name__}: {e}",
            file=sys.stderr,
        )
        print(
            "NOTE: tool bug path — do NOT interpret as device fault; "
            "do NOT rollback software on this alone",
            file=sys.stderr,
        )
        traceback.print_exc(file=sys.stderr)
        return RC_UNSCORED


def _self_test() -> int:
    """RED if real classify/sample path raises; inject alone is not enough."""
    failures: list[str] = []

    # Detect the parent crash form: __import__(...).Image.open
    # (binds Image CLASS). Do not flag the detector string itself.
    import re as _re
    src_body = Path(__file__).read_text(encoding="utf-8")
    # strip the self-test function body from the audit window to avoid
    # matching the detector; audit production helpers only.
    prod = src_body.split("def _self_test")[0]
    if _re.search(r"__import__\s*\([^)]*PIL\.Image[^)]*\)\s*\.Image\s*\.open", prod):
        failures.append("forbidden_broken_PIL_import_form in production code")
    if "from PIL import Image" not in prod and "import PIL.Image" not in prod:
        # classify_png_path must use correct form
        if "Image.open" in prod:
            failures.append("Image.open used without from PIL import Image in prod")

    import io
    from contextlib import redirect_stdout, redirect_stderr

    buf = io.StringIO()
    err = io.StringIO()
    with redirect_stdout(buf), redirect_stderr(err):
        rc = run_preflight(
            device="/dev/null", size="64x64", skip_frame=True, inject_stats="7,7,0"
        )
    out = buf.getvalue()
    if rc != RC_NO_SIGNAL:
        failures.append(f"inject_nosig rc={rc} want 78")
    if "do NOT rollback" not in out:
        failures.append("inject_nosig missing ACTION do_NOT_rollback text")
    print("SELF_TEST inject_no_signal rc=78 ACTION present OK")

    buf = io.StringIO()
    with redirect_stdout(buf), redirect_stderr(err):
        rc = run_preflight(
            device="/dev/null", size="64x64", skip_frame=True, inject_stats="0,242,9.0"
        )
    if rc != RC_OK:
        failures.append(f"inject_real rc={rc} want 0")
    print("SELF_TEST inject_real rc=0 OK")

    try:
        import numpy as np
        from PIL import Image
    except ImportError as e:
        failures.append(f"PIL/numpy missing: {e}")
        print("SELF_TEST_FAIL", failures)
        return RC_ERR

    # Import this file as a module for patching _run
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "grabber_preflight_under_test", Path(__file__).resolve()
    )
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    with tempfile.TemporaryDirectory(prefix="gp_st_") as td:
        td_p = Path(td)
        uni = td_p / "uni.png"
        real = td_p / "real.png"
        Image.fromarray(np.full((64, 64, 3), 7, dtype=np.uint8)).save(uni)
        rr = np.zeros((64, 64, 3), dtype=np.uint8)
        rr[10:40, 10:40] = 200
        rr[0, 0] = 1
        Image.fromarray(rr).save(real)

        try:
            cu = mod.classify_png_path(uni)
        except Exception as e:  # noqa: BLE001
            failures.append(f"classify_png_uniform_RAISED {e!r}")
            cu = {"ok": False}
        try:
            cr = mod.classify_png_path(real)
        except Exception as e:  # noqa: BLE001
            failures.append(f"classify_png_real_RAISED {e!r}")
            cr = {"ok": False}

        if not cu.get("ok") or not cu.get("no_signal"):
            failures.append(f"uniform_classify {cu}")
        else:
            print("SELF_TEST classify_png uniform NO_SIGNAL OK")
        if not cr.get("ok") or cr.get("no_signal"):
            failures.append(f"real_classify {cr}")
        else:
            print("SELF_TEST classify_png real REAL_PICTURE OK")

        try:
            sf = mod.sample_frame("/dev/no_such_grabber_device_xx", size="64x64")
        except Exception as e:  # noqa: BLE001
            failures.append(f"sample_frame_RAISED_on_bad_dev {e!r}")
            sf = {}
        if sf.get("ok") is True:
            failures.append("sample_frame_ok_on_missing_dev")
        print("SELF_TEST sample_frame bad_dev no_raise OK")

        real_run = mod._run

        def fake_run(cmd: list[str], timeout: float = 8.0) -> tuple[int, str, str]:
            if cmd and cmd[0] == "ffmpeg":
                out_pat = cmd[-1]
                parent = Path(out_pat).parent
                parent.mkdir(parents=True, exist_ok=True)
                for i in range(1, 4):
                    Image.fromarray(np.full((32, 32, 3), 7, dtype=np.uint8)).save(
                        parent / f"f_{i:02d}.png"
                    )
                return 0, "", ""
            return real_run(cmd, timeout=timeout)

        mod._run = fake_run  # type: ignore[assignment]
        try:
            try:
                sf2 = mod.sample_frame("/dev/video0", size="32x32")
            except Exception as e:  # noqa: BLE001
                failures.append(f"sample_frame_mock_RAISED {e!r}")
                sf2 = {"ok": False}
        finally:
            mod._run = real_run  # type: ignore[assignment]

        if not sf2.get("ok") or not sf2.get("no_signal"):
            failures.append(f"mock_ffmpeg_sample {sf2}")
        else:
            print("SELF_TEST sample_frame mock_ffmpeg PIL.open path NO_SIGNAL OK")

        v, rc, _reason = mod.decide(
            dv={
                "active_w": 0,
                "active_h": 0,
                "pixelclock_hz": 0.0,
                "locked": False,
                "rc": 0,
            },
            frame_info=None,
        )
        if rc != RC_NO_SIGNAL:
            failures.append(f"decide_unlocked rc={rc}")
        else:
            print("SELF_TEST decide DV 0x0 → rc=78 OK")

        # DV unlocked + frame sample failed still → 78 (not crash, not rc=1)
        v, rc, _reason = mod.decide(
            dv={
                "active_w": 0,
                "active_h": 0,
                "pixelclock_hz": 0.0,
                "locked": False,
                "rc": 0,
            },
            frame_info={"ok": False, "error": "simulated"},
        )
        if rc != RC_NO_SIGNAL:
            failures.append(f"decide_unlocked_frame_fail rc={rc}")
        else:
            print("SELF_TEST decide unlocked+frame_fail → rc=78 OK")

    if failures:
        print("SELF_TEST_FAIL")
        for f in failures:
            print(f"  FAIL: {f}")
        return RC_ERR
    print("SELF_TEST_OK")
    return RC_OK


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--device", default=DEFAULT_DEV)
    ap.add_argument("--size", default="1920x1080")
    ap.add_argument("--skip-frame", action="store_true")
    ap.add_argument(
        "--inject-stats",
        default=None,
        help="min,max,std synthetic (e.g. 7,7,0); does NOT replace real-path self-test",
    )
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    return run_preflight(
        device=args.device,
        size=args.size,
        skip_frame=bool(args.skip_frame),
        inject_stats=args.inject_stats,
    )


if __name__ == "__main__":
    sys.exit(main())
