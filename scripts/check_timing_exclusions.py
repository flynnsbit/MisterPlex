#!/usr/bin/env python3
"""check_timing_exclusions.py — verify no SDC constraint hides clk_sys↔clk_ddr timing paths.

WHAT THIS GATE LITERALLY CHECKS:
  1. No set_clock_groups -asynchronous appears in any SDC file
  2. No set_false_path targets registers in both general[0] (clk_sys) and general[2] (clk_ddr) domains
  3. The existing set_clock_groups -exclusive groups all core PLL outputs TOGETHER (not separately)

WHAT THIS GATE DOES NOT COVER:
  - It does not check for set_multicycle_path that could relax timing
  - It does not check for manually created clocks that shadow the PLL outputs
  - It performs text matching, not semantic SDC parsing — a sufficiently
    obfuscated constraint could evade it

RED PROOF:  Run with --inject-red to add a synthetic asynchronous exclusion
            and confirm the gate catches it (rc=1).
"""
import argparse
import re
import sys
from pathlib import Path

# Patterns that would hide the clk_sys↔clk_ddr crossing
ASYNC_PATTERN = re.compile(r'set_clock_groups\s+.*-asynchronous', re.IGNORECASE)

# Registers known to be in the clk_sys↔clk_ddr crossing
CLK_SYS_REGS = ['ddr_bus_arbiter', 'ddr_bitstream_reader', 'current_session',
                 'decode_stub', 'stream_path']
CLK_DDR_REGS = ['ddr_frame_store', 'y_valid', 'DDRAM_ADDR', 'disp_buf',
                'fstore', 'present_core']

# The correct grouping: all core PLL outputs in ONE exclusive group
# The SDC uses backslash line continuation, so we join lines before matching.
CORRECT_GROUP_PATTERN = re.compile(
    r'set_clock_groups\s+-exclusive\b.*'
    r'\*\|pll\|pll_inst\|altera_pll_i\|\*\[\*\]\.\*\|divclk',
    re.DOTALL
)


def check_file(path: Path, inject_red: bool = False) -> list[str]:
    """Return list of violations found in an SDC file."""
    violations = []
    text = path.read_text()

    if inject_red:
        text += ('\n# INJECTED FOR RED PROOF — remove after testing\n'
                 'set_clock_groups -asynchronous '
                 '-group [get_clocks {*general[0]*divclk}] '
                 '-group [get_clocks {*general[2]*divclk}]\n')

    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('#'):
            continue

        # Check 1: no -asynchronous anywhere
        if ASYNC_PATTERN.search(stripped):
            violations.append(f'{path}:{i}: set_clock_groups -asynchronous found: {stripped}')

        # Check 2: no set_false_path targeting both domains
        if 'set_false_path' in stripped:
            has_sys = any(r in stripped for r in CLK_SYS_REGS)
            has_ddr = any(r in stripped for r in CLK_DDR_REGS)
            if has_sys and has_ddr:
                violations.append(
                    f'{path}:{i}: set_false_path targets registers in BOTH '
                    f'clk_sys and clk_ddr domains: {stripped}')

            # Also catch general[0]↔general[2] by clock name
            if 'general[0]' in stripped and 'general[2]' in stripped:
                violations.append(
                    f'{path}:{i}: set_false_path references both general[0] '
                    f'and general[2] clock domains: {stripped}')

    # Check 3: if this file has set_clock_groups -exclusive, verify core PLL
    # outputs are grouped TOGETHER (same -group clause), not separated
    # Join continuation lines first (backslash + newline)
    joined = text.replace('\\\n', ' ')
    if 'set_clock_groups' in joined and '-exclusive' in joined:
        if not CORRECT_GROUP_PATTERN.search(joined):
            if 'pll_inst' in joined or 'general[' in joined:
                violations.append(
                    f'{path}: set_clock_groups -exclusive does not group all '
                    f'core PLL outputs together — may be splitting synchronous clocks')

    return violations


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sta-rpt', help='STA report (unused, kept for CLI compat)')
    parser.add_argument('--sdc', nargs='*', help='SDC files to check (default: auto-find)')
    parser.add_argument('--inject-red', action='store_true',
                        help='Inject a synthetic violation for red proof')
    args = parser.parse_args()

    # Find SDC files
    if args.sdc:
        sdc_files = [Path(f) for f in args.sdc]
    else:
        base = Path('fpga/Plex_MiSTer')
        if not base.exists():
            base = Path('.')
        sdc_files = list(base.glob('**/*.sdc'))

    if not sdc_files:
        print('ERROR: no SDC files found', file=sys.stderr)
        sys.exit(2)

    all_violations = []
    for f in sdc_files:
        violations = check_file(f, inject_red=args.inject_red)
        all_violations.extend(violations)

    if all_violations:
        print(f'FAIL: {len(all_violations)} timing exclusion violation(s) found:')
        for v in all_violations:
            print(f'  {v}')
        sys.exit(1)
    else:
        print(f'PASS: {len(sdc_files)} SDC file(s) checked, no exclusions hiding '
              f'clk_sys↔clk_ddr crossing.')
        if args.inject_red:
            print('ERROR: --inject-red was set but no violation detected. '
                  'Gate cannot fail — this is a broken gate.', file=sys.stderr)
            sys.exit(3)
        sys.exit(0)


if __name__ == '__main__':
    main()
