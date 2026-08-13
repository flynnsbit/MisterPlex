# HDMI Preview

Live `/dev/video0` preview and annotation tool for MiSTer HDMI capture. It
shows the same frame to the user and an agent, supports red-line and text
annotations, and exports PNG, JPEG, raw YUYV, and JSON evidence.

## Requirements

- Omarchy or another Wayland/X11 Linux desktop
- Python 3.11 or newer
- `uv`
- `ffmpeg`
- A V4L2 capture device, defaulting to `/dev/video0`

On Omarchy:

```bash
omarchy pkg add ffmpeg uv
```

## Setup

From this directory:

```bash
uv venv .venv
uv pip install --python .venv/bin/python -r requirements.txt
./install_desktop.sh
```

The virtual environment is intentionally excluded from git.

## Launch

```bash
./hdmi_preview.sh
```

The desktop installer adds **HDMI Preview** to the application launcher using
the absolute path of the current clone.

## Controls

| Key / button | Action |
|---|---|
| **Space** / Pause | Freeze the current frame |
| **L** / Draw red lines | Click-drag red lines over defects |
| **N** / Place note | Click a spot and enter a note |
| **Z** / Undo | Remove the last line or note |
| **Esc** / Clear marks | Clear annotations |
| **S** / Screenshot + notes | Save a timestamped evidence package |
| **A** / Save for agent | Save evidence and update `latest_*` files |

The window stays on top by default. Pass `--no-top` to disable that behavior.

## Shared files

Exports default to `lab/captures/hdmi_preview_live/`, which is git-ignored.
Override the location with `HDMI_PREVIEW_SHARED`.

| File | Meaning |
|---|---|
| `latest.jpg` | Auto-refreshed live frame |
| `latest_annotated.jpg` / `.png` | Frame with annotations |
| `latest.yuyv` | Raw YUYV frame |
| `annotations.json` | Machine-readable annotations |
| `latest_NOTES.txt` | Human-readable notes |
| `latest_export.txt` | Path to the latest evidence package |
| `status.json` | Running, pause, FPS, and process state |
| `commands/grab` | Agent command that pauses and exports |

Helper commands:

```bash
./hdmi_preview.sh status
./hdmi_preview.sh grab
./hdmi_preview.sh replace
```

Capture settings can be overridden with `HDMI_DEVICE`, `HDMI_W`, and `HDMI_H`.
Only one process can own a V4L2 device at a time.
