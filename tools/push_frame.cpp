// Push YUV420p video via DDR, or non-video PCM/annex-B via SPI ioctl,
// or dump core status.
//
// Product path (same as MediaPlayer):
//   push_frame --ddr [--bank N] [--yuv420p 624x480] file.i420
//   → FpgaSpi::sendYuv420pFrameDdr → publishDdrFrame → sendDdrFrame
//
// V_STORE ceiling fixtures (no codec; built-in I420 patterns):
//   push_frame --ddr --pattern mid_grey|even_black|even_white|odd_black|odd_white
//   push_frame --ddr --pattern mid_grey --hold-ms 8000
//
// Daily-driver: STOP misterplexd before --ddr publish (it overwrites the bank).
// Restore misterplexd after capture. Do not leave Main stopped.
//
// Usage:
//   push_frame --ddr [--bank N] [--yuv420p WxH] [--hold-ms N] file
//   push_frame --ddr --pattern NAME [--hold-ms N]
//   push_frame --index 2|3 file
//   push_frame --status
//   push_frame --raw
//   push_frame --set-bit N 0|1
//   push_frame --pulse N
#include "fpga_spi.hpp"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

// Video-range Y; neutral chroma. Matches kYuv420BlackY/U/V style.
constexpr uint8_t kYBlack = 16;
constexpr uint8_t kYWhite = 235;
constexpr uint8_t kYMid = 128;
constexpr uint8_t kUvNeutral = 128;

// Built-in patterns for V_STORE even-row ceiling (store_y = py*2).
// even_black: even store rows black, odd white → current core shows BLACK
// even_white: even white, odd black → WHITE
// odd_*: one-row phase shift (inversion under 240-row ceiling)
// mid_grey: CONTROL — must be uniform mid-grey or entire suite UNSCORED
enum class BuiltinPattern {
    None,
    MidGrey,
    EvenBlack,
    EvenWhite,
    OddBlack,
    OddWhite,
};

BuiltinPattern parsePattern(const char* s) {
    if (!s)
        return BuiltinPattern::None;
    if (std::strcmp(s, "mid_grey") == 0 || std::strcmp(s, "control") == 0)
        return BuiltinPattern::MidGrey;
    if (std::strcmp(s, "even_black") == 0)
        return BuiltinPattern::EvenBlack;
    if (std::strcmp(s, "even_white") == 0)
        return BuiltinPattern::EvenWhite;
    if (std::strcmp(s, "odd_black") == 0)
        return BuiltinPattern::OddBlack;
    if (std::strcmp(s, "odd_white") == 0)
        return BuiltinPattern::OddWhite;
    return BuiltinPattern::None;
}

const char* patternName(BuiltinPattern p) {
    switch (p) {
    case BuiltinPattern::MidGrey:
        return "mid_grey";
    case BuiltinPattern::EvenBlack:
        return "even_black";
    case BuiltinPattern::EvenWhite:
        return "even_white";
    case BuiltinPattern::OddBlack:
        return "odd_black";
    case BuiltinPattern::OddWhite:
        return "odd_white";
    default:
        return "none";
    }
}

// Fill planar I420: Y full WxH, U/V (W/2)*(H/2).
// evenY/oddY: per-luma-row values (row index in coded frame).
bool fillI420Pattern(std::vector<uint8_t>& out, int w, int h, BuiltinPattern pat) {
    if (w < 2 || h < 2 || (w % 2) || (h % 2))
        return false;
    const size_t yBytes = static_cast<size_t>(w) * static_cast<size_t>(h);
    const size_t cBytes = yBytes / 4;
    out.assign(yBytes + 2 * cBytes, 0);
    uint8_t* Y = out.data();
    uint8_t* U = Y + yBytes;
    uint8_t* V = U + cBytes;

    uint8_t evenY = kYMid;
    uint8_t oddY = kYMid;
    bool flat = false;
    switch (pat) {
    case BuiltinPattern::MidGrey:
        flat = true;
        evenY = oddY = kYMid;
        break;
    case BuiltinPattern::EvenBlack:
        evenY = kYBlack;
        oddY = kYWhite;
        break;
    case BuiltinPattern::EvenWhite:
        evenY = kYWhite;
        oddY = kYBlack;
        break;
    case BuiltinPattern::OddBlack:
        // phase shift of even_black: odd rows black
        evenY = kYWhite;
        oddY = kYBlack;
        break;
    case BuiltinPattern::OddWhite:
        evenY = kYBlack;
        oddY = kYWhite;
        break;
    default:
        return false;
    }

    for (int y = 0; y < h; ++y) {
        const uint8_t val = flat ? kYMid : ((y % 2) == 0 ? evenY : oddY);
        std::memset(Y + static_cast<size_t>(y) * static_cast<size_t>(w), val, static_cast<size_t>(w));
    }
    std::memset(U, kUvNeutral, cBytes);
    std::memset(V, kUvNeutral, cBytes);
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    uint8_t index = 1;
    int rgb24w = 0, rgb24h = 0;
    int yuvW = 0, yuvH = 0;
    bool do_status = false;
    bool do_raw = false;
    bool use_ddr = false;
    int bank = 0;
    int set_bit = -1, set_val = 0;
    int pulse_bit = -1;
    int hold_ms = 0;
    BuiltinPattern pattern = BuiltinPattern::None;
    const char* path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--index") == 0 && i + 1 < argc)
            index = static_cast<uint8_t>(std::atoi(argv[++i]));
        else if (std::strcmp(argv[i], "--rgb24") == 0 && i + 1 < argc) {
            std::sscanf(argv[++i], "%dx%d", &rgb24w, &rgb24h);
        } else if (std::strcmp(argv[i], "--yuv420p") == 0 && i + 1 < argc) {
            std::sscanf(argv[++i], "%dx%d", &yuvW, &yuvH);
        } else if (std::strcmp(argv[i], "--status") == 0) {
            do_status = true;
        } else if (std::strcmp(argv[i], "--raw") == 0) {
            do_raw = true;
        } else if (std::strcmp(argv[i], "--set-bit") == 0 && i + 2 < argc) {
            set_bit = std::atoi(argv[++i]);
            set_val = std::atoi(argv[++i]) ? 1 : 0;
        } else if (std::strcmp(argv[i], "--pulse") == 0 && i + 1 < argc) {
            pulse_bit = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--ddr") == 0) {
            use_ddr = true;
        } else if (std::strcmp(argv[i], "--bank") == 0 && i + 1 < argc) {
            bank = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--hold-ms") == 0 && i + 1 < argc) {
            hold_ms = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--pattern") == 0 && i + 1 < argc) {
            pattern = parsePattern(argv[++i]);
            if (pattern == BuiltinPattern::None) {
                std::fprintf(stderr,
                             "unknown --pattern (want mid_grey|even_black|even_white|"
                             "odd_black|odd_white)\n");
                return 1;
            }
            use_ddr = true;  // patterns are DDR I420 only
        } else if (argv[i][0] != '-')
            path = argv[i];
    }

    if (path && use_ddr && (rgb24w > 0 || rgb24h > 0)) {
        std::fprintf(stderr,
                     "non-YUV frame send refused: DDR frame-store path is YUV420p only; "
                     "--rgb24 is disabled for F1\n");
        return 1;
    }
    if (path && !use_ddr && (index == 1 || rgb24w > 0 || rgb24h > 0)) {
        std::fprintf(stderr,
                     "non-YUV frame send refused: F1 frame-store path is DDR YUV420p only; "
                     "use --ddr --yuv420p WxH\n");
        return 1;
    }

    misterplex::FpgaSpi spi;
    if (!spi.open()) {
        std::fprintf(stderr, "fpga open: %s\n", spi.lastError().c_str());
        return 1;
    }

    if (set_bit >= 0) {
        if (!spi.setStatusBit(set_bit, set_val)) {
            std::fprintf(stderr, "set-bit: %s\n", spi.lastError().c_str());
            return 1;
        }
        std::printf("set bit %d = %d\n", set_bit, set_val);
        usleep(50000);
    }
    if (pulse_bit >= 0) {
        if (!spi.setStatusBit(pulse_bit, 1)) {
            std::fprintf(stderr, "pulse: %s\n", spi.lastError().c_str());
            return 1;
        }
        usleep(5000);
        if (!spi.setStatusBit(pulse_bit, 0)) {
            std::fprintf(stderr, "pulse low: %s\n", spi.lastError().c_str());
            return 1;
        }
        std::printf("pulsed bit %d\n", pulse_bit);
        usleep(50000);
    }

    if (do_raw) {
        for (int attempt = 0; attempt < 5; ++attempt) {
            uint8_t raw[16]{};
            if (!spi.getCoreStatus(raw)) {
                std::fprintf(stderr, "raw: %s\n", spi.lastError().c_str());
                return 1;
            }
            std::printf("raw[%d]:", attempt);
            for (int i = 0; i < 16; ++i)
                std::printf(" %02x", raw[i]);
            std::printf("  lo=0x%04x\n", raw[0] | (raw[1] << 8));
            usleep(20000);
        }
        return 0;
    }

    if (do_status || set_bit >= 0 || pulse_bit >= 0) {
        misterplex::FpgaSpi::CoreStatus st;
        if (!spi.readCoreStatus(st)) {
            std::fprintf(stderr, "status: %s\n", spi.lastError().c_str());
            return 1;
        }
        misterplex::FrameStoreStatus fs{};
        const bool haveFrameStoreStatus = spi.readFrameStoreStatus(fs);
        std::printf(
            "status has_frame=%d has_audio=%d has_stream=%d underrun=%d "
            "has_idr=%d stub_busy=%d sps_valid=%d pps_valid=%d nalu=%u last_nal=0x%02x "
            "slice_type=%u mb0=%u qp=%u res_ok=%d res_tc=%u res_t1=%u res_dc=%d res_csum=%u "
            "recon_sig=%u recon_dbg=0x%02x ddr_busy=%d sps=%ux%u "
            "stream_nalus=%u bytes_in_unavailable=1",
            st.has_frame ? 1 : 0, st.has_audio ? 1 : 0, st.has_stream ? 1 : 0,
            st.audio_underrun ? 1 : 0, st.has_idr ? 1 : 0, st.stub_busy ? 1 : 0,
            st.sps_valid ? 1 : 0, st.pps_valid ? 1 : 0, st.nalu_count, st.last_nal_type,
            st.slice_type, st.first_mb_type, st.slice_qp, st.residual_ok ? 1 : 0, st.residual_tc,
            st.residual_t1, static_cast<int>(st.residual_dc),
            static_cast<unsigned>(st.residual_csum), static_cast<unsigned>(st.recon_sig),
            static_cast<unsigned>(st.recon_dbg),
            st.ddr_busy ? 1 : 0, st.sps_width, st.sps_height, st.stream_nalus);
        misterplex::FpgaSpi::DdrDoorbellStatus tok;
        if (spi.readDdrDoorbellStatus(tok)) {
            std::printf(" frame_bank=%d frame_format=yuv420p frame_seq=%u",
                        tok.bank, tok.seq);
        }
        if (haveFrameStoreStatus) {
            std::printf(" frame_debug=0x%02x frame_underrun=%u frame_status_seq=%u",
                        static_cast<unsigned>(fs.debug_state),
                        static_cast<unsigned>(fs.underrun_count),
                        static_cast<unsigned>(fs.seq));
        } else {
            std::printf(" frame_status=absent");
        }
        std::printf("\n");
        if (haveFrameStoreStatus && fs.nonYuvDoorbellRejected())
            std::printf("ERROR %s\n", misterplex::frameStoreDebugDescription(fs.debug_state));
        else if (!haveFrameStoreStatus)
            std::printf("ERROR %s: %s\n",
                        misterplex::frameStoreStatusUnavailableDescription(),
                        spi.lastError().c_str());
        if (!path)
            return 0;
    }

    if (!path && pattern == BuiltinPattern::None) {
        std::fprintf(stderr,
                     "usage: push_frame --ddr [--bank 0|1] [--yuv420p 624x480] "
                     "[--hold-ms N] file.i420\n"
                     "       push_frame --ddr --pattern mid_grey|even_black|even_white|"
                     "odd_black|odd_white [--hold-ms N]\n"
                     "       push_frame --index 2|3 file\n"
                     "       push_frame --status\n"
                     "NOTE: stop misterplexd before --ddr; restore after. Same path as "
                     "publishDdrFrame / playback.\n");
        return 1;
    }
    std::vector<uint8_t> buf;
    if (pattern != BuiltinPattern::None) {
        if (path) {
            std::fprintf(stderr, "pass either --pattern or a file, not both\n");
            return 1;
        }
        // Default product coded geometry when pattern has no --yuv420p
        if (yuvW <= 0 || yuvH <= 0) {
            yuvW = misterplex::kPlex480pCodedWidth.get();
            yuvH = misterplex::kPlex480pCodedHeight.get();
        }
        if (!fillI420Pattern(buf, yuvW, yuvH, pattern)) {
            std::fprintf(stderr, "pattern fill failed for %dx%d\n", yuvW, yuvH);
            return 1;
        }
        use_ddr = true;
        std::printf("pattern=%s yuv420p=%dx%d bytes=%zu\n", patternName(pattern), yuvW,
                    yuvH, buf.size());
    } else {
        std::ifstream in(path, std::ios::binary);
        if (!in) {
            std::perror(path);
            return 1;
        }
        buf.assign(std::istreambuf_iterator<char>(in), {});
    }
    bool ok = false;
    if (use_ddr) {
        if (rgb24w > 0 || rgb24h > 0) {
            std::fprintf(stderr,
                         "non-YUV frame send refused: DDR frame-store path is YUV420p only; "
                         "--rgb24 is disabled for F1\n");
            return 1;
        }
        misterplex::DdrFrameGeometry g{};
        if (yuvW > 0 && yuvH > 0) {
            g = misterplex::makeDdrFrameGeometry(yuvW, yuvH);
        } else if (buf.size() == static_cast<size_t>(misterplex::kPlex480pYuv420pBytes)) {
            g = misterplex::plex480pDdrFrameGeometry();
        } else {
            std::fprintf(stderr,
                         "DDR frame-store path is YUV420p only; pass --yuv420p WxH or a "
                         "%d-byte Plex 480p I420 frame\n",
                         misterplex::kPlex480pYuv420pBytes);
            return 1;
        }
        const size_t want = misterplex::yuv420pFrameBytes(g.coded_width, g.coded_height);
        if (buf.size() < want) {
            std::fprintf(stderr, "file too small for %dx%d YUV420p\n", g.coded_width.get(),
                         g.coded_height.get());
            return 1;
        }
        // Product path: sendYuv420pFrameDdr → publishDdrFrame → sendDdrFrame
        ok = spi.sendYuv420pFrameDdr(buf.data(), want, g, bank);
    } else if (index == 1 || rgb24w > 0 || rgb24h > 0) {
        std::fprintf(stderr,
                     "non-YUV frame send refused: F1 frame-store path is DDR YUV420p only; "
                     "use --ddr --yuv420p WxH\n");
        return 1;
    } else {
        ok = spi.sendFileTx(buf.data(), buf.size(), index);
    }
    if (!ok) {
        std::fprintf(stderr, "push failed: %s\n", spi.lastError().c_str());
        return 1;
    }
    // Ensure Force-bars debug is off (status[9]=0) so auto frame present shows
    if (!use_ddr)
        spi.setStatusBit(9, 0);
    const char* via = use_ddr ? "DDR" : "SPI";
    std::printf("pushed %zu bytes %s bank=%d index=%u pattern=%s OK (%.1f ms)\n", buf.size(),
                via, bank, index, patternName(pattern), spi.lastPushMs());
    if (hold_ms > 0) {
        std::printf("hold %d ms (frame stays until next publish; capture now)\n", hold_ms);
        usleep(static_cast<useconds_t>(hold_ms) * 1000u);
    }
    return 0;
}
