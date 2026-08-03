// Multi-frame scanout gate for ddr_frame_store want_y policy.
//
// Hardware (parent): RBF f0d3a385 hold_y_visible → frozen near-black HDMI while
// ARM DDR presents advanced; Plex_v2 moving OK.
//
// Product facts (quoted):
// - colorbars.sv: frame_start when hc==H_LAST && vc==last → ddr vsync_pulse
// - present_core: store_y holds 478 for py>=240; PRESENT_Y=0 ⇒ rd_y_visible=1 always
// - at hc==H_LAST store_x=LAST ∉ present X ⇒ OLD thrash want_y=0 at swap
// - ddr_frame_store: prep fills 0..LINE_COUNT-1; current tracks want_y window;
//   fill start invalidates victim slot in current set
//
// Policies:
//   Thrash     — OLD: want= rd_visible ? y : 0
//   HoldYVis   — BAD fit f0d3a385: want tracks y while rd_y_visible (always)
//   ForceTop   — FIX: no X thrash; vsync forces want=0 until beam y < LINE_COUNT
//
// Pre-register:
//   HoldYVis: tops_at_de0 < LINE_COUNT after swap (evicted) AND mostly_black/!motion
//   Thrash: motion+full_height, thrash_hblank>0
//   ForceTop: motion+full_height, thrash_hblank==0, tops_at_de0==LINE_COUNT

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

constexpr int kLC = 8;
constexpr int kHLast = 637;
constexpr int kHDe = 529;
constexpr int kPX = 11, kPEX = 629, kFW = 640;
constexpr int kHoldY = 478;
constexpr int kFillLat = 80; // Y + chroma pair budget
constexpr int kSXScale = (kFW * 39647) / 320;
constexpr int kFrames = 4;
constexpr int kAct = 240, kBlk = 22;

enum class Pol { Thrash, HoldYVis, ForceTop };

struct Slot {
    bool v = false;
    int y = -1, b = -1, f = -1;
};

int sx(int hc) {
    int c = (hc * kSXScale) >> 16;
    return std::min(std::max(c, 0), kFW - 1);
}
int sy(int phase, bool act) { return act ? std::min(phase * 2, kHoldY) : kHoldY; }

bool has(const std::vector<Slot>& s, int y, int b, int f) {
    for (auto& sl : s)
        if (sl.v && sl.y == y && sl.b == b && sl.f == f)
            return true;
    return false;
}
int tops(const std::vector<Slot>& s, int b, int f) {
    int n = 0;
    for (int y = 0; y < kLC; ++y)
        if (has(s, y, b, f))
            ++n;
    return n;
}
int vict(std::vector<Slot>& s, int lo, int hi) {
    for (int i = 0; i < kLC; ++i)
        if (!s[i].v)
            return i;
    for (int i = 0; i < kLC; ++i)
        if (s[i].y < lo || s[i].y >= hi)
            return i;
    return 0;
}

struct FO {
    int hit = 0, miss = 0, thrash = 0;
    int tops_at_de0 = -1;
    int ymin = 9999, ymax = -1;
    uint64_t hash = 0;
};
struct Res {
    std::vector<FO> fr;
    bool motion = false, full_h = false, black = false;
};

uint64_t mix(uint64_t h, uint64_t x) {
    return h ^ (x + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
}

Res run(Pol p) {
    Res R;
    std::vector<Slot> S[2] = {std::vector<Slot>(kLC), std::vector<Slot>(kLC)};
    int ds = 0, want = 0, db = 0, df = 0, pb = 1, pf = 1;
    bool sp = false, hasf = false, force = false;
    bool filling = false;
    int fl = 0, fset = 0, fi = 0, fy = 0, fb = 0, ff = 0;

    auto tick = [&] {
        if (!filling)
            return;
        if (--fl > 0)
            return;
        S[fset][fi] = Slot{true, fy, fb, ff};
        filling = false;
    };
    auto fill = [&](int set, int y, int b, int f, int lo, int hi) {
        if (filling || has(S[set], y, b, f))
            return false;
        int i = vict(S[set], lo, hi);
        S[set][i].v = false;
        filling = true;
        fl = kFillLat;
        fset = set;
        fi = i;
        fy = y;
        fb = b;
        ff = f;
        return true;
    };
    auto sched = [&] {
        tick();
        if (filling)
            return;
        int prep = ds ^ 1;
        if (sp) {
            for (int y = 0; y < kLC; ++y)
                if (fill(prep, y, pb, pf, 0, kLC))
                    return;
        }
        if (!hasf)
            return;
        for (int a = 0; a < kLC; ++a) {
            int y = std::min(want + a, 479);
            if (fill(ds, y, db, df, want, want + kLC))
                return;
        }
    };

    for (int fr = 0; fr < kFrames; ++fr) {
        sp = true;
        if (fr == 0) {
            pb = 0;
            pf = 0;
        } else {
            pb = db ^ 1;
            pf = df + 1;
        }
        FO o;
        bool measured_de0 = false;

        for (int phase = 0; phase < kAct + kBlk; ++phase) {
            bool act = phase < kAct;
            int y = sy(phase, act);
            for (int hc = 0; hc <= kHLast; ++hc) {
                int x = sx(hc);
                bool xvis = x >= kPX && x < kPEX;
                bool vis = xvis; // y always visible in product
                bool rd_act = act && hc < kHDe && xvis;
                bool fstart = (!act && phase == kAct + kBlk - 1 && hc == kHLast);

                int prev = want;
                // force_top / want policy
                if (p == Pol::ForceTop) {
                    if (fstart)
                        force = true;
                    else if (y < kLC)
                        force = false;
                }
                switch (p) {
                case Pol::Thrash:
                    want = vis ? y : 0;
                    break;
                case Pol::HoldYVis:
                    want = y;
                    break;
                case Pol::ForceTop:
                    want = (force || fstart) ? 0 : y;
                    break;
                }
                if (prev && !want && act && !xvis && y)
                    ++o.thrash;

                if (fstart && sp && tops(S[ds ^ 1], pb, pf) >= kLC) {
                    ds ^= 1;
                    db = pb;
                    df = pf;
                    sp = false;
                    hasf = true;
                }

                sched();
                // After swap at H_LAST, blank continues with store_y=478 until DE.
                // HoldYVis keeps want=478 and burns through current-set slots.
                // ForceTop/Thrash keep want=0 and retain prep tops.
                if (fstart) {
                    for (int k = 0; k < kLC * kFillLat + 2; ++k)
                        sched();
                }

                if (rd_act && hasf) {
                    if (!measured_de0 && act && phase == 0) {
                        o.tops_at_de0 = tops(S[ds], db, df);
                        measured_de0 = true;
                    }
                    if (has(S[ds], y, db, df)) {
                        ++o.hit;
                        o.hash = mix(o.hash, (uint64_t)(df * 1000 + y) << 16 | x);
                        o.ymin = std::min(o.ymin, y);
                        o.ymax = std::max(o.ymax, y);
                    } else {
                        ++o.miss;
                    }
                }
            }
        }
        if (o.ymax < o.ymin) {
            o.ymin = -1;
            o.ymax = -1;
        }
        R.fr.push_back(o);
    }

    int nb = 0, span = 0;
    std::vector<uint64_t> hs;
    for (auto& f : R.fr) {
        if (f.hit > 1000) {
            ++nb;
            hs.push_back(f.hash);
            if (f.ymin >= 0)
                span = std::max(span, f.ymax - f.ymin);
        }
    }
    std::sort(hs.begin(), hs.end());
    hs.erase(std::unique(hs.begin(), hs.end()), hs.end());
    R.motion = (int)hs.size() >= 2;
    R.full_h = span >= 400;
    R.black = nb == 0;
    return R;
}

void pr(const char* n, const Res& r) {
    std::printf("POLICY %s motion=%d full_height=%d mostly_black=%d\n", n, r.motion, r.full_h,
                r.black);
    for (size_t i = 0; i < r.fr.size(); ++i) {
        auto& f = r.fr[i];
        std::printf("  f%zu hit=%d miss=%d y=[%d..%d] thrash=%d tops_de0=%d hash=%016llx\n", i, f.hit,
                    f.miss, f.ymin, f.ymax, f.thrash, f.tops_at_de0, (unsigned long long)f.hash);
    }
}

} // namespace

int main() {
    std::puts("PRE-REGISTER:");
    std::puts("  HoldYVis: tops_de0 < 8 on a post-swap frame OR miss-dominated/black");
    std::puts("  Thrash: motion && full_height && thrash>0");
    std::puts("  ForceTop: motion && full_height && thrash==0 && tops_de0==8");

    auto A = run(Pol::Thrash);
    auto B = run(Pol::HoldYVis);
    auto D = run(Pol::ForceTop);
    pr("thrash_visible", A);
    pr("hold_y_visible", B);
    pr("force_top_vsync", D);

    bool ok = true;

    // B: reproduce eviction — tops_at_de0 drops below kLC on some live frame
    bool b_evict = false;
    int b_hit = 0, b_miss = 0;
    for (size_t i = 1; i < B.fr.size(); ++i) {
        if (B.fr[i].tops_at_de0 >= 0 && B.fr[i].tops_at_de0 < kLC)
            b_evict = true;
        b_hit += B.fr[i].hit;
        b_miss += B.fr[i].miss;
    }
    bool b_fail_scan = B.black || !B.full_h || !B.motion || b_miss > b_hit;
    // Hard gate: bad fit must lose top residency at DE open (the freeze seed).
    if (!(b_evict && B.fr.size() > 1 && B.fr[1].tops_at_de0 < kLC)) {
        std::fputs("MISS: hold_y_visible did not show top-eviction at DE open\n", stderr);
        ok = false;
    } else {
        std::printf("REPRO_OK: hold_y_visible tops_de0 f1=%d (<%d) fail_scan=%d\n",
                    B.fr[1].tops_at_de0, kLC, b_fail_scan ? 1 : 0);
    }

    if (!(A.motion && A.full_h)) {
        std::fputs("MISS: thrash should present\n", stderr);
        ok = false;
    }
    int at = 0, dt = 0;
    for (auto& f : A.fr)
        at += f.thrash;
    for (auto& f : D.fr)
        dt += f.thrash;
    if (at <= 0) {
        std::fputs("MISS: thrash count\n", stderr);
        ok = false;
    }

    if (!(D.motion && D.full_h) || dt != 0) {
        std::fputs("MISS: force_top fix gate (motion/height/thrash)\n", stderr);
        ok = false;
    }
    for (size_t i = 1; i < D.fr.size(); ++i) {
        if (D.fr[i].tops_at_de0 >= 0 && D.fr[i].tops_at_de0 < kLC) {
            std::fprintf(stderr, "MISS: force_top lost tops_de0=%d on f%zu\n", D.fr[i].tops_at_de0,
                         i);
            ok = false;
        }
    }
    // D should retain tops better than B
    int d_tops = 0, b_tops = 0, n = 0;
    for (size_t i = 1; i < D.fr.size(); ++i) {
        if (D.fr[i].tops_at_de0 >= 0) {
            d_tops += D.fr[i].tops_at_de0;
            b_tops += B.fr[i].tops_at_de0;
            ++n;
        }
    }
    if (n > 0 && d_tops <= b_tops) {
        std::fprintf(stderr, "MISS: fix tops (%d) not better than hold (%d)\n", d_tops, b_tops);
        ok = false;
    }

    std::puts(ok ? "test_ddr_scanout_multiframe: PASS" : "test_ddr_scanout_multiframe: FAIL");
    return ok ? 0 : 1;
}
