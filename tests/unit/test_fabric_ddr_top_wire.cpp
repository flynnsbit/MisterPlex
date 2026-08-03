// Default-safe: FABRIC_DDR_WRITER must stay OFF in product QSF; both arbiter
// paths must exist in Plex.sv for integration enable without redesign.
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>

static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#c); ++fails; } } while(0)

static std::string slurp(const char* path) {
    std::ifstream f(path);
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

int main() {
    const auto qsf = slurp("fpga/Plex_MiSTer/Plex.qsf");
    const auto top = slurp("fpga/Plex_MiSTer/Plex.sv");
    CHECK(!qsf.empty() && !top.empty());
    // Macro assignment must remain commented (default OFF).
    CHECK(qsf.find("#set_global_assignment -name VERILOG_MACRO \"FABRIC_DDR_WRITER=1\"") != std::string::npos);
    // Must NOT have an uncommented enable line.
    {
        bool live = false;
        std::string line;
        std::ifstream f("fpga/Plex_MiSTer/Plex.qsf");
        while (std::getline(f, line)) {
            if (line.find("FABRIC_DDR_WRITER=1") == std::string::npos) continue;
            // strip leading ws
            size_t i = 0;
            while (i < line.size() && (line[i]==' '||line[i]=='\t')) ++i;
            if (i < line.size() && line[i] != '#') live = true;
        }
        CHECK(!live);
    }
    CHECK(top.find("ddr_bus_arbiter3") != std::string::npos); // FABRIC_DDR_WRITER path
    CHECK(top.find("fabric_ddr_attach") != std::string::npos);
    CHECK(top.find("`ifdef FABRIC_DDR_WRITER") != std::string::npos);
    // Product DEFAULT (writer OFF): ddr_bus_arbiter_plxc instance name ddr_arb.
    // Legacy 2-port "ddr_bus_arbiter ddr_arb" was retired — test was stale, not the RTL.
    CHECK(top.find("ddr_bus_arbiter_plxc") != std::string::npos);
    CHECK(top.find("ddr_arb") != std::string::npos);
    CHECK(top.find("ddr_bus_arbiter ddr_arb") == std::string::npos);
    // PLXC chrome grant path (m_gnt) must be wired, not hollow 1'b0.
    CHECK(top.find(".m_gnt(plxc_c_gnt)") != std::string::npos);
    CHECK(top.find("ddr_plxc_master_bridge") != std::string::npos);
    CHECK(top.find(".m_gnt(1'b0)") == std::string::npos);
    // Idle producer must not paint over has_frame (synced).
    CHECK(top.find("has_frame_s2") != std::string::npos);
    CHECK(top.find("DDR_FRAME_720P_PHYS_BASE") != std::string::npos); // Option-C capacity default
    CHECK(top.find("produce_en") != std::string::npos);
    CHECK(top.find("FABRIC_DDR_WRITER_480P") != std::string::npos); // opt-out to product banks
    CHECK(top.find("fabric_bank_credit") != std::string::npos ||
          top.find("fabric_free_mask") != std::string::npos);
    CHECK(qsf.find("rtl/fabric_bank_credit.sv") != std::string::npos);
    CHECK(qsf.find("rtl/host_bank_ingest_credit.sv") != std::string::npos);
    CHECK(top.find("host_bank_ingest_credit") != std::string::npos);
    CHECK(qsf.find("FABRIC_DDR_WRITER_480P=1") != std::string::npos);
    if (fails) { std::fprintf(stderr,"test_fabric_ddr_top_wire: %d fails\n", fails); return 1; }
    std::printf("test_fabric_ddr_top_wire: OK default_off=1 arb3_wired=1 plxc_arb=1 m_gnt_wired=1 optionc_default=1\n");
    return 0;
}
