#include "Vplex_delivery_path_stamp_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static void tick(Vplex_delivery_path_stamp_tb_top* top) {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* top = new Vplex_delivery_path_stamp_tb_top;
  top->reset = 1;
  for (int i = 0; i < 4; i++) tick(top);
  top->reset = 0;
  for (int i = 0; i < 4; i++) tick(top);

  const int arm = top->arm_copy_path;
  const int dma = top->fabric_dma_path;
  const int cls = top->path_class & 0xff;
  const int alive = top->stamp_alive;

  std::printf("CASE EXECUTED plex_delivery_path_stamp\n");
  std::printf("measured_arm_copy=%d\n", arm);
  std::printf("measured_fabric_dma=%d\n", dma);
  std::printf("measured_path_class=0x%02x\n", cls);
  std::printf("measured_stamp_alive=%d\n", alive);

  int fail = 0;
#if defined(EXPECT_FABRIC_DMA)
  if (arm != 0 || dma != 1 || cls != 0x02 || !alive) {
    std::printf("FAIL EXPECT_FABRIC_DMA arm=%d dma=%d class=0x%02x alive=%d\n",
                arm, dma, cls, alive);
    fail = 1;
  } else {
    std::printf("PASS EXPECT_FABRIC_DMA\n");
  }
#else
  if (arm != 1 || dma != 0 || cls != 0x01 || !alive) {
    std::printf("FAIL DEFAULT_ARM_COPY arm=%d dma=%d class=0x%02x alive=%d\n",
                arm, dma, cls, alive);
    fail = 1;
  } else {
    std::printf("PASS DEFAULT_ARM_COPY\n");
  }
#endif

  if (fail) {
    std::printf("FAIL plex_delivery_path_stamp_tb\n");
    std::printf("true rc=1\n");
    delete top;
    return 1;
  }
  std::printf("PASS plex_delivery_path_stamp_tb\n");
  std::printf("true rc=0\n");
  delete top;
  return 0;
}
