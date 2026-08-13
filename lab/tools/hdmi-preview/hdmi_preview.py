#!/usr/bin/env python3
"""Live HDMI capture preview + annotate for MiSTerPlex lab.

Owns /dev/video0 while open. Pause a frame, draw red marks, place notes,
export PNG/YUYV/JSON for the agent (and yourself).

Shared dir (default):
  lab/captures/hdmi_preview_live/
    latest.png / latest.jpg / latest.yuyv / annotations.json / status.json
    notes/  export snapshots
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

import numpy as np
from PySide6.QtCore import QPoint, QPointF, QRect, QSize, Qt, QTimer, Signal, QObject
from PySide6.QtGui import (
    QAction,
    QColor,
    QFont,
    QImage,
    QKeySequence,
    QPainter,
    QPen,
    QPixmap,
    QShortcut,
)
from PySide6.QtWidgets import (
    QApplication,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QSizePolicy,
    QStatusBar,
    QToolBar,
    QVBoxLayout,
    QWidget,
    QCheckBox,
    QSpinBox,
    QComboBox,
)

# ---------------------------------------------------------------------------
# Paths / geometry
# ---------------------------------------------------------------------------

DEFAULT_DEVICE = "/dev/video0"
DEFAULT_W = 1280
DEFAULT_H = 720
DEFAULT_SHARED = Path(__file__).resolve().parents[2] / "captures/hdmi_preview_live"


@dataclass
class LineMark:
    x0: float
    y0: float
    x1: float
    y1: float
    color: str = "#ff2222"
    width: int = 3


@dataclass
class NoteMark:
    x: float
    y: float
    text: str
    color: str = "#ff2222"


@dataclass
class AnnotationDoc:
    lines: list[LineMark] = field(default_factory=list)
    notes: list[NoteMark] = field(default_factory=list)
    frame_w: int = DEFAULT_W
    frame_h: int = DEFAULT_H
    paused: bool = False
    updated: str = ""


def yuyv_to_rgb(yuyv: bytes, w: int, h: int) -> np.ndarray:
    """YUYV packed -> RGB uint8 HxWx3 (BT.601 full-range-ish)."""
    a = np.frombuffer(yuyv, dtype=np.uint8).reshape(h, w, 2)
    y = a[:, :, 0].astype(np.float32)
    u = np.empty((h, w), np.float32)
    v = np.empty((h, w), np.float32)
    u[:, 0::2] = a[:, 0::2, 1]
    u[:, 1::2] = a[:, 0::2, 1]
    v[:, 1::2] = a[:, 1::2, 1]
    v[:, 0::2] = a[:, 1::2, 1]
    uf, vf = u - 128.0, v - 128.0
    r = np.clip(y + 1.402 * vf, 0, 255)
    g = np.clip(y - 0.344136 * uf - 0.714136 * vf, 0, 255)
    b = np.clip(y + 1.772 * uf, 0, 255)
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


def rgb_to_qimage(rgb: np.ndarray) -> QImage:
    h, w, _ = rgb.shape
    # contiguous RGB888
    buf = np.ascontiguousarray(rgb)
    qimg = QImage(buf.data, w, h, w * 3, QImage.Format.Format_RGB888)
    return qimg.copy()  # detach from numpy buffer


# ---------------------------------------------------------------------------
# Capture thread
# ---------------------------------------------------------------------------


class CaptureWorker(QObject):
    frame_ready = Signal(object, object)  # rgb ndarray, yuyv bytes
    error = Signal(str)
    started_ok = Signal()

    def __init__(self, device: str, w: int, h: int, parent=None):
        super().__init__(parent)
        self.device = device
        self.w = w
        self.h = h
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._proc: Optional[subprocess.Popen] = None

    def start(self):
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="hdmi-cap", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._proc and self._proc.poll() is None:
            try:
                self._proc.terminate()
                self._proc.wait(timeout=1.5)
            except Exception:
                try:
                    self._proc.kill()
                except Exception:
                    pass
        if self._thread:
            self._thread.join(timeout=2.0)

    def _run(self):
        frame_bytes = self.w * self.h * 2  # YUYV
        cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "v4l2",
            "-input_format",
            "yuyv422",
            "-video_size",
            f"{self.w}x{self.h}",
            "-i",
            self.device,
            "-f",
            "rawvideo",
            "-pix_fmt",
            "yuyv422",
            "-",
        ]
        try:
            self._proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=frame_bytes * 2,
            )
        except Exception as e:
            self.error.emit(f"ffmpeg open failed: {e}")
            return

        self.started_ok.emit()
        assert self._proc.stdout is not None
        while not self._stop.is_set():
            raw = self._proc.stdout.read(frame_bytes)
            if not raw or len(raw) < frame_bytes:
                # drain stderr for hint
                err = ""
                if self._proc.stderr:
                    try:
                        err = self._proc.stderr.read(400).decode(errors="replace")
                    except Exception:
                        pass
                if not self._stop.is_set():
                    self.error.emit(
                        f"capture ended (got {len(raw) if raw else 0} bytes). {err}"
                    )
                break
            try:
                rgb = yuyv_to_rgb(raw, self.w, self.h)
                self.frame_ready.emit(rgb, raw)
            except Exception as e:
                self.error.emit(f"decode: {e}")
                break

        if self._proc and self._proc.poll() is None:
            try:
                self._proc.terminate()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Canvas
# ---------------------------------------------------------------------------


class PreviewCanvas(QLabel):
    """Shows video + annotation overlay. Coordinates in source frame space."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setMinimumSize(640, 360)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setMouseTracking(True)
        self.setCursor(Qt.CursorShape.CrossCursor)

        self._rgb: Optional[np.ndarray] = None
        self._pixmap_clean: Optional[QPixmap] = None
        self.ann = AnnotationDoc()
        self.mode = "line"  # line | note | pan(none)
        self._drag_start: Optional[QPointF] = None  # frame coords
        self._drag_cur: Optional[QPointF] = None
        self._scale = 1.0
        self._ox = 0
        self._oy = 0
        self.fw = DEFAULT_W
        self.fh = DEFAULT_H

    def set_frame(self, rgb: np.ndarray):
        self._rgb = rgb
        self.fw, self.fh = rgb.shape[1], rgb.shape[0]
        self.ann.frame_w, self.ann.frame_h = self.fw, self.fh
        self._pixmap_clean = QPixmap.fromImage(rgb_to_qimage(rgb))
        self._repaint_composite()

    def clear_annotations(self):
        self.ann.lines.clear()
        self.ann.notes.clear()
        self._repaint_composite()

    def undo_last(self):
        if self.ann.notes:
            self.ann.notes.pop()
        elif self.ann.lines:
            self.ann.lines.pop()
        self._repaint_composite()

    def export_annotated_rgb(self) -> Optional[np.ndarray]:
        if self._rgb is None:
            return None
        # paint into QImage full res
        img = rgb_to_qimage(self._rgb)
        p = QPainter(img)
        self._paint_annotations(p, scale=1.0, ox=0, oy=0)
        p.end()
        # QImage -> RGB
        img = img.convertToFormat(QImage.Format.Format_RGB888)
        w, h = img.width(), img.height()
        bpl = img.bytesPerLine()
        ptr = img.bits()
        arr = np.frombuffer(ptr, dtype=np.uint8).reshape(h, bpl)[:, : w * 3].reshape(h, w, 3).copy()
        return arr

    def _fit_geom(self) -> tuple[float, int, int]:
        if self._pixmap_clean is None:
            return 1.0, 0, 0
        cw, ch = self.width(), self.height()
        pw, ph = self._pixmap_clean.width(), self._pixmap_clean.height()
        scale = min(cw / pw, ch / ph)
        dw, dh = int(pw * scale), int(ph * scale)
        ox = (cw - dw) // 2
        oy = (ch - dh) // 2
        return scale, ox, oy

    def _widget_to_frame(self, pos: QPoint) -> Optional[QPointF]:
        scale, ox, oy = self._fit_geom()
        if scale <= 0:
            return None
        x = (pos.x() - ox) / scale
        y = (pos.y() - oy) / scale
        if x < 0 or y < 0 or x >= self.fw or y >= self.fh:
            return None
        return QPointF(x, y)

    def _paint_annotations(self, p: QPainter, scale: float, ox: int, oy: int):
        pen = QPen(QColor("#ff2222"))
        pen.setWidth(max(2, int(3 * (scale if scale > 0.01 else 1))))
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        p.setPen(pen)
        for ln in self.ann.lines:
            p.drawLine(
                QPointF(ox + ln.x0 * scale, oy + ln.y0 * scale),
                QPointF(ox + ln.x1 * scale, oy + ln.y1 * scale),
            )
        # in-progress drag
        if self._drag_start is not None and self._drag_cur is not None and self.mode == "line":
            p.drawLine(
                QPointF(ox + self._drag_start.x() * scale, oy + self._drag_start.y() * scale),
                QPointF(ox + self._drag_cur.x() * scale, oy + self._drag_cur.y() * scale),
            )
        font = QFont("Sans", max(10, int(12 * (scale if scale >= 0.5 else 0.5))))
        p.setFont(font)
        for n in self.ann.notes:
            px = ox + n.x * scale
            py = oy + n.y * scale
            # red pin + label bubble
            p.setBrush(QColor(255, 40, 40, 200))
            p.setPen(QPen(QColor("#ffffff")))
            p.drawEllipse(QPointF(px, py), 6, 6)
            text = n.text
            br = p.fontMetrics().boundingRect(text)
            pad = 4
            box = QRect(
                int(px + 10),
                int(py - br.height() - pad),
                br.width() + pad * 2,
                br.height() + pad * 2,
            )
            p.fillRect(box, QColor(20, 20, 20, 210))
            p.setPen(QPen(QColor("#ff6666")))
            p.drawRect(box)
            p.setPen(QPen(QColor("#ffffff")))
            p.drawText(box.adjusted(pad, pad // 2, 0, 0), text)

    def _repaint_composite(self):
        if self._pixmap_clean is None:
            self.setText("No signal — waiting for HDMI capture…")
            return
        scale, ox, oy = self._fit_geom()
        self._scale, self._ox, self._oy = scale, ox, oy
        canvas = QPixmap(self.size())
        canvas.fill(QColor(18, 18, 22))
        p = QPainter(canvas)
        pw = int(self._pixmap_clean.width() * scale)
        ph = int(self._pixmap_clean.height() * scale)
        p.drawPixmap(ox, oy, pw, ph, self._pixmap_clean)
        self._paint_annotations(p, scale, ox, oy)
        p.end()
        self.setPixmap(canvas)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._repaint_composite()

    def mousePressEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton:
            return
        fp = self._widget_to_frame(event.position().toPoint())
        if fp is None:
            return
        if self.mode == "line":
            self._drag_start = fp
            self._drag_cur = fp
        elif self.mode == "note":
            text, ok = QInputDialog.getMultiLineText(
                self,
                "Annotation note",
                "What is wrong here? (shown to agent + saved in JSON)",
                "",
            )
            if ok and text.strip():
                self.ann.notes.append(NoteMark(x=fp.x(), y=fp.y(), text=text.strip()))
                self._repaint_composite()

    def mouseMoveEvent(self, event):
        if self._drag_start is not None and self.mode == "line":
            fp = self._widget_to_frame(event.position().toPoint())
            if fp is not None:
                self._drag_cur = fp
                self._repaint_composite()

    def mouseReleaseEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton:
            return
        if self.mode == "line" and self._drag_start is not None and self._drag_cur is not None:
            x0, y0 = self._drag_start.x(), self._drag_start.y()
            x1, y1 = self._drag_cur.x(), self._drag_cur.y()
            if abs(x1 - x0) + abs(y1 - y0) > 3:
                self.ann.lines.append(LineMark(x0=x0, y0=y0, x1=x1, y1=y1))
            self._drag_start = None
            self._drag_cur = None
            self._repaint_composite()


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------


class HdmiPreviewWindow(QMainWindow):
    def __init__(self, device: str, w: int, h: int, shared: Path, float_top: bool):
        super().__init__()
        self.device = device
        self.fw, self.fh = w, h
        self.shared = shared
        self.shared.mkdir(parents=True, exist_ok=True)
        (self.shared / "notes").mkdir(exist_ok=True)
        (self.shared / "commands").mkdir(exist_ok=True)

        self.setWindowTitle(f"HDMI Preview — {device} {w}x{h}")
        self.resize(1100, 720)
        if float_top:
            self.setWindowFlags(self.windowFlags() | Qt.WindowType.WindowStaysOnTopHint)

        self.paused = False
        self._last_rgb: Optional[np.ndarray] = None
        self._last_yuyv: Optional[bytes] = None
        self._frame_i = 0
        self._fps_t0 = time.time()
        self._fps_n = 0
        self._fps = 0.0

        # UI
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        layout.setContentsMargins(6, 6, 6, 6)

        self.canvas = PreviewCanvas()
        layout.addWidget(self.canvas, stretch=1)

        bar = QHBoxLayout()
        self.btn_pause = QPushButton("Pause (Space)")
        self.btn_pause.setCheckable(True)
        self.btn_pause.clicked.connect(self.toggle_pause)
        bar.addWidget(self.btn_pause)

        self.btn_line = QPushButton("Draw red lines")
        self.btn_line.setCheckable(True)
        self.btn_line.setChecked(True)
        self.btn_line.clicked.connect(lambda: self.set_mode("line"))
        bar.addWidget(self.btn_line)

        self.btn_note = QPushButton("Place note")
        self.btn_note.setCheckable(True)
        self.btn_note.clicked.connect(lambda: self.set_mode("note"))
        bar.addWidget(self.btn_note)

        self.btn_undo = QPushButton("Undo")
        self.btn_undo.clicked.connect(self.canvas.undo_last)
        bar.addWidget(self.btn_undo)

        self.btn_clear = QPushButton("Clear marks")
        self.btn_clear.clicked.connect(self.canvas.clear_annotations)
        bar.addWidget(self.btn_clear)

        self.btn_shot = QPushButton("Screenshot + notes")
        self.btn_shot.clicked.connect(lambda: self.save_snapshot(agent=False))
        bar.addWidget(self.btn_shot)

        self.btn_agent = QPushButton("Save for agent")
        self.btn_agent.setStyleSheet("background:#4a2020; color:#ffcccc; font-weight:bold;")
        self.btn_agent.clicked.connect(lambda: self.save_snapshot(agent=True))
        bar.addWidget(self.btn_agent)

        self.chk_auto = QCheckBox("Auto-export live JPEG")
        self.chk_auto.setChecked(True)
        self.chk_auto.setToolTip("Writes latest.jpg every N frames so the agent sees what you see")
        bar.addWidget(self.chk_auto)

        self.spin_every = QSpinBox()
        self.spin_every.setRange(1, 60)
        self.spin_every.setValue(5)
        self.spin_every.setPrefix("every ")
        self.spin_every.setSuffix(" f")
        bar.addWidget(self.spin_every)

        bar.addStretch(1)
        layout.addLayout(bar)

        self.status = QStatusBar()
        self.setStatusBar(self.status)
        self.status.showMessage("Starting capture…")

        # shortcuts
        QShortcut(QKeySequence(Qt.Key.Key_Space), self, self.toggle_pause)
        QShortcut(QKeySequence("L"), self, lambda: self.set_mode("line"))
        QShortcut(QKeySequence("N"), self, lambda: self.set_mode("note"))
        QShortcut(QKeySequence("S"), self, lambda: self.save_snapshot(agent=False))
        QShortcut(QKeySequence("A"), self, lambda: self.save_snapshot(agent=True))
        QShortcut(QKeySequence("Z"), self, self.canvas.undo_last)
        QShortcut(QKeySequence("Escape"), self, self.canvas.clear_annotations)

        # capture
        self.worker = CaptureWorker(device, w, h)
        self.worker.frame_ready.connect(self.on_frame)
        self.worker.error.connect(self.on_error)
        self.worker.started_ok.connect(lambda: self.status.showMessage(f"Live on {device}"))
        self.worker.start()

        # poll agent command file
        self._cmd_timer = QTimer(self)
        self._cmd_timer.timeout.connect(self._poll_commands)
        self._cmd_timer.start(250)

        self._write_status(running=True, msg="starting")

    def set_mode(self, mode: str):
        self.canvas.mode = mode
        self.btn_line.setChecked(mode == "line")
        self.btn_note.setChecked(mode == "note")
        self.status.showMessage(
            "Draw mode: click-drag red lines" if mode == "line" else "Note mode: click to place text"
        )

    def toggle_pause(self):
        self.paused = not self.paused
        self.btn_pause.setChecked(self.paused)
        self.btn_pause.setText("Resume (Space)" if self.paused else "Pause (Space)")
        self.canvas.ann.paused = self.paused
        self.status.showMessage("PAUSED — annotate freely" if self.paused else "LIVE")
        if self.paused:
            self._export_live(force=True)
            self._write_annotations()

    def on_frame(self, rgb: np.ndarray, yuyv: bytes):
        self._last_yuyv = yuyv
        if self.paused:
            return
        self._last_rgb = rgb
        self.canvas.set_frame(rgb)
        self._frame_i += 1
        self._fps_n += 1
        now = time.time()
        if now - self._fps_t0 >= 1.0:
            self._fps = self._fps_n / (now - self._fps_t0)
            self._fps_n = 0
            self._fps_t0 = now
            self.status.showMessage(
                f"LIVE {self.device}  {self.fw}x{self.fh}  ~{self._fps:.1f} fps  "
                f"lines={len(self.canvas.ann.lines)} notes={len(self.canvas.ann.notes)}"
            )
        if self.chk_auto.isChecked() and (self._frame_i % max(1, self.spin_every.value()) == 0):
            self._export_live(force=False)

    def on_error(self, msg: str):
        self.status.showMessage(f"ERROR: {msg}")
        self._write_status(running=True, msg=msg, error=True)

    def _export_live(self, force: bool):
        if self._last_rgb is None:
            return
        try:
            # lightweight JPEG for chat-side glance
            from PIL import Image

            img = Image.fromarray(self._last_rgb)
            img.save(self.shared / "latest.jpg", quality=85, optimize=True)
            # annotated overlay version for "what I marked"
            ann_rgb = self.canvas.export_annotated_rgb()
            if ann_rgb is not None:
                Image.fromarray(ann_rgb).save(self.shared / "latest_annotated.jpg", quality=90)
            self._write_annotations()
            self._write_status(running=True, msg="live" if not self.paused else "paused")
        except Exception as e:
            self.status.showMessage(f"export live failed: {e}")

    def _write_annotations(self):
        self.canvas.ann.updated = datetime.now().isoformat(timespec="seconds")
        self.canvas.ann.paused = self.paused
        doc = {
            "lines": [asdict(x) for x in self.canvas.ann.lines],
            "notes": [asdict(x) for x in self.canvas.ann.notes],
            "frame_w": self.canvas.ann.frame_w,
            "frame_h": self.canvas.ann.frame_h,
            "paused": self.paused,
            "updated": self.canvas.ann.updated,
            "device": self.device,
        }
        (self.shared / "annotations.json").write_text(json.dumps(doc, indent=2))

    def _write_status(self, running: bool, msg: str = "", error: bool = False):
        st = {
            "running": running,
            "pid": os.getpid(),
            "device": self.device,
            "size": [self.fw, self.fh],
            "paused": self.paused,
            "frame_i": self._frame_i,
            "fps": round(self._fps, 2),
            "msg": msg,
            "error": error,
            "shared": str(self.shared),
            "updated": datetime.now().isoformat(timespec="seconds"),
            "lines": len(self.canvas.ann.lines),
            "notes": len(self.canvas.ann.notes),
        }
        (self.shared / "status.json").write_text(json.dumps(st, indent=2))
        (self.shared / "hdmi_preview.pid").write_text(str(os.getpid()))

    def save_snapshot(self, agent: bool = False):
        if self._last_rgb is None and self.canvas._rgb is None:
            QMessageBox.warning(self, "No frame", "No frame captured yet.")
            return
        # ensure paused visual is what we save
        if not self.paused and self._last_rgb is not None:
            self.canvas.set_frame(self._last_rgb)

        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        tag = "agent" if agent else "shot"
        out_dir = self.shared / "notes" / f"{tag}_{ts}"
        out_dir.mkdir(parents=True, exist_ok=True)

        from PIL import Image

        raw_rgb = self.canvas._rgb if self.canvas._rgb is not None else self._last_rgb
        assert raw_rgb is not None
        Image.fromarray(raw_rgb).save(out_dir / "frame.png")
        Image.fromarray(raw_rgb).save(self.shared / "latest.png")
        ann = self.canvas.export_annotated_rgb()
        if ann is not None:
            Image.fromarray(ann).save(out_dir / "frame_annotated.png")
            Image.fromarray(ann).save(self.shared / "latest_annotated.png")
            Image.fromarray(ann).save(self.shared / "latest_annotated.jpg", quality=92)

        if self._last_yuyv:
            (out_dir / "frame.yuyv").write_bytes(self._last_yuyv)
            (self.shared / "latest.yuyv").write_bytes(self._last_yuyv)

        self._write_annotations()
        # also copy annotations into snapshot folder
        (out_dir / "annotations.json").write_text(
            (self.shared / "annotations.json").read_text()
        )
        # human-readable notes
        lines = [
            f"# HDMI annotation {ts}",
            f"device={self.device} size={self.fw}x{self.fh} paused={self.paused}",
            "",
        ]
        for i, n in enumerate(self.canvas.ann.notes, 1):
            lines.append(f"NOTE {i} @ ({n.x:.0f},{n.y:.0f}): {n.text}")
        for i, ln in enumerate(self.canvas.ann.lines, 1):
            lines.append(
                f"LINE {i}: ({ln.x0:.0f},{ln.y0:.0f}) -> ({ln.x1:.0f},{ln.y1:.0f})"
            )
        (out_dir / "NOTES.txt").write_text("\n".join(lines) + "\n")
        (self.shared / "latest_NOTES.txt").write_text("\n".join(lines) + "\n")

        # pointer for agent
        (self.shared / "latest_export.txt").write_text(str(out_dir) + "\n")
        self._write_status(running=True, msg=f"saved {out_dir.name}")

        self.status.showMessage(f"Saved {out_dir}  (also latest_* in shared dir)")
        if agent:
            # toast-ish
            self.status.showMessage(
                f"AGENT PACKAGE READY → {out_dir}  |  notes={len(self.canvas.ann.notes)} lines={len(self.canvas.ann.lines)}"
            )

    def _poll_commands(self):
        """Agent can `touch commands/grab` or write commands/request.json."""
        grab = self.shared / "commands" / "grab"
        if grab.exists():
            try:
                grab.unlink()
            except Exception:
                pass
            # pause + export for agent
            if not self.paused:
                self.toggle_pause()
            self.save_snapshot(agent=True)
            (self.shared / "commands" / "grab_done").write_text(
                datetime.now().isoformat(timespec="seconds") + "\n"
            )

    def closeEvent(self, event):
        self.worker.stop()
        self._write_status(running=False, msg="closed")
        try:
            (self.shared / "hdmi_preview.pid").unlink(missing_ok=True)
        except Exception:
            pass
        super().closeEvent(event)


def already_running(shared: Path) -> Optional[int]:
    pid_path = shared / "hdmi_preview.pid"
    if not pid_path.exists():
        return None
    try:
        pid = int(pid_path.read_text().strip())
        os.kill(pid, 0)
        return pid
    except Exception:
        return None


def main(argv=None):
    ap = argparse.ArgumentParser(description="Live HDMI preview + annotate")
    ap.add_argument("--device", default=os.environ.get("HDMI_DEVICE", DEFAULT_DEVICE))
    ap.add_argument("--width", type=int, default=int(os.environ.get("HDMI_W", DEFAULT_W)))
    ap.add_argument("--height", type=int, default=int(os.environ.get("HDMI_H", DEFAULT_H)))
    ap.add_argument(
        "--shared",
        type=Path,
        default=Path(os.environ.get("HDMI_PREVIEW_SHARED", str(DEFAULT_SHARED))),
    )
    ap.add_argument("--no-top", action="store_true", help="Do not stay on top")
    ap.add_argument(
        "--replace",
        action="store_true",
        help="Kill existing preview instance first",
    )
    args = ap.parse_args(argv)

    pid = already_running(args.shared)
    if pid and not args.replace:
        print(f"HDMI preview already running pid={pid} shared={args.shared}", file=sys.stderr)
        print("Use --replace to restart, or open the existing window.", file=sys.stderr)
        # still raise window? can't easily — exit 0 so launchers are idempotent
        return 0
    if pid and args.replace:
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.5)
        except Exception:
            pass

    # Wayland / X11
    os.environ.setdefault("QT_QPA_PLATFORM", "wayland;xcb")

    app = QApplication(sys.argv)
    app.setApplicationName("HDMI Preview")
    win = HdmiPreviewWindow(
        device=args.device,
        w=args.width,
        h=args.height,
        shared=args.shared,
        float_top=not args.no_top,
    )
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
