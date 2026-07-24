// Host-side H.264 PPS + slice header parse (Baseline) for unit tests / 3.3d.
#pragma once
#include "libmisterplex/h264_sps.hpp"

#include <cstdint>
#include <vector>

namespace misterplex {

struct PpsInfo {
    bool valid = false;
    uint8_t pps_id = 0;
    uint8_t sps_id = 0;
    bool entropy_cabac = false; // must be 0 for Baseline CAVLC
    uint8_t num_ref_idx_l0_default = 0;
    int8_t pic_init_qp = 0; // 26 + pic_init_qp_minus26
};

struct SliceHeader {
    bool valid = false;
    uint32_t first_mb_in_slice = 0;
    uint8_t slice_type = 0; // 2 or 7 = I
    uint8_t pps_id = 0;
    uint32_t frame_num = 0;
    uint32_t idr_pic_id = 0;
    bool is_idr = false;
    bool is_i_slice = false;
};

inline bool isISliceType(uint8_t t) {
    // 2=I, 7=I (all), also 4=SI, 9=SI
    return t == 2 || t == 7;
}

inline PpsInfo parsePpsRbsp(const uint8_t* payload, size_t len) {
    PpsInfo out;
    if (!payload || len < 2)
        return out;
    auto rbsp = detail::removeEpb(payload, len);
    detail::BitReader br(rbsp.data(), rbsp.size());
    out.pps_id = static_cast<uint8_t>(br.ue());
    out.sps_id = static_cast<uint8_t>(br.ue());
    out.entropy_cabac = br.u(1) != 0;
    br.u(1); // bottom_field_pic_order_in_frame_present
    uint32_t sg = br.ue();
    if (sg > 0)
        return out; // FMO not supported
    out.num_ref_idx_l0_default = static_cast<uint8_t>(br.ue());
    br.ue(); // l1
    br.u(1); // weighted_pred
    br.u(2); // weighted_bipred
    int32_t qpm = br.se();
    out.pic_init_qp = static_cast<int8_t>(26 + qpm);
    br.se(); // qs
    br.se(); // chroma_qp_index_offset
    br.u(1); // deblocking
    br.u(1); // constrained_intra
    br.u(1); // redundant_pic_cnt
    if (!br.ok || out.entropy_cabac)
        return out; // Baseline path wants CAVLC
    out.valid = true;
    return out;
}

inline SliceHeader parseSliceHeaderRbsp(const uint8_t* payload, size_t len, uint8_t nal_type,
                                        uint8_t log2_max_frame_num, uint8_t /*poc_type*/) {
    SliceHeader out;
    if (!payload || len < 1 || log2_max_frame_num == 0 || log2_max_frame_num > 16)
        return out;
    auto rbsp = detail::removeEpb(payload, len);
    detail::BitReader br(rbsp.data(), rbsp.size());
    out.first_mb_in_slice = br.ue();
    out.slice_type = static_cast<uint8_t>(br.ue());
    out.pps_id = static_cast<uint8_t>(br.ue());
    out.frame_num = br.u(log2_max_frame_num);
    out.is_idr = (nal_type == 5);
    if (out.is_idr)
        out.idr_pic_id = br.ue();
    // poc_type 0 would need pic_order_cnt_lsb — skip for type 2
    if (!br.ok)
        return out;
    out.is_i_slice = isISliceType(out.slice_type);
    out.valid = true;
    return out;
}

// Scan annex-B: SPS + PPS + first IDR/slice
struct NalChainInfo {
    SpsInfo sps;
    PpsInfo pps;
    SliceHeader slice;
};

inline NalChainInfo parseAnnexBChain(const uint8_t* data, size_t n) {
    NalChainInfo info;
    if (!data || n < 5)
        return info;
    size_t i = 0;
    uint8_t log2 = 0;
    uint8_t poc = 0;
    while (i + 3 < n) {
        size_t sc = 0;
        if (i + 3 < n && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1)
            sc = 4;
        else if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            sc = 3;
        else {
            ++i;
            continue;
        }
        size_t j = i + sc;
        while (j + 3 < n) {
            if (data[j] == 0 && data[j + 1] == 0 &&
                (data[j + 2] == 1 || (j + 3 < n && data[j + 2] == 0 && data[j + 3] == 1)))
                break;
            ++j;
        }
        if (j + 3 >= n)
            j = n;
        if (i + sc < j) {
            uint8_t hdr = data[i + sc];
            uint8_t t = hdr & 0x1f;
            const uint8_t* pay = data + i + sc + 1;
            size_t plen = j - (i + sc + 1);
            if (t == 7) {
                info.sps = parseSpsRbsp(pay, plen);
                // re-parse log2/poc quickly from same RBSP
                auto rb = detail::removeEpb(pay, plen);
                detail::BitReader br(rb.data(), rb.size());
                br.u(8);
                br.u(8);
                br.u(8);
                br.ue();
                log2 = static_cast<uint8_t>(br.ue() + 4);
                poc = static_cast<uint8_t>(br.ue());
            } else if (t == 8) {
                info.pps = parsePpsRbsp(pay, plen);
            } else if ((t == 1 || t == 5) && info.sps.valid && log2) {
                info.slice = parseSliceHeaderRbsp(pay, plen, t, log2, poc);
                if (info.slice.valid)
                    break;
            }
        }
        i = j;
    }
    return info;
}

} // namespace misterplex
