#!/usr/bin/env python3
"""Reject libav archives that load host glibc modules from a static ARM binary."""
import argparse
from pathlib import Path
import subprocess
import sys


ARCHIVES = ("libavformat.a", "libavcodec.a", "libavutil.a", "libswresample.a")
REQUIRED = {
    "ff_file_protocol", "ff_http_protocol", "ff_tcp_protocol",
    "ff_mpegts_demuxer", "ff_hls_demuxer", "ff_aac_decoder", "ff_h264_parser",
    "ff_h264_mp4toannexb_bsf", "swr_init",
}
MODULE_LOADERS = {
    "iconv", "iconv_open", "iconv_close",
    "libiconv", "libiconv_open", "libiconv_close",
    "__gconv", "__gconv_open", "__gconv_find_shlib",
    "dlopen", "dlmopen", "__libc_dlopen_mode",
}


class Refused(RuntimeError):
    pass


def check_archives(prefix, nm):
    archives = [Path(prefix) / "lib" / name for name in ARCHIVES]
    if not all(path.is_file() for path in archives):
        raise Refused("all four ARM libav archives are required")
    result = subprocess.run([nm, "-g", *map(str, archives)], capture_output=True, text=True)
    if result.returncode:
        raise Refused("cannot inspect ARM libav archive symbols")
    defined = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 2 or len(fields[-2]) != 1:
            continue
        kind, symbol = fields[-2], fields[-1].split("@", 1)[0]
        if symbol in MODULE_LOADERS:
            raise Refused("libav references a runtime module loader; rebuild with --disable-iconv")
        if kind not in ("U", "w", "v"):
            defined.add(symbol)
    if not REQUIRED <= defined:
        raise Refused("ARM libav lacks required HTTP/HLS/MPEGTS/H.264/AAC/PCM support")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--nm", default="nm")
    args = parser.parse_args()
    try:
        check_archives(args.prefix, args.nm)
    except (OSError, Refused) as error:
        print("ARM_FFMPEG_REFUSED " + str(error), file=sys.stderr)
        return 1
    print("ARM_FFMPEG_STATIC_SAFE HTTP/HLS/MPEGTS/H264/AAC/PCM; no iconv/module-loader symbols")
    return 0


if __name__ == "__main__":
    sys.exit(main())
