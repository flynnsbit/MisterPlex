"""Mutation harness: each mutation of score_idle_screen.py must turn
tests/unit/test_capture_gate_states.py RED.  A mutation that stays green
means the test does not actually constrain that behaviour.
"""
import shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "score_idle_screen.py"
PREFLIGHT = ROOT / "scripts" / "capture_preflight.py"
TEST = ROOT / "tests" / "unit" / "test_capture_gate_states.py"
BAK = GATE.with_suffix(".py.mutbak")

MUTATIONS = [
    (PREFLIGHT, "filler-check-removed",
     "    if filler >= FILLER_DOMINANCE_THRESHOLD:",
     "    if False:"),
    (PREFLIGHT, "filler-threshold-unreachable",
     "FILLER_DOMINANCE_THRESHOLD: float = 0.50",
     "FILLER_DOMINANCE_THRESHOLD: float = 1.10"),
    (PREFLIGHT, "filler-graded-as-BLACK-blaming-the-core",
     '            "state": "NO_SIGNAL",\n            "unique_hashes": unique,\n            "total_frames": total,\n            "mean_luma": round(luma, 2),\n            "spatial_std": round(std, 2),\n            "filler_frac": round(filler, 4),',
     '            "state": "BLACK_SIGNAL",\n            "unique_hashes": unique,\n            "total_frames": total,\n            "mean_luma": round(luma, 2),\n            "spatial_std": round(std, 2),\n            "filler_frac": round(filler, 4),'),
    (GATE, "always-pass",
     '    state = signal["state"]\n',
     '    state = signal["state"]\n    return EXIT_PASS\n'),
    (GATE, "no-signal-passes",
     '    if state == "NO_SIGNAL":\n        print("REFUSE: no usable HDMI signal',
     '    if state == "NO_SIGNAL":\n        return EXIT_PASS\n        print("REFUSE: no usable HDMI signal'),
    (GATE, "stale-passes",
     '    if state == "STALE_CAPTURE":\n        print("REFUSE: capture is frozen',
     '    if state == "STALE_CAPTURE":\n        return EXIT_PASS\n        print("REFUSE: capture is frozen'),
    (GATE, "black-blamed-on-core-regardless-of-host",
     '        if args.host and not host_reachable(args.host):',
     '        if False:'),
    (GATE, "black-always-refuses",
     '        print("FAIL: valid signal but the screen is BLACK',
     '        return EXIT_REFUSE\n        print("FAIL: valid signal but the screen is BLACK'),
    (GATE, "chevron-always-present",
     '    chevron = score_chevron(frame)',
     '    chevron = score_chevron(frame)\n    chevron["present"] = True'),
    (GATE, "chevron-never-present",
     '    chevron = score_chevron(frame)',
     '    chevron = score_chevron(frame)\n    chevron["present"] = False'),
    (GATE, "left-edge-never-detected",
     '    edge = score_left_edge(frame)',
     '    edge = score_left_edge(frame)\n    edge["present"] = False'),
    (GATE, "left-edge-always-detected",
     '    edge = score_left_edge(frame)',
     '    edge = score_left_edge(frame)\n    edge["present"] = True'),
    (GATE, "chevron-aspect-gate-removed",
     '    if not (lo <= aspect <= hi):',
     '    if False:'),
    (GATE, "chevron-fill-gate-removed",
     '    if fill < CHEVRON_MIN_FILL:',
     '    if False:'),
    (GATE, "chevron-aspect-range-widened-to-anything",
     'CHEVRON_ASPECT_RANGE = (0.40, 2.50)',
     'CHEVRON_ASPECT_RANGE = (0.0, 1000.0)'),
    (GATE, "chevron-fill-threshold-zeroed",
     'CHEVRON_MIN_FILL = 0.18',
     'CHEVRON_MIN_FILL = 0.0'),
    (GATE, "provenance-check-removed",
     '    if args.expect_corename or args.expect_rbf_md5:',
     '    if False:'),
]

def run_test() -> int:
    return subprocess.run([sys.executable, str(TEST)],
                          capture_output=True, text=True).returncode

ORIG = {GATE: GATE.read_text(), PREFLIGHT: PREFLIGHT.read_text()}
for f in ORIG:
    shutil.copy2(f, f.with_suffix(".py.mutbak"))
survivors, killed = [], []
try:
    base = run_test()
    if base != 0:
        print(f"BASELINE NOT GREEN (rc={base}) — cannot mutation-test")
        raise SystemExit(2)
    print("baseline rc=0 GREEN")
    for target, name, old, new in MUTATIONS:
        orig = ORIG[target]
        if old not in orig:
            print(f"SKIP  {name}: anchor not found")
            survivors.append(name + " (anchor missing)")
            continue
        target.write_text(orig.replace(old, new, 1))
        rc = run_test()
        target.write_text(orig)
        if rc == 0:
            print(f"SURVIVED  {name}  (test still green — VACUOUS)")
            survivors.append(name)
        else:
            print(f"KILLED    {name}  (rc={rc})")
            killed.append(name)
finally:
    for f, txt in ORIG.items():
        f.write_text(txt)
        f.with_suffix(".py.mutbak").unlink()

print(f"\nScope: {len(MUTATIONS)} mutations; killed {len(killed)}, survived {len(survivors)}")
if survivors:
    print("SURVIVORS: " + ", ".join(survivors))
    raise SystemExit(1)
print("MUTATION_OK — every mutation turned the test red")
