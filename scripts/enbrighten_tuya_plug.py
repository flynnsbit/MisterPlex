#!/usr/bin/env python3
"""Local control for Enbrighten (Tuya OEM) Wi-Fi plug powering the MiSTer.

Requires: tinytuya, and env ENBRIGHTEN_DEVICE_ID + ENBRIGHTEN_LOCAL_KEY
(see Memory/lab/ops/ENBRIGHTEN_POWER_PLUG_MISTER.md).
"""
from __future__ import annotations

import argparse
import os
import sys
import time


def _env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None or v == "":
        raise SystemExit(f"missing env {name} (see Memory/lab/ops/ENBRIGHTEN_POWER_PLUG_MISTER.md)")
    return v


def plug_ip() -> str:
    return os.environ.get("ENBRIGHTEN_IP", "192.168.1.91")


def _http_cmnd(cmnd: str, timeout: float = 5.0) -> str:
    """OpenBeken / Tasmota HTTP after cloudcutter flash (no Tuya local key)."""
    import urllib.error
    import urllib.parse
    import urllib.request

    ip = plug_ip()
    ports = [int(p) for p in os.environ.get("ENBRIGHTEN_HTTP_PORTS", "80,8080,81").split(",") if p.strip()]
    last = None
    for port in ports:
        url = f"http://{ip}:{port}/cm?cmnd={urllib.parse.quote(cmnd)}"
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                body = r.read().decode("utf-8", "replace")
                print(f"HTTP {cmnd} -> {url} {body[:200]}")
                return body
        except Exception as e:
            last = e
            continue
    raise SystemExit(
        f"OpenBeken HTTP failed for {cmnd!r} on {ip} ports={ports}: {type(last).__name__}: {last}\n"
        "flash-enbrighten.sh installed OpenBeken; tinytuya keys are unused after that flash."
    )


def make_device():
    # Post-flash path: OpenBeken HTTP. Tuya keys only if HTTP is down AND keys are set.
    http_first = os.environ.get("ENBRIGHTEN_TRANSPORT", "http").lower() != "tuya"
    if http_first:
        return None
    try:
        import tinytuya
    except ImportError as e:
        raise SystemExit(
            "tinytuya not installed. Example:\n"
            "  uv venv ~/tuya-venv && uv pip install --python ~/tuya-venv/bin/python tinytuya\n"
            f"import error: {e}"
        ) from e

    dev_id = _env("ENBRIGHTEN_DEVICE_ID")
    ip = plug_ip()
    key = _env("ENBRIGHTEN_LOCAL_KEY")
    ver = float(os.environ.get("ENBRIGHTEN_VERSION", "3.3"))
    d = tinytuya.OutletDevice(dev_id, ip, key)
    d.set_version(ver)
    d.set_socketTimeout(5)
    return d


def switch_dps() -> int:
    return int(os.environ.get("ENBRIGHTEN_SWITCH_DPS", "1"))


def cmd_status(_: argparse.Namespace) -> int:
    d = make_device()
    if d is None:
        _http_cmnd("Power")
        return 0
    st = d.status()
    print(st)
    return 0 if isinstance(st, dict) and "Error" not in st else 1


def cmd_on(_: argparse.Namespace) -> int:
    d = make_device()
    if d is None:
        _http_cmnd("Power On")
        return 0
    r = d.set_status(True, switch_dps())
    print(r)
    return 0


def cmd_off(_: argparse.Namespace) -> int:
    d = make_device()
    if d is None:
        _http_cmnd("Power Off")
        return 0
    r = d.set_status(False, switch_dps())
    print(r)
    return 0


def cmd_cycle(args: argparse.Namespace) -> int:
    d = make_device()
    if d is None:
        print("OFF", _http_cmnd("Power Off"), flush=True)
        time.sleep(max(1.0, float(args.off_secs)))
        print("ON", _http_cmnd("Power On"), flush=True)
        return 0
    dps = switch_dps()
    print("OFF", d.set_status(False, dps), flush=True)
    time.sleep(max(1.0, float(args.off_secs)))
    print("ON", d.set_status(True, dps), flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Enbrighten/Tuya local plug control (MiSTer AC)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="Query plug status/DPS").set_defaults(func=cmd_status)
    sub.add_parser("on", help="Turn outlet ON").set_defaults(func=cmd_on)
    sub.add_parser("off", help="Turn outlet OFF").set_defaults(func=cmd_off)
    c = sub.add_parser("cycle", help="OFF, wait, ON")
    c.add_argument("--off-secs", type=float, default=8.0, help="Seconds off before ON (default 8)")
    c.set_defaults(func=cmd_cycle)
    args = p.parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
