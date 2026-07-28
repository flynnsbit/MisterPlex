#!/usr/bin/env python3
"""Adversarial probes for the core-subtree reachability gate.

Creates a disposable snapshot under build/ and mutates that copy only.  It does
not edit worker branches or run Quartus.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(cmd: list[str], cwd: Path, check: bool = False) -> tuple[int, str]:
    proc = subprocess.run(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    if check and proc.returncode != 0:
        raise RuntimeError(f"command failed rc={proc.returncode}: {' '.join(cmd)}\n{proc.stdout}")
    return proc.returncode, proc.stdout


def make_snapshot(ref: str) -> Path:
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    pid = os.getpid()
    snap = build / f'w_audit_core_subtree_attack_{pid}'
    if snap.exists():
        raise SystemExit(f'snapshot path already exists: {snap}')
    snap.mkdir()
    tar_path = build / f'w_audit_core_subtree_attack_{pid}.tar'
    run(['git', 'archive', '--format=tar', ref, '-o', str(tar_path)], ROOT, check=True)
    run(['tar', '-xf', str(tar_path), '-C', str(snap)], ROOT, check=True)
    run(['git', 'init', '--quiet'], snap, check=True)
    run(['git', 'add', '.'], snap, check=True)
    run(['git', '-c', 'user.email=w-audit@example.invalid', '-c', 'user.name=W-AUDIT', 'commit', '--quiet', '-m', 'snapshot'], snap, check=True)
    return snap


def gate(snap: Path, *args: str) -> tuple[int, str]:
    return run(['python3', 'scripts/check_rtl_module_instantiations.py', *args], snap)


def restore_core(snap: Path) -> None:
    run(['git', 'restore', 'fpga/Plex_MiSTer/rtl/h264_decode_core.sv'], snap, check=True)


def inject_before_endmodule(snap: Path, text: str) -> None:
    p = snap / 'fpga/Plex_MiSTer/rtl/h264_decode_core.sv'
    body = p.read_text()
    if 'endmodule\n' not in body:
        raise RuntimeError('h264_decode_core.sv lacks endmodule marker')
    p.write_text(body.replace('endmodule\n', text + 'endmodule\n', 1))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--ref', default='origin/w-deblock-seam', help='Git ref containing the --root/--require gate')
    args = ap.parse_args(argv[1:])

    ref_sha = subprocess.check_output(['git', 'rev-parse', '--short', args.ref], cwd=ROOT, text=True).strip()
    snap = make_snapshot(args.ref)
    print(f'W_AUDIT_CORE_SUBTREE_ATTACK ref={args.ref} ref_sha={ref_sha} snapshot={snap.relative_to(ROOT)}')

    rc_core_green, out_core_green = gate(snap, '--root', 'h264_decode_core', '--require', 'h264_deblock_writeback_ctrl')
    rc_emu_core, out_emu_core = gate(snap, '--root', 'emu', '--require', 'h264_decode_core')
    print(f'CASE dead_root_core_subtree_green rc_core_root={rc_core_green} rc_emu_requires_core={rc_emu_core}')
    print(out_core_green.strip())
    print(out_emu_core.strip())

    rc_baseline, out_baseline = gate(snap, '--root', 'h264_decode_core', '--require', 'h264_inter_mc_part')
    print(f'CASE baseline_missing_inter_mc_part rc={rc_baseline}')
    print(out_baseline.strip())

    restore_core(snap)
    inject_before_endmodule(snap, '''
    generate
        if (0) begin : w_audit_false_reachable_disabled_generate
            h264_inter_mc_part u_w_audit_false_reachable();
        end
    endgenerate

''')
    rc_disabled, out_disabled = gate(snap, '--root', 'h264_decode_core', '--require', 'h264_inter_mc_part')
    print(f'CASE disabled_generate_false_reachable rc={rc_disabled}')
    print(out_disabled.strip())

    restore_core(snap)
    inject_before_endmodule(snap, '''
    h264_inter_mc_part \\w_audit.escaped_inst ();

''')
    rc_escaped, out_escaped = gate(snap, '--root', 'h264_decode_core', '--require', 'h264_inter_mc_part')
    print(f'CASE escaped_instance_false_unreachable rc={rc_escaped}')
    print(out_escaped.strip())

    restore_core(snap)
    child = snap / 'fpga/Plex_MiSTer/rtl/w_audit_qip_missing_core_child.sv'
    child.write_text('module w_audit_qip_missing_core_child(input logic a, output logic b);\n    assign b = a;\nendmodule\n')
    run(['git', 'add', str(child.relative_to(snap))], snap, check=True)
    inject_before_endmodule(snap, '''
    wire w_audit_qip_missing_wire;
    w_audit_qip_missing_core_child u_w_audit_qip_missing(.a(clk), .b(w_audit_qip_missing_wire));

''')
    rc_qip, out_qip = gate(snap, '--root', 'h264_decode_core', '--require', 'w_audit_qip_missing_core_child')
    qip_contains = 'w_audit_qip_missing_core_child' in (snap / 'fpga/Plex_MiSTer/files.qip').read_text(errors='ignore')
    print(f'CASE qip_omission_false_reachable rc={rc_qip} files_qip_contains={int(qip_contains)}')
    print(out_qip.strip())

    print('W_AUDIT_CORE_SUBTREE_ATTACK_DONE report_mode_rc0')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
