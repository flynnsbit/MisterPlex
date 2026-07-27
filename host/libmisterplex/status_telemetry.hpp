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
inline constexpr int kStreamBytesBitLo = 112;
inline constexpr int kStreamBytesBitHi = 127;

inline constexpr int kResidualDcByte = 12;
inline constexpr int kResidualCsumByte = 13;
inline constexpr int kStreamBytesLoByte = 14;
inline constexpr int kStreamBytesHiByte = 15;

} // namespace status_telemetry
} // namespace misterplex
