#!/usr/bin/env python3
"""Pin the media-player A/V observability needed by external measurements."""
from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MEDIA = (ROOT / "arm" / "misterplexd" / "media_player.cpp").read_text()
MAIN = (ROOT / "arm" / "misterplexd" / "main.cpp").read_text()
FPGA = (ROOT / "arm" / "misterplexd" / "fpga_spi.cpp").read_text()
LAYOUT = (ROOT / "host" / "libmisterplex" / "ddr_frame_layout.hpp").read_text()
MAILBOX = (ROOT / "host" / "libmisterplex" / "input_mailbox.hpp").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    require(
        'content fps exact=%d/%d' in MAIN,
        "resolver log must preserve the exact rational numerator/denominator",
    )
    require(
        re.search(r'content fps=" \+ std::to_string\(fpsNum\).*std::to_string\(fpsDen\)', MEDIA, re.S)
        is not None,
        "present-loop startup log must include exact rational fps",
    )
    require(
        '" fps=" + std::to_string(fpsNum) + "/" + std::to_string(fpsDen)' in MEDIA,
        "periodic playback log must include exact rational fps",
    )
    require(
        MEDIA.count('" av_drift_ms=" + std::to_string(avDriftMs_.load())') >= 2
        and MEDIA.count('" drops=" + std::to_string(droppedFrames_.load())') >= 2,
        "both present paths must log live drift and cumulative drops",
    )
    require(
        '"media: A/V resync drop drift_ms=" + std::to_string(avDriftMs_.load())' in MEDIA,
        "drop log must carry the measured drift",
    )
    require(
        '"media: audio latency " + std::to_string(latMs) + "ms queued=" +' in MEDIA,
        "MrAudio log must expose both latency and queued bytes",
    )
    require(
        re.search(
            r"misterplex::audibleClockMs\(audioBytes_\.load\(\),\s*"
            r"audioQueuedBytes_\.load\(\)\)",
            MEDIA,
        )
        is not None,
        "video clock must subtract the measured MrAudio queue depth",
    )
    require(
        '"media: A/V origin armed audio_active=" +' in MEDIA,
        "startup log must show whether the audible clock was armed",
    )
    require(
        '"fps=" + std::to_string(fpsNum_) + "/" + std::to_string(fpsDen_) + ","' in MEDIA,
        "FFmpeg CFR filter must receive the exact rational source rate",
    )
    require(
        "isPlex480pDdrFrameGeometry" in LAYOUT and
        "true480Pipeline" in MEDIA and
        "DdrBankWritePolicy::RequireReleased" in MEDIA,
        "strict bank-release policy must be geometry-gated to exact true480",
    )
    require(
        re.search(
            r"frameContentUs\(slotFrameIndex,\s*fpsNum,\s*fpsDen\)",
            MEDIA,
        ) is not None
        and re.search(
            r"audibleClockUs\(audioBytes_\.load\(\),\s*"
            r"audioQueuedBytes_\.load\(\)\)",
            MEDIA,
        ) is not None,
        "true480 pipeline must use exact-rate microsecond audible-clock eligibility",
    )
    require(
        "kPlxdWaitMaxUs = 50000" in FPGA
        and "PLXD timeout waiting for frames_done advance" in FPGA
        and "PLXD acknowledgement required but unavailable" in FPGA,
        "strict PLXD path must wait boundedly and fail closed before DDR writes",
    )
    require(
        "status.frames_done != frames_done" in MAILBOX
        and "decideDdrBankWrite(brs, policy, strictDdrRelease_)" in FPGA
        and "strictDdrRelease_.beginWrite()" in FPGA
        and "strictDdrRelease_.noteWrite(postKickStatus)" in FPGA
        and "strict PLXD post-kick frames_done unavailable" in FPGA,
        "strict PLXD writes must reject stale free masks until frames_done advances",
    )
    require(
        FPGA.index("strictDdrRelease_.beginWrite()")
        < FPGA.index("kickDdrDoorbell(bank)")
        < FPGA.index("strictDdrRelease_.noteWrite(postKickStatus)"),
        "strict frames_done baseline must be captured after the doorbell, not before copy/kick",
    )
    require(
        FPGA.count("strictDdrRelease_.reset()") >= 4
        and re.search(
            r"void FpgaSpi::releaseDdrMap\(\).*?strictDdrRelease_\.reset\(\)",
            FPGA,
            re.S,
        ) is not None
        and re.search(
            r"wrote && \(word\[0\] & 0x01u\).*?strictDdrRelease_\.reset\(\)",
            FPGA,
            re.S,
        ) is not None,
        "strict PLXD baseline must clear on reset, reprobe, and DDR remap/layout change",
    )
    require(
        "true480PipelineAborted = pipelineFatal.load()" in MEDIA
        and "lastSummary_.true480PipelineAborted = true480PipelineAborted" in MEDIA
        and re.search(
            r"classifyPlaybackTerminalState\(\s*stop_\.load\(\),\s*"
            r"true480PipelineAborted,\s*hadContent\)",
            MEDIA,
        ) is not None
        and 'terminal == PlaybackTerminalState::Stopped' in MEDIA,
        "strict true480 pipeline abort must survive teardown as stopped/non-auto-next",
    )
    require(
        re.search(r'if\s*\(hadContent\)\s*onProgress_\("ended"', MEDIA) is None,
        "hadContent alone must never classify a failed true480 pipeline as ended",
    )
    print("test_av_logging_contract: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
