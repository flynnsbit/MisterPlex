// Host dump: P-slice MB cbp + chroma residual levels for discrimination vs RTL.
// Usage: dump_p_mb_chroma_res <annexb.264> <frame_idx> <mb_addr>
#include "libmisterplex/h264_nal.hpp"
#include "libmisterplex/h264_cavlc.hpp"

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>

using namespace misterplex;

// FFmpeg golomb_to_inter4x4_cbp
static const uint8_t kMeInter[48] = {
	0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13,
	14, 6, 9, 31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46,
	17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41};
static const uint8_t kMeIntra[48] = {
	47, 31, 15, 0, 23, 27, 29, 30, 7, 11, 13, 14, 39, 43, 45, 46,
	16, 3, 5, 10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1, 2, 4,
	8, 17, 18, 20, 24, 6, 9, 22, 25, 32, 33, 34, 36, 40, 38, 41};

static std::vector<uint8_t> readFile(const char* path) {
	std::ifstream f(path, std::ios::binary);
	return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), {});
}

struct Nal {
	uint8_t type = 0;
	uint8_t nri = 0;
	std::vector<uint8_t> payload;
};

static std::vector<Nal> splitNals(const uint8_t* a, size_t n) {
	std::vector<Nal> out;
	size_t i = 0;
	while (i + 3 < n) {
		size_t sc = 0;
		if (i + 3 < n && a[i] == 0 && a[i + 1] == 0 && a[i + 2] == 0 && a[i + 3] == 1)
			sc = 4;
		else if (a[i] == 0 && a[i + 1] == 0 && a[i + 2] == 1)
			sc = 3;
		else {
			++i;
			continue;
		}
		size_t j = i + sc;
		while (j + 3 < n) {
			if (a[j] == 0 && a[j + 1] == 0 &&
			    (a[j + 2] == 1 || (j + 3 < n && a[j + 2] == 0 && a[j + 3] == 1)))
				break;
			++j;
		}
		if (j + 3 >= n)
			j = n;
		Nal nal;
		nal.nri = (a[i + sc] >> 5) & 3;
		nal.type = a[i + sc] & 0x1f;
		nal.payload.assign(a + i + sc + 1, a + j);
		out.push_back(std::move(nal));
		i = j;
	}
	return out;
}

static int ncAvg(int a, int av, int b, int bv) {
	if (!av && !bv)
		return 0;
	if (!av)
		return b;
	if (!bv)
		return a;
	return (a + b + 1) >> 1;
}

static int wrapQp(int qp) {
	while (qp < 0)
		qp += 52;
	while (qp > 51)
		qp -= 52;
	return qp;
}

static bool parseHdrToMb(detail::BitReader& br, uint8_t nal_type, uint8_t nri,
                         uint8_t log2_fn, const PpsInfo& pps, SliceHeader& out) {
	out = {};
	out.first_mb_in_slice = br.ue();
	out.slice_type = static_cast<uint8_t>(br.ue());
	out.pps_id = static_cast<uint8_t>(br.ue());
	out.frame_num = br.u(log2_fn);
	out.is_idr = (nal_type == 5);
	if (out.is_idr)
		out.idr_pic_id = br.ue();
	bool is_p_or_b = !isISliceType(out.slice_type) && (out.slice_type % 5) != 4;
	if (is_p_or_b) {
		if (br.u(1))
			br.ue();
	}
	if (is_p_or_b) {
		if (br.u(1)) {
			uint32_t idc;
			do {
				idc = br.ue();
				if (idc == 0 || idc == 1)
					br.ue();
				else if (idc == 2)
					br.ue();
			} while (idc != 3 && br.ok);
		}
	}
	if (nri != 0) {
		if (out.is_idr) {
			br.u(1);
			br.u(1);
		} else if (br.u(1)) {
			uint32_t mmco;
			do {
				mmco = br.ue();
				if (mmco == 1 || mmco == 3)
					br.ue();
				if (mmco == 2)
					br.ue();
				if (mmco == 3 || mmco == 6)
					br.ue();
				if (mmco == 4)
					br.ue();
			} while (mmco != 0 && br.ok);
		}
	}
	out.slice_qp_delta = static_cast<int8_t>(br.se());
	int qp = static_cast<int>(pps.pic_init_qp) + out.slice_qp_delta;
	out.slice_qp = static_cast<int8_t>(wrapQp(qp));
	if (pps.deblock_ctrl) {
		out.disable_deblocking_idc = static_cast<uint8_t>(br.ue());
		if (out.disable_deblocking_idc != 1) {
			br.se();
			br.se();
		}
	}
	out.is_i_slice = isISliceType(out.slice_type);
	out.valid = br.ok;
	return br.ok;
}

int main(int argc, char** argv) {
	if (argc < 4) {
		std::fprintf(stderr, "usage: %s annexb.264 frame_idx mb_addr\n", argv[0]);
		return 2;
	}
	const int want_f = std::atoi(argv[2]);
	const int want_mb = std::atoi(argv[3]);
	auto bytes = readFile(argv[1]);
	auto nals = splitNals(bytes.data(), bytes.size());
	auto chain = parseAnnexBChain(bytes.data(), bytes.size());
	if (!chain.sps.valid || !chain.pps.valid) {
		std::fprintf(stderr, "no sps/pps\n");
		return 1;
	}
	const int mb_w = chain.sps.width / 16;
	const int mb_h = chain.sps.height / 16;
	const int pic_mbs = mb_w * mb_h;
	std::printf("geom %dx%d mbs=%d log2_fn=%u pic_init_qp=%d\n", chain.sps.width, chain.sps.height,
	            pic_mbs, chain.log2_max_frame_num, (int)chain.pps.pic_init_qp);

	int chroma_off = 0;
	for (const auto& nal : nals) {
		if (nal.type != 8)
			continue;
		auto rbsp = detail::removeEpb(nal.payload.data(), nal.payload.size());
		detail::BitReader br(rbsp.data(), rbsp.size());
		br.ue(); br.ue(); br.u(1); br.u(1);
		if (br.ue() > 0) break;
		br.ue(); br.ue(); br.u(1); br.u(2);
		br.se(); br.se();
		chroma_off = br.se();
		break;
	}
	std::printf("chroma_qp_index_offset=%d\n", chroma_off);

	int frame_idx = -1;
	for (const auto& nal : nals) {
		if (nal.type != 1 && nal.type != 5)
			continue;
		++frame_idx;
		if (frame_idx != want_f)
			continue;

		auto rbsp = detail::removeEpb(nal.payload.data(), nal.payload.size());
		detail::BitReader br(rbsp.data(), rbsp.size());
		SliceHeader sh;
		if (!parseHdrToMb(br, nal.type, nal.nri, chain.log2_max_frame_num, chain.pps, sh)) {
			std::printf("HOST_FAIL header f=%d\n", frame_idx);
			return 1;
		}
		std::printf("SLICE f=%d nal=%u type=%u i=%d qp=%d bit=%zu\n", frame_idx, nal.type,
		            sh.slice_type, (int)sh.is_i_slice, (int)sh.slice_qp, br.bit);
		if (sh.is_i_slice || nal.type == 5) {
			std::printf("I-slice — not dumped\n");
			return 0;
		}

		int qp = sh.slice_qp;
		std::vector<int> tc_top(mb_w * 4, 0), tc_top_v(mb_w * 4, 0);
		int tc_left[4] = {}, tc_left_v[4] = {};
		std::vector<int> tc_chr_top0(mb_w * 2, 0), tc_chr_top1(mb_w * 2, 0);
		std::vector<int> tc_chr_top_v0(mb_w * 2, 0), tc_chr_top_v1(mb_w * 2, 0);
		int tc_chr_left[2][2] = {}, tc_chr_left_v[2][2] = {};

		int mb = 0;
		while (mb < pic_mbs && br.ok) {
			int mbx = mb % mb_w;
			int mby = mb / mb_w;
			if (mbx == 0) {
				std::memset(tc_left, 0, sizeof(tc_left));
				std::memset(tc_left_v, 0, sizeof(tc_left_v));
				std::memset(tc_chr_left, 0, sizeof(tc_chr_left));
				std::memset(tc_chr_left_v, 0, sizeof(tc_chr_left_v));
			}

			uint32_t skip = br.ue();
			for (uint32_t s = 0; s < skip && mb < pic_mbs; ++s) {
				mbx = mb % mb_w; mby = mb / mb_w;
				if (mbx == 0) {
					std::memset(tc_left, 0, sizeof(tc_left));
					std::memset(tc_left_v, 0, sizeof(tc_left_v));
					std::memset(tc_chr_left, 0, sizeof(tc_chr_left));
					std::memset(tc_chr_left_v, 0, sizeof(tc_chr_left_v));
				}
				for (int t = 0; t < 4; ++t) {
					tc_left[t] = 0; tc_left_v[t] = 1;
					tc_top[mbx * 4 + t] = 0; tc_top_v[mbx * 4 + t] = 1;
				}
				for (int p = 0; p < 2; ++p)
					for (int b = 0; b < 2; ++b) {
						tc_chr_left[p][b] = 0; tc_chr_left_v[p][b] = 1;
						if (p == 0) { tc_chr_top0[mbx * 2 + b] = 0; tc_chr_top_v0[mbx * 2 + b] = 1; }
						else { tc_chr_top1[mbx * 2 + b] = 0; tc_chr_top_v1[mbx * 2 + b] = 1; }
					}
				if (mb == want_mb)
					std::printf("HOST f=%d mb=%d (%d,%d) P_Skip cbp_c=0 qp=%d\n", frame_idx, mb, mbx, mby, qp);
				++mb;
			}
			if (mb >= pic_mbs) break;
			mbx = mb % mb_w; mby = mb / mb_w;
			if (mbx == 0) {
				std::memset(tc_left, 0, sizeof(tc_left));
				std::memset(tc_left_v, 0, sizeof(tc_left_v));
				std::memset(tc_chr_left, 0, sizeof(tc_chr_left));
				std::memset(tc_chr_left_v, 0, sizeof(tc_chr_left_v));
			}

			uint32_t mt = br.ue();
			int cbp = 0, cbp_l = 0, cbp_c = 0;
			bool is_intra = false, is_i16 = false;
			int mvd_pairs = 1;
			if (mt >= 5) {
				is_intra = true;
				uint32_t imt = mt - 5;
				if (imt == 0) {
					for (int k = 0; k < 16; ++k)
						if (br.u(1) == 0) br.u(3);
					br.ue();
					uint32_t code = br.ue();
					if (code >= 48) { std::printf("HOST_FAIL cbp intra mb=%d\n", mb); return 1; }
					cbp = kMeIntra[code];
				} else if (imt <= 24) {
					is_i16 = true;
					br.ue();
					int cbp_c_i = ((int)imt - 1) / 4 % 3;
					int cbp_l_i = (((int)imt - 1) / 12) ? 15 : 0;
					cbp = (cbp_c_i << 4) | cbp_l_i;
				} else { std::printf("HOST_FAIL PCM mb=%d\n", mb); return 1; }
			} else {
				if (mt == 1 || mt == 2) mvd_pairs = 2;
				else if (mt == 3 || mt == 4) {
					mvd_pairs = 0;
					for (int i = 0; i < 4; ++i) {
						uint32_t st = br.ue();
						if (st == 0) mvd_pairs += 1;
						else if (st == 1 || st == 2) mvd_pairs += 2;
						else mvd_pairs += 4;
					}
				}
				for (int i = 0; i < mvd_pairs; ++i) { br.se(); br.se(); }
				uint32_t code = br.ue();
				if (code >= 48) { std::printf("HOST_FAIL cbp inter mb=%d code=%u\n", mb, code); return 1; }
				cbp = kMeInter[code];
			}
			cbp_l = cbp & 15;
			cbp_c = cbp >> 4;
			if (cbp != 0)
				qp = wrapQp(qp + (int)br.se());

			int tc4[16] = {}, tc4v[16] = {};
			auto getLumaNC = [&](int blk) {
				int bx = blk % 4, by = blk / 4;
				int a = 0, av = 0, b = 0, bv = 0;
				if (bx > 0) { a = tc4[by * 4 + bx - 1]; av = tc4v[by * 4 + bx - 1]; }
				else { a = tc_left[by]; av = tc_left_v[by]; }
				if (by > 0) { b = tc4[(by - 1) * 4 + bx]; bv = tc4v[(by - 1) * 4 + bx]; }
				else { b = tc_top[mbx * 4 + bx]; bv = tc_top_v[mbx * 4 + bx]; }
				return ncAvg(a, av, b, bv);
			};
			auto commitLuma = [&](int blk, int tc) {
				int bx = blk % 4, by = blk / 4;
				tc4[blk] = tc; tc4v[blk] = 1;
				if (bx == 3) { tc_left[by] = tc; tc_left_v[by] = 1; }
				if (by == 3) { tc_top[mbx * 4 + bx] = tc; tc_top_v[mbx * 4 + bx] = 1; }
			};

			int16_t chr_dc[2][4] = {};
			int chr_dc_tc[2] = {};
			int16_t chr_ac[2][4][16] = {};
			int chr_ac_tc[2][4] = {};

			if (is_i16) {
				auto r = cavlc::residualBlock(br, getLumaNC(0), 16);
				if (!r.ok) { std::printf("HOST_FAIL i16dc mb=%d\n", mb); return 1; }
				if (cbp_l) {
					for (int i = 0; i < 16; ++i) {
						auto ra = cavlc::residualBlock(br, getLumaNC(i), 15);
						if (!ra.ok) { std::printf("HOST_FAIL i16ac mb=%d i=%d\n", mb, i); return 1; }
						commitLuma(i, ra.total_coeff);
					}
				} else for (int i = 0; i < 16; ++i) commitLuma(i, 0);
			} else {
				for (int i8 = 0; i8 < 4; ++i8) {
					int coded = (cbp_l >> i8) & 1;
					for (int i4 = 0; i4 < 4; ++i4) {
						int bx = (i8 % 2) * 2 + (i4 % 2);
						int by = (i8 / 2) * 2 + (i4 / 2);
						int blk = by * 4 + bx;
						if (coded) {
							auto r = cavlc::residualBlock(br, getLumaNC(blk), 16);
							if (!r.ok) { std::printf("HOST_FAIL luma mb=%d blk=%d\n", mb, blk); return 1; }
							commitLuma(blk, r.total_coeff);
						} else commitLuma(blk, 0);
					}
				}
			}
			for (int t = 0; t < 4; ++t) {
				tc_left[t] = tc4[t * 4 + 3]; tc_left_v[t] = 1;
				tc_top[mbx * 4 + t] = tc4[12 + t]; tc_top_v[mbx * 4 + t] = 1;
			}

			if (cbp_c) {
				for (int p = 0; p < 2; ++p) {
					auto r = cavlc::residualBlock(br, -1, 4);
					if (!r.ok) { std::printf("HOST_FAIL chrDC mb=%d p=%d\n", mb, p); return 1; }
					chr_dc_tc[p] = r.total_coeff;
					for (int k = 0; k < 4; ++k) chr_dc[p][k] = r.coeff[k];
				}
			}
			if (cbp_c == 2) {
				for (int p = 0; p < 2; ++p) {
					for (int bi = 0; bi < 4; ++bi) {
						int bx = bi % 2, by = bi / 2;
						int a = 0, av = 0, b = 0, bv = 0;
						if (bx > 0) { a = chr_ac_tc[p][bi - 1]; av = 1; }
						else { a = tc_chr_left[p][by]; av = tc_chr_left_v[p][by]; }
						if (by > 0) { b = chr_ac_tc[p][bi - 2]; bv = 1; }
						else {
							if (p == 0) { b = tc_chr_top0[mbx * 2 + bx]; bv = tc_chr_top_v0[mbx * 2 + bx]; }
							else { b = tc_chr_top1[mbx * 2 + bx]; bv = tc_chr_top_v1[mbx * 2 + bx]; }
						}
						auto r = cavlc::residualBlock(br, ncAvg(a, av, b, bv), 15);
						if (!r.ok) { std::printf("HOST_FAIL chrAC mb=%d p=%d bi=%d\n", mb, p, bi); return 1; }
						chr_ac_tc[p][bi] = r.total_coeff;
						for (int k = 0; k < 16; ++k) chr_ac[p][bi][k] = r.coeff[k];
						if (bx == 1) { tc_chr_left[p][by] = r.total_coeff; tc_chr_left_v[p][by] = 1; }
						if (by == 1) {
							if (p == 0) { tc_chr_top0[mbx * 2 + bx] = r.total_coeff; tc_chr_top_v0[mbx * 2 + bx] = 1; }
							else { tc_chr_top1[mbx * 2 + bx] = r.total_coeff; tc_chr_top_v1[mbx * 2 + bx] = 1; }
						}
					}
				}
			} else {
				for (int p = 0; p < 2; ++p)
					for (int b = 0; b < 2; ++b) {
						tc_chr_left[p][b] = 0; tc_chr_left_v[p][b] = 1;
						if (p == 0) { tc_chr_top0[mbx * 2 + b] = 0; tc_chr_top_v0[mbx * 2 + b] = 1; }
						else { tc_chr_top1[mbx * 2 + b] = 0; tc_chr_top_v1[mbx * 2 + b] = 1; }
					}
			}

			if (mb == want_mb) {
				std::printf("HOST f=%d mb=%d (%d,%d) mt=%u intra=%d i16=%d cbp=0x%02x cbp_l=%d cbp_c=%d qp=%d chroma_off=%d bit=%zu\n",
				            frame_idx, mb, mbx, mby, mt, (int)is_intra, (int)is_i16, cbp, cbp_l, cbp_c, qp, chroma_off, br.bit);
				if (cbp_c) {
					for (int p = 0; p < 2; ++p) {
						std::printf("  chrDC[%c] tc=%d:", p ? 'V' : 'U', chr_dc_tc[p]);
						for (int k = 0; k < 4; ++k) std::printf(" %d", (int)chr_dc[p][k]);
						std::printf("\n");
					}
				} else {
					std::printf("  (no chroma residual coded)\n");
				}
				if (cbp_c == 2) {
					for (int p = 0; p < 2; ++p)
						for (int bi = 0; bi < 4; ++bi) {
							std::printf("  chrAC[%c][%d] tc=%d:", p ? 'V' : 'U', bi, chr_ac_tc[p][bi]);
							for (int k = 0; k < 4; ++k) std::printf(" %d", (int)chr_ac[p][bi][k]);
							std::printf("\n");
						}
				}
				return 0;
			}
			++mb;
		}
		std::printf("HOST_FAIL end without mb=%d (mb=%d ok=%d)\n", want_mb, mb, (int)br.ok);
		return 1;
	}
	std::printf("HOST_FAIL frame %d not found\n", want_f);
	return 1;
}
