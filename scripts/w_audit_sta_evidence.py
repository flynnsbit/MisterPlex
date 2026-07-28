#!/usr/bin/env python3
"""W-AUDIT read-only audit of W-FIT hour27 STA/RBF evidence."""
from __future__ import annotations

import datetime as dt
import hashlib
import re
import subprocess
from pathlib import Path

INTEG = Path('/home/flynnsbit/Projects/mp-wt-integ')
REPORTS = {
    'reported_with_old_false_paths_wfit_b': INTEG / 'fpga/Plex_MiSTer/remote_out/wfit-hour27-b/Plex.sta.rpt',
    'reported_without_old_false_paths_copy': INTEG / '.copilot-logs/Plex.no_false_paths.sta.rpt',
    'deploy_candidate_fb4bad_sdc_b': INTEG / 'fpga/Plex_MiSTer/remote_out/wfit-hour27-sdc-b/Plex.sta.rpt',
    'deploy_candidate_fb4bad_bdiag_b': INTEG / 'fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.sta.rpt',
    'known_bad_baseline_slot11': INTEG / 'fpga/Plex_MiSTer/remote_out/slot11/Plex.sta.rpt',
}
BUILDS = {
    'wfit-hour27-b': INTEG / 'fpga/Plex_MiSTer/remote_out/wfit-hour27-b',
    'wfit-hour27-sdc-b': INTEG / 'fpga/Plex_MiSTer/remote_out/wfit-hour27-sdc-b',
    'wfit-hour27-bdiag-b': INTEG / 'fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b',
}
REMOTE_BUILDS = {
    'wfit-hour27-b': Path('/home/flynnsbit/mplex-builds/wfit-hour27-b/Plex_MiSTer'),
    'wfit-hour27-no-false-paths': Path('/home/flynnsbit/mplex-builds/wfit-hour27-no-false-paths/Plex_MiSTer'),
    'wfit-hour27-sdc-b': Path('/home/flynnsbit/mplex-builds/wfit-hour27-sdc-b/Plex_MiSTer'),
    'wfit-hour27-bdiag-b': Path('/home/flynnsbit/mplex-builds/wfit-hour27-bdiag-b/Plex_MiSTer'),
}


def md5(path: Path) -> str:
    h = hashlib.md5()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def stamp(path: Path) -> str:
    return dt.datetime.fromtimestamp(path.stat().st_mtime).isoformat()


def parse_sta(path: Path) -> dict[str, object]:
    text = path.read_text(errors='ignore')
    worst = {m.group(1): float(m.group(2)) for m in re.finditer(r'Info \(332146\): Worst-case ([a-z ]+) slack is (-?\d+\.\d+)', text)}
    rows = []
    current = None
    saw_header = False
    for line in text.splitlines():
        m = re.match(r'; (Setup|Hold|Recovery|Removal|Minimum Pulse Width) Summary\s+;', line)
        if m:
            current = m.group(1)
            saw_header = False
            continue
        if current and 'Clock' in line and 'Slack' in line:
            saw_header = True
            continue
        if current and saw_header and line.startswith(';'):
            parts = [c.strip() for c in line.strip().strip(';').split(';')]
            if len(parts) >= 3 and parts[0] and not parts[0].startswith('+') and parts[0] != 'Clock':
                try:
                    slack = float(parts[1])
                    tns = float(parts[2]) if parts[2] not in {'--', ''} else 0.0
                except ValueError:
                    continue
                rows.append((current, parts[0], slack, tns))
    unconstrained = {}
    idx = text.find('; Unconstrained Paths Summary', 10000)
    if idx >= 0:
        for line in text[idx:idx + 1000].splitlines():
            m = re.match(r';\s*([^;]+?)\s*;\s*(\d+)\s*;\s*(\d+)\s*;', line)
            if m and m.group(1).strip() != 'Property':
                unconstrained[m.group(1).strip()] = (int(m.group(2)), int(m.group(3)))
    return {
        'md5': md5(path),
        'size': path.stat().st_size,
        'mtime': stamp(path),
        'first_line': text.splitlines()[0] if text.splitlines() else '',
        'worst': worst,
        'summary_rows': len(rows),
        'negative_slack_rows': sum(1 for _, _, slack, _ in rows if slack < 0),
        'negative_tns_rows': sum(1 for _, _, _, tns in rows if tns < 0),
        'sections': sorted({r[0] for r in rows}),
        'unconstrained': unconstrained,
        'old_cut_signal_hits': {needle: text.count(needle) for needle in ['m1_want_s1', 'reset_s1', 'underrun_count', 'frame_mbox_last']},
    }


def active_constraint_lines(sdc: Path) -> list[str]:
    if not sdc.exists():
        return []
    out = []
    for no, line in enumerate(sdc.read_text(errors='ignore').splitlines(), 1):
        stripped = line.strip()
        if stripped and not stripped.startswith('#') and ('set_false_path' in stripped or 'set_max_delay' in stripped):
            out.append(f'{no}: {stripped}')
    return out


def main() -> int:
    print(f'W_AUDIT_STA_WORKTREE branch={subprocess.check_output(["git", "-C", str(INTEG), "branch", "--show-current"], text=True).strip()} head={subprocess.check_output(["git", "-C", str(INTEG), "rev-parse", "--short", "HEAD"], text=True).strip()}')
    for name, build in BUILDS.items():
        rbf = build / 'Plex.rbf'
        sta = build / 'Plex.sta.rpt'
        fit = build / 'Plex.fit.rpt'
        if rbf.exists():
            print(f'W_AUDIT_RBF build={name} md5={md5(rbf)} size={rbf.stat().st_size} mtime={stamp(rbf)}')
        if fit.exists() and sta.exists():
            print(f'W_AUDIT_BUILD_ORDER build={name} fit_mtime={stamp(fit)} rbf_mtime={stamp(rbf)} sta_mtime={stamp(sta)}')
    for name, build in REMOTE_BUILDS.items():
        print(f'W_AUDIT_REMOTE_SDC build={name}')
        for line in active_constraint_lines(build / 'Plex.sdc'):
            print(f'  {line}')
    for name, rpt in REPORTS.items():
        if not rpt.exists():
            print(f'W_AUDIT_STA_MISSING name={name} path={rpt}')
            continue
        data = parse_sta(rpt)
        worst = ','.join(f'{k}={v:.3f}' for k, v in sorted(data['worst'].items()))
        print(f'W_AUDIT_STA_REPORT name={name} md5={data["md5"]} size={data["size"]} mtime={data["mtime"]} first_line={data["first_line"]!r}')
        print(f'  worst {worst}')
        print(f'  rows={data["summary_rows"]} neg_slack={data["negative_slack_rows"]} neg_tns={data["negative_tns_rows"]} sections={"/".join(data["sections"])}')
        print(f'  unconstrained={data["unconstrained"]}')
        print(f'  old_cut_signal_hits={data["old_cut_signal_hits"]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
