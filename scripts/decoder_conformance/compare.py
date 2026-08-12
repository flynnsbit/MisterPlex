"""Bit-exact ARM-oracle vs fabric output compare with first-divergence RCA.

A bare "mismatch" wastes days. Report MB index, component, sample coords,
linear offset, expected vs actual on the first disagreeing sample.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass(frozen=True)
class CompareResult:
    ok: bool
    width: int
    height: int
    stage: str
    format: str
    arm_bytes: int
    rtl_bytes: int
    # divergence fields (valid when ok is False and sizes matched)
    mb_index: Optional[int] = None
    mb_x: Optional[int] = None
    mb_y: Optional[int] = None
    component: Optional[str] = None  # Y|U|V|RAW
    sample_x: Optional[int] = None
    sample_y: Optional[int] = None
    offset: Optional[int] = None
    expected: Optional[int] = None
    actual: Optional[int] = None
    reason: str = ""

    def summary_line(self) -> str:
        if self.ok:
            return (
                f"BITEXACT_OK stage={self.stage or '-'} format={self.format} "
                f"{self.width}x{self.height} bytes={self.arm_bytes}"
            )
        return format_first_divergence(self)


def format_first_divergence(r: CompareResult) -> str:
    if r.ok:
        return r.summary_line()
    if r.reason and r.offset is None:
        return (
            f"BITEXACT_FAIL stage={r.stage or '-'} format={r.format} "
            f"reason={r.reason} arm_bytes={r.arm_bytes} rtl_bytes={r.rtl_bytes}"
        )
    return (
        f"BITEXACT_FAIL stage={r.stage or '-'} format={r.format} "
        f"first_divergence mb_index={r.mb_index} mb_x={r.mb_x} mb_y={r.mb_y} "
        f"component={r.component} sample_x={r.sample_x} sample_y={r.sample_y} "
        f"offset={r.offset} expected=0x{(r.expected or 0):02x} "
        f"actual=0x{(r.actual or 0):02x}"
    )


def _i420_sizes(width: int, height: int) -> tuple[int, int, int, int]:
    if width <= 0 or height <= 0 or (width % 2) or (height % 2):
        raise ValueError(f"I420 geometry must be positive even WxH, got {width}x{height}")
    y = width * height
    c = (width // 2) * (height // 2)
    total = y + 2 * c
    return y, c, c, total


def compare_bytes(
    arm: bytes,
    rtl: bytes,
    *,
    stage: str = "",
    fmt: str = "raw",
) -> CompareResult:
    """Raw byte compare; first divergence as RAW offset (no MB geometry)."""
    if len(arm) != len(rtl):
        return CompareResult(
            ok=False,
            width=0,
            height=0,
            stage=stage,
            format=fmt,
            arm_bytes=len(arm),
            rtl_bytes=len(rtl),
            reason="size_mismatch",
        )
    for i, (a, b) in enumerate(zip(arm, rtl)):
        if a != b:
            return CompareResult(
                ok=False,
                width=0,
                height=0,
                stage=stage,
                format=fmt,
                arm_bytes=len(arm),
                rtl_bytes=len(rtl),
                mb_index=None,
                mb_x=None,
                mb_y=None,
                component="RAW",
                sample_x=i,
                sample_y=0,
                offset=i,
                expected=a,
                actual=b,
            )
    return CompareResult(
        ok=True,
        width=0,
        height=0,
        stage=stage,
        format=fmt,
        arm_bytes=len(arm),
        rtl_bytes=len(rtl),
    )


def compare_i420(
    arm: bytes,
    rtl: bytes,
    width: int,
    height: int,
    *,
    stage: str = "",
) -> CompareResult:
    """Planar I420/YUV420p bit-exact compare with MB-localised first divergence."""
    try:
        y_sz, u_sz, v_sz, total = _i420_sizes(width, height)
    except ValueError as e:
        return CompareResult(
            ok=False,
            width=width,
            height=height,
            stage=stage,
            format="i420",
            arm_bytes=len(arm),
            rtl_bytes=len(rtl),
            reason=str(e),
        )

    if len(arm) != total or len(rtl) != total:
        return CompareResult(
            ok=False,
            width=width,
            height=height,
            stage=stage,
            format="i420",
            arm_bytes=len(arm),
            rtl_bytes=len(rtl),
            reason=(
                f"size_mismatch want={total} "
                f"(Y={y_sz}+U={u_sz}+V={v_sz}) arm={len(arm)} rtl={len(rtl)}"
            ),
        )

    mb_w = (width + 15) // 16

    def locate(offset: int) -> tuple[str, int, int, int, int, int]:
        """component, sample_x, sample_y, mb_x, mb_y, mb_index"""
        if offset < y_sz:
            sx = offset % width
            sy = offset // width
            comp = "Y"
        elif offset < y_sz + u_sz:
            off = offset - y_sz
            cw, ch = width // 2, height // 2
            sx = off % cw
            sy = off // cw
            # chroma sample maps to 2x2 luma block origin
            sx_l, sy_l = sx * 2, sy * 2
            mb_x = sx_l // 16
            mb_y = sy_l // 16
            return "U", sx, sy, mb_x, mb_y, mb_y * mb_w + mb_x
        else:
            off = offset - y_sz - u_sz
            cw = width // 2
            sx = off % cw
            sy = off // cw
            sx_l, sy_l = sx * 2, sy * 2
            mb_x = sx_l // 16
            mb_y = sy_l // 16
            return "V", sx, sy, mb_x, mb_y, mb_y * mb_w + mb_x
        mb_x = sx // 16
        mb_y = sy // 16
        return comp, sx, sy, mb_x, mb_y, mb_y * mb_w + mb_x

    for i in range(total):
        a = arm[i]
        b = rtl[i]
        if a != b:
            comp, sx, sy, mb_x, mb_y, mb_i = locate(i)
            return CompareResult(
                ok=False,
                width=width,
                height=height,
                stage=stage,
                format="i420",
                arm_bytes=len(arm),
                rtl_bytes=len(rtl),
                mb_index=mb_i,
                mb_x=mb_x,
                mb_y=mb_y,
                component=comp,
                sample_x=sx,
                sample_y=sy,
                offset=i,
                expected=a,
                actual=b,
            )

    return CompareResult(
        ok=True,
        width=width,
        height=height,
        stage=stage,
        format="i420",
        arm_bytes=len(arm),
        rtl_bytes=len(rtl),
    )


def refuse_same_path(arm_path: Path, rtl_path: Path) -> Optional[str]:
    """Tautology guard: feeding the same file as ARM and RTL is not a proof."""
    try:
        if arm_path.resolve() == rtl_path.resolve():
            return (
                "TAUTOLOGICAL_INPUT arm_path==rtl_path "
                f"({arm_path}) — oracle and DUT must be independent artifacts"
            )
    except OSError:
        pass
    return None
