#!/usr/bin/env python3
"""Static gate: T_copy skip defaults OFF; memcpy required; ON legal PRODUCT_WIRE=1 only.

When the skip flag is OFF (product default), sendDdrFrame must still contain the
publication memcpy path. Enabling skip is legal only under PRODUCT_WIRE=1 with
fabric publish active — never product-default ON.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPI = ROOT / "arm" / "misterplexd" / "fpga_spi.cpp"
INGEST = ROOT / "host" / "libmisterplex" / "ddr_zero_copy_ingest.hpp"


def fail(msg: str) -> int:
    print(f"FAIL ddr_t_copy_skip_static: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    spi = SPI.read_text(encoding="utf-8", errors="replace")
    ingest = INGEST.read_text(encoding="utf-8", errors="replace")

    # --- Header: default PRODUCT_WIRE OFF ---
    if not re.search(
        r"#ifndef\s+MISTERPLEX_PRODUCT_WIRE\s*\n\s*#define\s+MISTERPLEX_PRODUCT_WIRE\s+0\b",
        ingest,
    ):
        return fail("MISTERPLEX_PRODUCT_WIRE must default to 0 (product OFF)")
    if "kDdrPublishFabricPathEnabledInProduct = false" not in ingest:
        return fail("kDdrPublishFabricPathEnabledInProduct must be false (no fabric in product)")
    if "ON is legal with PRODUCT_WIRE=1 ONLY" not in ingest and \
       "ON is legal with PRODUCT_WIRE=1 only" not in ingest:
        return fail("header must document ON legal with PRODUCT_WIRE=1 only")
    if "ddrPublishSkipTcopyActiveFor" not in ingest:
        return fail("missing ddrPublishSkipTcopyActiveFor helper")
    if "ddrPublishSkipTcopyLegalForWire" not in ingest:
        return fail("missing ddrPublishSkipTcopyLegalForWire helper")

    # --- sendDdrFrame T_copy site: gate present, memcpy path present when !skip ---
    if "ddrPublishSkipTcopyActive(kDdrPublishFabricPathEnabledInProduct)" not in spi:
        return fail("sendDdrFrame must call skip gate with product fabric flag (default false)")
    if "std::memcpy(ddrMap_ + bankOff, payload, len)" not in spi:
        return fail("when flag OFF, T_copy memcpy path must still be present in sendDdrFrame")
    if "if (!skip_t_copy)" not in spi:
        return fail("memcpy body must be gated by !skip_t_copy")
    # Do not hard-enable fabric in product source.
    if re.search(r"kDdrPublishFabricPathEnabledInProduct\s*=\s*true", spi):
        return fail("must not enable fabric path in product (fpga_spi.cpp)")
    if re.search(r"ddrPublishSkipTcopyActive\s*\(\s*true\s*\)", spi):
        return fail("must not pass fabric_publish_active=true in product sendDdrFrame")

    # Barrier retained on both arms (visibility before doorbell).
    if spi.count("__sync_synchronize()") < 1:
        return fail("visibility barrier must remain on publish path")

    print(
        "test_ddr_t_copy_skip_static: OK "
        "PRODUCT_WIRE_default=0 fabric_product=0 "
        "memcpy_present=1 skip_gate=1 legal_only=PRODUCT_WIRE=1"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
