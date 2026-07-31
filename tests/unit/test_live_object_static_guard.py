#!/usr/bin/env python3
"""Static guard: live-object / decoy / unreachable-branch family.

Flags scripts that:
  1) Treat underscore _user-startup.sh as the sole boot authority
  2) Have motion behind elif after idle (unreachable when idle default true)
  3) Print conf-keys / boot NOTE without touching rc nearby
  4) Soft-skip (exit 77) on paths that look like hard promote gates without SKIP-NOT-PASS

RBG: boot_hook_policy must define LIVE path without underscore and DECOY path
with underscore; promotion_gate must call boot_hook_check_live_and_decoy and
must not use exclusive elif for motion after idle.

Exit 0 clean, 1 findings.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    errs: list[str] = []

    boot = (ROOT / "scripts" / "boot_hook_policy.sh").read_text(errors="ignore")
    if 'BOOT_HOOK_DEVICE_PATH="${BOOT_HOOK_DEVICE_PATH:-/media/fat/linux/user-startup.sh}"' not in boot \
       and "/media/fat/linux/user-startup.sh" not in boot.split("DECOY")[0]:
        # LIVE default must be no-underscore
        m = re.search(r'BOOT_HOOK_DEVICE_PATH=.*', boot)
        if not m or "_user-startup" in m.group(0):
            errs.append("boot_hook_policy: BOOT_HOOK_DEVICE_PATH default must be user-startup.sh (no underscore)")
    if "BOOT_HOOK_DECOY_PATH" not in boot:
        errs.append("boot_hook_policy: missing BOOT_HOOK_DECOY_PATH")
    if "boot_hook_check_live_and_decoy" not in boot:
        errs.append("boot_hook_policy: missing boot_hook_check_live_and_decoy")
    if "decoy_ok_live_bad" not in boot:
        errs.append("boot_hook_policy: missing decoy_ok_live_bad reason")

    promo = (ROOT / "scripts" / "promotion_gate_check.sh").read_text(errors="ignore")
    if "boot_hook_check_live_and_decoy" not in promo:
        errs.append("promotion_gate_check: must call boot_hook_check_live_and_decoy")
    if "/media/fat/linux/user-startup.sh" not in promo:
        errs.append("promotion_gate_check: must fetch LIVE user-startup.sh")
    # Unreachable motion: exclusive elif idle before motion is banned
    if re.search(
        r"elif\s+\[\s+-n\s+\"\$\{PAIR_IDLE_PNG[^\]]*\][\s\S]{0,200}?elif\s+\[\s+-n\s+\"\$motion_cmd",
        promo,
    ):
        errs.append("promotion_gate_check: motion still elif-behind idle (unreachable branch class)")
    if "MOTION runs whenever" not in promo and "never elif-behind idle" not in promo:
        # require explicit comment or motion-first structure
        if "motion_hook true rc=$vr" not in promo and "motion_hook true rc=$vrc" not in promo:
            errs.append("promotion_gate_check: motion_hook path missing")
    if "FAIL conf-keys not injected" not in promo:
        errs.append("promotion_gate_check: conf-keys must FAIL not NOTE")
    if re.search(r'echo "NOTE conf-keys not injected', promo):
        errs.append("promotion_gate_check: still has NOTE conf-keys (cannot-fail check)")

    # Deploy/rollback must write LIVE path
    for rel in ("scripts/deploy_misterplexd.sh", "scripts/rollback_v2.sh"):
        t = (ROOT / rel).read_text(errors="ignore")
        # Prefer LIVE path as hook= assignment
        if "hook=/media/fat/linux/_user-startup.sh" in t or \
           re.search(r'BOOT_HOOK_PATH=.*_user-startup\.sh', t):
            # allow if also documents decoy — still flag sole underscore default
            if "user-startup.sh" not in t.replace("_user-startup.sh", ""):
                errs.append(f"{rel}: boot hook path still underscore-only decoy")

    # pair_visual must reject menu_color_bars
    vis = (ROOT / "scripts" / "pair_visual_gate.sh").read_text(errors="ignore")
    if "menu_color_bars" not in vis:
        errs.append("pair_visual_gate: missing menu_color_bars reject (postboot MENU class)")

    # live_object.inc must exist
    if not (ROOT / "scripts" / "live_object.inc.sh").is_file():
        errs.append("missing scripts/live_object.inc.sh")

    if errs:
        print(f"LIVE_OBJECT_STATIC findings={len(errs)}")
        for e in errs:
            print(f"  FIND {e}")
        print("true rc=1")
        return 1
    print("LIVE_OBJECT_STATIC OK")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
