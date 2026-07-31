#pragma once
// Core identity (PLXC) — running bitstream provenance + path capability.
//
// Addresses are DOORBELL-RELATIVE (see mailbox_abi_spec.hpp). Never hardcode
// 0x3007F130 / 0x300FF130 — resolve via coreIdentityMailboxPhys(doorbell).

#include "mailbox_abi_spec.hpp"

#include <cstdint>
#include <cstdio>
#include <string>

namespace misterplex {

constexpr uint32_t kCoreIdentityMailboxOffset = mailbox_abi::kPlxcOffset;
constexpr uint32_t kCoreIdentityMailboxMagic = mailbox_abi::kPlxcMagic;
// Legacy example absolute only (table/collision gates).
constexpr uint32_t kCoreIdentityMailboxPhys = mailbox_abi::kPlxcAddr;

inline constexpr uint32_t coreIdentityMailboxPhys(uint32_t doorbell_phys) {
    return mailbox_abi::frameStoreMailboxPhys(doorbell_phys, kCoreIdentityMailboxOffset);
}

enum class CorePathClass {
    Absent,     // no PLXC magic — SPI daily / pre-identity RBF / unmapped residue
    Ddr,        // CAP_DDR_FRAME_STORE=1
    SpiLegacy,  // CAP_SPI_LEGACY=1 (reserved; not written by ddr_frame_store)
    Invalid,    // magic ok but caps/abi illegal
};

struct CoreIdentity {
    bool present = false;
    uint32_t provenance28 = 0;
    bool cap_ddr = false;
    bool cap_spi = false;
    unsigned abi_version = 0;
    CorePathClass path = CorePathClass::Absent;
    uint32_t raw_lo = 0;
    uint32_t raw_hi = 0;
};

// Returns true when the low word is PLXC magic (fields filled; path may be Invalid).
// Returns false when magic is absent (SPI / pre-identity / residue).
inline bool decodeCoreIdentityWord(uint64_t word, CoreIdentity& out) {
    out = CoreIdentity{};
    out.raw_lo = static_cast<uint32_t>(word);
    out.raw_hi = static_cast<uint32_t>(word >> 32);
    if (out.raw_lo != kCoreIdentityMailboxMagic) {
        out.path = CorePathClass::Absent;
        return false;
    }
    out.present = true;
    out.provenance28 = out.raw_hi & ((1u << mailbox_abi::kPlxcProvenanceWidth) - 1u);
    out.cap_ddr = ((out.raw_hi >> mailbox_abi::kPlxcCapDdrBit) & 1u) != 0;
    out.cap_spi = ((out.raw_hi >> mailbox_abi::kPlxcCapSpiBit) & 1u) != 0;
    out.abi_version = (out.raw_hi >> mailbox_abi::kPlxcAbiBit) &
                      ((1u << mailbox_abi::kPlxcAbiWidth) - 1u);
    if (out.abi_version != mailbox_abi::kPlxcAbiVersion) {
        out.path = CorePathClass::Invalid;
        return true;
    }
    if (out.cap_ddr && !out.cap_spi) {
        out.path = CorePathClass::Ddr;
        return true;
    }
    if (out.cap_spi && !out.cap_ddr) {
        out.path = CorePathClass::SpiLegacy;
        return true;
    }
    out.path = CorePathClass::Invalid;
    return true;
}

inline bool decodeStableCoreIdentity(uint32_t lo, uint32_t hi, uint32_t vlo, uint32_t vhi,
                                     CoreIdentity& out) {
    if (lo != vlo || hi != vhi)
        return false;
    const uint64_t word = static_cast<uint64_t>(lo) | (static_cast<uint64_t>(hi) << 32);
    return decodeCoreIdentityWord(word, out);
}

// Pairing policy for promotion / video_regression:
//   expect_ddr=true  → running core MUST present PLXC with CAP_DDR (after identity RBF)
//   expect_ddr=false → running core MUST NOT present CAP_DDR (SPI daily or pre-identity OK)
//
// Pre-identity DDR (c5382bee): PLXC absent. treat_absent_as_ddr_ok lets the
// known-good pre-identity pair keep passing until the first identity-bearing RBF
// ships; set false once product requires PLXC.
enum class CorePairVerdict {
    Ok,
    RedMixedDdrDaemonOnNonDdrCore, // DDR daemon + SPI/absent when identity required
    RedMixedSpiDaemonOnDdrCore,    // SPI daemon + CAP_DDR live (black-screen class)
    RedInvalidIdentity,
    RedProvenanceMismatch,
};

struct CorePairExpect {
    bool expect_ddr_path = false;
    bool require_identity_present = false; // false: absent OK for pre-identity cores
    uint32_t expect_provenance28 = 0;      // 0 = do not check provenance
    bool check_provenance = false;
};

inline CorePairVerdict checkCoreDaemonPair(const CoreIdentity& id, const CorePairExpect& exp) {
    if (id.present && id.path == CorePathClass::Invalid)
        return CorePairVerdict::RedInvalidIdentity;

    if (exp.expect_ddr_path) {
        if (id.present && id.path == CorePathClass::SpiLegacy)
            return CorePairVerdict::RedMixedDdrDaemonOnNonDdrCore;
        if (exp.require_identity_present) {
            if (!id.present || id.path != CorePathClass::Ddr)
                return CorePairVerdict::RedMixedDdrDaemonOnNonDdrCore;
        } else if (id.present && id.path != CorePathClass::Ddr) {
            return CorePairVerdict::RedMixedDdrDaemonOnNonDdrCore;
        }
    } else {
        // SPI / non-DDR daemon: CAP_DDR live is the mixed black-screen class.
        if (id.present && id.path == CorePathClass::Ddr)
            return CorePairVerdict::RedMixedSpiDaemonOnDdrCore;
    }

    if (exp.check_provenance && id.present) {
        if (id.provenance28 != (exp.expect_provenance28 & 0x0FFFFFFFu))
            return CorePairVerdict::RedProvenanceMismatch;
    }
    return CorePairVerdict::Ok;
}

inline const char* corePairVerdictStr(CorePairVerdict v) {
    switch (v) {
    case CorePairVerdict::Ok:
        return "OK";
    case CorePairVerdict::RedMixedDdrDaemonOnNonDdrCore:
        return "RED_DDR_DAEMON_NON_DDR_CORE";
    case CorePairVerdict::RedMixedSpiDaemonOnDdrCore:
        return "RED_SPI_DAEMON_DDR_CORE";
    case CorePairVerdict::RedInvalidIdentity:
        return "RED_INVALID_IDENTITY";
    case CorePairVerdict::RedProvenanceMismatch:
        return "RED_PROVENANCE_MISMATCH";
    }
    return "RED_UNKNOWN";
}

inline std::string formatCoreIdentity(const CoreIdentity& id) {
    if (!id.present)
        return "PLXC=absent";
    char buf[128];
    std::snprintf(buf, sizeof(buf),
                  "PLXC present path=%s prov=0x%07x abi=%u cap_ddr=%d cap_spi=%d",
                  id.path == CorePathClass::Ddr       ? "ddr"
                  : id.path == CorePathClass::SpiLegacy ? "spi"
                  : id.path == CorePathClass::Invalid ? "invalid"
                                                      : "absent",
                  id.provenance28, id.abi_version, id.cap_ddr ? 1 : 0, id.cap_spi ? 1 : 0);
    return std::string(buf);
}

} // namespace misterplex
