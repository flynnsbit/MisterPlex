#!/usr/bin/env python3
"""Self-checking audio marker: index + checksum in the PCM (not a bare click).

Contract (caller_supplied design constants — see docs/audio_frame_id_contract.md)
==============================================================================
Each marker is an FSK *packet* locked to content time t_k = k * PERIOD_S, which
equals video frame n_k = round(t_k * FPS) at FPS=24/1.

Packet layout (all tones pure sine, stereo identical):
  1) PREAMBLE  PREAMBLE_S @ F_PREAMBLE_HZ   (sync / AGC)
  2) GAP       GAP_S silence
  3) 20 bits MSB-first, each BIT_S long:
        bit=0 → F0_HZ    bit=1 → F1_HZ
     bits[0:16]  = payload = (n & 0xFFFF)   # video frame index low 16 bits
     bits[16:20] = checksum nibble
  4) checksum = (nibble0+nibble1+nibble2+nibble3) & 0xF
     where payload is split into 4 nibbles MSB-first

Why not a bare click: a click cannot tell *which* event you found; mis-detection
is silent. Checksum makes invalid packets UNRESOLVED (same role as video c=D).

Time resolution / sampling margin (DERIVED, not HDMI-measured)
-------------------------------------------------------------
- Onset: 1 ms linear attack on preamble; detect via Goertzel/energy hop 1 ms
  → onset resolution ≈ 1–2 ms on file (matches beep path).
- AAC LC frame @ 48 kHz ≈ 1024/48000 = 21.333 ms.
- BIT_S = 64 ms = 3.0 AAC frames → positive margin of ~2 full AAC frames of
  steady tone after windowing/overlap. (ERROR 18/19: never ship markers with
  zero/negative sampling margin vs the observation grid.)
- Packet duration ≈ PREAMBLE+GAP+20*BIT = 0.08+0.01+1.28 = 1.37 s.
- PERIOD_S = 2.0 s → 0.63 s quiet between packets (no overlap).

A/V lock: packet start sample i = round(t_k * SR) coincides with video marker
frame n_k (body flash thr-cross at same t_k when paired with glass sync video).

Sign convention (same as avsync_measure_hdmi):
  offset_ms = (t_audio_packet_onset - t_video_flash) * 1000
"""
from __future__ import annotations

import math
import struct
from dataclasses import dataclass
from typing import Any

import numpy as np

# ---- design constants (caller_supplied) ----
SR = 48000
FPS_NUM = 24
FPS_DEN = 1
PERIOD_S = 2.0

F_PREAMBLE_HZ = 2500.0
F0_HZ = 1000.0
F1_HZ = 1600.0

PREAMBLE_S = 0.080
GAP_S = 0.010
BIT_S = 0.064  # 64 ms = 3 * 1024/48000
ATTACK_S = 0.001
N_PAYLOAD_BITS = 16
N_CHECK_BITS = 4
N_BITS = N_PAYLOAD_BITS + N_CHECK_BITS  # 20

AMP = 0.85


def fps() -> float:
    return FPS_NUM / float(FPS_DEN)


def packet_duration_s() -> float:
    return PREAMBLE_S + GAP_S + N_BITS * BIT_S


def aac_frame_s(sr: int = SR, frame_n: int = 1024) -> float:
    return frame_n / float(sr)


def sampling_margin_report() -> dict[str, Any]:
    aac = aac_frame_s()
    return {
        "aac_frame_ms": aac * 1000.0,
        "aac_frame_ms_src": "caller_supplied_1024/48000",
        "bit_s_ms": BIT_S * 1000.0,
        "bit_in_aac_frames": BIT_S / aac,
        "margin_aac_frames_beyond_one": BIT_S / aac - 1.0,
        "onset_attack_ms": ATTACK_S * 1000.0,
        "onset_hop_design_ms": 1.0,
        "packet_duration_s": packet_duration_s(),
        "period_s": PERIOD_S,
        "quiet_gap_between_packets_s": PERIOD_S - packet_duration_s(),
        "note": "BIT_S chosen for ≥2 AAC frames of steady tone (positive margin)",
        "src": "caller_supplied_derived",
    }


def checksum_nibble(payload_u16: int) -> int:
    """4-bit checksum: sum of 4 MSB-first nibbles of payload, mod 16."""
    p = int(payload_u16) & 0xFFFF
    s = 0
    for shift in (12, 8, 4, 0):
        s += (p >> shift) & 0xF
    return s & 0xF


def bits_for_frame_n(n: int) -> list[int]:
    payload = int(n) & 0xFFFF
    c = checksum_nibble(payload)
    word = (payload << N_CHECK_BITS) | c
    bits = []
    for i in range(N_BITS - 1, -1, -1):  # MSB first
        bits.append((word >> i) & 1)
    return bits


def frame_n_from_bits(bits: list[int]) -> tuple[bool, int | None, str]:
    if len(bits) != N_BITS:
        return False, None, "bad_len"
    word = 0
    for b in bits:
        word = (word << 1) | (int(b) & 1)
    payload = (word >> N_CHECK_BITS) & 0xFFFF
    c_got = word & 0xF
    c_exp = checksum_nibble(payload)
    if c_got != c_exp:
        return False, None, f"bad_checksum got={c_got} exp={c_exp}"
    return True, payload, "ok"


def _sine_block(n_samp: int, freq: float, sr: int, phase0: float = 0.0) -> tuple[np.ndarray, float]:
    t = (np.arange(n_samp, dtype=np.float64) / sr)
    ph = phase0 + 2.0 * math.pi * freq * t
    # continuous phase end
    phase1 = float(phase0 + 2.0 * math.pi * freq * (n_samp / sr))
    return np.sin(ph), phase1


def render_packet(n: int, sr: int = SR) -> np.ndarray:
    """Float64 mono packet for frame index n, amplitude AMP, 1 ms attack on preamble."""
    bits = bits_for_frame_n(n)
    parts: list[np.ndarray] = []
    phase = 0.0
    # preamble
    n_pre = int(round(PREAMBLE_S * sr))
    pre, phase = _sine_block(n_pre, F_PREAMBLE_HZ, sr, phase)
    att = int(round(ATTACK_S * sr))
    env = np.ones(n_pre, dtype=np.float64)
    if att > 0:
        env[:att] = np.linspace(0.0, 1.0, att, endpoint=False)
    parts.append(pre * env * AMP)
    # gap
    n_gap = int(round(GAP_S * sr))
    parts.append(np.zeros(n_gap, dtype=np.float64))
    phase = 0.0
    # bits
    n_bit = int(round(BIT_S * sr))
    for b in bits:
        freq = F1_HZ if b else F0_HZ
        blk, phase = _sine_block(n_bit, freq, sr, 0.0)
        parts.append(blk * AMP)
    return np.concatenate(parts)


def marker_times(duration_s: float, period_s: float = PERIOD_S) -> list[tuple[int, float]]:
    """List of (frame_n, t_s) for each marker with t < duration_s."""
    f = fps()
    out = []
    k = 0
    while True:
        t = k * period_s
        if t >= duration_s - 1e-9:
            break
        n = int(round(t * f))
        out.append((n, t))
        k += 1
    return out


def synthesize_pcm(
    duration_s: float,
    *,
    period_s: float = PERIOD_S,
    audio_delay_s: float = 0.0,
    sr: int = SR,
) -> tuple[np.ndarray, list[dict[str, Any]]]:
    """Mono float PCM with packets at t_k + audio_delay_s. Returns (pcm, meta list)."""
    n_total = int(round(duration_s * sr))
    pcm = np.zeros(n_total, dtype=np.float64)
    meta = []
    for n, t in marker_times(duration_s, period_s):
        t_a = t + audio_delay_s
        if t_a < 0 or t_a >= duration_s:
            continue
        i0 = int(round(t_a * sr))
        pkt = render_packet(n, sr)
        i1 = min(n_total, i0 + pkt.size)
        if i0 >= n_total:
            continue
        pcm[i0:i1] += pkt[: i1 - i0]
        meta.append({
            "frame_n": n,
            "t_video_s": t,
            "t_audio_onset_s_designed": t_a,
            "sample_i0": i0,
            "checksum": checksum_nibble(n & 0xFFFF),
            "bits": bits_for_frame_n(n),
        })
    # clip
    np.clip(pcm, -1.0, 1.0, out=pcm)
    return pcm, meta


def write_pcm_s16le_stereo(path, pcm_mono: np.ndarray) -> None:
    with open(path, "wb") as f:
        for x in pcm_mono:
            v = int(max(-32767, min(32767, round(x * 32767))))
            f.write(struct.pack("<hh", v, v))


# ---- decoder ----
def goertzel_power(block: np.ndarray, sr: int, freq: float) -> float:
    n = block.size
    if n == 0:
        return 0.0
    k = int(0.5 + (n * freq) / sr)
    w = 2.0 * math.pi * k / n
    coeff = 2.0 * math.cos(w)
    s0 = s1 = s2 = 0.0
    for x in block:
        s0 = float(x) + coeff * s1 - s2
        s2 = s1
        s1 = s0
    return float(s1 * s1 + s2 * s2 - coeff * s1 * s2) / (n * n)


@dataclass
class DecodePacket:
    ok: bool
    n: int | None
    status: str
    reason: str
    t_onset_s: float | None = None
    bits: list[int] | None = None
    checksum_ok: bool | None = None
    src: str = "measured"


def detect_preamble_onsets(
    pcm: np.ndarray,
    sr: int = SR,
    *,
    hop_s: float = 0.001,
    min_sep_s: float = 1.0,
) -> tuple[list[float], dict[str, Any]]:
    """Energy at F_PREAMBLE via Goertzel on hop windows; thr mid floor/peak."""
    hop = max(1, int(round(hop_s * sr)))
    win = max(hop, int(round(0.008 * sr)))  # 8 ms analysis window
    n_h = max(0, (pcm.size - win) // hop)
    if n_h < 4:
        return [], {"reason": "short"}
    env = np.zeros(n_h, dtype=np.float64)
    for i in range(n_h):
        block = pcm[i * hop : i * hop + win]
        env[i] = goertzel_power(block, sr, F_PREAMBLE_HZ)
    floor = float(np.percentile(env, 20))
    peak = float(np.percentile(env, 99.5))
    contrast = peak - floor
    meta = {
        "floor": floor, "peak": peak, "contrast": contrast,
        "hop_s": hop / sr, "win_s": win / sr, "src": "measured",
    }
    if contrast <= 0 or peak < 1e-12:
        meta["reason"] = "no_preamble_energy"
        return [], meta
    thr = floor + 0.35 * contrast
    meta["thr"] = thr
    hot = env > thr
    onsets: list[float] = []
    i = 0
    while i < hot.size:
        if not hot[i]:
            i += 1
            continue
        if i == 0 or not hot[i - 1]:
            if i == 0:
                ts = 0.0
            else:
                y0, y1 = float(env[i - 1]), float(env[i])
                t0, t1 = (i - 1) * hop / sr, i * hop / sr
                if y1 > y0:
                    frac = max(0.0, min(1.0, (thr - y0) / (y1 - y0)))
                    ts = t0 + frac * (t1 - t0)
                else:
                    ts = t1
            if not onsets or (ts - onsets[-1]) >= min_sep_s:
                onsets.append(ts)
        while i < hot.size and hot[i]:
            i += 1
    meta["n_onsets"] = len(onsets)
    return onsets, meta


def decode_packet_at(
    pcm: np.ndarray,
    t_onset_s: float,
    sr: int = SR,
) -> DecodePacket:
    """Decode FSK bits starting at preamble onset time."""
    i0 = int(round(t_onset_s * sr))
    # skip preamble + gap
    i_bits = i0 + int(round((PREAMBLE_S + GAP_S) * sr))
    n_bit = int(round(BIT_S * sr))
    bits: list[int] = []
    for b in range(N_BITS):
        a = i_bits + b * n_bit
        # center 50% of bit to avoid transitions
        m = n_bit // 4
        block = pcm[a + m : a + n_bit - m]
        if block.size < 8:
            return DecodePacket(False, None, "UNRESOLVED", "short_bit", t_onset_s, src="measured")
        p0 = goertzel_power(block, sr, F0_HZ)
        p1 = goertzel_power(block, sr, F1_HZ)
        bits.append(1 if p1 > p0 else 0)
    ok, n, reason = frame_n_from_bits(bits)
    if not ok:
        return DecodePacket(False, None, "UNRESOLVED", reason, t_onset_s, bits, False, src="measured")
    return DecodePacket(True, n, "OK", "checksum_ok", t_onset_s, bits, True, src="measured")


def decode_all(
    pcm: np.ndarray,
    sr: int = SR,
    *,
    period_s: float = PERIOD_S,
) -> tuple[list[DecodePacket], dict[str, Any]]:
    onsets, ometa = detect_preamble_onsets(pcm, sr, min_sep_s=period_s * 0.5)
    pkts = [decode_packet_at(pcm, t, sr) for t in onsets]
    meta = {
        "preamble": ometa,
        "n_ok": sum(1 for p in pkts if p.ok),
        "n_fail": sum(1 for p in pkts if not p.ok),
        "n_onsets": len(onsets),
    }
    return pkts, meta


def contract_dict() -> dict[str, Any]:
    ex_n = 2358
    return {
        "sr": SR,
        "fps": f"{FPS_NUM}/{FPS_DEN}",
        "period_s": PERIOD_S,
        "f_preamble_hz": F_PREAMBLE_HZ,
        "f0_hz": F0_HZ,
        "f1_hz": F1_HZ,
        "preamble_s": PREAMBLE_S,
        "gap_s": GAP_S,
        "bit_s": BIT_S,
        "n_bits": N_BITS,
        "payload": "bits[0:16] = n & 0xFFFF MSB-first",
        "checksum": "bits[16:20] = (sum of 4 nibbles of payload) & 0xF",
        "example_n_2358": {
            "bits": bits_for_frame_n(ex_n),
            "checksum": checksum_nibble(ex_n),
            "packet_duration_s": packet_duration_s(),
        },
        "sampling_margin": sampling_margin_report(),
        "doc": "docs/audio_frame_id_contract.md",
        "src": "caller_supplied",
    }


if __name__ == "__main__":
    import json
    print(json.dumps(contract_dict(), indent=2))
