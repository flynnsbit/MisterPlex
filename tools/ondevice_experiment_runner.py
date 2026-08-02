#!/usr/bin/env python3
"""On-device self-validating experiment runner (conf arms + log markers).

WHY (parent 2026-08-02 — hand harness fabricated-looking data)
-------------------------------------------------------------
7-arm bitrate sweep via per-step SSH produced four silent defects:
  1. `cp -a conf bak` failed silently → ORIG_MD5 empty → match=NO vs nothing
  2. 3/7 arms empty SSH drop → printed `ARM br=1200 -> ` as if measured
  3. Byte-offset log window spanned multi-session (maxVideoBitrate 2000 AND
     397 AND measured 312x240 AND 624x480 simultaneously)
  4. No-op conf write still emitted default maxVideoBitrate=2000 →
     indistinguishable from a real arm

CONTRACT
--------
- Runs DETACHED ON DEVICE as one process (scp + nohup/setsid; poll sentinel).
  SSH is NOT in the critical path of any arm step.
- Conf is USER-OWNED STATE: backup must exist + md5 match source BEFORE any
  mutation; restore must return byte-exact original (RESTORE_OK/RESTORE_FAIL).
  Backup/restore failure → ABORT (never continue).
- Per-arm log isolation by MARKER lines, never byte offsets.
- Per-arm POSITIVE validation:
    * conf file post-write contains intended key=value
    * wire/log window contains expected independent-variable token(s)
    * exactly one session in window (one unique maxVideoBitrate, one unique
      measured=, one ffmpeg/spawn start) unless arm opts out
  Failure → arm status=INVALID + reason; never emit a measured value.
- Absence is INVALID/NO-DATA, never empty-string-as-data.

Exit codes (capture DIRECTLY: cmd; echo "true rc=$?" — never through a pipe):
   0  EXPERIMENT_OK     all arms VALID, RESTORE_OK
   4  ARMS_INVALID      finished; ≥1 arm INVALID; conf restored OK (retryable)
  80  ABORT_USER_STATE  conf backup/restore failed — user state at risk
  77  UNSCORED          misconfig / cannot run (never a pass)
   2  USAGE / self-test fail

Modes:
  self-test   host RBG (no device) — conf no-op INVALID + empty window INVALID
  run         on-device (or host with --root fake tree)
  validate-log  pure slice+validate against a log file (unit helper)

Parent owns hardware. Agent does not SSH/cast/deploy.

Example device launch (parent runs):
  scp tools/ondevice_experiment_runner.py root@HOST:/media/fat/misterplex/bin/
  scp arms.json root@HOST:/media/fat/misterplex/experiments/arms.json
  ssh root@HOST 'setsid nohup python3 /media/fat/misterplex/bin/ondevice_experiment_runner.py \
    run --spec /media/fat/misterplex/experiments/arms.json \
    --out-dir /media/fat/misterplex/experiments/run1 \
    > /media/fat/misterplex/experiments/run1/runner.stdout 2>&1 &
    echo $!'
  # poll:
  ssh root@HOST 'test -f /media/fat/misterplex/experiments/run1/COMPLETE && cat .../result.json'
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Optional

RC_OK = 0
RC_USAGE = 2
RC_INVALID = 4  # retryable — arms invalid, conf restored
RC_UNSCORED = 77
RC_ABORT = 80  # user-owned conf state at risk

MARKER_BEGIN = "EXP_ARM_BEGIN"
MARKER_END = "EXP_ARM_END"
MARKER_PREFIX = "=== MiSTerPlexExperiment "

# ---------------------------------------------------------------------------
# md5 / conf IO
# ---------------------------------------------------------------------------


def md5_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def parse_conf_kv(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def apply_conf_keys(text: str, keys: dict[str, str]) -> str:
    """Set/replace KEY=value lines; preserve comments/order; append missing."""
    seen: set[str] = set()
    out_lines: list[str] = []
    for line in text.splitlines():
        raw = line
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            out_lines.append(raw)
            continue
        k = s.split("=", 1)[0].strip()
        if k in keys:
            out_lines.append(f"{k}={keys[k]}")
            seen.add(k)
        else:
            out_lines.append(raw)
    for k, v in keys.items():
        if k not in seen:
            out_lines.append(f"{k}={v}")
    body = "\n".join(out_lines)
    if body and not body.endswith("\n"):
        body += "\n"
    return body


# ---------------------------------------------------------------------------
# backup / restore — USER-OWNED STATE
# ---------------------------------------------------------------------------


@dataclass
class BackupState:
    conf_path: str
    bak_path: str
    orig_md5: str
    ok: bool
    reason: str = ""


def backup_conf(conf_path: Path, bak_path: Path) -> BackupState:
    """cp then IMMEDIATELY verify exists + md5. Failure = hard abort input."""
    if not conf_path.is_file():
        return BackupState(
            conf_path=str(conf_path),
            bak_path=str(bak_path),
            orig_md5="",
            ok=False,
            reason=f"conf_missing path={conf_path}",
        )
    try:
        bak_path.parent.mkdir(parents=True, exist_ok=True)
        if bak_path.exists():
            bak_path.unlink()
        shutil.copy2(conf_path, bak_path)
    except OSError as e:
        return BackupState(
            str(conf_path), str(bak_path), "", False, f"cp_failed err={e}"
        )
    if not bak_path.is_file():
        return BackupState(
            str(conf_path),
            str(bak_path),
            "",
            False,
            "backup_missing_after_cp — ABORT before mutation",
        )
    src_md5 = md5_file(conf_path)
    bak_md5 = md5_file(bak_path)
    if not src_md5 or src_md5 != bak_md5:
        return BackupState(
            str(conf_path),
            str(bak_path),
            src_md5 or "",
            False,
            f"backup_md5_mismatch src={src_md5!r} bak={bak_md5!r} — ABORT",
        )
    return BackupState(
        str(conf_path), str(bak_path), src_md5, True, "backup_ok"
    )


def restore_conf(st: BackupState) -> tuple[bool, str]:
    """Restore bak → conf; require md5 == recorded original."""
    if not st.ok or not st.orig_md5:
        return False, "restore_refused no_valid_backup_state"
    conf = Path(st.conf_path)
    bak = Path(st.bak_path)
    if not bak.is_file():
        return False, f"RESTORE_FAIL bak_missing path={bak}"
    try:
        shutil.copy2(bak, conf)
    except OSError as e:
        return False, f"RESTORE_FAIL cp_err={e}"
    if not conf.is_file():
        return False, "RESTORE_FAIL conf_missing_after_restore"
    got = md5_file(conf)
    if got != st.orig_md5:
        return (
            False,
            f"RESTORE_FAIL md5_mismatch got={got} want={st.orig_md5}",
        )
    return True, f"RESTORE_OK md5={got}"


# ---------------------------------------------------------------------------
# markers + log slice
# ---------------------------------------------------------------------------


def marker_line(kind: str, arm_id: str, token: str) -> str:
    # kind is BEGIN or END
    return f"{MARKER_PREFIX}{kind} arm_id={arm_id} token={token} ===\n"


def append_marker(log_path: Path, kind: str, arm_id: str, token: str) -> str:
    line = marker_line(kind, arm_id, token)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as f:
        f.write(line)
        f.flush()
        os.fsync(f.fileno())
    return line.strip()


def slice_between_markers(
    log_text: str, arm_id: str, token: str
) -> tuple[Optional[str], str]:
    """Return (slice_text|None, reason). Markers must match arm_id+token."""
    begin_re = re.compile(
        re.escape(MARKER_PREFIX)
        + r"BEGIN"
        + rf" arm_id={re.escape(arm_id)} token={re.escape(token)} "
    )
    end_re = re.compile(
        re.escape(MARKER_PREFIX)
        + r"END"
        + rf" arm_id={re.escape(arm_id)} token={re.escape(token)} "
    )
    lines = log_text.splitlines(keepends=True)
    begin_i = end_i = None
    for i, ln in enumerate(lines):
        if begin_i is None and begin_re.search(ln):
            begin_i = i
        elif begin_i is not None and end_re.search(ln):
            end_i = i
            break
    if begin_i is None:
        return None, "marker_begin_missing"
    if end_i is None:
        return None, "marker_end_missing"
    # exclusive of marker lines
    body = "".join(lines[begin_i + 1 : end_i])
    return body, "ok"


# ---------------------------------------------------------------------------
# arm validation
# ---------------------------------------------------------------------------


@dataclass
class ArmResult:
    arm_id: str
    status: str  # VALID | INVALID | ABORT | SKIPPED
    reason: str
    expect: dict[str, str] = field(default_factory=dict)
    conf_after: dict[str, str] = field(default_factory=dict)
    observed: dict[str, Any] = field(default_factory=dict)
    measurements: dict[str, Any] = field(default_factory=dict)
    token: str = ""
    log_slice_chars: int = 0


def _unique_matches(pattern: str, text: str) -> list[str]:
    return list(dict.fromkeys(re.findall(pattern, text)))


def validate_arm_window(
    *,
    arm_id: str,
    window: str,
    expect_wire: dict[str, str],
    conf_after: dict[str, str],
    conf_keys_set: dict[str, str],
    require_single_session: bool = True,
) -> ArmResult:
    """Positive validation. Empty window → INVALID. Never invent values."""
    base = ArmResult(
        arm_id=arm_id,
        status="INVALID",
        reason="",
        expect=dict(expect_wire),
        conf_after={k: conf_after.get(k, "") for k in conf_keys_set},
    )

    if window is None:
        base.reason = "window_is_none"
        return base

    # NO-DATA: empty
    if not window.strip():
        base.reason = "empty_window NO-DATA (absence is not a measurement)"
        base.log_slice_chars = 0
        base.observed = {"empty": True}
        return base

    base.log_slice_chars = len(window)

    # Conf keys must have landed
    for k, want in conf_keys_set.items():
        got = conf_after.get(k)
        if got is None or got != want:
            base.reason = (
                f"conf_write_not_landed key={k} want={want!r} got={got!r}"
            )
            base.observed = {"conf_mismatch": True}
            return base

    # Wire / log expected tokens (e.g. maxVideoBitrate=1200)
    observed_vals: dict[str, list[str]] = {}
    for key, want in expect_wire.items():
        # match key=value in URLs or plain log
        pats = [
            rf"{re.escape(key)}={re.escape(want)}(?:&|\s|$)",
            rf"{re.escape(key)}={re.escape(want)}\b",
        ]
        found = False
        for pat in pats:
            if re.search(pat, window):
                found = True
                break
        all_vals = _unique_matches(rf"{re.escape(key)}=([^\s&\"']+)", window)
        observed_vals[key] = all_vals
        if not found:
            base.reason = (
                f"wire_expect_missing key={key} want={want!r} "
                f"observed_values={all_vals!r} "
                f"(no-op conf or stale session — NOT a measurement)"
            )
            base.observed = {"wire": observed_vals}
            return base

    base.observed["wire"] = observed_vals

    if require_single_session:
        # unique maxVideoBitrate
        brs = _unique_matches(r"maxVideoBitrate=([0-9]+)", window)
        base.observed["maxVideoBitrate_unique"] = brs
        if len(brs) == 0:
            # only fail if expect_wire asked for it; else soft
            if any(k == "maxVideoBitrate" for k in expect_wire):
                base.reason = "no_maxVideoBitrate_in_window"
                return base
        elif len(brs) > 1:
            base.reason = (
                f"multi_session maxVideoBitrate values={brs} "
                f"(marker window spans >1 session — attribution destroyed)"
            )
            return base

        measured = _unique_matches(r"measured=([0-9]+x[0-9]+)", window)
        base.observed["measured_unique"] = measured
        if len(measured) > 1:
            base.reason = (
                f"multi_session measured values={measured} "
                f"(byte-offset-class contamination)"
            )
            return base

        spawns = len(
            re.findall(
                r"media: spawn single-process|media: spawn |ffmpeg -hide_banner",
                window,
            )
        )
        # Also count PLAY lines as session starts
        plays = len(re.findall(r"misterplexd: PLAY |PLAY https?://", window))
        base.observed["spawn_or_ffmpeg_hits"] = spawns
        base.observed["play_hits"] = plays
        session_starts = max(spawns, plays)
        if session_starts == 0:
            base.reason = (
                "no_session_start_in_window "
                "(no PLAY/spawn/ffmpeg — cast missed or wrong log)"
            )
            return base
        if session_starts > 1:
            base.reason = (
                f"multi_session session_starts={session_starts} "
                f"spawns={spawns} plays={plays}"
            )
            return base

    # VALID — only now attach measurements from the single session
    measurements: dict[str, Any] = {}
    for key in expect_wire:
        vals = observed_vals.get(key) or []
        if len(vals) == 1:
            measurements[key] = vals[0]
        elif len(vals) > 1:
            # should have been caught; belt
            base.reason = f"non_unique_measurement key={key} vals={vals}"
            return base
    m = re.search(r"measured=([0-9]+x[0-9]+)", window)
    if m:
        measurements["measured"] = m.group(1)
    m = re.search(r"videoResolution=([0-9]+x[0-9]+)", window)
    if m:
        measurements["videoResolution"] = m.group(1)
    m = re.search(r"\bframes=(\d+)", window)
    if m:
        measurements["frames"] = int(m.group(1))
    m = re.search(r"\bdrops=(\d+)", window)
    if m:
        measurements["drops"] = int(m.group(1))
    m = re.search(r"\bvfps=([0-9.]+)", window)
    if m:
        measurements["vfps"] = m.group(1)

    base.status = "VALID"
    base.reason = "positive_validation_ok"
    base.measurements = measurements
    return base


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------


def _run_cmd(
    cmd: str, *, cwd: Optional[str] = None, timeout: Optional[float] = None
) -> tuple[int, str, str]:
    if not cmd or not cmd.strip():
        return 0, "", ""
    try:
        p = subprocess.run(
            cmd,
            shell=True,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return int(p.returncode), p.stdout or "", p.stderr or ""
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except OSError as e:
        return 127, "", str(e)


def run_experiment(spec: dict[str, Any], out_dir: Path) -> dict[str, Any]:
    """Execute all arms. Always attempts restore if backup ok."""
    out_dir.mkdir(parents=True, exist_ok=True)
    conf_path = Path(spec["conf_path"])
    log_path = Path(spec["log_path"])
    bak_path = Path(
        spec.get("bak_path")
        or (str(conf_path) + f".exp_bak_{int(time.time())}")
    )
    settle_s = float(spec.get("settle_s", 32))
    restart_cmd = spec.get(
        "restart_cmd", "killall misterplexd 2>/dev/null || true"
    )
    wait_ready_cmd = spec.get("wait_ready_cmd", "")
    cast_cmd_template = spec.get("cast_cmd", "")  # may include {arm_id}
    require_single = bool(spec.get("require_single_session", True))
    # dry hooks for self-test: inject log lines after marker begin
    simulate = spec.get("simulate")  # dict arm_id -> log text to append

    result: dict[str, Any] = {
        "experiment_id": spec.get("experiment_id", "unnamed"),
        "verdict": "ABORT_USER_STATE",
        "rc": RC_ABORT,
        "restore": "NOT_ATTEMPTED",
        "orig_md5": "",
        "arms": [],
        "provenance": "ondevice_experiment_runner",
    }

    bak = backup_conf(conf_path, bak_path)
    result["orig_md5"] = bak.orig_md5
    result["backup_reason"] = bak.reason
    if not bak.ok:
        result["verdict"] = "ABORT_USER_STATE"
        result["rc"] = RC_ABORT
        result["reason"] = bak.reason
        print(
            f"ABORT_USER_STATE rc={RC_ABORT} reason={bak.reason}",
            flush=True,
        )
        print(
            "ACTION: do NOT continue; conf was NOT modified; "
            "fix backup path/permissions before any experiment",
            flush=True,
        )
        _write_result(out_dir, result)
        return result

    print(f"BACKUP_OK md5={bak.orig_md5} bak={bak_path}", flush=True)

    arm_results: list[ArmResult] = []
    abort_mid = False
    abort_reason = ""

    try:
        for arm in spec.get("arms") or []:
            arm_id = str(arm["id"])
            conf_set = {str(k): str(v) for k, v in (arm.get("conf_set") or {}).items()}
            expect_wire = {
                str(k): str(v) for k, v in (arm.get("expect_wire") or {}).items()
            }
            if not conf_set:
                ar = ArmResult(
                    arm_id=arm_id,
                    status="INVALID",
                    reason="arm_missing_conf_set",
                )
                arm_results.append(ar)
                print(f"ARM {arm_id} INVALID reason={ar.reason}", flush=True)
                continue
            if not expect_wire:
                # default: if WEAK_BITRATE set, expect maxVideoBitrate
                if "WEAK_BITRATE" in conf_set:
                    expect_wire = {"maxVideoBitrate": conf_set["WEAK_BITRATE"]}
                else:
                    ar = ArmResult(
                        arm_id=arm_id,
                        status="INVALID",
                        reason="arm_missing_expect_wire",
                    )
                    arm_results.append(ar)
                    print(
                        f"ARM {arm_id} INVALID reason={ar.reason}", flush=True
                    )
                    continue

            token = uuid.uuid4().hex[:12]
            print(f"ARM_START id={arm_id} token={token}", flush=True)

            # Optional skip_write for RBG no-op tests
            skip_write = bool(arm.get("skip_conf_write", False))

            if not skip_write:
                try:
                    cur = read_text(conf_path) if conf_path.is_file() else ""
                    new = apply_conf_keys(cur, conf_set)
                    write_text_atomic(conf_path, new)
                except OSError as e:
                    ar = ArmResult(
                        arm_id=arm_id,
                        status="INVALID",
                        reason=f"conf_write_os_error err={e}",
                        token=token,
                    )
                    arm_results.append(ar)
                    print(
                        f"ARM {arm_id} INVALID reason={ar.reason}", flush=True
                    )
                    continue

            # Verify conf on disk
            conf_after = parse_conf_kv(read_text(conf_path))

            # BEGIN marker AFTER conf write so restart sees new conf, before cast
            try:
                append_marker(log_path, "BEGIN", arm_id, token)
            except OSError as e:
                ar = ArmResult(
                    arm_id=arm_id,
                    status="INVALID",
                    reason=f"marker_begin_write_fail err={e}",
                    token=token,
                    conf_after={k: conf_after.get(k, "") for k in conf_set},
                )
                arm_results.append(ar)
                continue

            # restart daemon (best-effort; failure → INVALID not ABORT)
            if restart_cmd and not spec.get("skip_restart"):
                rc_k, _o, e_k = _run_cmd(restart_cmd, timeout=30)
                if rc_k not in (0, 1):  # killall returns 1 if none
                    # still continue — wait_ready may fail
                    print(
                        f"ARM {arm_id} restart_cmd rc={rc_k} err={e_k[:200]!r}",
                        flush=True,
                    )
                if wait_ready_cmd:
                    rc_w, _o, e_w = _run_cmd(wait_ready_cmd, timeout=60)
                    if rc_w != 0:
                        append_marker(log_path, "END", arm_id, token)
                        ar = ArmResult(
                            arm_id=arm_id,
                            status="INVALID",
                            reason=f"daemon_not_ready rc={rc_w} err={e_w[:200]!r}",
                            token=token,
                            conf_after={
                                k: conf_after.get(k, "") for k in conf_set
                            },
                        )
                        arm_results.append(ar)
                        print(
                            f"ARM {arm_id} INVALID reason={ar.reason}",
                            flush=True,
                        )
                        continue

            # cast
            if cast_cmd_template:
                cast_cmd = cast_cmd_template.format(
                    arm_id=arm_id, token=token, **conf_set
                )
                rc_c, _o, e_c = _run_cmd(cast_cmd, timeout=60)
                if rc_c != 0:
                    append_marker(log_path, "END", arm_id, token)
                    ar = ArmResult(
                        arm_id=arm_id,
                        status="INVALID",
                        reason=f"cast_cmd_failed rc={rc_c} err={e_c[:200]!r}",
                        token=token,
                        conf_after={
                            k: conf_after.get(k, "") for k in conf_set
                        },
                    )
                    arm_results.append(ar)
                    print(
                        f"ARM {arm_id} INVALID reason={ar.reason}", flush=True
                    )
                    continue

            # simulation hook (self-test / host): append synthetic daemon lines
            if simulate is not None:
                sim = simulate.get(arm_id)
                if sim is not None:
                    with log_path.open("a", encoding="utf-8") as f:
                        f.write(sim if sim.endswith("\n") else sim + "\n")

            # settle
            arm_settle = float(arm.get("settle_s", settle_s))
            if arm_settle > 0 and not spec.get("skip_sleep"):
                time.sleep(arm_settle)

            try:
                append_marker(log_path, "END", arm_id, token)
            except OSError as e:
                ar = ArmResult(
                    arm_id=arm_id,
                    status="INVALID",
                    reason=f"marker_end_write_fail err={e}",
                    token=token,
                )
                arm_results.append(ar)
                continue

            log_text = read_text(log_path) if log_path.is_file() else ""
            window, slice_reason = slice_between_markers(
                log_text, arm_id, token
            )
            if window is None:
                ar = ArmResult(
                    arm_id=arm_id,
                    status="INVALID",
                    reason=f"log_slice_fail {slice_reason}",
                    token=token,
                    conf_after={k: conf_after.get(k, "") for k in conf_set},
                )
                arm_results.append(ar)
                print(f"ARM {arm_id} INVALID reason={ar.reason}", flush=True)
                continue

            ar = validate_arm_window(
                arm_id=arm_id,
                window=window,
                expect_wire=expect_wire,
                conf_after=conf_after,
                conf_keys_set=conf_set,
                require_single_session=require_single,
            )
            ar.token = token
            arm_results.append(ar)
            if ar.status == "VALID":
                print(
                    f"ARM {arm_id} VALID measurements={json.dumps(ar.measurements)}",
                    flush=True,
                )
            else:
                print(
                    f"ARM {arm_id} INVALID reason={ar.reason}", flush=True
                )

    except Exception as e:  # noqa: BLE001
        abort_mid = True
        abort_reason = f"runner_exception {type(e).__name__}: {e}"
        traceback.print_exc()
    finally:
        ok_r, rsn = restore_conf(bak)
        result["restore"] = "RESTORE_OK" if ok_r else "RESTORE_FAIL"
        result["restore_detail"] = rsn
        print(rsn, flush=True)
        if not ok_r:
            abort_mid = True
            abort_reason = abort_reason or rsn

    result["arms"] = [asdict(a) for a in arm_results]

    if abort_mid or result["restore"] != "RESTORE_OK":
        result["verdict"] = "ABORT_USER_STATE"
        result["rc"] = RC_ABORT
        result["reason"] = abort_reason or result.get("restore_detail", "")
    else:
        n_valid = sum(1 for a in arm_results if a.status == "VALID")
        n_inv = sum(1 for a in arm_results if a.status == "INVALID")
        if n_inv == 0 and n_valid > 0:
            result["verdict"] = "EXPERIMENT_OK"
            result["rc"] = RC_OK
        elif n_valid == 0 and n_inv == 0:
            result["verdict"] = "UNSCORED"
            result["rc"] = RC_UNSCORED
            result["reason"] = "no_arms"
        else:
            result["verdict"] = "ARMS_INVALID"
            result["rc"] = RC_INVALID
            result["reason"] = f"valid={n_valid} invalid={n_inv}"

    print(
        f"VERDICT={result['verdict']} rc={result['rc']} "
        f"restore={result['restore']}",
        flush=True,
    )
    _write_result(out_dir, result)
    return result


def _write_result(out_dir: Path, result: dict[str, Any]) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "result.json"
    write_text_atomic(path, json.dumps(result, indent=2, sort_keys=True) + "\n")
    # sentinel LAST so pollers see complete JSON
    (out_dir / "COMPLETE").write_text(
        f"rc={result.get('rc')}\nverdict={result.get('verdict')}\n",
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# self-test (host, red-before-green)
# ---------------------------------------------------------------------------


def _self_test() -> int:
    failures: list[str] = []

    # Prefer project-local scratch (agents must not depend on /tmp).
    scratch_root = os.environ.get("EXP_RUNNER_TEST_TMP")
    if not scratch_root:
        here = Path(__file__).resolve().parent.parent
        scratch_root = str(here / ".agent-work" / "w-instr" / "exp_runner_st")
    Path(scratch_root).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="exp_runner_st_", dir=scratch_root) as td:
        root = Path(td)
        conf = root / "misterplex.conf"
        log = root / "misterplexd.log"
        conf.write_text(
            "# user owned\nDECODE=320x240\nWEAK_BITRATE=2000\nPRESENT=fpga\n",
            encoding="utf-8",
        )
        log.write_text("boot\n", encoding="utf-8")
        orig = md5_file(conf)

        # --- backup happy path ---
        bak = backup_conf(conf, root / "c.bak")
        if not bak.ok or bak.orig_md5 != orig:
            failures.append(f"backup_ok {bak}")
        else:
            print("SELF_TEST backup_ok md5 match OK")

        # --- backup fail: missing conf ---
        bad = backup_conf(root / "nope.conf", root / "x.bak")
        if bad.ok:
            failures.append("backup_missing_conf should fail")
        else:
            print("SELF_TEST backup_missing ABORT-class OK")

        # --- restore ---
        conf.write_text("MUTATED=1\n", encoding="utf-8")
        ok_r, rsn = restore_conf(bak)
        if not ok_r or md5_file(conf) != orig:
            failures.append(f"restore {rsn} md5={md5_file(conf)}")
        else:
            print("SELF_TEST RESTORE_OK byte-exact OK")

        # --- (a) conf write no-op → INVALID ---
        out_a = root / "out_noop"
        # skip_conf_write leaves WEAK_BITRATE=2000; arm expects 1200
        # simulate log with default 2000 only (the parent failure mode)
        spec_a = {
            "experiment_id": "rbg_noop",
            "conf_path": str(conf),
            "log_path": str(log),
            "bak_path": str(root / "bak_a"),
            "settle_s": 0,
            "skip_restart": True,
            "skip_sleep": True,
            "restart_cmd": "",
            "simulate": {
                "br=1200": (
                    "misterplexd: PLAY https://x/start.mp4?"
                    "videoResolution=320x240&maxVideoBitrate=2000&videoCodec=h264\n"
                    "media: spawn single-process /media/fat/misterplex/bin/ffmpeg "
                    "-i https://x/start.mp4?maxVideoBitrate=2000\n"
                    "media: frames=100 vfps=24.0 drops=0 measured=320x240\n"
                )
            },
            "arms": [
                {
                    "id": "br=1200",
                    "conf_set": {"WEAK_BITRATE": "1200"},
                    "expect_wire": {"maxVideoBitrate": "1200"},
                    "skip_conf_write": True,  # deliberate no-op
                    "settle_s": 0,
                }
            ],
        }
        # restore conf to known baseline first
        conf.write_text(
            "# user owned\nDECODE=320x240\nWEAK_BITRATE=2000\nPRESENT=fpga\n",
            encoding="utf-8",
        )
        ra = run_experiment(spec_a, out_a)
        if ra["rc"] != RC_INVALID:
            failures.append(f"noop want rc=4 got {ra['rc']} {ra}")
        arm0 = (ra.get("arms") or [{}])[0]
        if arm0.get("status") != "INVALID":
            failures.append(f"noop arm status {arm0}")
        if "wire_expect_missing" not in (arm0.get("reason") or "") and \
           "conf_write_not_landed" not in (arm0.get("reason") or ""):
            failures.append(f"noop reason {arm0.get('reason')}")
        if ra.get("restore") != "RESTORE_OK":
            failures.append(f"noop restore {ra.get('restore')}")
        # must NOT emit a measurement value for invalid arm
        if arm0.get("measurements"):
            failures.append(f"noop leaked measurements {arm0.get('measurements')}")
        print(
            f"SELF_TEST conf_noop → INVALID rc={ra['rc']} "
            f"reason={arm0.get('reason')!r} OK"
        )

        # --- (b) empty window → INVALID ---
        conf.write_text(
            "# user owned\nDECODE=320x240\nWEAK_BITRATE=2000\nPRESENT=fpga\n",
            encoding="utf-8",
        )
        log.write_text("boot\n", encoding="utf-8")
        out_b = root / "out_empty"
        spec_b = {
            "experiment_id": "rbg_empty",
            "conf_path": str(conf),
            "log_path": str(log),
            "bak_path": str(root / "bak_b"),
            "settle_s": 0,
            "skip_restart": True,
            "skip_sleep": True,
            "restart_cmd": "",
            "simulate": {"br=800": ""},  # empty — dropped command class
            "arms": [
                {
                    "id": "br=800",
                    "conf_set": {"WEAK_BITRATE": "800"},
                    "expect_wire": {"maxVideoBitrate": "800"},
                    "settle_s": 0,
                }
            ],
        }
        rb = run_experiment(spec_b, out_b)
        if rb["rc"] != RC_INVALID:
            failures.append(f"empty want rc=4 got {rb['rc']}")
        armb = (rb.get("arms") or [{}])[0]
        if armb.get("status") != "INVALID":
            failures.append(f"empty status {armb}")
        if "empty_window" not in (armb.get("reason") or ""):
            failures.append(f"empty reason {armb.get('reason')}")
        if armb.get("measurements"):
            failures.append("empty leaked measurements")
        print(
            f"SELF_TEST empty_window → INVALID rc={rb['rc']} "
            f"reason={armb.get('reason')!r} OK"
        )

        # --- multi-session window → INVALID ---
        conf.write_text(
            "DECODE=320x240\nWEAK_BITRATE=2000\n", encoding="utf-8"
        )
        log.write_text("boot\n", encoding="utf-8")
        out_c = root / "out_multi"
        multi_log = (
            "misterplexd: PLAY https://x/?maxVideoBitrate=2000&videoResolution=320x240\n"
            "media: spawn single-process ffmpeg -i https://x/?maxVideoBitrate=2000\n"
            "media: frames=10 measured=312x240\n"
            "misterplexd: PLAY https://x/?maxVideoBitrate=397&videoResolution=624x480\n"
            "media: spawn single-process ffmpeg -i https://x/?maxVideoBitrate=397\n"
            "media: frames=20 measured=624x480\n"
        )
        spec_c = {
            "experiment_id": "rbg_multi",
            "conf_path": str(conf),
            "log_path": str(log),
            "bak_path": str(root / "bak_c"),
            "skip_restart": True,
            "skip_sleep": True,
            "restart_cmd": "",
            "simulate": {"br=397": multi_log},
            "arms": [
                {
                    "id": "br=397",
                    "conf_set": {"WEAK_BITRATE": "397"},
                    "expect_wire": {"maxVideoBitrate": "397"},
                    "settle_s": 0,
                }
            ],
        }
        rc_m = run_experiment(spec_c, out_c)
        armc = (rc_m.get("arms") or [{}])[0]
        if armc.get("status") != "INVALID" or "multi_session" not in (
            armc.get("reason") or ""
        ):
            failures.append(f"multi {armc}")
        else:
            print(
                f"SELF_TEST multi_session → INVALID reason={armc.get('reason')!r} OK"
            )

        # --- happy VALID arm ---
        conf.write_text(
            "DECODE=320x240\nWEAK_BITRATE=2000\n", encoding="utf-8"
        )
        log.write_text("boot\n", encoding="utf-8")
        out_d = root / "out_ok"
        good = (
            "misterplexd: PLAY https://x/start.mp4?"
            "videoResolution=320x240&maxVideoBitrate=1500&videoCodec=h264\n"
            "media: spawn single-process /media/fat/misterplex/bin/ffmpeg "
            "-i https://x/start.mp4?maxVideoBitrate=1500\n"
            "media: frames=200 vfps=23.9 drops=1 measured=320x240\n"
        )
        spec_d = {
            "experiment_id": "rbg_ok",
            "conf_path": str(conf),
            "log_path": str(log),
            "bak_path": str(root / "bak_d"),
            "skip_restart": True,
            "skip_sleep": True,
            "restart_cmd": "",
            "simulate": {"br=1500": good},
            "arms": [
                {
                    "id": "br=1500",
                    "conf_set": {"WEAK_BITRATE": "1500"},
                    "expect_wire": {"maxVideoBitrate": "1500"},
                    "settle_s": 0,
                }
            ],
        }
        rd = run_experiment(spec_d, out_d)
        armd = (rd.get("arms") or [{}])[0]
        if rd["rc"] != RC_OK or armd.get("status") != "VALID":
            failures.append(f"valid arm {rd}")
        if armd.get("measurements", {}).get("maxVideoBitrate") != "1500":
            failures.append(f"valid measurements {armd.get('measurements')}")
        if rd.get("restore") != "RESTORE_OK":
            failures.append("valid restore fail")
        print(
            f"SELF_TEST happy_path VALID rc={rd['rc']} "
            f"meas={armd.get('measurements')} OK"
        )

        # --- backup abort before mutation (chmod-less: use unwritable bak dir) ---
        conf.write_text("DECODE=320x240\n", encoding="utf-8")
        # bak path under a file-as-directory to force cp fail
        blocker = root / "block"
        blocker.write_text("x", encoding="utf-8")
        out_e = root / "out_abort"
        spec_e = {
            "experiment_id": "rbg_abort",
            "conf_path": str(conf),
            "log_path": str(log),
            "bak_path": str(blocker / "bak"),  # parent is file → fail
            "skip_restart": True,
            "skip_sleep": True,
            "restart_cmd": "",
            "arms": [
                {
                    "id": "x",
                    "conf_set": {"WEAK_BITRATE": "1"},
                    "expect_wire": {"maxVideoBitrate": "1"},
                }
            ],
        }
        re_ = run_experiment(spec_e, out_e)
        if re_["rc"] != RC_ABORT:
            failures.append(f"abort want 80 got {re_['rc']} {re_}")
        # conf must be unchanged (still no WEAK_BITRATE=1 if write never happened)
        if "WEAK_BITRATE=1" in conf.read_text(encoding="utf-8"):
            failures.append("abort mutated conf")
        print(f"SELF_TEST backup_fail ABORT rc={re_['rc']} conf_untouched OK")

    if failures:
        print("SELF_TEST_FAIL")
        for f in failures:
            print(f"  FAIL: {f}")
        return RC_USAGE
    print("SELF_TEST_OK ondevice_experiment_runner")
    return RC_OK


def load_spec(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_st = sub.add_parser("self-test", help="host RBG, no device")
    p_st.set_defaults(fn="self-test")

    p_run = sub.add_parser("run", help="execute experiment (on-device)")
    p_run.add_argument("--spec", required=True, type=Path)
    p_run.add_argument("--out-dir", required=True, type=Path)
    p_run.set_defaults(fn="run")

    p_v = sub.add_parser(
        "validate-window", help="validate a pre-sliced log window"
    )
    p_v.add_argument("--window-file", required=True, type=Path)
    p_v.add_argument("--arm-id", default="arm")
    p_v.add_argument(
        "--expect",
        action="append",
        default=[],
        help="key=value expected wire field (repeatable)",
    )
    p_v.add_argument(
        "--conf-after",
        action="append",
        default=[],
        help="key=value conf post-state (repeatable)",
    )
    p_v.set_defaults(fn="validate-window")

    args = ap.parse_args(argv)

    if args.fn == "self-test":
        return _self_test()

    if args.fn == "validate-window":
        window = args.window_file.read_text(encoding="utf-8", errors="replace")
        expect = {}
        for item in args.expect:
            k, v = item.split("=", 1)
            expect[k] = v
        conf_after = {}
        for item in args.conf_after:
            k, v = item.split("=", 1)
            conf_after[k] = v
        conf_keys = dict(conf_after) if conf_after else dict(expect)
        # map maxVideoBitrate expect back if only wire given
        ar = validate_arm_window(
            arm_id=args.arm_id,
            window=window,
            expect_wire=expect,
            conf_after=conf_after or conf_keys,
            conf_keys_set=conf_keys,
        )
        print(json.dumps(asdict(ar), indent=2))
        return RC_OK if ar.status == "VALID" else RC_INVALID

    if args.fn == "run":
        if not args.spec.is_file():
            print(
                f"VERDICT=UNSCORED rc={RC_UNSCORED} reason=spec_missing",
                file=sys.stderr,
            )
            return RC_UNSCORED
        try:
            spec = load_spec(args.spec)
        except (OSError, json.JSONDecodeError) as e:
            print(
                f"VERDICT=UNSCORED rc={RC_UNSCORED} reason=spec_bad {e}",
                file=sys.stderr,
            )
            return RC_UNSCORED
        result = run_experiment(spec, args.out_dir)
        return int(result["rc"])

    return RC_USAGE


if __name__ == "__main__":
    sys.exit(main())
