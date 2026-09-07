#!/usr/bin/env python3
"""Generate only the eight bounded 240p experiments; larger caps stay unadvertised."""
from pathlib import Path
import xml.etree.ElementTree as ET


def profile(prototype, rate, filtering):
    name = f"MiSTerPlex-FPGA-{prototype}-240p-{rate}-{filtering}"
    client = ET.Element("Client", name=name)
    targets = ET.SubElement(client, "TranscodeTargets")
    video = ET.SubElement(targets, "VideoProfile", protocol="http", container="mpegts",
                          codec="h264", audioCodec="aac", context="streaming")
    keyint = 1 if prototype == "IDR" else 24
    fps = "24" if rate == "24" else "24000/1001"
    opts = ("cabac=0:bframes=0:ref=1:weightp=0:8x8dct=0:partitions=none:"
            f"keyint={keyint}:min-keyint={keyint}:scenecut=0:open-gop=0:"
            "intra-refresh=0:threads=1:sliced-threads=0:slices=1:"
            "vbv-maxrate=4000:vbv-bufsize=1000:qpmin=10:qpmax=40:"
            f"no-deblock={int(filtering == 'filter-off')}")
    ET.SubElement(video, "Setting", name="VideoEncodeFlags",
                  value=f"-c:v libx264 -profile:v baseline -level 3.0 -r {fps} -x264opts {opts}")
    ET.SubElement(video, "Setting", name="SubtitleSize", value="100")
    codecs = ET.SubElement(client, "CodecProfiles")
    limits = ET.SubElement(ET.SubElement(codecs, "VideoCodec", name="*"), "Limitations")
    for field, value in (("width", "320"), ("height", "240"), ("frameRate", "24"),
                         ("bitDepth", "8")):
        ET.SubElement(limits, "UpperBound", name=f"video.{field}", value=value,
                      isRequired="true")
    target = ET.SubElement(ET.SubElement(client, "TranscodeTargetProfiles"),
                           "VideoTranscodeTarget", protocol="http", context="streaming")
    for parent in (codecs, target):
        limits = ET.SubElement(ET.SubElement(parent, "VideoCodec", name="h264"),
                               "Limitations")
        ET.SubElement(limits, "Match", name="video.profile", list="baseline", isRequired="true")
        for field, value in (("level", "30"), ("refFrames", "1")):
            ET.SubElement(limits, "UpperBound", name=f"video.{field}", value=value,
                          isRequired="true")
        limits = ET.SubElement(ET.SubElement(parent, "VideoAudioCodec", name="aac"),
                               "Limitations")
        ET.SubElement(limits, "UpperBound", name="audio.channels", value="2",
                      isRequired="true")
    ET.indent(client, space="  ")
    return name, ET.tostring(client, encoding="unicode") + "\n"


if __name__ == "__main__":
    for prototype in ("IDR", "IP"):
        for rate in ("24", "23976"):
            for filtering in ("filter-on", "filter-off"):
                name, text = profile(prototype, rate, filtering)
                (Path(__file__).parent / f"{name}.xml").write_text(
                    '<?xml version="1.0" encoding="utf-8"?>\n' + text)
