// Characterises the ddr_frame_store left-edge defect:
// want_y was derived from src_y, and src_y was gated on full rd_visible (X∩Y).
// During every left HBlank, store_x < PRESENT_X ⇒ rd_visible=0 ⇒ src_y forced to 0
// ⇒ want_y thrashed back to line 0 while the beam was still on line N. The DDR
// prefetcher then abandoned the current-line fill and restarted from line 0,
// so when DE re-opened the current line was not yet in an M10K slot. Pixels
// output black until the mid-line fill completed (asymmetric_left_wander).
//
// frame_store.sv already tracked want_y from free-running rd_y; DDR path must
// track vertical beam via rd_y_visible only.
//
// Pre-register:
//   broken model: thrash_to_zero_events > 0 and left_miss_px spread >= 20
//   fixed model:  thrash_to_zero_events == 0 and left_miss_px == 0

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int kFrameW = 640;
constexpr int kFrameH = 480;
constexpr int kPresentX = 11;
constexpr int kPresentW = 618;
constexpr int kPresentEndX = kPresentX + kPresentW; // 629
constexpr int kLineCount = 8;
// Synthetic: one line fill costs this many active-line pixel clocks of DDR work
// when the prefetcher is not already holding the line.
constexpr int kFillLatencyPx = 40;

struct Sample {
    int rd_x;
    int rd_y;
    bool rd_active;
};

// One scanline: left blank (x below PRESENT_X), then active DE across present
// window, then right overhang. Mirrors free-running store_x/store_y.
std::vector<Sample> build_line(int y) {
    std::vector<Sample> s;
    // Left blank: x runs 0..PRESENT_X-1 with rd_active=0 (HBlank / pillar)
    for (int x = 0; x < kPresentX; ++x)
        s.push_back({x, y, false});
    // Active DE across present window
    for (int x = kPresentX; x < kPresentEndX; ++x)
        s.push_back({x, y, true});
    // Right blank overhang (clamped store_x would hold LAST, model as end-1)
    for (int x = kPresentEndX; x < kFrameW; ++x)
        s.push_back({x, y, false});
    return s;
}

struct ModelResult {
    int thrash_to_zero = 0;
    int left_first_hit_spread = 0; // max-min of first non-miss x per row
    int rows_with_left_miss = 0;
    int max_left_miss_run = 0;
};

bool rd_x_visible(int rd_x) {
    return rd_x >= kPresentX && rd_x < kPresentEndX;
}
bool rd_y_visible(int rd_y) {
    return rd_y >= 0 && rd_y < kFrameH;
}
bool rd_visible(int rd_x, int rd_y) {
    return rd_x_visible(rd_x) && rd_y_visible(rd_y);
}

// broken=true: want_y follows src_y gated on full rd_visible (tree before fix)
// broken=false: want_y follows src_y_prefetch gated on rd_y_visible only
ModelResult simulate(bool broken, int lines_to_scan) {
    ModelResult r;
    int want_y = 0;
    // Lines currently resident in the dual-set line buffer (simplified single set).
    std::vector<bool> line_ready(kFrameH, false);
    // Warm the first LINE_COUNT lines as if post-swap prep completed.
    for (int i = 0; i < kLineCount && i < kFrameH; ++i)
        line_ready[static_cast<size_t>(i)] = true;

    int ddr_busy_until_cycle = -1;
    int ddr_filling_y = -1;
    int global_cycle = 0;
    std::vector<int> first_hit_x;

    for (int y = 0; y < lines_to_scan; ++y) {
        const auto samples = build_line(y);
        int first_hit = -1;
        int left_miss_run = 0;
        bool seen_hit = false;

        for (const auto& s : samples) {
            const bool vis = rd_visible(s.rd_x, s.rd_y);
            const bool y_vis = rd_y_visible(s.rd_y);
            const int display_y = s.rd_y; // PRESENT_Y=0
            const int src_y = vis ? display_y : 0;
            const int src_y_prefetch = y_vis ? display_y : 0;

            // --- want_y update (the defect site) ---
            const int prev_want = want_y;
            if (broken) {
                if (src_y != want_y)
                    want_y = src_y; // mirrors: if (src_y != want_y_sys) want_y_sys<=src_y
            } else {
                if (y_vis && src_y_prefetch != want_y)
                    want_y = src_y_prefetch;
            }
            if (prev_want != 0 && want_y == 0 && y == display_y && display_y != 0)
                ++r.thrash_to_zero;

            // --- naive prefetcher: keep [want_y, want_y+LINE_COUNT) warm ---
            // Complete in-flight fill
            if (ddr_filling_y >= 0 && global_cycle >= ddr_busy_until_cycle) {
                line_ready[static_cast<size_t>(ddr_filling_y)] = true;
                ddr_filling_y = -1;
            }
            if (ddr_filling_y < 0) {
                for (int ahead = 0; ahead < kLineCount; ++ahead) {
                    const int t = std::min(want_y + ahead, kFrameH - 1);
                    if (!line_ready[static_cast<size_t>(t)]) {
                        // Evict farthest line outside the window to free a slot
                        // (capacity model: only LINE_COUNT lines may be ready).
                        int ready_count = 0;
                        for (int i = 0; i < kFrameH; ++i)
                            if (line_ready[static_cast<size_t>(i)])
                                ++ready_count;
                        if (ready_count >= kLineCount) {
                            for (int i = 0; i < kFrameH; ++i) {
                                if (!line_ready[static_cast<size_t>(i)])
                                    continue;
                                if (i < want_y || i >= want_y + kLineCount) {
                                    line_ready[static_cast<size_t>(i)] = false;
                                    break;
                                }
                            }
                        }
                        ddr_filling_y = t;
                        ddr_busy_until_cycle = global_cycle + kFillLatencyPx;
                        break;
                    }
                }
            }

            // --- scanout miss (rd_miss_now model) ---
            if (s.rd_active && vis) {
                const bool hit = line_ready[static_cast<size_t>(display_y)];
                if (!hit) {
                    if (!seen_hit)
                        ++left_miss_run;
                } else if (first_hit < 0) {
                    first_hit = s.rd_x;
                    seen_hit = true;
                }
            }
            ++global_cycle;
        }

        if (first_hit < 0)
            first_hit = kPresentEndX; // entire line missed
        first_hit_x.push_back(first_hit);
        if (left_miss_run > 0)
            ++r.rows_with_left_miss;
        r.max_left_miss_run = std::max(r.max_left_miss_run, left_miss_run);
    }

    if (!first_hit_x.empty()) {
        const int mn = *std::min_element(first_hit_x.begin(), first_hit_x.end());
        const int mx = *std::max_element(first_hit_x.begin(), first_hit_x.end());
        r.left_first_hit_spread = mx - mn;
    }
    return r;
}

} // namespace

int main() {
    // Pre-register predictions before measuring.
    std::puts("PRE-REGISTER:");
    std::puts("  broken: thrash_to_zero > 0 AND (max_left_miss_run >= 20 OR left_first_hit_spread >= 20)");
    std::puts("  fixed:  thrash_to_zero == 0 AND max_left_miss_run == 0 AND left_first_hit_spread == 0");

    constexpr int kScan = 64; // enough rows past the initial warm window
    const ModelResult broken = simulate(true, kScan);
    const ModelResult fixed = simulate(false, kScan);

    std::printf("BROKEN thrash_to_zero=%d rows_with_left_miss=%d max_left_miss_run=%d left_first_hit_spread=%d\n",
                broken.thrash_to_zero, broken.rows_with_left_miss, broken.max_left_miss_run,
                broken.left_first_hit_spread);
    std::printf("FIXED  thrash_to_zero=%d rows_with_left_miss=%d max_left_miss_run=%d left_first_hit_spread=%d\n",
                fixed.thrash_to_zero, fixed.rows_with_left_miss, fixed.max_left_miss_run,
                fixed.left_first_hit_spread);

    bool ok = true;
    if (!(broken.thrash_to_zero > 0)) {
        std::fputs("MISS: broken model did not thrash want_y to 0\n", stderr);
        ok = false;
    }
    if (!(broken.max_left_miss_run >= 20 || broken.left_first_hit_spread >= 20)) {
        std::fputs("MISS: broken model did not produce left-edge miss signature\n", stderr);
        ok = false;
    }
    if (fixed.thrash_to_zero != 0) {
        std::fputs("MISS: fixed model still thrashes want_y\n", stderr);
        ok = false;
    }
    if (fixed.max_left_miss_run != 0 || fixed.left_first_hit_spread != 0) {
        std::fputs("MISS: fixed model still has left-edge miss\n", stderr);
        ok = false;
    }

    // Static source guard: product RTL must feed want_y / line-hit from src_y_line
    // (rd_y_visible), never X-gated src_y. DE_LAG is not this gate.
    {
        const char* path = "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv";
        FILE* f = std::fopen(path, "r");
        if (!f) {
            // Allow running from build/ via ROOT-relative fallbacks.
            f = std::fopen("../fpga/Plex_MiSTer/rtl/ddr_frame_store.sv", "r");
        }
        if (!f) {
            std::fputs("MISS: cannot open ddr_frame_store.sv for want_y source guard\n", stderr);
            ok = false;
        } else {
            std::string text;
            char buf[4096];
            while (std::size_t n = std::fread(buf, 1, sizeof buf, f))
                text.append(buf, n);
            std::fclose(f);
            auto strip = [](std::string s) {
                // Drop // line comments then whitespace for needle match.
                std::string o;
                o.reserve(s.size());
                for (size_t i = 0; i < s.size();) {
                    if (i + 1 < s.size() && s[i] == '/' && s[i + 1] == '/') {
                        while (i < s.size() && s[i] != '\n')
                            ++i;
                        continue;
                    }
                    if (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
                        ++i;
                        continue;
                    }
                    o.push_back(s[i++]);
                }
                return o;
            };
            const std::string nt = strip(text);
            // Product path: src_y_line (rd_y_visible) → pref_y (WANT_Y_LINE_ONLY=1)
            // → want_y_sys / y_hit. Control builds may bind pref_y to X-gated src_y.
            // Accept bare (display_y+CROP) or cast form CODED_Y_W'(display_y)+CODED_Y_W'(CROP)
            // used when CODED_* may exceed FRAME_* after crop widen for 720p.
            const bool has_line =
                nt.find("src_y_line=rd_y_visible?(display_y+CROP_TOP_L):'0") != std::string::npos ||
                nt.find("src_y_line=rd_y_visible?(CODED_Y_W'(display_y)+CODED_Y_W'(CROP_TOP_L)):'0") !=
                    std::string::npos;
            const bool has_pref =
                nt.find("pref_y=WANT_Y_LINE_ONLY?src_y_line:src_y") != std::string::npos;
            const bool default_line_only =
                nt.find("WANT_Y_LINE_ONLY=1'b1") != std::string::npos;
            const bool want_ok =
                nt.find("want_y_sys<=Y_W'(pref_y)") != std::string::npos ||
                nt.find("want_y_sys<=Y_W'(src_y_line)") != std::string::npos;
            const bool hit_ok =
                nt.find("y_line_v2[video_slot]==Y_W'(pref_y)") != std::string::npos ||
                nt.find("y_line_v2[video_slot]==Y_W'(src_y_line)") != std::string::npos;
            // Red-check: sole product want_y from bare X-gated src_y (no line/pref).
            const bool legacy_thrash =
                nt.find("want_y_sys<=Y_W'(src_y)") != std::string::npos &&
                nt.find("want_y_sys<=Y_W'(src_y_line)") == std::string::npos &&
                nt.find("want_y_sys<=Y_W'(pref_y)") == std::string::npos;
            if (!has_line || !has_pref || !default_line_only || !want_ok || !hit_ok ||
                legacy_thrash) {
                std::fputs(
                    "MISS: ddr_frame_store.sv want_y must track pref_y=src_y_line "
                    "(WANT_Y_LINE_ONLY=1 default), not X-gated src_y alone\n",
                    stderr);
                ok = false;
            } else {
                std::puts("PASS RTL source: want_y/hit follow pref_y/src_y_line "
                          "(no HBlank thrash; LINE_ONLY default)");
            }
        }
    }

    std::puts(ok ? "test_ddr_want_y_hblank_thrash: PASS" : "test_ddr_want_y_hblank_thrash: FAIL");
    return ok ? 0 : 1;
}
