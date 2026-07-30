// DEFECT 1 twin: post-copy PLXO stability. Mutation that skips the check is RED
// only at the product call site (fpga_spi); here we unit-test the helper and
// simulate adversarial writer wrap during "slow copy".
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>

using namespace mailbox_abi;

static uint32_t makeHi(bool ready, bool torn, int bank, uint16_t seq) {
    uint32_t hi = 0;
    if (ready)
        hi |= (1u << kPlxoReadyBit);
    if (torn)
        hi |= (1u << kPlxoTornBit);
    if (bank)
        hi |= (1u << kPlxoBankBit);
    hi |= (1u << kPlxoFmtYuvBit);
    hi |= (static_cast<uint32_t>(seq) << kPlxoSeqBit);
    return hi;
}

int main() {
    int fail = 0;
    const uint32_t lo = kPlxoMagic;
    const uint32_t hi_ok = makeHi(true, false, 0, 7);

    if (!plxoPostCopyStable(lo, hi_ok, lo, hi_ok)) {
        std::fprintf(stderr, "FAIL: stable snapshot rejected\n");
        ++fail;
    }
    // Writer advanced seq mid-copy (bank reuse hazard)
    const uint32_t hi_seq = makeHi(true, false, 0, 8);
    if (plxoPostCopyStable(lo, hi_ok, lo, hi_seq)) {
        std::fprintf(stderr, "FAIL: seq change accepted (copy race)\n");
        ++fail;
    }
    // Writer flipped bank under reader
    const uint32_t hi_bank = makeHi(true, false, 1, 7);
    if (plxoPostCopyStable(lo, hi_ok, lo, hi_bank)) {
        std::fprintf(stderr, "FAIL: bank change accepted (copy race)\n");
        ++fail;
    }
    // Became not-ready
    const uint32_t hi_nr = makeHi(false, false, 0, 7);
    if (plxoPostCopyStable(lo, hi_ok, lo, hi_nr)) {
        std::fprintf(stderr, "FAIL: ready dropped accepted\n");
        ++fail;
    }
    // Torn mid-copy
    const uint32_t hi_t = makeHi(true, true, 0, 7);
    if (plxoPostCopyStable(lo, hi_ok, lo, hi_t)) {
        std::fprintf(stderr, "FAIL: torn mid-copy accepted\n");
        ++fail;
    }
    // Magic corruption
    if (plxoPostCopyStable(lo, hi_ok, 0xDEADBEEFu, hi_ok)) {
        std::fprintf(stderr, "FAIL: magic change accepted\n");
        ++fail;
    }
    // Seq wrap identity: 0xFFFF then same after wrap is still "stable" only if
    // words match; wrap itself is a change → reject (ARM must not accept).
    const uint32_t hi_wrap_a = makeHi(true, false, 0, 0xFFFF);
    const uint32_t hi_wrap_b = makeHi(true, false, 0, 0);
    if (plxoPostCopyStable(lo, hi_wrap_a, lo, hi_wrap_b)) {
        std::fprintf(stderr, "FAIL: seq wrap mid-copy accepted\n");
        ++fail;
    }

#ifndef HYBRID_FAULT_SKIP_POST_COPY_PLXO
    // Product path includes the guard — adversarial change must fail closed.
    if (plxoPostCopyStable(lo, hi_ok, lo, hi_seq) != false) {
        std::fprintf(stderr, "FAIL: product helper soft\n");
        ++fail;
    }
#else
    // Mutation twin: if someone compiles the helper out of the check path,
    // this binary is only used as a compile flag canary for the shell twin.
    std::fprintf(stderr, "FAULT: HYBRID_FAULT_SKIP_POST_COPY_PLXO defined\n");
    return 1;
#endif

    // Stride must fit 624x480 I420
    constexpr uint32_t k480pI420 = 624u * 480u * 3u / 2u;
    if (kReconExportBankStride < k480pI420) {
        std::fprintf(stderr, "FAIL: bank stride 0x%x < 624x480 I420 %u\n",
                     kReconExportBankStride, k480pI420);
        ++fail;
    }
    if (kReconExportMapBytes < 2u * kReconExportBankStride) {
        std::fprintf(stderr, "FAIL: recon map too small for 2 banks\n");
        ++fail;
    }

    if (fail) {
        std::fprintf(stderr, "FAIL test_plxo_post_copy: %d\n", fail);
        return 1;
    }
    std::printf("OK test_plxo_post_copy: post_copy_stable=1 seq_bank_race_red=1 "
                "stride_480p_fit=1 stride=0x%x\n",
                kReconExportBankStride);
    return 0;
}
