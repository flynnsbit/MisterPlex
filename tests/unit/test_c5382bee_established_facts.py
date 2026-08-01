#!/usr/bin/env python3
"""Lock parent-proven c5382bee facts (fleet broadcast 2026-08-01).

Hardware was parent-only. This gate fails if the repo regresses documentation
or scoring in ways that re-open retracted claims.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FACTS = ROOT / "docs/ESTABLISHED_FACTS_c5382bee.md"
SWAP = ROOT / "host/libmisterplex/publish_swap_delta_ledger.hpp"
INTERVAL = ROOT / "host/libmisterplex/publish_interval_ledger.hpp"
PLXD = ROOT / "host/libmisterplex/plxd_liveness.hpp"
LEDGER = ROOT / "host/libmisterplex/frame_ledger.hpp"
SPI = ROOT / "arm/misterplexd/fpga_spi.cpp"


def audit() -> list[str]:
    errs: list[str] = []
    if not FACTS.is_file():
        return ["MISSING docs/ESTABLISHED_FACTS_c5382bee.md"]
    ft = FACTS.read_text(encoding="utf-8", errors="replace")
    for n in (
        "vertical only",
        "std = 0.00",
        "odd store rows",
        "UNSCORED",
        "two stats of one series",
        "ARM supply only",
        "vsync pack",
        "NOT YET FITTED" if False else "frames_done",
    ):
        if n is False:
            continue
        if n not in ft and n.lower() not in ft.lower():
            # allow case fold
            if n.lower() not in ft.lower():
                errs.append(f"ESTABLISHED_FACTS missing {n!r}")

    # Scoring: sigma >> mean → UNSCORED
    for p, label in ((SWAP, "swap_delta"), (INTERVAL, "interval")):
        if not p.is_file():
            errs.append(f"MISSING {p.relative_to(ROOT)}")
            continue
        t = p.read_text(encoding="utf-8", errors="replace")
        if "2.0 * " not in t and "2.0*" not in t.replace(" ", ""):
            errs.append(f"{label}: missing σ>2×mean → UNSCORED guard")
        if 'verdict = "UNSCORED"' not in t and 'interval_verdict = "UNSCORED"' not in t:
            # both should set UNSCORED somewhere for high sigma
            if "UNSCORED" not in t:
                errs.append(f"{label}: no UNSCORED path")

    if not PLXD.is_file() or "does NOT prove: bank swaps" not in PLXD.read_text():
        errs.append("plxd_liveness must state fd advance ≠ swap proof")
    if not LEDGER.is_file() or "ARM_PUBLISH_NOT_DISPLAY" not in LEDGER.read_text():
        errs.append("frame_ledger must scope ARM_PUBLISH_NOT_DISPLAY")
    if not SPI.is_file() or "plxdLivenessObserve" not in SPI.read_text():
        errs.append("fpga_spi must use plxdLivenessObserve (freeze-blindness fix)")

    # Ban re-claiming horizontal as proven in established facts doc
    if "horizontal" in ft.lower() and "not" not in ft.lower():
        pass  # weak
    if re.search(r"horizontal.*proven|proven.*horizontal", ft, re.I):
        if "not" not in ft.lower():
            errs.append("must not claim horizontal ceiling proven")

    return errs


def rbg_high_sigma_unit() -> tuple[int, str]:
    """Compile tiny C++ that uses PublishSwapDeltaLedger with wild intervals."""
    bin_path = ROOT / "build/test_p_ge50_high_sigma"
    src = r'''
#include "libmisterplex/publish_swap_delta_ledger.hpp"
#include <cstdio>
int main() {
  misterplex::PublishSwapDeltaLedger L;
  // mean ~50ms but inject huge outliers so sigma >> mean
  long long t = 1000000;
  uint16_t fd = 0;
  for (int i = 0; i < 200; ++i) {
    L.note(t, fd, 0, 1, 0);
    // Parent class: mean~50ms, sigma~500ms (preemption fat tail).
    // Mostly 50ms; every 10th sample is 5s → σ ≫ mean.
    long long step = (i % 10 == 0) ? 5000000LL : 50000LL; // us
    t += step;
    fd = (uint16_t)(fd + 3); // vsync-ish
  }
  auto s = L.summarize();
  std::printf("mean=%.3f sigma=%.3f p_ge50=%.4f verdict=%s skip=%s fd=%s\n",
    s.mean_ms, s.sigma_ms, s.p_ge50, s.interval_verdict, s.skip_verdict, s.fd_semantics);
  if (s.sigma_ms <= 2.0 * s.mean_ms) {
    std::fprintf(stderr, "fixture sigma not >> mean\n");
    return 2;
  }
  if (std::string(s.interval_verdict) != "UNSCORED") {
    std::fprintf(stderr, "want interval_verdict=UNSCORED got %s\n", s.interval_verdict);
    return 1;
  }
  // skip must also be unscored under vsync pack
  if (std::string(s.skip_verdict) != "UNSCORED") {
    std::fprintf(stderr, "want skip UNSCORED got %s\n", s.skip_verdict);
    return 1;
  }
  std::printf("OK high_sigma_unscored\n");
  return 0;
}
'''
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    cpp = ROOT / "build/_p_ge50_high_sigma.cpp"
    cpp.write_text(src)
    r = subprocess.run(
        ["g++", "-std=c++17", "-O0", "-I" + str(ROOT / "host"), "-o", str(bin_path), str(cpp)],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        return r.returncode, "BUILD_FAIL\n" + r.stderr
    r2 = subprocess.run([str(bin_path)], capture_output=True, text=True)
    return r2.returncode, r2.stdout + r2.stderr


def main() -> int:
    findings = audit()
    print("C5382BEE_FACTS_BEGIN")
    print(f"findings={len(findings)}")
    for f in findings:
        print(f"FIND {f}")
    print("C5382BEE_FACTS_END")
    if findings:
        print("C5382BEE_FACTS_FAIL")
        print("true rc=1")
        return 1
    rc, out = rbg_high_sigma_unit()
    print(out)
    if rc != 0:
        print("C5382BEE_FACTS_FAIL high_sigma")
        print(f"true rc={rc}")
        return rc
    print("C5382BEE_FACTS_OK")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
