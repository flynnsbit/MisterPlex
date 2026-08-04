// Verilator TB for plex_rbf_build_id — GREEN healthy + RED fault twin.
#include "Vplex_rbf_build_id_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static void tick(Vplex_rbf_build_id_tb_top* top) {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* top = new Vplex_rbf_build_id_tb_top;

  // Reset
  top->reset = 1;
  for (int i = 0; i < 4; i++) tick(top);
  top->reset = 0;
  for (int i = 0; i < 4; i++) tick(top);

  const uint64_t id = top->build_id_good;
  const uint32_t magic = static_cast<uint32_t>(id >> 32);
  const int valid = top->id_valid_good;
  const int alive = top->stamp_alive_good;
  const int fault_valid = top->id_valid_fault;
  const int fault_alive_ok = top->fault_alive_is_zero;

  std::printf("CASE EXECUTED plex_rbf_build_id\n");
  std::printf("measured_magic=0x%08x\n", magic);
  std::printf("measured_id_valid_good=%d\n", valid);
  std::printf("measured_stamp_alive_good=%d\n", alive);
  std::printf("measured_id_valid_fault=%d\n", fault_valid);
  std::printf("measured_fault_alive_zero=%d\n", fault_alive_ok);
  std::printf("measured_build_id_good=0x%016llx\n",
              static_cast<unsigned long long>(id));

  int fail = 0;
  if (magic != 0x504C5842u) {
    std::printf("FAIL magic want PLXB got 0x%08x\n", magic);
    fail = 1;
  }
  if (!valid) {
    std::printf("FAIL id_valid_good expected 1\n");
    fail = 1;
  }
  if (!alive) {
    std::printf("FAIL stamp_alive_good expected 1\n");
    fail = 1;
  }
  // RED twin: faulted instance must not claim valid
  if (fault_valid) {
    std::printf("FAIL id_valid_fault expected 0 (FAULT_ZERO_STAMP)\n");
    fail = 1;
  }
  if (!fault_alive_ok) {
    std::printf("FAIL fault path still looks alive\n");
    fail = 1;
  }

  // Commit prefix 0x0139F2C5 folded: high bits of low half
  const uint32_t commit_hi = static_cast<uint32_t>((id >> 1) & 0x7fff);
  const uint32_t want_hi = (0x0139F2C5u >> 17) & 0x7fff;
  if (commit_hi != want_hi) {
    std::printf("FAIL commit_hi got=0x%x want=0x%x\n", commit_hi, want_hi);
    fail = 1;
  } else {
    std::printf("OK commit_prefix_bits_present\n");
  }

  if (fail) {
    std::printf("FAIL plex_rbf_build_id_tb\n");
    std::printf("true rc=1\n");
    delete top;
    return 1;
  }
  std::printf("PASS plex_rbf_build_id_tb\n");
  std::printf("true rc=0\n");
  delete top;
  return 0;
}
