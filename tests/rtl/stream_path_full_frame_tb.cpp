#include "Vstream_path_full_frame_tb.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <sstream>
#include <vector>

namespace {

std::vector<uint8_t> readBytes(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open " + path);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), {});
}

struct Args {
    std::string annexb;
    std::string refRgb;
    std::string sequenceJson;
    std::string sourceSha256;
    std::string jsonOut;
    int width = 0;
    int height = 0;
    bool expectRed = false;
};

Args parseArgs(int argc, char** argv) {
    Args a;
    for (int i = 1; i < argc; ++i) {
        const std::string k = argv[i];
        auto need = [&](const char* name) -> std::string {
            if (++i >= argc) throw std::runtime_error(std::string("missing value for ") + name);
            return argv[i];
        };
        if (k == "--annexb") a.annexb = need("--annexb");
        else if (k == "--ref-rgb") a.refRgb = need("--ref-rgb");
        else if (k == "--sequence") a.sequenceJson = need("--sequence");
        else if (k == "--source-sha256") a.sourceSha256 = need("--source-sha256");
        else if (k == "--json-out") a.jsonOut = need("--json-out");
        else if (k == "--width") a.width = std::stoi(need("--width"));
        else if (k == "--height") a.height = std::stoi(need("--height"));
        else if (k == "--expect-red") a.expectRed = true;
        else throw std::runtime_error("unknown argument: " + k);
    }
    if (a.annexb.empty() || a.refRgb.empty() || a.sequenceJson.empty() || a.sourceSha256.empty() ||
        a.width <= 0 || a.height <= 0)
        throw std::runtime_error("usage: --annexb in.264 --ref-rgb ref.rgb --sequence sequence.json "
                                 "--source-sha256 SHA --width W --height H [--json-out out.json] [--expect-red]");
    return a;
}

int parseIntAfter(const std::string& text, const std::string& key, std::size_t start = 0) {
    const std::string needle = "\"" + key + "\"";
    std::size_t p = text.find(needle, start);
    if (p == std::string::npos) throw std::runtime_error("missing sequence key: " + key);
    p = text.find(':', p);
    if (p == std::string::npos) throw std::runtime_error("malformed sequence key: " + key);
    ++p;
    while (p < text.size() && std::isspace(static_cast<unsigned char>(text[p]))) ++p;
    char* end = nullptr;
    long v = std::strtol(text.c_str() + p, &end, 10);
    if (end == text.c_str() + p) throw std::runtime_error("invalid integer sequence key: " + key);
    return static_cast<int>(v);
}

std::string parseStringAfter(const std::string& text, const std::string& key, std::size_t start = 0) {
    const std::string needle = "\"" + key + "\"";
    std::size_t p = text.find(needle, start);
    if (p == std::string::npos) throw std::runtime_error("missing sequence key: " + key);
    p = text.find(':', p);
    p = text.find('"', p);
    if (p == std::string::npos) throw std::runtime_error("malformed sequence string key: " + key);
    const std::size_t q = text.find('"', p + 1);
    if (q == std::string::npos) throw std::runtime_error("unterminated sequence string key: " + key);
    return text.substr(p + 1, q - p - 1);
}

struct FrameMeta {
    int frameNum = -1;
    std::string sliceKind = "?";
};

struct SequenceMeta {
    int bytes = 0;
    int width = 0;
    int height = 0;
    int nalCount = 0;
    int vcl = 0;
    int idr = 0;
    int nonIdr = 0;
    int pSlices = 0;
    std::string sha256;
    std::vector<FrameMeta> frames;
};

SequenceMeta parseSequenceManifest(const std::string& text) {
    if (parseStringAfter(text, "format") != "misterplex.p3.nal_sequence.v1")
        throw std::runtime_error("sequence manifest is not misterplex.p3.nal_sequence.v1");
    if (text.find("\"ioctl_injection\"") == std::string::npos ||
        text.find("ioctl_download") == std::string::npos ||
        text.find("ioctl_wr") == std::string::npos)
        throw std::runtime_error("sequence manifest does not declare ioctl injection route");

    SequenceMeta m;
    m.bytes = parseIntAfter(text, "bytes");
    m.sha256 = parseStringAfter(text, "sha256");
    m.width = parseIntAfter(text, "coded_width");
    m.height = parseIntAfter(text, "coded_height");
    m.nalCount = parseIntAfter(text, "nal_count");
    m.vcl = parseIntAfter(text, "vcl");
    m.idr = parseIntAfter(text, "idr");
    m.nonIdr = parseIntAfter(text, "non_idr");
    m.pSlices = parseIntAfter(text, "p_slices");

    std::size_t p = 0;
    while ((p = text.find("\"vcl_index\"", p)) != std::string::npos) {
        FrameMeta fm;
        fm.frameNum = parseIntAfter(text, "frame_num", p);
        fm.sliceKind = parseStringAfter(text, "slice_kind", p);
        m.frames.push_back(fm);
        ++p;
    }
    return m;
}

struct NalSeg {
    std::size_t start = 0;
    std::size_t end = 0;
    uint8_t type = 0;
};

std::size_t startCodeLen(const std::vector<uint8_t>& b, std::size_t pos) {
    if (pos + 4 <= b.size() && b[pos] == 0 && b[pos + 1] == 0 && b[pos + 2] == 0 && b[pos + 3] == 1) return 4;
    if (pos + 3 <= b.size() && b[pos] == 0 && b[pos + 1] == 0 && b[pos + 2] == 1) return 3;
    return 0;
}

std::vector<NalSeg> findNals(const std::vector<uint8_t>& b) {
    std::vector<std::size_t> starts;
    for (std::size_t i = 0; i + 3 < b.size();) {
        const std::size_t len = startCodeLen(b, i);
        if (len) {
            starts.push_back(i);
            i += len;
        } else {
            ++i;
        }
    }
    std::vector<NalSeg> out;
    for (std::size_t i = 0; i < starts.size(); ++i) {
        const std::size_t hdr = starts[i] + startCodeLen(b, starts[i]);
        if (hdr >= b.size()) throw std::runtime_error("truncated NAL header");
        out.push_back({starts[i], (i + 1 < starts.size()) ? starts[i + 1] : b.size(),
                       static_cast<uint8_t>(b[hdr] & 0x1f)});
    }
    return out;
}

uint8_t expand5(uint16_t v) { return static_cast<uint8_t>((v << 3) | (v >> 2)); }
uint8_t expand6(uint16_t v) { return static_cast<uint8_t>((v << 2) | (v >> 4)); }

std::array<uint8_t, 3> rgb565ToRgb(uint16_t px) {
    return {expand5((px >> 11) & 0x1f), expand6((px >> 5) & 0x3f), expand5(px & 0x1f)};
}

std::array<uint8_t, 3> rgb888ToRgb565Expanded(uint8_t r, uint8_t g, uint8_t b) {
    return rgb565ToRgb(static_cast<uint16_t>(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)));
}

class Sim {
public:
    explicit Sim(int w, int h) : width(w), height(h), framePixels(static_cast<std::size_t>(w) * h) {}

    Vstream_path_full_frame_tb top{};
    uint64_t cycles = 0;
    int width = 0;
    int height = 0;
    std::size_t framePixels = 0;
    std::vector<std::vector<uint8_t>> frames;
    std::vector<uint8_t> cur;

    void capturePosedge() {
        if (top.fs_wr_reset) cur.clear();
        if (!top.fs_wr_en) return;
        const auto rgb = rgb565ToRgb(static_cast<uint16_t>(top.fs_wr_pixel));
        cur.push_back(rgb[0]);
        cur.push_back(rgb[1]);
        cur.push_back(rgb[2]);
        if (cur.size() == framePixels * 3) {
            frames.push_back(cur);
            cur.clear();
        } else if (cur.size() > framePixels * 3) {
            throw std::runtime_error("captured more pixels than one frame before fs_wr_reset");
        }
    }

    void tick() {
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
        capturePosedge();
        top.clk = 0;
        top.eval();
        ++cycles;
    }

    void reset() {
        top.reset = 1;
        top.flush = 0;
        top.ioctl_download = 0;
        top.ioctl_wr = 0;
        top.ioctl_dout = 0;
        for (int i = 0; i < 8; ++i) tick();
        top.reset = 0;
        for (int i = 0; i < 4; ++i) tick();
    }

    void feedByte(uint8_t v) {
        top.ioctl_download = 1;
        top.ioctl_dout = v;
        top.ioctl_wr = 1;
        tick();
        top.ioctl_wr = 0;
        tick();
    }

    bool waitForBytes(uint32_t want, int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            if (top.bytes_seen >= want) return true;
            tick();
        }
        return top.bytes_seen >= want;
    }

    bool waitForFrames(uint16_t want, int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            if (top.stub_frames >= want && frames.size() >= want && !top.stub_busy) return true;
            tick();
        }
        return top.stub_frames >= want && frames.size() >= want && !top.stub_busy;
    }
};

struct PlaneStats {
    uint64_t exact = 0;
    uint64_t sumAbs = 0;
    uint8_t maxAbs = 0;
    double mae = 0.0;
};

struct BadPixel {
    bool valid = false;
    std::size_t frame = 0;
    int plane = 0;
    int x = 0;
    int y = 0;
    int got = 0;
    int ref = 0;
    int abs = 0;
};

struct FrameCompareStats {
    std::array<PlaneStats, 3> plane;
    std::array<BadPixel, 3> firstBad;
};

struct CompareResult {
    bool exact = true;
    int firstBadFrame = -1;
    BadPixel firstBad;
    std::vector<FrameCompareStats> frames;
};

uint8_t clamp8(int v) {
    return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
}

std::array<uint8_t, 3> rgbToYuv(uint8_t r, uint8_t g, uint8_t b) {
    return {
        clamp8((77 * r + 150 * g + 29 * b + 128) >> 8),
        clamp8((-43 * r - 85 * g + 128 * b + 32896) >> 8),
        clamp8((128 * r - 107 * g - 21 * b + 32896) >> 8),
    };
}

CompareResult compareFrames(const std::vector<std::vector<uint8_t>>& got,
                            const std::vector<uint8_t>& ref,
                            int width, int height) {
    const std::size_t pixels = static_cast<std::size_t>(width) * height;
    const std::size_t frameBytes = pixels * 3;
    const std::size_t refFrames = ref.size() / frameBytes;
    CompareResult result;
    const char* names = "YUV";
    for (std::size_t f = 0; f < got.size(); ++f) {
        if (got[f].size() != frameBytes) throw std::runtime_error("captured frame has wrong byte count");
        FrameCompareStats frameStats;
        for (std::size_t i = 0; i < pixels; ++i) {
            const auto gyuv = rgbToYuv(got[f][i * 3 + 0], got[f][i * 3 + 1], got[f][i * 3 + 2]);
            const auto rrgb = rgb888ToRgb565Expanded(ref[f * frameBytes + i * 3 + 0],
                                                     ref[f * frameBytes + i * 3 + 1],
                                                     ref[f * frameBytes + i * 3 + 2]);
            const auto ryuv = rgbToYuv(rrgb[0], rrgb[1], rrgb[2]);
            const int x = static_cast<int>(i % static_cast<std::size_t>(width));
            const int y = static_cast<int>(i / static_cast<std::size_t>(width));
            for (int p = 0; p < 3; ++p) {
                PlaneStats& st = frameStats.plane[static_cast<std::size_t>(p)];
                const uint8_t g = gyuv[static_cast<std::size_t>(p)];
                const uint8_t r = ryuv[static_cast<std::size_t>(p)];
                const uint8_t d = static_cast<uint8_t>(g > r ? g - r : r - g);
                st.exact += (d == 0);
                st.sumAbs += d;
                st.maxAbs = std::max(st.maxAbs, d);
                if (d != 0 && !frameStats.firstBad[static_cast<std::size_t>(p)].valid) {
                    frameStats.firstBad[static_cast<std::size_t>(p)] =
                        {true, f, p, x, y, static_cast<int>(g), static_cast<int>(r), static_cast<int>(d)};
                }
                if (d != 0 && !result.firstBad.valid) {
                    result.firstBad = {true, f, p, x, y, static_cast<int>(g), static_cast<int>(r), static_cast<int>(d)};
                    result.firstBadFrame = static_cast<int>(f);
                }
            }
        }
        for (int p = 0; p < 3; ++p) {
            PlaneStats& st = frameStats.plane[static_cast<std::size_t>(p)];
            st.mae = static_cast<double>(st.sumAbs) / static_cast<double>(pixels);
            const BadPixel& first = frameStats.firstBad[static_cast<std::size_t>(p)];
            std::cout << "FULL_FRAME_COMPARE raw frame=" << f
                      << " colorspace=YUV444_FROM_RGB565"
                      << " plane=" << names[p]
                      << " exact=" << st.exact
                      << " pixels=" << pixels
                      << " mae=" << std::fixed << std::setprecision(6) << st.mae
                      << " max_abs=" << static_cast<int>(st.maxAbs) << "\n";
            if (first.valid) {
                std::cout << "FULL_FRAME_COMPARE first_bad frame=" << f
                          << " colorspace=YUV444_FROM_RGB565"
                          << " plane=" << names[p]
                          << " x=" << first.x
                          << " y=" << first.y
                          << " mb_x=" << (first.x / 16)
                          << " mb_y=" << (first.y / 16)
                          << " pixel_in_mb_x=" << (first.x & 15)
                          << " pixel_in_mb_y=" << (first.y & 15)
                          << " got=" << first.got
                          << " ref=" << first.ref
                          << " abs=" << first.abs << "\n";
            }
        }
        result.frames.push_back(frameStats);
    }
    result.exact = (result.firstBadFrame < 0) && (got.size() == refFrames);
    return result;
}

void writeJsonReport(const std::string& path, const Args& args, const SequenceMeta& seq,
                     const CompareResult& cr, int nals, int idr, int p, std::size_t bytes,
                     uint64_t cycles) {
    if (path.empty()) return;
    std::ofstream out(path);
    if (!out) throw std::runtime_error("cannot write compare JSON: " + path);
    const std::size_t pixels = static_cast<std::size_t>(args.width) * args.height;
    const char* names[3] = {"Y", "U", "V"};
    out << "{\n";
    out << "  \"format\": \"misterplex.p3.frame_planes_compare.v1\",\n";
    out << "  \"source\": {\"path\": \"" << args.annexb << "\", \"bytes\": " << bytes
        << ", \"sha256\": \"" << args.sourceSha256 << "\"},\n";
    out << "  \"sequence_manifest\": \"" << args.sequenceJson << "\",\n";
    out << "  \"geometry\": {\"width\": " << args.width << ", \"height\": " << args.height
        << ", \"colorspace\": \"YUV444_FROM_RGB565\", \"planes\": [\"Y\", \"U\", \"V\"]},\n";
    out << "  \"summary\": {\"nals\": " << nals << ", \"idr\": " << idr << ", \"p\": " << p
        << ", \"cycles\": " << cycles << ", \"first_bad_frame\": " << cr.firstBadFrame
        << ", \"first_bad\": ";
    if (cr.firstBad.valid) {
        out << "{\"frame_index\": " << cr.firstBad.frame << ", \"plane\": \"" << names[cr.firstBad.plane]
            << "\", \"x\": " << cr.firstBad.x << ", \"y\": " << cr.firstBad.y
            << ", \"mb_x\": " << (cr.firstBad.x / 16) << ", \"mb_y\": " << (cr.firstBad.y / 16)
            << ", \"pixel_in_mb_x\": " << (cr.firstBad.x & 15)
            << ", \"pixel_in_mb_y\": " << (cr.firstBad.y & 15)
            << ", \"got\": " << cr.firstBad.got << ", \"ref\": " << cr.firstBad.ref
            << ", \"abs\": " << cr.firstBad.abs << "}";
    } else {
        out << "null";
    }
    out << ", \"strict_pass\": " << (cr.exact ? "true" : "false")
        << ", \"expectation\": \"" << (args.expectRed ? "red" : "strict") << "\"},\n";
    out << "  \"frames\": [\n";
    for (std::size_t f = 0; f < cr.frames.size(); ++f) {
        const int frameNum = f < seq.frames.size() ? seq.frames[f].frameNum : static_cast<int>(f);
        const std::string kind = f < seq.frames.size() ? seq.frames[f].sliceKind : "?";
        out << "    {\"frame_index\": " << f << ", \"frame_num\": " << frameNum
            << ", \"slice_kind\": \"" << kind << "\", \"planes\": [";
        for (int pi = 0; pi < 3; ++pi) {
            const auto& st = cr.frames[f].plane[static_cast<std::size_t>(pi)];
            if (pi) out << ", ";
            const BadPixel& first = cr.frames[f].firstBad[static_cast<std::size_t>(pi)];
            out << "{\"plane\": \"" << names[pi] << "\", \"width\": " << args.width
                << ", \"height\": " << args.height << ", \"exact_pixels\": " << st.exact
                << ", \"total_pixels\": " << pixels << ", \"mae\": "
                << std::fixed << std::setprecision(6) << st.mae
                << ", \"max_abs\": " << static_cast<int>(st.maxAbs) << ", \"first_bad\": ";
            if (first.valid) {
                out << "{\"x\": " << first.x << ", \"y\": " << first.y
                    << ", \"mb_x\": " << (first.x / 16) << ", \"mb_y\": " << (first.y / 16)
                    << ", \"pixel_in_mb_x\": " << (first.x & 15)
                    << ", \"pixel_in_mb_y\": " << (first.y & 15)
                    << ", \"got\": " << first.got << ", \"ref\": " << first.ref
                    << ", \"abs\": " << first.abs << "}";
            } else {
                out << "null";
            }
            out << "}";
        }
        out << "]}";
        if (f + 1 != cr.frames.size()) out << ",";
        out << "\n";
    }
    out << "  ]\n";
    out << "}\n";
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        const Args args = parseArgs(argc, argv);
        const auto annexb = readBytes(args.annexb);
        const auto ref = readBytes(args.refRgb);
        const auto sequenceText = readBytes(args.sequenceJson);
        const SequenceMeta seq = parseSequenceManifest(std::string(sequenceText.begin(), sequenceText.end()));
        const std::size_t frameBytes = static_cast<std::size_t>(args.width) * args.height * 3;
        if (ref.empty() || (ref.size() % frameBytes) != 0)
            throw std::runtime_error("reference RGB size is not a whole number of frames");
        const std::size_t refFrames = ref.size() / frameBytes;
        const auto nals = findNals(annexb);
        if (nals.size() < 2) throw std::runtime_error("fixture must contain >=2 NALs");

        int idr = 0, p = 0, vcl = 0;
        for (const auto& n : nals) {
            if (n.type == 5) { ++idr; ++vcl; }
            if (n.type == 1) { ++p; ++vcl; }
        }
        if (vcl < 2 || idr < 1 || p < 1)
            throw std::runtime_error("full-frame gate requires IDR plus P-frame VCL NALs");
        if (static_cast<std::size_t>(vcl) != refFrames)
            throw std::runtime_error("reference frame count does not match VCL count");
        if (seq.sha256 != args.sourceSha256 || seq.bytes != static_cast<int>(annexb.size()))
            throw std::runtime_error("sequence manifest source hash/size does not match bitstream");
        if (seq.width != args.width || seq.height != args.height)
            throw std::runtime_error("sequence manifest geometry does not match ffprobe geometry");
        if (seq.nalCount != static_cast<int>(nals.size()) || seq.vcl != vcl ||
            seq.idr != idr || seq.nonIdr != p || seq.pSlices != p)
            throw std::runtime_error("sequence manifest NAL/VCL counts do not match bitstream");
        if (seq.frames.size() != refFrames)
            throw std::runtime_error("sequence manifest VCL metadata count does not match reference frame count");

        Sim sim(args.width, args.height);
        sim.reset();
        uint32_t fed = 0;
        uint16_t expectedFrames = 0;
        for (const auto& n : nals) {
            for (std::size_t i = n.start; i < n.end; ++i) sim.feedByte(annexb[i]);
            fed += static_cast<uint32_t>(n.end - n.start);
            sim.top.ioctl_download = 0;
            sim.tick();
            if (!sim.waitForBytes(fed, 20000))
                throw std::runtime_error("scanner did not drain bytes after NAL type " + std::to_string(n.type));
            if (n.type == 5 || n.type == 1) {
                ++expectedFrames;
                if (!sim.waitForFrames(expectedFrames, 200000))
                    throw std::runtime_error("stream_path did not emit frame " + std::to_string(expectedFrames));
            } else {
                for (int i = 0; i < 256; ++i) sim.tick();
            }
        }

        if (sim.frames.size() != refFrames)
            throw std::runtime_error("captured frame count does not match reference");
        if (sim.top.sps_width != args.width || sim.top.sps_height != args.height)
            throw std::runtime_error("SPS geometry does not match ffprobe geometry");

        const CompareResult cr = compareFrames(sim.frames, ref, args.width, args.height);
        writeJsonReport(args.jsonOut, args, seq, cr, static_cast<int>(nals.size()), idr, p,
                        annexb.size(), sim.cycles);
        std::cout << "FULL_FRAME_COMPARE summary width=" << args.width
                  << " height=" << args.height
                  << " frames=" << sim.frames.size()
                  << " nals=" << nals.size()
                  << " idr=" << idr
                  << " p=" << p
                  << " bytes=" << annexb.size()
                  << " cycles=" << sim.cycles
                  << " first_bad_frame=" << cr.firstBadFrame
                  << " strict_pass=" << (cr.exact ? 1 : 0)
                  << " mode=" << (args.expectRed ? "expect-red" : "strict") << "\n";

        if (args.expectRed) {
            if (cr.exact) {
                std::cerr << "FAIL full-frame expected-red: stream_path unexpectedly matched reference decoder\n";
                return 1;
            }
            std::cout << "OK full-frame expected-red: strict reference comparison diverged at frame "
                      << cr.firstBadFrame << "\n";
            return 0;
        }
        if (!cr.exact) {
            std::cerr << "FAIL full-frame strict: stream_path pixels differ from reference decoder at frame "
                      << cr.firstBadFrame << "\n";
            return 1;
        }
        std::cout << "OK full-frame strict: all RGB planes matched reference decoder\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL full-frame compare: " << e.what() << "\n";
        return 1;
    }
}
