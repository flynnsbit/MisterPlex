#include "Vh264_cavlc_residual_tb_top.h"
#include "verilated.h"
#include "libmisterplex/h264_cavlc.hpp"
#include "libmisterplex/h264_nal.hpp"
#include "libmisterplex/h264_slice_walk.hpp"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

using misterplex::cavlc::tables::coeff_token_bits;
using misterplex::cavlc::tables::coeff_token_len;
using misterplex::cavlc::tables::chroma_dc_bits;
using misterplex::cavlc::tables::chroma_dc_len;
using misterplex::cavlc::tables::chroma_tz_bits;
using misterplex::cavlc::tables::chroma_tz_len;
using misterplex::cavlc::tables::run_bits;
using misterplex::cavlc::tables::run_len;
using misterplex::cavlc::tables::total_zeros_bits;
using misterplex::cavlc::tables::total_zeros_len;

constexpr int kMaxBytes = 128;

struct Encoded {
    std::vector<int> bits;
    int total_coeff = 0;
    int trailing_ones = 0;
    int total_zeros = 0;
};

static int failures = 0;

static void tick(Vh264_cavlc_residual_tb_top& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
}

static int sx16(int v) {
    v &= 0xffff;
    return (v & 0x8000) ? (v - 0x10000) : v;
}

static void put_bits(std::vector<int>& out, int bits, int len) {
    for (int i = len - 1; i >= 0; --i)
        out.push_back((bits >> i) & 1);
}

static int signed_to_level_code(int level) {
    return level > 0 ? 2 * level - 2 : -2 * level - 1;
}

static int suffix_next_first(int prefix, int suffix_length, int level) {
    if (prefix > 14 || (prefix == 14 && suffix_length == 0))
        return 2;
    return 1 + (std::abs(level) > 3);
}

static int suffix_next(int suffix_length, int level) {
    static const unsigned lim[7] = {0, 3, 6, 12, 24, 48, 0xffffffffu};
    if (suffix_length < 6 && static_cast<unsigned>(std::abs(level)) > lim[suffix_length])
        return suffix_length + 1;
    return suffix_length;
}

static void encode_level(std::vector<int>& bits, int level, bool first_non_t1, int t1, int& suffix_length) {
    int level_code = signed_to_level_code(level);
    if (first_non_t1 && t1 < 3)
        level_code -= 2;
    if (level_code < 0) {
        std::cerr << "encoder internal negative level_code\n";
        std::exit(2);
    }

    int prefix = 0;
    int suffix_bits = 0;
    int suffix_len = 0;
    if (first_non_t1) {
        if (suffix_length == 0) {
            if (level_code < 14) {
                prefix = level_code;
                suffix_len = 0;
            } else if (level_code < 30) {
                prefix = 14;
                suffix_len = 4;
                suffix_bits = level_code - 14;
            } else {
                prefix = 15;
                suffix_len = 12;
                suffix_bits = level_code - 30;
            }
        } else if (level_code < (14 << suffix_length)) {
            prefix = level_code >> suffix_length;
            suffix_len = suffix_length;
            suffix_bits = level_code & ((1 << suffix_length) - 1);
        } else {
            prefix = 15;
            suffix_len = 12;
            suffix_bits = level_code - (15 << suffix_length);
        }
    } else if (level_code < (15 << suffix_length)) {
        prefix = level_code >> suffix_length;
        suffix_len = suffix_length;
        suffix_bits = level_code & ((1 << suffix_length) - 1);
    } else {
        prefix = 15;
        suffix_len = 12;
        suffix_bits = level_code - (15 << suffix_length);
    }

    for (int i = 0; i < prefix; ++i)
        bits.push_back(0);
    bits.push_back(1);
    put_bits(bits, suffix_bits, suffix_len);
    suffix_length = first_non_t1 ? suffix_next_first(prefix, suffix_length, level)
                                 : suffix_next(suffix_length, level);
}

static Encoded encode_residual(const std::array<int, 16>& coeff, int table, int max_coeff) {
    Encoded e;
    std::vector<int> positions;
    std::vector<int> levels;
    for (int p = max_coeff - 1; p >= 0; --p) {
        if (coeff[p] != 0) {
            positions.push_back(p);
            levels.push_back(coeff[p]);
        }
    }
    const int tc = static_cast<int>(levels.size());
    int t1 = 0;
    while (t1 < tc && t1 < 3 && std::abs(levels[t1]) == 1)
        ++t1;
    e.total_coeff = tc;
    e.trailing_ones = t1;

    const int tok_idx = 4 * tc + t1;
    int tok_len = 0, tok_bits = 0;
    if (table == 4) {
        tok_len = chroma_dc_len[tok_idx];
        tok_bits = chroma_dc_bits[tok_idx];
    } else {
        tok_len = coeff_token_len[table][tok_idx];
        tok_bits = coeff_token_bits[table][tok_idx];
    }
    if (!tok_len) {
        std::cerr << "invalid token table=" << table << " tc=" << tc << " t1=" << t1 << "\n";
        std::exit(2);
    }
    put_bits(e.bits, tok_bits, tok_len);
    if (tc == 0)
        return e;

    for (int i = 0; i < t1; ++i)
        e.bits.push_back(levels[i] < 0 ? 1 : 0);

    int suffix_length = (tc > 10 && t1 < 3) ? 1 : 0;
    for (int i = t1; i < tc; ++i)
        encode_level(e.bits, levels[i], i == t1, t1, suffix_length);

    std::vector<int> pos_asc = positions;
    std::reverse(pos_asc.begin(), pos_asc.end());
    std::vector<int> run(tc, 0);
    int prev = -1;
    for (int a = 0; a < tc; ++a) {
        int run_for_ascending = pos_asc[a] - prev - 1;
        run[tc - 1 - a] = run_for_ascending;
        prev = pos_asc[a];
    }
    int total_zeros = 0;
    for (int r : run) total_zeros += r;
    e.total_zeros = total_zeros;

    if (tc < max_coeff) {
        int z_len = 0, z_bits = 0;
        if (max_coeff == 4) {
            z_len = chroma_tz_len[tc - 1][total_zeros];
            z_bits = chroma_tz_bits[tc - 1][total_zeros];
        } else {
            z_len = total_zeros_len[tc - 1][total_zeros];
            z_bits = total_zeros_bits[tc - 1][total_zeros];
        }
        if (!z_len) {
            std::cerr << "invalid total_zeros tc=" << tc << " z=" << total_zeros << " max=" << max_coeff << "\n";
            std::exit(2);
        }
        put_bits(e.bits, z_bits, z_len);
    }

    int zeros_left = total_zeros;
    for (int i = 0; i < tc - 1 && zeros_left > 0; ++i) {
        int r = run[i];
        int row = zeros_left < 7 ? zeros_left - 1 : 6;
        int r_len = run_len[row][r];
        int r_bits = run_bits[row][r];
        if (!r_len) {
            std::cerr << "invalid run_before zeros_left=" << zeros_left << " run=" << r << "\n";
            std::exit(2);
        }
        put_bits(e.bits, r_bits, r_len);
        zeros_left -= r;
    }
    return e;
}

static std::array<int, 16> make_coeff(int tc, int t1, int total_zeros, int max_coeff, const std::vector<int>& run_override = {}) {
    std::array<int, 16> coeff{};
    if (tc == 0)
        return coeff;
    std::vector<int> run(tc, 0);
    if (!run_override.empty()) {
        run = run_override;
    } else {
        run[tc - 1] = total_zeros;
    }
    std::vector<int> levels(tc, 0);
    for (int i = 0; i < tc; ++i) {
        if (i < t1)
            levels[i] = (i & 1) ? -1 : 1;
        else
            levels[i] = (i & 1) ? -(2 + i) : (2 + i);
    }
    int coeff_num = -1;
    for (int i = tc - 1; i >= 0; --i) {
        coeff_num += run[i] + 1;
        if (coeff_num < 0 || coeff_num >= max_coeff) {
            std::cerr << "bad synthetic coeff position\n";
            std::exit(2);
        }
        coeff[coeff_num] = levels[i];
    }
    return coeff;
}

static std::vector<uint8_t> pack_bits(const std::vector<int>& bits) {
    std::vector<uint8_t> bytes((bits.size() + 7) / 8, 0);
    for (size_t i = 0; i < bits.size(); ++i)
        if (bits[i]) bytes[i / 8] |= uint8_t(1u << (7 - (i & 7)));
    return bytes;
}

static void run_case(Vh264_cavlc_residual_tb_top& dut, const char* name, const std::array<int, 16>& coeff, int table, int max_coeff) {
    Encoded enc = encode_residual(coeff, table, max_coeff);
    auto bytes = pack_bits(enc.bits);
    if (bytes.size() > kMaxBytes) {
        std::cerr << "case too large " << name << "\n";
        std::exit(2);
    }
    for (int i = 0; i < kMaxBytes; ++i)
        dut.rbsp[i] = (i < static_cast<int>(bytes.size())) ? bytes[i] : 0;
    dut.coeff_token_table = table;
    dut.max_coeff = max_coeff;
    dut.bit_offset_start = 0;
    dut.bit_len = static_cast<int>(enc.bits.size());
    dut.start = 1;
    tick(dut);
    dut.start = 0;
    int guard = 1000;
    while (!dut.done && guard-- > 0)
        tick(dut);
    if (guard <= 0) {
        std::cerr << "timeout " << name << "\n";
        ++failures;
        return;
    }
    bool bad = false;
    if (!dut.ok || dut.total_coeff != enc.total_coeff || dut.trailing_ones != enc.trailing_ones ||
        dut.total_zeros != enc.total_zeros || dut.bit_offset_end != enc.bits.size()) {
        bad = true;
    }
    for (int i = 0; i < 16; ++i) {
        if (sx16(dut.coeff[i]) != coeff[i])
            bad = true;
    }
    if (bad) {
        std::cerr << "FAIL " << name << " table=" << table << " max=" << max_coeff
                  << " ok=" << int(dut.ok) << " tc=" << int(dut.total_coeff) << "/" << enc.total_coeff
                  << " t1=" << int(dut.trailing_ones) << "/" << enc.trailing_ones
                  << " tz=" << int(dut.total_zeros) << "/" << enc.total_zeros
                  << " bits=" << int(dut.bit_offset_end) << "/" << enc.bits.size() << " coeff=";
        for (int i = 0; i < 16; ++i)
            std::cerr << ' ' << sx16(dut.coeff[i]) << '(' << coeff[i] << ')';
        std::cerr << "\n";
        ++failures;
    }
}

static std::vector<uint8_t> read_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

static bool first_idr_payload(const std::vector<uint8_t>& annexb, const uint8_t*& pay, size_t& plen) {
    size_t i = 0;
    while (i + 3 < annexb.size()) {
        size_t sc = 0;
        if (i + 3 < annexb.size() && annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 0 && annexb[i + 3] == 1)
            sc = 4;
        else if (annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1)
            sc = 3;
        else {
            ++i;
            continue;
        }
        size_t j = i + sc;
        while (j + 3 < annexb.size()) {
            if (annexb[j] == 0 && annexb[j + 1] == 0 &&
                (annexb[j + 2] == 1 || (j + 3 < annexb.size() && annexb[j + 2] == 0 && annexb[j + 3] == 1)))
                break;
            ++j;
        }
        if (j + 3 >= annexb.size())
            j = annexb.size();
        if ((annexb[i + sc] & 0x1f) == 5) {
            pay = annexb.data() + i + sc + 1;
            plen = j - (i + sc + 1);
            return true;
        }
        i = j;
    }
    return false;
}

static int table_from_nc(int nc) {
    return (nc < 2) ? 0 : (nc < 4) ? 1 : (nc < 8) ? 2 : 3;
}

static void run_actual_mb0_block11(Vh264_cavlc_residual_tb_top& dut) {
    using namespace misterplex;
    auto annexb = read_file("tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264");
    auto chain = parseAnnexBChain(annexb.data(), annexb.size());
    const uint8_t* pay = nullptr;
    size_t plen = 0;
    if (!first_idr_payload(annexb, pay, plen) || !chain.slice.valid) {
        std::cerr << "missing actual MB0 block fixture\n";
        ++failures;
        return;
    }
    auto rbsp = detail::removeEpb(pay, plen);
    detail::BitReader br(rbsp.data(), rbsp.size());
    br.ue(); br.ue(); br.ue();
    br.u(chain.log2_max_frame_num);
    br.ue(); br.u(1); br.u(1);
    br.se();
    if (chain.pps.deblock_ctrl) {
        uint32_t idc = br.ue();
        if (idc != 1) {
            br.se();
            br.se();
        }
    }
    br.ue();
    for (int k = 0; k < 16; ++k)
        if (br.u(1) == 0)
            br.u(3);
    br.ue();
    int cbp = walk_detail::kMeIntra[br.ue()];
    if (cbp)
        br.se();
    std::array<int, 16> tc_grid;
    tc_grid.fill(-1);
    auto tcat = [&](int lx, int ly) -> int* {
        if (lx < 0 || ly < 0 || lx > 3 || ly > 3)
            return nullptr;
        int& v = tc_grid[ly * 4 + lx];
        return (v < 0) ? nullptr : &v;
    };
    int start = 0, end = 0, nc = 0, target_nc = 0;
    misterplex::cavlc::ResidualResult gold;
    std::array<int, 16> block_end{};
    std::array<int, 16> block_tc{};
    std::array<int, 16> block_t1{};
    std::array<std::array<int, 16>, 16> block_coeff{};
    for (int i8 = 0; i8 < 4; ++i8) {
        for (int i4 = 0; i4 < 4; ++i4) {
            int lx = 0, ly = 0;
            walk_detail::blkXY(i8, i4, lx, ly);
            nc = walk_detail::ncFrom((lx > 0) ? tcat(lx - 1, ly) : nullptr,
                                     (ly > 0) ? tcat(lx, ly - 1) : nullptr);
            int idx = i8 * 4 + i4;
            int bit0 = static_cast<int>(br.bit);
            auto r = cavlc::residualBlock(br, nc, 16);
            tc_grid[ly * 4 + lx] = r.total_coeff;
            block_end[idx] = static_cast<int>(br.bit);
            block_tc[idx] = r.total_coeff;
            block_t1[idx] = r.trailing_ones;
            for (int c = 0; c < 16; ++c)
                block_coeff[idx][c] = r.coeff[c];
            if (idx == 11) {
                start = bit0;
                end = static_cast<int>(br.bit);
                target_nc = nc;
                gold = r;
            }
        }
    }
    for (int i = 0; i < kMaxBytes; ++i)
        dut.rbsp[i] = (i < static_cast<int>(rbsp.size())) ? rbsp[i] : 0;
    dut.coeff_token_table = table_from_nc(target_nc);
    dut.max_coeff = 16;
    dut.bit_offset_start = start;
    dut.bit_len = end;
    dut.start = 1;
    tick(dut);
    dut.start = 0;
    int guard = 1000;
    while (!dut.done && guard-- > 0)
        tick(dut);
    bool bad = (guard <= 0) || !dut.ok || dut.total_coeff != gold.total_coeff ||
               dut.trailing_ones != gold.trailing_ones || dut.bit_offset_end != end;
    for (int i = 0; i < 16; ++i)
        if (sx16(dut.coeff[i]) != gold.coeff[i])
            bad = true;
    if (bad) {
        std::cerr << "FAIL actual_mb0_block11_nc7 table=" << table_from_nc(target_nc)
                  << " ok=" << int(dut.ok) << " tc=" << int(dut.total_coeff) << "/" << gold.total_coeff
                  << " t1=" << int(dut.trailing_ones) << "/" << gold.trailing_ones
                  << " tz=" << int(dut.total_zeros)
                  << " end=" << int(dut.bit_offset_end) << "/" << end << " coeff=";
        for (int i = 0; i < 16; ++i)
            std::cerr << ' ' << sx16(dut.coeff[i]) << '(' << gold.coeff[i] << ')';
        std::cerr << " level=";
        for (int i = 0; i < 16; ++i)
            std::cerr << ' ' << sx16(dut.level_dbg[i]);
        std::cerr << " run=";
        for (int i = 0; i < 16; ++i)
            std::cerr << ' ' << int(dut.run_dbg[i]);
        std::cerr << "\n";
        ++failures;
    }

    dut.src_bit_offset_start = 77;
    dut.src_bit_len = block_end[15];
    dut.src_cbp_luma = 0xf;
    dut.src_qp = chain.slice.slice_qp;
    dut.src_start = 1;
    tick(dut);
    dut.src_start = 0;
    int seen = 0;
    int src_guard = 10000;
    while (!dut.src_done && src_guard-- > 0) {
        tick(dut);
        if (dut.src_luma4x4_valid) {
            int idx = dut.src_luma4x4_idx;
            bool src_bad = idx != seen || dut.src_luma4x4_qp != chain.slice.slice_qp ||
                           dut.src_luma4x4_total_coeff != block_tc[idx] ||
                           dut.src_luma4x4_trailing_ones != block_t1[idx] ||
                           dut.src_luma4x4_bit_offset_end != block_end[idx];
            for (int c = 0; c < 16; ++c)
                if (sx16(dut.src_luma4x4_coeff_zigzag[c]) != block_coeff[idx][c])
                    src_bad = true;
            if (src_bad) {
                std::cerr << "FAIL actual_mb0_luma4x4_source block=" << idx << " seen=" << seen
                          << " tc=" << int(dut.src_luma4x4_total_coeff) << "/" << block_tc[idx]
                          << " t1=" << int(dut.src_luma4x4_trailing_ones) << "/" << block_t1[idx]
                          << " end=" << int(dut.src_luma4x4_bit_offset_end) << "/" << block_end[idx] << "\n";
                ++failures;
            }
            ++seen;
        }
    }
    if (src_guard <= 0 || !dut.src_ok || seen != 16 || dut.src_bit_offset_end != block_end[15]) {
        std::cerr << "FAIL actual_mb0_luma4x4_source summary ok=" << int(dut.src_ok)
                  << " seen=" << seen << " end=" << int(dut.src_bit_offset_end)
                  << "/" << block_end[15] << "\n";
        ++failures;
    }
    std::cout << "Scope: luma4x4 source 16/16 luma residual blocks for real IDR MB0 (1/300 MBs in 320x240 fixture); coeff order=zigzag; qp="
              << int(chain.slice.slice_qp) << "\n";
}

struct Code { int len; int bits; std::string sym; };

static void validate_prefix_free(const std::string& name, const std::vector<Code>& codes) {
    std::set<std::pair<int,int>> seen;
    for (const auto& c : codes) {
        if (!seen.insert({c.len, c.bits}).second) {
            std::cerr << "duplicate VLC code in " << name << " len=" << c.len << " bits=" << c.bits << "\n";
            ++failures;
        }
    }
    for (size_t i = 0; i < codes.size(); ++i) {
        for (size_t j = 0; j < codes.size(); ++j) {
            if (i == j) continue;
            const auto& a = codes[i];
            const auto& b = codes[j];
            if (a.len <= b.len && (b.bits >> (b.len - a.len)) == a.bits) {
                std::cerr << "prefix violation " << name << ": " << a.sym << " prefixes " << b.sym << "\n";
                ++failures;
            }
        }
    }
}

static void validate_tables() {
    for (int tab = 0; tab < 4; ++tab) {
        std::vector<Code> codes;
        for (int idx = 0; idx < 68; ++idx)
            if (coeff_token_len[tab][idx]) codes.push_back({coeff_token_len[tab][idx], coeff_token_bits[tab][idx], std::to_string(idx)});
        validate_prefix_free("coeff_token_" + std::to_string(tab), codes);
    }
    {
        std::vector<Code> codes;
        for (int idx = 0; idx < 20; ++idx)
            if (chroma_dc_len[idx]) codes.push_back({chroma_dc_len[idx], chroma_dc_bits[idx], std::to_string(idx)});
        validate_prefix_free("coeff_token_chroma_dc", codes);
    }
    for (int tc = 1; tc <= 15; ++tc) {
        std::vector<Code> codes;
        for (int z = 0; z <= 16 - tc; ++z)
            if (total_zeros_len[tc - 1][z]) codes.push_back({total_zeros_len[tc - 1][z], total_zeros_bits[tc - 1][z], std::to_string(z)});
        validate_prefix_free("total_zeros_" + std::to_string(tc), codes);
    }
    for (int tc = 1; tc <= 3; ++tc) {
        std::vector<Code> codes;
        for (int z = 0; z <= 4 - tc; ++z)
            if (chroma_tz_len[tc - 1][z]) codes.push_back({chroma_tz_len[tc - 1][z], chroma_tz_bits[tc - 1][z], std::to_string(z)});
        validate_prefix_free("chroma_total_zeros_" + std::to_string(tc), codes);
    }
    for (int zl = 1; zl <= 7; ++zl) {
        std::vector<Code> codes;
        int row = zl < 7 ? zl - 1 : 6;
        int n = zl < 7 ? zl + 1 : 15;
        for (int r = 0; r < n; ++r)
            if (run_len[row][r]) codes.push_back({run_len[row][r], run_bits[row][r], std::to_string(r)});
        validate_prefix_free("run_before_" + std::to_string(zl), codes);
    }
}

static void check_nc(Vh264_cavlc_residual_tb_top& dut, const char* name, int mbx, int mby, int mb_index, int mbw,
                     int first, int bx, int by, bool lv, int ltc, bool uv, int utc,
                     bool exp_a, bool exp_b, int exp_nc, int exp_tab) {
    dut.nc_mb_x = mbx; dut.nc_mb_y = mby; dut.nc_mb_index = mb_index; dut.nc_mb_width = mbw;
    dut.nc_first_mb_in_slice = first; dut.nc_block_x = bx; dut.nc_block_y = by;
    dut.nc_left_tc_valid = lv; dut.nc_left_tc = ltc; dut.nc_up_tc_valid = uv; dut.nc_up_tc = utc;
    dut.eval();
    if (dut.nc_nA_available != exp_a || dut.nc_nB_available != exp_b || dut.nc_nC != exp_nc || dut.nc_coeff_token_table != exp_tab) {
        std::cerr << "NC FAIL " << name << " got avail=" << int(dut.nc_nA_available) << ',' << int(dut.nc_nB_available)
                  << " nC=" << int(dut.nc_nC) << " tab=" << int(dut.nc_coeff_token_table)
                  << " expected avail=" << exp_a << ',' << exp_b << " nC=" << exp_nc << " tab=" << exp_tab << "\n";
        ++failures;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    validate_tables();
    Vh264_cavlc_residual_tb_top dut;
    dut.clk = 0; dut.reset = 1; dut.start = 0;
    dut.src_start = 0;
    tick(dut);
    dut.reset = 0;

    check_nc(dut, "mb0-none", 0,0,0,39,0,0,0,false,0,false,0,false,false,0,0);
    check_nc(dut, "intra-mb-left", 0,0,0,39,0,1,0,true,5,false,0,true,false,5,2);
    check_nc(dut, "row0-left-mb", 1,0,1,39,0,0,0,true,3,false,0,true,false,3,1);
    check_nc(dut, "col0-up-mb", 0,1,39,39,0,0,0,false,0,true,4,false,true,4,2);
    check_nc(dut, "both-average", 2,2,80,39,0,0,0,true,3,true,4,true,true,4,2);
    check_nc(dut, "slice-start-blocked", 1,1,40,39,40,0,0,true,7,true,8,false,false,0,0);
    check_nc(dut, "slice-start-internal", 1,1,40,39,40,1,1,true,7,true,8,true,true,8,3);

    int cases = 0;
    for (int tab = 0; tab < 4; ++tab) {
        for (int tc = 0; tc <= 16; ++tc) {
            for (int t1 = 0; t1 <= 3; ++t1) {
                if (t1 > tc || coeff_token_len[tab][4 * tc + t1] == 0) continue;
                auto c = make_coeff(tc, t1, 0, 16);
                run_case(dut, "coeff_token", c, tab, 16);
                ++cases;
            }
        }
    }
    for (int tc = 0; tc <= 4; ++tc) {
        for (int t1 = 0; t1 <= 3; ++t1) {
            if (t1 > tc || chroma_dc_len[4 * tc + t1] == 0) continue;
            auto c = make_coeff(tc, t1, 0, 4);
            run_case(dut, "chroma_coeff_token", c, 4, 4);
            ++cases;
        }
    }
    for (int tc = 1; tc <= 15; ++tc) {
        int t1 = std::min(3, tc);
        for (int z = 0; z <= 16 - tc; ++z) {
            auto c = make_coeff(tc, t1, z, 16);
            run_case(dut, "total_zeros", c, 0, 16);
            ++cases;
        }
    }
    for (int tc = 1; tc <= 3; ++tc) {
        int t1 = std::min(3, tc);
        for (int z = 0; z <= 4 - tc; ++z) {
            auto c = make_coeff(tc, t1, z, 4);
            run_case(dut, "chroma_total_zeros", c, 4, 4);
            ++cases;
        }
    }
    for (int z = 1; z <= 14; ++z) {
        for (int r = 0; r <= z; ++r) {
            std::vector<int> runs = {r, z - r};
            auto c = make_coeff(2, 0, z, 16, runs);
            run_case(dut, "run_before", c, 0, 16);
            ++cases;
        }
    }
    {
        std::array<int, 16> c{};
        int vals[] = {300, -301, 255, -256, 64, -33, 17, -8, 4, -2, 1, -1};
        for (int i = 0; i < 12; ++i) c[i] = vals[i];
        run_case(dut, "large_suffix_gt9bit", c, 0, 16);
        ++cases;
    }
    {
        std::array<int, 16> c = {-1, 11, -3, 0, 9, 1, -1, 3, -6, 0, 0, 2, -2, 3, -5, 0};
        run_case(dut, "real_mb0_block11_nc7", c, 2, 16);
        ++cases;
    }
    run_actual_mb0_block11(dut);

    if (failures) {
        std::cerr << "H264 CAVLC residual RTL FAILED failures=" << failures << " cases=" << cases << "\n";
        return 1;
    }
    std::cout << "H264 CAVLC residual Verilator PASS: prefix-free tables checked; roundtrip_cases="
              << cases << " including all coeff_token tables, luma/chroma total_zeros, run_before, nC edges, suffix escalation\n";
    return 0;
}
