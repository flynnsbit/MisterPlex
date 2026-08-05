// Tiny unit: fabricResearchPathEnvEnabled() + product fabric flag default OFF.
//
// RESEARCH gate only — MISTERPLEX_FABRIC_DMA must default OFF (unset/empty/non-1).
// Product path remains kDdrPublishFabricPathEnabledInProduct=false.
// OFFLINE — no device. Env is restored before exit.

#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/fabric_dma_host.hpp"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

using namespace misterplex;

static int g_fails = 0;

static void expect(bool cond, const char* msg) {
    if (!cond) {
        std::cerr << "FAIL: " << msg << "\n";
        ++g_fails;
    } else {
        std::cout << "OK: " << msg << "\n";
    }
}

// Save/restore MISTERPLEX_FABRIC_DMA so the process leaves the suite clean.
struct EnvGuard {
    bool had = false;
    std::string prev;

    EnvGuard() {
        if (const char* v = std::getenv("MISTERPLEX_FABRIC_DMA")) {
            had = true;
            prev = v;
        }
        ::unsetenv("MISTERPLEX_FABRIC_DMA");
    }

    ~EnvGuard() {
        if (had) {
            ::setenv("MISTERPLEX_FABRIC_DMA", prev.c_str(), 1);
        } else {
            ::unsetenv("MISTERPLEX_FABRIC_DMA");
        }
    }
};

int main() {
    EnvGuard env_guard;

    std::cout << "CASE product_flag_false EXECUTED\n";
    expect(!kDdrPublishFabricPathEnabledInProduct,
           "kDdrPublishFabricPathEnabledInProduct remains false");
    expect(!ddrPublishSkipTcopyLegal(), "skip T_copy illegal under product default");

    std::cout << "CASE env_default_off EXECUTED\n";
    // Unset (EnvGuard ctor) → off
    expect(!fabricResearchPathEnvEnabled(), "unset env → fabricResearchPathEnvEnabled=false");

    ::setenv("MISTERPLEX_FABRIC_DMA", "", 1);
    expect(!fabricResearchPathEnvEnabled(), "empty env → false");

    ::setenv("MISTERPLEX_FABRIC_DMA", "0", 1);
    expect(!fabricResearchPathEnvEnabled(), "MISTERPLEX_FABRIC_DMA=0 → false");

    ::setenv("MISTERPLEX_FABRIC_DMA", "false", 1);
    expect(!fabricResearchPathEnvEnabled(), "MISTERPLEX_FABRIC_DMA=false → false");

    ::setenv("MISTERPLEX_FABRIC_DMA", "11", 1);
    expect(!fabricResearchPathEnvEnabled(), "MISTERPLEX_FABRIC_DMA=11 → false (exact '1' only)");

    ::setenv("MISTERPLEX_FABRIC_DMA", "1", 1);
    expect(fabricResearchPathEnvEnabled(), "MISTERPLEX_FABRIC_DMA=1 → true (lab opt-in only)");

    // Leave unset for product-default assertion at end of main path.
    ::unsetenv("MISTERPLEX_FABRIC_DMA");
    expect(!fabricResearchPathEnvEnabled(), "restored unset → default off");

    if (g_fails != 0) {
        std::cerr << "test_fabric_env_gate FAIL fails=" << g_fails << "\n";
        return 1;
    }
    std::cout << "test_fabric_env_gate PASS product_flag=0 env_default=off\n";
    return 0;
}
