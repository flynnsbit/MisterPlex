"""Mutation harness: each mutation of score_idle_screen.py must turn
tests/unit/test_capture_gate_states.py RED.  A mutation that stays green
means the test does not actually constrain that behaviour.
"""
import shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "score_idle_screen.py"
TEST = ROOT / "tests" / "unit" / "test_capture_gate_states.py"
BAK = GATE.with_suffix(".py.mutbak")

MUTATIONS = [
    ("always-pass",
     '    state = signal["state"]\n',
     '    state = signal["state"]\n    return EXIT_PASS\n'),
    ("no-signal-passes",
     '    if state == "NO_SIGNAL":\n        print("REFUSE: no usable HDMI signal',
     '    if state == "NO_SIGNAL":\n        return EXIT_PASS\n        print("REFUSE: no usable HDMI signal'),
    ("stale-passes",
     '    if state == "STALE_CAPTURE":\n        print("REFUSE: capture is frozen',
     '    if state == "STALE_CAPTURE":\n        return EXIT_PASS\n        print("REFUSE: capture is frozen'),
    ("black-blamed-on-core-regardless-of-host",
     '        if args.host and not host_reachable(args.host):',
     '        if False:'),
    ("black-always-refuses",
     '        print("FAIL: valid signal but the screen is BLACK',
     '        return EXIT_REFUSE\n        print("FAIL: valid signal but the screen is BLACK'),
    ("chevron-always-present",
     '    chevron = score_chevron(frame)',
     '    chevron = score_chevron(frame)\n    chevron["present"] = True'),
    ("chevron-never-present",
     '    chevron = score_chevron(frame)',
     '    chevron = score_chevron(frame)\n    chevron["present"] = False'),
    ("left-edge-never-detected",
     '    edge = score_left_edge(frame)',
     '    edge = score_left_edge(frame)\n    edge["present"] = False'),
    ("left-edge-always-detected",
     '    edge = score_left_edge(frame)',
     '    edge = score_left_edge(frame)\n    edge["present"] = True'),
    ("provenance-check-removed",
     '    if args.expect_corename or args.expect_rbf_md5:',
     '    if False:'),
]

def run_test() -> int:
    return subprocess.run([sys.executable, str(TEST)],
                          capture_output=True, text=True).returncode

shutil.copy2(GATE, BAK)
orig = GATE.read_text()
survivors, killed = [], []
try:
    base = run_test()
    if base != 0:
        print(f"BASELINE NOT GREEN (rc={base}) — cannot mutation-test")
        raise SystemExit(2)
    print("baseline rc=0 GREEN")
    for name, old, new in MUTATIONS:
        if old not in orig:
            print(f"SKIP  {name}: anchor not found")
            survivors.append(name + " (anchor missing)")
            continue
        GATE.write_text(orig.replace(old, new, 1))
        rc = run_test()
        GATE.write_text(orig)
        if rc == 0:
            print(f"SURVIVED  {name}  (test still green — VACUOUS)")
            survivors.append(name)
        else:
            print(f"KILLED    {name}  (rc={rc})")
            killed.append(name)
finally:
    shutil.copy2(BAK, GATE)
    BAK.unlink()

print(f"\nScope: {len(MUTATIONS)} mutations; killed {len(killed)}, survived {len(survivors)}")
if survivors:
    print("SURVIVORS: " + ", ".join(survivors))
    raise SystemExit(1)
print("MUTATION_OK — every mutation turned the test red")
