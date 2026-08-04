// Wave-3 w-path: T_copy skip gate defaults OFF; ON legal with PRODUCT_WIRE=1 only.
// No device. Soft-skip ≠ PASS — product fabric path must stay disabled.
#include "libmisterplex/ddr_zero_copy_ingest.hpp"

#include <cstdio>
#include <cstring>

#define CHECK(cond, msg)                                                                           \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);                     \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

int main() {
    using namespace misterplex;
    int fails = 0;

    // --- Product default: PRODUCT_WIRE=0, fabric path OFF ---
    CHECK(kDdrPublishProductWire == 0, "product PRODUCT_WIRE must be 0");
    CHECK(!kDdrPublishProductWireOn, "product PRODUCT_WIRE must not be ON");
    CHECK(!kDdrPublishFabricPathEnabledInProduct, "fabric path must stay OFF in product");
    CHECK(!ddrPublishSkipTcopyLegal(), "skip T_copy illegal under product default");
    CHECK(!ddrPublishSkipTcopyActive(false), "default: no skip when fabric inactive");
    // Fabric-active alone must NOT skip without PRODUCT_WIRE=1.
    CHECK(!ddrPublishSkipTcopyActive(true), "fabric_active alone cannot skip without PRODUCT_WIRE");

    // --- Truth table (legal only PRODUCT_WIRE=1 + fabric active) ---
    // wire=0: never skip
    CHECK(!ddrPublishSkipTcopyLegalForWire(0), "wire0 illegal");
    CHECK(!ddrPublishSkipTcopyActiveFor(0, false), "wire0 fabric0");
    CHECK(!ddrPublishSkipTcopyActiveFor(0, true), "wire0 fabric1 — still no skip");
    // wire=1, fabric inactive: still no skip (default-off runtime path)
    CHECK(ddrPublishSkipTcopyLegalForWire(1), "wire1 legal");
    CHECK(!ddrPublishSkipTcopyActiveFor(1, false), "wire1 fabric0 — still copy");
    // wire=1 + fabric active: the only legal ON
    CHECK(ddrPublishSkipTcopyActiveFor(1, true), "wire1 fabric1 — skip ON (PRODUCT_WIRE only)");
    // Other wire values never legal
    CHECK(!ddrPublishSkipTcopyLegalForWire(2), "wire2 illegal");
    CHECK(!ddrPublishSkipTcopyActiveFor(2, true), "wire2 fabric1 still no skip");
    CHECK(!ddrPublishSkipTcopyLegalForWire(-1), "wire-1 illegal");

    // Documented contract string pins (grep-friendly for static tests / evidence).
    const char* legality =
        "ON is legal with PRODUCT_WIRE=1 only (fabric publish product-wire build)";
    CHECK(std::strstr(legality, "PRODUCT_WIRE=1 only") != nullptr, "legality pin string");

    if (fails) {
        std::printf("test_ddr_t_copy_skip: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_ddr_t_copy_skip: OK product_wire=%d fabric_product=%d "
                "skip_default=0 legal_only=PRODUCT_WIRE=1+fabric\n",
                kDdrPublishProductWire,
                kDdrPublishFabricPathEnabledInProduct ? 1 : 0);
    return 0;
}
