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
inline constexpr int kReconDbgBitLo = 120;
inline constexpr int kReconDbgBitHi = 127;

inline constexpr int kResidualDcByte = 12;
inline constexpr int kResidualCsumByte = 13;
inline constexpr int kReconSigByte = 14;
inline constexpr int kReconDbgByte = 15;

// P3-3l2 first 4x4 reconstructed-pixel signature:
// XOR of the 16 reconstructed Y samples after inverse quant + IDCT + pred=128.
// MB0 block0 golden recon is:
//   73,72,76,76, 72,74,71,73, 76,71,32,27, 76,73,27,24
inline constexpr int kReconSigMb0Block0 = 0x3B;

// P3-3l2 silicon RCA byte (raw[15]); bits [2:1] are reserved because the
// Aspect Ratio OSD splice overlaps them. Used bits (no PARSE desync sticky):
//   bit0 coeff_nonzero, bit3 dequant_nonzero, bit4 idct_residual_nonzero,
//   bit5 recon_differs_from_pred, bit6 lat_res_ok, bit7 waited_for_residual
//
// Sticky PARSE desync overlay (Plex.sv st_recon_dbg_telem) when a slice
// walker fault latched (hold until core reset / explicit clear):
//   bit0 desync_early   — more_rbsp_data false before PicSizeInMbs
//   bit1 desync_long    — data/skip past PicSizeInMbs or bad trailing
//   [7:4] desync_cause  — first-fault code (see kDesyncCause* below)
//   When bit0|bit1 set (or cause!=0): raw[10..11] (sps_mb_w/h slots) hold
//   desync_mb little-endian (MB address where the walker broke).
inline constexpr int kReconDbgCoeffNonzero = 0x01;
inline constexpr int kReconDbgDequantNonzero = 0x08;
inline constexpr int kReconDbgIdctNonzero = 0x10;
inline constexpr int kReconDbgReconDiffers = 0x20;
inline constexpr int kReconDbgLatResOk = 0x40;
inline constexpr int kReconDbgWaitedForResidual = 0x80;
inline constexpr int kReconDbgMb0Block0 = kReconDbgCoeffNonzero | kReconDbgDequantNonzero |
                                          kReconDbgIdctNonzero | kReconDbgReconDiffers |
                                          kReconDbgLatResOk | kReconDbgWaitedForResidual;

// PARSE desync sticky fields inside raw[15] / status[127:120]
inline constexpr int kDesyncEarlyBit = 0;
inline constexpr int kDesyncLongBit = 1;
inline constexpr int kDesyncCauseShift = 4;
inline constexpr int kDesyncCauseMask = 0xF;
// Dual-use SPS dim bytes when desync sticky (same raw indices as sps_mb_*)
inline constexpr int kDesyncMbLoByte = 10; // status[87:80]
inline constexpr int kDesyncMbHiByte = 11; // status[95:88]

// First-fault cause codes (h264_i_mb_feed DSC_*)
inline constexpr int kDesyncCauseNone = 0;
inline constexpr int kDesyncCauseEarly = 1;
inline constexpr int kDesyncCauseLong = 2;
inline constexpr int kDesyncCauseSkipOverrun = 3;
inline constexpr int kDesyncCauseCavlc = 4;
inline constexpr int kDesyncCauseRbspOverrun = 5;
inline constexpr int kDesyncCauseSyntax = 6;

} // namespace status_telemetry
} // namespace misterplex
