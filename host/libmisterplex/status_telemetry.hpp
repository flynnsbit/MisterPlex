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
// Aspect Ratio OSD splice overlaps them. Used bits:
//   bit0 coeff_nonzero, bit3 dequant_nonzero, bit4 idct_residual_nonzero,
//   bit5 recon_differs_from_pred, bit6 lat_res_ok, bit7 waited_for_residual
inline constexpr int kReconDbgCoeffNonzero = 0x01;
inline constexpr int kReconDbgDequantNonzero = 0x08;
inline constexpr int kReconDbgIdctNonzero = 0x10;
inline constexpr int kReconDbgReconDiffers = 0x20;
inline constexpr int kReconDbgLatResOk = 0x40;
inline constexpr int kReconDbgWaitedForResidual = 0x80;
inline constexpr int kReconDbgMb0Block0 = kReconDbgCoeffNonzero | kReconDbgDequantNonzero |
                                          kReconDbgIdctNonzero | kReconDbgReconDiffers |
                                          kReconDbgLatResOk | kReconDbgWaitedForResidual;

// telem_flags byte (Plex.sv MSB-first pack → bit7..bit0). Keep in lockstep with
// fpga_spi.cpp parseCoreStatus and tests/unit/test_telem_flags_abi.py.
inline constexpr int kTelemFlagHasFrameBit = 0;
inline constexpr int kTelemFlagHasAudioBit = 1;
inline constexpr int kTelemFlagHasStreamBit = 2;
inline constexpr int kTelemFlagAudioUnderrunBit = 3;
inline constexpr int kTelemFlagHasIdrBit = 4;
inline constexpr int kTelemFlagStubBusyBit = 5;  // PRODUCT_NO_STUB: tie 0, never delete
inline constexpr int kTelemFlagSpsValidBit = 6;
inline constexpr int kTelemFlagPpsValidBit = 7;

} // namespace status_telemetry
} // namespace misterplex
