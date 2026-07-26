#!/usr/bin/env python3
"""Inject key sequences into MiSTer via /dev/uinput (run ON the MiSTer).

Used to drive the Plex core OSD from CI/lab automation: MiSTer_cmd has no key
injection, so the only way to exercise the real user path (Main_MiSTer parses
CONF_STR -> user turns a knob -> status word changes -> misterplexd applies it)
is to present a virtual keyboard.

usage: osd_keys.py f12 down down down enter esc
       osd_keys.py --hold 20 f12          # leave the device alive for a capture
"""
import ctypes
import fcntl
import os
import struct
import sys
import time

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_SYN, EV_KEY = 0, 1

KEYS = {
    "f12": 88, "esc": 1, "enter": 28, "up": 103, "down": 108,
    "left": 105, "right": 106, "space": 57,
}


def main(argv):
    hold = 0.0
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--hold":
            hold = float(argv[i + 1])
            i += 2
            continue
        args.append(argv[i])
        i += 1

    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for k in range(1, 128):
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    name = b"plex-osd-keys".ljust(80, b"\0")
    os.write(fd, name + struct.pack("HHHH", 3, 0x1234, 0x5678, 1) +
             struct.pack("i", 0) + b"\0" * (4 * 64 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    # Main_MiSTer discovers new input devices via inotify and re-enumerates; keys
    # sent before that lands are dropped on the floor.
    time.sleep(6.0)

    def ev(t, c, v):
        os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))

    for a in args:
        code = KEYS.get(a.lower())
        if code is None:
            print("unknown key: %s" % a, file=sys.stderr)
            continue
        ev(EV_KEY, code, 1)
        ev(EV_SYN, 0, 0)
        time.sleep(0.12)
        ev(EV_KEY, code, 0)
        ev(EV_SYN, 0, 0)
        time.sleep(0.45)

    if hold:
        time.sleep(hold)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)
    print("sent: %s" % " ".join(args))


if __name__ == "__main__":
    main(sys.argv[1:])
