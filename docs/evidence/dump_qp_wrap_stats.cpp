// Per-clip I-slice stats: mode counts, wrapQpY events, qp histogram (host lockstep).
#include "libmisterplex/h264_nal.hpp"
#include "libmisterplex/h264_cavlc.hpp"
#include "libmisterplex/h264_slice_walk.hpp"
#include "libmisterplex/h264_recon.hpp"
#include <cstdio>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

using namespace misterplex;

static std::vector<uint8_t> rf(const std::string& p) {
	std::ifstream in(p, std::ios::binary);
	return {std::istreambuf_iterator<char>(in), {}};
}

int main(int argc, char** a) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s stream.264\n", a[0]);
		return 2;
	}
	auto buf = rf(a[1]);
	auto chain = parseAnnexBChain(buf.data(), buf.size());
	if (!chain.sps.valid || !chain.pps.valid) {
		fprintf(stderr, "no sps/pps\n");
		return 2;
	}
	size_t i = 0;
	const uint8_t* pay = nullptr;
	size_t plen = 0;
	uint8_t nt = 0;
	while (i + 3 < buf.size()) {
		size_t sc = 0;
		if (i + 4 <= buf.size() && buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 0 && buf[i + 3] == 1)
			sc = 4;
		else if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1)
			sc = 3;
		else {
			++i;
			continue;
		}
		size_t h = i + sc;
		uint8_t t = buf[h] & 0x1f;
		size_t j = h + 1;
		while (j + 3 < buf.size()) {
			if (buf[j] == 0 && buf[j + 1] == 0 &&
			    (buf[j + 2] == 1 || (buf[j + 2] == 0 && j + 3 < buf.size() && buf[j + 3] == 1)))
				break;
			++j;
		}
		if (t == 5) {
			pay = buf.data() + h + 1;
			plen = j - (h + 1);
			nt = t;
			break;
		}
		i = j;
	}
	if (!pay) {
		fprintf(stderr, "no IDR\n");
		return 3;
	}
	auto rbsp = detail::removeEpb(pay, plen);
	detail::BitReader br(rbsp.data(), rbsp.size());
	br.ue();
	br.ue();
	br.ue();
	br.u(chain.log2_max_frame_num);
	if (nt == 5) {
		br.ue();
		br.u(1);
		br.u(1);
	}
	int qp = static_cast<int>(chain.pps.pic_init_qp) + br.se();
	if (qp < 0)
		qp = 0;
	if (qp > 51)
		qp = 51;
	if (chain.pps.deblock_ctrl) {
		uint32_t d = br.ue();
		if (d != 1) {
			br.se();
			br.se();
		}
	}
	const int mbW = (chain.sps.width + 15) / 16;
	const int mbH = (chain.sps.height + 15) / 16;
	std::vector<int> tcL(static_cast<size_t>(mbW * mbH * 16), -1);
	std::vector<int> tc0(static_cast<size_t>(mbW * mbH * 4), -1), tc1(static_cast<size_t>(mbW * mbH * 4), -1);
	auto tcatL = [&](int mbx, int mby, int lx, int ly) -> int* {
		if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH)
			return nullptr;
		int& v = tcL[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)];
		return (v < 0) ? nullptr : &v;
	};
	auto tcsetL = [&](int mbx, int mby, int lx, int ly, int v) {
		tcL[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] = v;
	};
	auto tcatC = [&](int p, int mbx, int mby, int lx, int ly) -> int* {
		auto& tc = p ? tc1 : tc0;
		if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH)
			return nullptr;
		int& v = tc[static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)];
		return (v < 0) ? nullptr : &v;
	};
	auto tcsetC = [&](int p, int mbx, int mby, int lx, int ly, int v) {
		(p ? tc1 : tc0)[static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)] = v;
	};
	auto parseChr = [&](int mbx, int mby, int cbp_c) -> bool {
		if (cbp_c) {
			if (!cavlc::residualBlock(br, -1, 4).ok || !cavlc::residualBlock(br, -1, 4).ok)
				return false;
		}
		if (cbp_c == 2) {
			for (int p = 0; p < 2; ++p)
				for (int b = 0; b < 4; ++b) {
					int lx, ly;
					walk_detail::chrXY(b, lx, ly);
					int* nA = (lx > 0) ? tcatC(p, mbx, mby, lx - 1, ly) : tcatC(p, mbx - 1, mby, 1, ly);
					int* nB = (ly > 0) ? tcatC(p, mbx, mby, lx, ly - 1) : tcatC(p, mbx, mby - 1, lx, 1);
					auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 15);
					if (!r.ok)
						return false;
					tcsetC(p, mbx, mby, lx, ly, r.total_coeff);
				}
		} else {
			for (int p = 0; p < 2; ++p)
				for (int b = 0; b < 4; ++b) {
					int lx, ly;
					walk_detail::chrXY(b, lx, ly);
					tcsetC(p, mbx, mby, lx, ly, 0);
				}
		}
		return true;
	};

	int nI4 = 0, nI16 = 0, nwrap = 0, qmin = 99, qmax = -1;
	long qsum = 0;
	std::map<int, int> hist, mth;
	using misterplex::recon::detail_r::wrapQpY;
	for (int mby = 0; mby < mbH; ++mby) {
		for (int mbx = 0; mbx < mbW; ++mbx) {
			if (!br.ok) {
				printf("FAIL br mb=%d\n", mby * mbW + mbx);
				return 4;
			}
			uint32_t mt = br.ue();
			if (mt > 25) {
				printf("FAIL mt mb=%d\n", mby * mbW + mbx);
				return 5;
			}
			mth[static_cast<int>(mt)]++;
			if (mt == 25) {
				while (br.ok && (br.bit % 8) != 0)
					br.u(1);
				for (int k = 0; k < 384 && br.ok; ++k)
					br.u(8);
				for (int ly = 0; ly < 4; ++ly)
					for (int lx = 0; lx < 4; ++lx)
						tcsetL(mbx, mby, lx, ly, 16);
				continue;
			}
			if (mt == 0) {
				nI4++;
				for (int k = 0; k < 16; ++k)
					if (br.u(1) == 0)
						br.u(3);
				br.ue();
				uint32_t code = br.ue();
				int cbp = walk_detail::kMeIntra[code];
				int cbp_l = cbp & 15, cbp_c = cbp >> 4;
				if (cbp) {
					int d = br.se();
					int raw = qp + d;
					int nw = wrapQpY(qp, d);
					if (raw != nw)
						nwrap++;
					qp = nw;
				}
				for (int i8 = 0; i8 < 4; ++i8) {
					if ((cbp_l >> i8) & 1) {
						for (int i4 = 0; i4 < 4; ++i4) {
							int lx, ly;
							walk_detail::blkXY(i8, i4, lx, ly);
							int* nA = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
							int* nB = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
							auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
							if (!r.ok) {
								printf("FAIL I4\n");
								return 6;
							}
							tcsetL(mbx, mby, lx, ly, r.total_coeff);
						}
					} else {
						for (int i4 = 0; i4 < 4; ++i4) {
							int lx, ly;
							walk_detail::blkXY(i8, i4, lx, ly);
							tcsetL(mbx, mby, lx, ly, 0);
						}
					}
				}
				if (!parseChr(mbx, mby, cbp_c)) {
					printf("FAIL chr\n");
					return 7;
				}
			} else {
				nI16++;
				int x = static_cast<int>(mt) - 1;
				int cbp_c = (x / 4) % 3, cbp_l = (x / 12) ? 15 : 0;
				br.ue();
				int d = br.se();
				int raw = qp + d;
				int nw = wrapQpY(qp, d);
				if (raw != nw)
					nwrap++;
				qp = nw;
				int* nA = tcatL(mbx - 1, mby, 3, 0);
				int* nB = tcatL(mbx, mby - 1, 0, 3);
				auto r = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
				if (!r.ok) {
					printf("FAIL dc\n");
					return 8;
				}
				if (cbp_l) {
					for (int i8 = 0; i8 < 4; ++i8)
						for (int i4 = 0; i4 < 4; ++i4) {
							int lx, ly;
							walk_detail::blkXY(i8, i4, lx, ly);
							int* aa = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
							int* bb = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
							auto rr = cavlc::residualBlock(br, walk_detail::ncFrom(aa, bb), 15);
							if (!rr.ok) {
								printf("FAIL ac\n");
								return 9;
							}
							tcsetL(mbx, mby, lx, ly, rr.total_coeff);
						}
				} else {
					for (int ly = 0; ly < 4; ++ly)
						for (int lx = 0; lx < 4; ++lx)
							tcsetL(mbx, mby, lx, ly, 0);
				}
				if (!parseChr(mbx, mby, cbp_c)) {
					printf("FAIL chr2\n");
					return 10;
				}
			}
			if (qp < qmin)
				qmin = qp;
			if (qp > qmax)
				qmax = qp;
			qsum += qp;
			hist[qp]++;
		}
	}
	printf("CLIP path=%s geom=%dx%d mb=%dx%d=%d rbsp_bytes=%zu\n", a[1], chain.sps.width, chain.sps.height, mbW,
	       mbH, mbW * mbH, rbsp.size());
	printf("MODES I4=%d I16=%d\n", nI4, nI16);
	printf("WRAP_EVENTS raw!=wrapQpY %d\n", nwrap);
	printf("QP_RANGE [%d,%d] mean=%.2f final=%d\n", qmin, qmax, qsum / (double)(mbW * mbH), qp);
	printf("MT_HIST");
	for (auto& kv : mth)
		printf(" %d:%d", kv.first, kv.second);
	printf("\nQP_HIST");
	for (auto& kv : hist)
		printf(" %d:%d", kv.first, kv.second);
	printf("\nOK bit=%zu br_ok=%d\n", br.bit, (int)br.ok);
	return 0;
}
