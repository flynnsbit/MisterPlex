// Host/FPGA status telemetry ABI shared constants.
//
// The residual checksum gate depends on these byte positions: pre-3.3l-1 RTL
// placed stream_bytes immediately after residual_dc, so raw[13] was the stream
// byte counter low byte. Keep these constants in sync with Plex.sv.
//
// telem_flags (status byte raw[2] / status_in[23:16]) is a positional ABI:
// Plex.sv packs MSB-first, ARM decodes by mask. Dropping a mid field (e.g.
// stub_busy) zero-extends the concat and shifts upper flags — silent wrong
// status, not picture loss. tests/unit/test_telem_flags_abi.py + the bit
// walk in test_status_telemetry.cpp mutation-lock both sides.
#pragma once

namespace misterplex {
namespace status_telemetry {

// Plex.sv: wire [7:0] telem_flags = {
//   pps_valid, sps_valid, stub_busy, has_idr,
//   audio_underrun, has_stream, has_audio, has_frame };
// ARM fpga_spi.cpp parseCoreStatus uses 1<<bit masks below.
inline constexpr int kTelemFlagHasFrameBit = 0;      // mask 0x01
inline constexpr int kTelemFlagHasAudioBit = 1;      // mask 0x02
inline constexpr int kTelemFlagHasStreamBit = 2;     // mask 0x04
inline constexpr int kTelemFlagAudioUnderrunBit = 3; // mask 0x08
inline constexpr int kTelemFlagHasIdrBit = 4;        // mask 0x10
inline constexpr int kTelemFlagStubBusyBit = 5;      // mask 0x20
inline constexpr int kTelemFlagSpsValidBit = 6;      // mask 0x40
inline constexpr int kTelemFlagPpsValidBit = 7;      // mask 0x80
inline constexpr int kTelemFlagsByte = 2;            // raw[2] low half of w1

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

} // namespace status_telemetry
} // namespace misterplex
