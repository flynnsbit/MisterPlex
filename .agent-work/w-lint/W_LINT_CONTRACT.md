# PLXC / running-core identity — w-fit ↔ w-lint contract

## Shared ABI (source of truth on w-fit branch)
- Offset: `DOORBELL_PHYS + 0x130` (`mailbox_abi::kPlxcOffset`)
- Magic: `0x504C5843` "PLXC"
- Word: lo=magic, hi[27:0]=provenance (git), hi[28]=CAP_DDR, hi[29]=CAP_SPI, hi[31:30]=abi=1
- Resolve: `coreIdentityMailboxPhys(doorbell)` — never bare absolute

## Gate fail-closed (aligned with w-lint)
- Default stamp: `GATE_CORE_IDENTITY=UNVERIFIED`
- NOTE always states pair/liveness GREEN is **NOT silicon proof** of bitstream hash
- `GATE_CORE_IDENTITY=VERIFIED_PLXC` only when live inject `VIDREG_CORE_ID=ddr|spi`
- Pre-identity `c5382bee`: path=absent allowed until first identity RBF; then `VIDREG_REQUIRE_CORE_ID=1`
- RED: SPI daemon + CAP_DDR → `RED_SPI_DAEMON_DDR_CORE` (black-screen mix)

## Pins (parent 2026-07-31)
- SPI: core `dfebf2bf` + daemon `50f4eb92` (PREV hybrid `3e2cbb98`)
- DDR CURRENT: core `c5382bee` + daemon `edc3a46b` (prefix ≥8 via md5_match)
- DDR PREV: `e9f79de2` full digest kept for rollback

## Interim without PLXC RBF
w-lint claim file + RBFNAME mtime remains authoritative for *which file was loaded*.
PLXC is fabric proof of *which bitstream content* is running. Both required after first identity RBF.
