// P3-3l5 hybrid MB ownership + I420 compose (daemon product path).
// Mirrors tools/hybrid_compose_i420.py and fpga/.../h264_hybrid_mb_own.sv.
//
// Safety: unmarked / ambiguous ownership never defaults to FPGA. An MB the FPGA
// claims without capability or without a real FPGA plane must be detectably
// host-owned or hard-fail — never silently plausible.
//
// Plane availability (2026-07-29 finding): FpgaSpi::tryCaptureReconI420 always
// fails closed — there is no FPGA→ARM reconstructed I420 readback. DDR frame
// banks are ARM→scanout only; FPGA DDRAM_WE writes mailboxes only. Live daemon
// therefore passes fpga_i420=nullptr and relies on loud host reclass
// (used_host_fallback). Offline tools/hybrid_compose_i420.py still scores
// file-plane composites. True FPGA+ARM pixel split waits on RTL recon export.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace misterplex {
namespace hybrid {

inline constexpr const char* kOwnMapFormat = "misterplex.p3.hybrid_own_map.v1";
inline constexpr const char* kComposeFormat = "misterplex.p3.hybrid_compose.v1";

enum class Owner : uint8_t { Fpga = 0, Host = 1 };

// OWN codes match h264_hybrid_mb_own.sv
enum class OwnCode : uint8_t {
    FpgaIntra = 0,
    HostInter = 1,
    HostCabac = 2,
    HostIpcm = 3,
    HostUnsup = 4,
    HostFail = 5,
    HostSlice = 6,
    Reserved = 7
};

struct Caps {
    bool cap_intra_i4 = true;
    bool cap_intra_i16 = true;
    bool cap_ipcm = false;
    bool cap_inter_pskip = false;
    bool cap_inter_p16 = false;
    bool cap_inter_part = false;
    bool cap_cabac = false;
};

struct MbClassIn {
    bool mb_valid = false;
    bool slice_is_i = false;
    bool entropy_cabac = false;
    bool fail_mb = false;
    uint8_t mb_type = 0; // I: 0=I_NxN, 1-24=I16, 25=IPCM
    bool is_p_slice_mb = false;
    bool p_skipped = false;
    bool p_is_intra = false;
    bool p_is_inter = false;
    bool p_uses_sub_mb = false;
    uint8_t p_part_mode = 0; // 0=16x16
    bool p_unsupported = false;
};

struct MbClassOut {
    bool fpga_owned = false;
    bool host_required = true;
    bool product_mb_ok = false;
    OwnCode own_code = OwnCode::HostUnsup;
    Owner owner = Owner::Host;
};

// Frame-level signals the FPGA publishes (or host synthesizes from status).
struct FpgaOwnSignal {
    bool valid = false;              // false → do not trust sticky bits
    bool product_recon_ok = false;   // pure FPGA-owned I path completed
    bool hybrid_host_required = false;
    bool hybrid_fpga_owned = false;
    OwnCode own_code = OwnCode::HostUnsup;
    bool entropy_cabac = false;
    bool slice_is_i = false;
    bool residual_ok = false;
    uint8_t slice_type = 0xFF; // raw H.264 slice_type if known
    uint8_t first_mb_type = 0xFF;
};

struct ComposeSummary {
    int width = 0;
    int height = 0;
    int frames = 0;
    int fpga_mb = 0;
    int host_mb = 0;
    int total_mb = 0;
    int reclassified_fpga_to_host = 0;
    bool product_recon_ok = false;
    bool used_host_fallback = false;
    bool hard_fail = false;
    const char* fail_reason = nullptr;
};

struct OwnMap {
    int width = 0;
    int height = 0;
    int mb_w = 0;
    int mb_h = 0;
    int frames = 0;
    // owners[frame * mb_w * mb_h + mb_index]
    std::vector<Owner> owners;
    bool complete = false;
    const char* fail_reason = nullptr;
};

inline int frameBytes(int width, int height) {
    return width * height * 3 / 2;
}

inline int mbCount(int width, int height) {
    return (width / 16) * (height / 16);
}

inline MbClassOut classifyMb(const MbClassIn& in, const Caps& caps = Caps{}) {
    MbClassOut o;
    auto set_host = [&](OwnCode code) {
        o.fpga_owned = false;
        o.host_required = true;
        o.product_mb_ok = false;
        o.own_code = code;
        o.owner = Owner::Host;
    };
    auto set_fpga = [&](OwnCode code) {
        o.fpga_owned = true;
        o.host_required = false;
        o.product_mb_ok = true;
        o.own_code = code;
        o.owner = Owner::Fpga;
    };

    if (!in.mb_valid) {
        set_host(OwnCode::HostUnsup);
        return o;
    }
    if (in.fail_mb) {
        set_host(OwnCode::HostFail);
        return o;
    }
    if (in.entropy_cabac && !caps.cap_cabac) {
        set_host(OwnCode::HostCabac);
        return o;
    }

    if (in.is_p_slice_mb) {
        if (in.p_unsupported) {
            set_host(OwnCode::HostUnsup);
            return o;
        }
        if (in.p_is_intra) {
            if (caps.cap_intra_i4 || caps.cap_intra_i16) {
                set_fpga(OwnCode::FpgaIntra);
            } else {
                set_host(OwnCode::HostSlice);
            }
            return o;
        }
        if (in.p_is_inter || in.p_skipped) {
            const bool inter_cap =
                (in.p_skipped && caps.cap_inter_pskip) ||
                (!in.p_skipped && in.p_is_inter && !in.p_uses_sub_mb && in.p_part_mode == 0 &&
                 caps.cap_inter_p16) ||
                (!in.p_skipped && in.p_is_inter &&
                 (in.p_part_mode == 1 || in.p_part_mode == 2 || in.p_part_mode == 3 ||
                  in.p_part_mode == 4 || in.p_uses_sub_mb) &&
                 caps.cap_inter_part);
            if (inter_cap)
                set_fpga(OwnCode::FpgaIntra); // code 0 + inter reason in RTL
            else
                set_host(OwnCode::HostInter);
            return o;
        }
        set_host(OwnCode::HostSlice);
        return o;
    }

    // I-slice MB
    const bool is_i_nxn = (in.mb_type == 0);
    const bool is_i16 = (in.mb_type >= 1 && in.mb_type <= 24);
    const bool is_ipcm = (in.mb_type == 25);
    if (is_i_nxn) {
        if (caps.cap_intra_i4)
            set_fpga(OwnCode::FpgaIntra);
        else
            set_host(OwnCode::HostUnsup);
        return o;
    }
    if (is_i16) {
        if (caps.cap_intra_i16)
            set_fpga(OwnCode::FpgaIntra);
        else
            set_host(OwnCode::HostUnsup);
        return o;
    }
    if (is_ipcm) {
        if (caps.cap_ipcm)
            set_fpga(OwnCode::FpgaIntra);
        else
            set_host(OwnCode::HostIpcm);
        return o;
    }
    if (in.slice_is_i) {
        set_host(OwnCode::HostUnsup);
        return o;
    }
    set_host(OwnCode::HostSlice);
    return o;
}

// H.264 slice_type: 2/7 = I, 0/5 = P, 1/6 = B (and all-intra variants).
inline bool isISliceType(uint8_t st) {
    const uint8_t m = static_cast<uint8_t>(st % 5);
    return m == 2 || m == 4; // I or SI
}

inline bool isPSliceType(uint8_t st) {
    return (st % 5) == 0;
}

// Dense ownership for one picture from slice kind + default caps.
// kind: 'I' or 'P' (other → fail closed all-host with HostSlice).
inline OwnMap buildFrameOwnMap(int width, int height, char slice_kind,
                               const Caps& caps = Caps{},
                               bool entropy_cabac = false,
                               bool fail_picture = false) {
    OwnMap m;
    m.width = width;
    m.height = height;
    if (width <= 0 || height <= 0 || (width % 16) || (height % 16)) {
        m.fail_reason = "geometry";
        return m;
    }
    m.mb_w = width / 16;
    m.mb_h = height / 16;
    m.frames = 1;
    const int nmb = m.mb_w * m.mb_h;
    m.owners.assign(static_cast<size_t>(nmb), Owner::Host);

    const char k = (slice_kind == 'i') ? 'I' : (slice_kind == 'p') ? 'P' : slice_kind;
    for (int i = 0; i < nmb; ++i) {
        MbClassIn in;
        in.mb_valid = true;
        in.entropy_cabac = entropy_cabac;
        in.fail_mb = fail_picture;
        if (k == 'I') {
            in.slice_is_i = true;
            in.is_p_slice_mb = false;
            in.mb_type = 0; // I_NxN representative
        } else if (k == 'P') {
            in.slice_is_i = false;
            in.is_p_slice_mb = true;
            in.p_is_inter = true;
            in.p_skipped = false;
            in.p_part_mode = 0;
        } else {
            // Unknown slice kind: never FPGA.
            in.slice_is_i = false;
            in.is_p_slice_mb = false;
            in.mb_type = 255;
        }
        m.owners[static_cast<size_t>(i)] = classifyMb(in, caps).owner;
    }
    m.complete = true;
    return m;
}

// Multi-frame map from per-frame kinds ("I","P",...).
inline OwnMap buildOwnMapFromKinds(int width, int height,
                                   const std::vector<char>& kinds,
                                   const Caps& caps = Caps{}) {
    OwnMap out;
    out.width = width;
    out.height = height;
    if (width <= 0 || height <= 0 || (width % 16) || (height % 16)) {
        out.fail_reason = "geometry";
        return out;
    }
    out.mb_w = width / 16;
    out.mb_h = height / 16;
    out.frames = static_cast<int>(kinds.size());
    const int nmb = out.mb_w * out.mb_h;
    out.owners.resize(static_cast<size_t>(out.frames * nmb), Owner::Host);
    for (int f = 0; f < out.frames; ++f) {
        OwnMap one = buildFrameOwnMap(width, height, kinds[static_cast<size_t>(f)], caps);
        if (!one.complete) {
            out.complete = false;
            out.fail_reason = one.fail_reason ? one.fail_reason : "frame_map";
            return out;
        }
        std::memcpy(out.owners.data() + static_cast<size_t>(f * nmb), one.owners.data(),
                    static_cast<size_t>(nmb) * sizeof(Owner));
    }
    out.complete = true;
    return out;
}

// Apply FPGA sticky signals. Fail closed on contradictions.
// - hybrid_host_required or cabac → force all host
// - product_recon_ok may stay true only if every MB is already FPGA-owned
// - If signal says product_recon_ok but map has host MBs → hard fail (silent skip-host risk)
inline bool applyFpgaOwnSignal(OwnMap& map, const FpgaOwnSignal& sig, ComposeSummary* sum) {
    if (!map.complete || map.owners.empty()) {
        if (sum) {
            sum->hard_fail = true;
            sum->fail_reason = "own_map_incomplete";
        }
        return false;
    }
    if (!sig.valid)
        return true; // no signal: keep synthesized map

    const int nmb = map.mb_w * map.mb_h;
    if (sig.entropy_cabac || sig.hybrid_host_required) {
        for (auto& o : map.owners)
            o = Owner::Host;
        return true;
    }
    if (sig.product_recon_ok) {
        // Only legal when this picture is pure FPGA-owned under the map.
        for (int f = 0; f < map.frames; ++f) {
            for (int i = 0; i < nmb; ++i) {
                if (map.owners[static_cast<size_t>(f * nmb + i)] != Owner::Fpga) {
                    if (sum) {
                        sum->hard_fail = true;
                        sum->fail_reason = "product_recon_ok_with_host_mb";
                    }
                    return false;
                }
            }
        }
    }
    return true;
}

inline void copyMb(uint8_t* dst, const uint8_t* src, int frame, int width, int height,
                   int mb_x, int mb_y) {
    const int fb = frameBytes(width, height);
    const int y_base = frame * fb;
    const int u_base = y_base + width * height;
    const int v_base = u_base + (width / 2) * (height / 2);
    for (int yy = 0; yy < 16; ++yy) {
        const int y = mb_y * 16 + yy;
        const int row = y_base + y * width + mb_x * 16;
        std::memcpy(dst + row, src + row, 16);
    }
    const int cw = width / 2;
    for (int yy = 0; yy < 8; ++yy) {
        const int y = mb_y * 8 + yy;
        const int urow = u_base + y * cw + mb_x * 8;
        const int vrow = v_base + y * cw + mb_x * 8;
        std::memcpy(dst + urow, src + urow, 8);
        std::memcpy(dst + vrow, src + vrow, 8);
    }
}

// Compose hybrid I420. Starts from host; overwrites FPGA-owned MBs from fpga plane.
// force_unmarked_as_fpga is a MUTATION-only path (tests).
// If fpga_plane is null/empty and any MB is FPGA-owned:
//   allow_host_fallback=true → reclassify those MBs to host (loud via summary)
//   allow_host_fallback=false → hard fail (strict hybrid)
inline bool composeI420(const uint8_t* fpga, size_t fpga_n, const uint8_t* host, size_t host_n,
                        int width, int height, int n_frames, const OwnMap& own,
                        std::vector<uint8_t>& out, ComposeSummary& sum,
                        bool allow_host_fallback = true,
                        bool force_unmarked_as_fpga = false) {
    sum = ComposeSummary{};
    sum.width = width;
    sum.height = height;
    sum.frames = n_frames;
    if (!own.complete && !force_unmarked_as_fpga) {
        sum.hard_fail = true;
        sum.fail_reason = "own_map_incomplete";
        return false;
    }
    if (width <= 0 || height <= 0 || (width % 16) || (height % 16) || n_frames <= 0) {
        sum.hard_fail = true;
        sum.fail_reason = "geometry";
        return false;
    }
    const int fb = frameBytes(width, height);
    const size_t need = static_cast<size_t>(n_frames) * static_cast<size_t>(fb);
    if (host_n < need) {
        sum.hard_fail = true;
        sum.fail_reason = "host_plane_short";
        return false;
    }
    const bool have_fpga = fpga != nullptr && fpga_n >= need;
    const int mb_w = width / 16;
    const int mb_h = height / 16;
    const int nmb = mb_w * mb_h;

    // Working ownership (may reclassify).
    std::vector<Owner> owners;
    owners.reserve(static_cast<size_t>(n_frames * nmb));
    for (int f = 0; f < n_frames; ++f) {
        for (int mi = 0; mi < nmb; ++mi) {
            Owner o = Owner::Host;
            const size_t idx = static_cast<size_t>(f * nmb + mi);
            if (idx < own.owners.size()) {
                o = own.owners[idx];
            } else if (force_unmarked_as_fpga) {
                o = Owner::Fpga;
            } else {
                sum.hard_fail = true;
                sum.fail_reason = "unmarked_mb";
                return false;
            }
            if (o == Owner::Fpga && !have_fpga) {
                if (!allow_host_fallback) {
                    sum.hard_fail = true;
                    sum.fail_reason = "fpga_plane_missing";
                    return false;
                }
                o = Owner::Host;
                ++sum.reclassified_fpga_to_host;
                sum.used_host_fallback = true;
            }
            owners.push_back(o);
        }
    }

    out.assign(host, host + need); // start host
    int fpga_mbs = 0;
    int host_mbs = 0;
    for (int f = 0; f < n_frames; ++f) {
        for (int mby = 0; mby < mb_h; ++mby) {
            for (int mbx = 0; mbx < mb_w; ++mbx) {
                const int mi = mby * mb_w + mbx;
                const Owner o = owners[static_cast<size_t>(f * nmb + mi)];
                if (o == Owner::Fpga) {
                    copyMb(out.data(), fpga, f, width, height, mbx, mby);
                    ++fpga_mbs;
                } else {
                    ++host_mbs;
                }
            }
        }
    }
    sum.fpga_mb = fpga_mbs;
    sum.host_mb = host_mbs;
    sum.total_mb = fpga_mbs + host_mbs;
    sum.product_recon_ok = (host_mbs == 0 && sum.total_mb > 0);
    return true;
}

// Decision helper for the live daemon path (single frame).
struct PresentDecision {
    bool ok = false;
    bool present_host_composite = true; // write F1 ourselves
    bool skip_host_f1 = false;          // only if product_recon_ok + pure FPGA + policy
    bool hard_fail = false;
    const char* fail_reason = nullptr;
    ComposeSummary summary{};
    char slice_kind = '?';
    std::string log_line;
};

inline PresentDecision decidePresentFrame(int width, int height, char slice_kind,
                                          const uint8_t* host_i420, size_t host_n,
                                          const uint8_t* fpga_i420, size_t fpga_n,
                                          const FpgaOwnSignal& sig, const Caps& caps,
                                          std::vector<uint8_t>& composite_out,
                                          bool allow_host_fallback = true,
                                          bool allow_skip_host_f1 = false) {
    PresentDecision d;
    d.slice_kind = slice_kind;

    // Prefer FPGA sticky slice kind when signal valid.
    char kind = slice_kind;
    if (sig.valid && sig.slice_type != 0xFF) {
        if (isISliceType(sig.slice_type))
            kind = 'I';
        else if (isPSliceType(sig.slice_type))
            kind = 'P';
        else
            kind = '?';
    }
    d.slice_kind = kind;

    OwnMap map = buildFrameOwnMap(width, height, kind, caps, sig.entropy_cabac,
                                  /*fail_picture=*/false);
    if (!map.complete) {
        d.hard_fail = true;
        d.fail_reason = map.fail_reason ? map.fail_reason : "own_map";
        d.ok = false;
        return d;
    }
    if (!applyFpgaOwnSignal(map, sig, &d.summary)) {
        d.hard_fail = true;
        d.fail_reason = d.summary.fail_reason;
        d.ok = false;
        return d;
    }

    // Ambiguous kind with no FPGA force-host signal → all host already from buildFrameOwnMap.
    if (kind == '?') {
        d.summary.used_host_fallback = true;
    }

    if (!composeI420(fpga_i420, fpga_n, host_i420, host_n, width, height, 1, map,
                     composite_out, d.summary, allow_host_fallback,
                     /*force_unmarked_as_fpga=*/false)) {
        d.hard_fail = true;
        d.fail_reason = d.summary.fail_reason;
        d.ok = false;
        return d;
    }

    // Skip-host only when FPGA signal asserts product_recon_ok AND composite is pure FPGA
    // AND caller opted in. Default product keeps host F1 ownership.
    if (allow_skip_host_f1 && sig.valid && sig.product_recon_ok && d.summary.product_recon_ok &&
        !d.summary.used_host_fallback) {
        d.skip_host_f1 = true;
        d.present_host_composite = false;
    }

    d.ok = true;
    d.log_line = std::string("hybrid frame kind=") + kind +
                 " fpga_mb=" + std::to_string(d.summary.fpga_mb) + "/" +
                 std::to_string(d.summary.total_mb) +
                 " host_mb=" + std::to_string(d.summary.host_mb) + "/" +
                 std::to_string(d.summary.total_mb) +
                 " reclass=" + std::to_string(d.summary.reclassified_fpga_to_host) +
                 " product_recon_ok=" + (d.summary.product_recon_ok ? "1" : "0") +
                 " skip_host_f1=" + (d.skip_host_f1 ? "1" : "0") +
                 " fallback=" + (d.summary.used_host_fallback ? "1" : "0");
    return d;
}

// Synthesize FpgaOwnSignal from existing CoreStatus-shaped fields (no new SPI bits yet).
// Honest: product_recon_ok stays false until RTL packs a real sticky; host never invents it.
inline FpgaOwnSignal signalFromStatus(bool status_ok, uint8_t slice_type, uint8_t first_mb_type,
                                      bool residual_ok, bool sps_valid, bool has_stream,
                                      bool cabac_sticky) {
    FpgaOwnSignal s;
    s.valid = status_ok && has_stream && sps_valid;
    s.slice_type = slice_type;
    s.first_mb_type = first_mb_type;
    s.residual_ok = residual_ok;
    s.entropy_cabac = cabac_sticky;
    s.slice_is_i = isISliceType(slice_type);
    // Until status_telem carries hybrid_host_required / product_recon_ok, synthesize
    // host_required for non-I / cabac / IPCM first_mb — never invent product_recon_ok.
    s.product_recon_ok = false;
    s.hybrid_fpga_owned = false;
    if (!s.valid) {
        s.hybrid_host_required = true;
        s.own_code = OwnCode::HostUnsup;
        return s;
    }
    if (cabac_sticky) {
        s.hybrid_host_required = true;
        s.own_code = OwnCode::HostCabac;
        return s;
    }
    if (first_mb_type == 25) {
        s.hybrid_host_required = true;
        s.own_code = OwnCode::HostIpcm;
        return s;
    }
    if (!s.slice_is_i) {
        s.hybrid_host_required = true;
        s.own_code = OwnCode::HostInter;
        return s;
    }
    // I-slice: FPGA may own under CAP_INTRA, but product_recon_ok stays 0 without RTL bit.
    s.hybrid_host_required = false;
    s.hybrid_fpga_owned = residual_ok;
    s.own_code = OwnCode::FpgaIntra;
    return s;
}

} // namespace hybrid
} // namespace misterplex
