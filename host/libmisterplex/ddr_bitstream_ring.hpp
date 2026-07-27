#pragma once

#include <cstddef>
#include <cstdint>

namespace misterplex::ddr_bitstream_ring {

constexpr uint32_t kDataPhys = 0x30100000u;
constexpr uint32_t kCtrlPhys = 0x30140000u;
constexpr uint32_t kReadPhys = 0x30140008u;
constexpr uint32_t kErrPhys = 0x30140010u;
constexpr size_t kRingBytes = 262144u;

constexpr uint32_t kCtrlMagic = 0x504C5842u; // PLXB, HPS -> FPGA
constexpr uint32_t kReadMagic = 0x504C5852u; // PLXR, FPGA -> HPS
constexpr uint32_t kErrMagic = 0x504C5845u;  // PLXE, FPGA -> HPS

// CTRL @ kCtrlPhys:
//   [31:0]  PLXB
//   [62:32] absolute producer byte count modulo 2^31
//   [63]    reset/flush epoch toggle
// READ @ kReadPhys:
//   [31:0]  PLXR
//   [63:32] absolute FPGA consumer byte count
// ERR @ kErrPhys:
//   [31:0]  PLXE
//   [39:32] seq
//   [40]    underrun sticky
//   [41]    overrun sticky
//   [42]    active
//   [55:48] saturated underrun count low byte
//   [63:56] saturated overrun count low byte

} // namespace misterplex::ddr_bitstream_ring
