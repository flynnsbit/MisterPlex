// Host/FPGA status telemetry ABI shared constants.
//
// The residual checksum gate depends on these byte positions: pre-3.3l-1 RTL
// placed stream_bytes immediately after residual_dc, so raw[13] was the stream
// byte counter low byte. Keep these constants in sync with Plex.sv.
#pragma once

namespace misterplex {
namespace status_telemetry {

inline constexpr int kResidualDcBitLo = 96;
inline constexpr int kResidualDcBitHi = 103;
inline constexpr int kResidualCsumBitLo = 104;
inline constexpr int kResidualCsumBitHi = 111;
inline constexpr int kReconSigBitLo = 112;
inline constexpr int kReconSigBitHi = 119;
inline constexpr int kStreamByteLowDebugBitLo = 120;
inline constexpr int kStreamByteLowDebugBitHi = 127;

inline constexpr int kResidualDcByte = 12;
inline constexpr int kResidualCsumByte = 13;
inline constexpr int kReconSigByte = 14;
inline constexpr int kStreamByteLowDebugByte = 15;

// P3-3l2 first 4x4 reconstructed-pixel signature:
// XOR of the 16 reconstructed Y samples after inverse quant + IDCT + pred=128.
// MB0 block0 golden recon is:
//   73,72,76,76, 72,74,71,73, 76,71,32,27, 76,73,27,24
inline constexpr int kReconSigMb0Block0 = 0x3B;

} // namespace status_telemetry
} // namespace misterplex
