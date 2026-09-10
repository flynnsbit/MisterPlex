#include "Vfpga_video_publish_tb.h"
#include "verilated.h"
#include "ddr_bitstream_ring.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace ring = misterplex::ddr_bitstream_ring;
static void check(bool ok, const char* reason) {
    if (!ok) throw std::runtime_error(reason);
}
constexpr uint32_t feedback = mailbox_abi::kVideoPresentationAddr / 8;
constexpr uint32_t commit = mailbox_abi::kVideoPresentationCommitAddr / 8;
constexpr uint64_t nonce1 = UINT64_C(0x8877665544332211);
constexpr uint64_t epoch1 = UINT64_C(0xfedcba9876543210);
#ifndef FULL_AU
#define FULL_AU 0
#endif
#ifndef FULL_AU_ORIGINAL_TIMING
#define FULL_AU_ORIGINAL_TIMING 0
#endif
#ifndef FULL_AU_RUNTIME_GEOMETRY
#define FULL_AU_RUNTIME_GEOMETRY 0
#endif
#ifndef FULL_AU_NATIVE_BEAM
#define FULL_AU_NATIVE_BEAM 0
#endif
#ifndef FULL_AU_SCANDOUBLE
#define FULL_AU_SCANDOUBLE 1
#endif
#ifndef FULL_AU_JOINT_FILTER
#define FULL_AU_JOINT_FILTER 0
#endif
#ifndef FULL_AU_FRAMES
#define FULL_AU_FRAMES 2
#endif
static_assert(FULL_AU_FRAMES >= 2 && FULL_AU_FRAMES <= 12);
#ifndef SIM_SYS_MHZ
#define SIM_SYS_MHZ 20
#endif
static_assert(SIM_SYS_MHZ == 20 || SIM_SYS_MHZ == 85 || SIM_SYS_MHZ == 120);
constexpr uint64_t kBaseHz = SIM_SYS_MHZ == 85 ? 3060000000ULL : 720000000ULL;
constexpr uint64_t kSysHz = uint64_t(SIM_SYS_MHZ) * 1000000;
constexpr uint64_t kSysPeriod = kBaseHz / kSysHz;
constexpr uint64_t kDdrPeriod = kBaseHz / 90000000;
constexpr uint64_t kNativeDivisor = SIM_SYS_MHZ == 85 ? 17 : SIM_SYS_MHZ / 20;
constexpr uint64_t kNativeDen = SIM_SYS_MHZ == 85 ? 4 : 1;
static_assert(kBaseHz % (2*kSysHz) == 0 && kDdrPeriod % 2 == 0);
constexpr uint64_t kNativePixelTicks = kBaseHz / 20000000;
constexpr uint64_t kNativeFrameTicks = 334312 * kNativePixelTicks;
constexpr uint64_t kEventBudget = kBaseHz; // Same one-second model budget as v5.

struct Sim {
    struct FrameMetrics {
        uint64_t vcl = 0, promoted = 0, copy = 0, copy_done = 0, filter_start = 0, filter_done = 0;
        uint64_t controller_busy = 0, filter_busy = 0, publisher_busy = 0;
        uint64_t prediction_fetches = 0, fractional_fetches = 0, nonzero_P_blocks = 0, filter_writes = 0;
        std::array<uint64_t, 8> stalls{};
    };
    std::array<FrameMetrics, FULL_AU_FRAMES> metrics;
    const std::vector<uint8_t>* legacy_oracle = nullptr;
    unsigned legacy_width = 0, legacy_height = 0;
    std::array<uint64_t, FULL_AU_FRAMES> legacy_pixels{};
    std::array<std::vector<uint16_t>, FULL_AU_FRAMES> legacy_rgb_payload;
    unsigned metric_frame = 0;
    bool metrics_active = false;
    bool previous_metric_au = false;
    uint64_t previous_native_ce_tick = 0, previous_native_frame_tick = 0;
    uint64_t native_ce_count = 0, native_ce_group_tick = 0;
    bool previous_overlay_valid = false;
    uint32_t previous_overlay_rgb = 0;
    bool previous_overlay_de = false, previous_overlay_hs = false, previous_overlay_vs = false;
    Vfpga_video_publish_tb d;
    std::unordered_map<uint32_t, uint64_t> memory;
    struct Response { uint64_t due, data; uint32_t address; };
    std::deque<Response> responses;
    struct RamResponse { uint64_t due, accepted; uint32_t address; uint8_t data; bool painter; };
    std::deque<RamResponse> ram_responses;
    bool ram_stress = false, hold_ram = false, ddr_stress = true;
    uint64_t ram_accepted = 0, ram_returned = 0, painter_accepted = 0, painter_returned = 0;
    uint64_t ram_last_accept = 0, ram_min_gap = UINT64_MAX;
    uint32_t ram_random = 0x5754c111;
    uint32_t ddr_random = 0x5754d00d;
    bool corrupt_copy_fence = false;
    std::vector<std::pair<uint32_t,uint64_t>> status_writes;
    std::vector<uint8_t> captured_sps, captured_pps;
    uint64_t time = 0, ddr_cycles = 0;
    uint64_t vsync_period = 128;
    uint64_t displayed_cycle = 0;
    uint16_t previous_frames_done = 0;
    unsigned image = 0;
    unsigned verified_frames = 0;
    std::vector<uint32_t> native_pixels[FULL_AU_FRAMES];
    std::vector<unsigned> native_lines[FULL_AU_FRAMES];
    unsigned native_line_length = 0;
    bool native_complete[FULL_AU_FRAMES]{};
    uint64_t native_requests[2]{}, native_responses[2]{};
    uint64_t native_lifetime_requests[2]{}, native_lifetime_responses[2]{};
    uint64_t ddr_read_beats_accepted = 0, ddr_read_beats_returned = 0, ddr_writes_accepted = 0;
    bool force_busy = false, vsync_enabled = false, force_vsync = false;
    bool hold_responses = false;
    bool pps_mismatch = false, bad_tail = false, negative_guard = false;
    bool vcl_overflow = false;
    bool ingress_seek = false, large_au = false;
    bool fault_recovery = false, filter_metadata_fault = false, fault_reset_in_progress = false;
    bool active_filter_fault = false;
    bool watch_write = false;
    uint32_t watched_address = 0;
    uint64_t watched_data = 0;
    unsigned watched_writes = 0;
    uint64_t load(uint32_t address) { return memory[address]; }
    uint8_t native(uint32_t address) const {
        const unsigned bank = address / 115200;
        address %= 115200;
        if (image == 4) {
            const unsigned plane = address < 76800 ? 0 : address < 96000 ? 1 : 2;
            const unsigned offset = address - (plane == 0 ? 0 : plane == 1 ? 76800 : 96000);
            const unsigned stride = plane ? 160 : 320;
            return uint8_t((offset % stride) * 73 + (offset / stride) * 37 + plane * 91 + bank * 53);
        }
        if (image >= 2) return address < 76800 ? (image == 2 ? 16 : 235) : 128;
        if (address < 76800) return uint8_t((address + image * 29) % 220 + 16);
        if (address < 96000) return uint8_t(96 + image);
        return uint8_t(160 - image);
    }
    static uint32_t rgb601(uint8_t y, uint8_t u, uint8_t v) {
        const int c = int(y) - 16, d = int(u) - 128, e = int(v) - 128;
        auto channel = [](int value) { return uint32_t(std::clamp(value >> 8, 0, 255)); };
        return channel(298 * c + 409 * e + 128) << 16 |
               channel(298 * c - 100 * d - 208 * e + 128) << 8 |
               channel(298 * c + 516 * d + 128);
    }
    static uint16_t reference565(uint8_t y, uint8_t u, uint8_t v, bool full, unsigned matrix) {
        const int yy = int(y) - (full ? 0 : 16), uu = int(u) - 128, vv = int(v) - 128;
        const int scale = full ? 256 : 298;
        const int rv = matrix == 1 ? (full ? 403 : 459) : (full ? 359 : 409);
        const int gu = matrix == 1 ? (full ? 48 : 55) : (full ? 88 : 100);
        const int gv = matrix == 1 ? (full ? 120 : 136) : (full ? 183 : 208);
        const int bu = matrix == 1 ? (full ? 475 : 541) : (full ? 454 : 516);
        const int r = std::clamp((scale * yy + rv * vv + 128) >> 8, 0, 255);
        const int g = std::clamp((scale * yy - gu * uu - gv * vv + 128) >> 8, 0, 255);
        const int b = std::clamp((scale * yy + bu * uu + 128) >> 8, 0, 255);
        return uint16_t((r >> 3) << 11 | (g >> 2) << 5 | (b >> 3));
    }
    void check_pixel(unsigned x, unsigned y, uint8_t luma, uint8_t u, uint8_t v) {
        d.sample_x = x;
        d.sample_y = y;
        const uint32_t expected = rgb601(luma, u, v);
        until([&] { return d.pixel_rgb == expected; }, "actual frame-store RGB conversion mismatch");
        run(kSysPeriod * 16);
        check(d.pixel_rgb == expected, "frame-store RGB did not remain stable");
    }
    void check_return_stream() {
        unsigned returned = 0;
        for (unsigned y : {0u, 1u, 6u, 239u}) {
            const unsigned chroma = (y / 2) * 160;
            check_pixel(0, y, native(y * 320), native(76800 + chroma), native(96000 + chroma));
            while (time % kSysPeriod) tick();
            std::deque<std::pair<uint32_t, bool>> expected;
            for (unsigned n = 0; n < 1026; ++n) {
                const unsigned x = n < 512 ? n : n < 1024 ? 1023 - n : 0;
                const bool de = x < 320;
                const uint32_t rgb = de ? rgb601(native(y * 320 + x),
                    native(76800 + chroma + x / 2), native(96000 + chroma + x / 2)) : 0;
                expected.emplace_back(rgb, de);
                d.sample_x = x;
                run(kSysPeriod);
                if (expected.size() == 3) {
                    const auto want = expected.front();
                    expected.pop_front();
                    if (d.pixel_rgb != want.first || bool(d.pixel_de) != want.second)
                        throw std::runtime_error(
                            "three-cycle line-buffer return lost RGB/DE/byte/row alignment at row=" +
                            std::to_string(y) + " beat=" + std::to_string(n - 2));
                    ++returned;
                }
            }
        }
        std::cout << "RETURN_STREAM returns=" << returned
                  << " latency=3 dense_SYS_requests=1 signed_BT601/byte/chroma/row/blanking verified\n";
    }
    void tick() {
        ++time;
        const bool sys_rise = time % kSysPeriod == 0;
        const bool ddr_rise = time % kDdrPeriod == 0;
        bool delivered = false;
        bool ram_due = false, painter_request = false;
        if (sys_rise && !FULL_AU) {
            const uint64_t cycle = time / kSysPeriod;
            ram_due = !hold_ram && !ram_responses.empty() && ram_responses.front().due <= cycle;
            ram_random ^= ram_random << 13; ram_random ^= ram_random >> 17; ram_random ^= ram_random << 5;
            painter_request = ram_stress && !d.reset && (ram_responses.empty() || ram_due) &&
                              (ram_random & 7) == 0;
            d.mem_ready = (ram_responses.empty() || ram_due) && !painter_request;
            d.mem_valid = ram_due && !ram_responses.front().painter;
            d.mem_data = ram_due ? ram_responses.front().data : 0xa5;
        }
        if (ddr_rise) {
            ++ddr_cycles;
            ddr_random ^= ddr_random << 13; ddr_random ^= ddr_random >> 17; ddr_random ^= ddr_random << 5;
            d.DDRAM_BUSY = force_busy || (ddr_stress &&
                (ram_stress ? (ddr_random & 7) < 2 : ddr_cycles % 29 < 7));
            delivered = !hold_responses && !responses.empty() &&
                        responses.front().due <= ddr_cycles;
            d.DDRAM_DOUT_READY = delivered;
            d.DDRAM_DOUT = delivered ? responses.front().data : 0;
        }
        if (sys_rise) d.vsync = force_vsync ||
                              (vsync_enabled && (time / kSysPeriod) % vsync_period == 0);
        d.eval();
        if (FULL_AU && sys_rise) {
            if (!d.reset)
                for (unsigned client = 0; client < 2; ++client) {
                    native_lifetime_requests[client] += (d.native_transactions >> (client * 2)) & 1;
                    native_lifetime_responses[client] += (d.native_transactions >> (client * 2 + 1)) & 1;
                    check(native_lifetime_responses[client] <= native_lifetime_requests[client],
                          "native response has no lifetime accepted owner");
                }
            if (d.native_transactions & 16) {
                for (unsigned client = 0; client < 2; ++client)
                    native_requests[client] = native_responses[client] = 0;
            } else {
                check((d.native_transactions & 10) != 10, "native response delivered to both clients");
                for (unsigned client = 0; client < 2; ++client) {
                    native_requests[client] += (d.native_transactions >> (client * 2)) & 1;
                    native_responses[client] += (d.native_transactions >> (client * 2 + 1)) & 1;
                    check(native_responses[client] <= native_requests[client] &&
                          native_requests[client] - native_responses[client] <= 1,
                          "native read acceptance/response ownership mismatch");
                }
            }
            if (d.header_capture & (1u << 21)) captured_sps.clear();
            else if (d.header_capture & (1u << 20))
                captured_sps.push_back(uint8_t(d.header_capture >> 8));
            if (d.header_capture & (1u << 18)) captured_pps.clear();
            else if (d.header_capture & (1u << 17))
                captured_pps.push_back(uint8_t(d.header_capture));
        }
        if (FULL_AU && sys_rise && d.observed_vcl)
            check(d.next_vcl_ready, "new VCL arrived before decoder/publication ownership release");
        if (FULL_AU && sys_rise && !d.reset && d.legacy_rgb_accept) {
            check(!negative_guard && legacy_oracle && d.observed_au_seq < FULL_AU_FRAMES &&
                  d.legacy_x < legacy_width && d.legacy_y < legacy_height,
                  "legacy RGB drain lacks an owned, valid coded picture");
            const size_t ysize = legacy_width * legacy_height;
            const size_t base = size_t(d.observed_au_seq) * ysize * 3 / 2;
            const size_t yi = size_t(d.legacy_y) * legacy_width + d.legacy_x;
            const size_t ci = size_t(d.legacy_y / 2) * (legacy_width / 2) + d.legacy_x / 2;
            const auto& ref = *legacy_oracle;
            const auto expected = reference565(ref[base + yi], ref[base + ysize + ci],
                ref[base + ysize * 5 / 4 + ci], d.legacy_full_range, d.legacy_matrix);
            if (d.legacy_rgb565 != expected)
                std::cerr << "legacy RGB seq=" << d.observed_au_seq << " x=" << d.legacy_x
                          << " y=" << d.legacy_y << " got=" << d.legacy_rgb565
                          << " expected=" << expected << '\n';
            check(d.legacy_rgb565 == expected, "legacy RGB565 drain differs from ordinary decoded pixels");
            ++legacy_pixels[d.observed_au_seq];
            legacy_rgb_payload[d.observed_au_seq].push_back(d.legacy_rgb565);
        }
        if (FULL_AU && sys_rise && !d.reset && !negative_guard) {
            if (d.observed_au_active) {
                check(d.observed_au_seq < FULL_AU_FRAMES, "metrics AU sequence outside selected frame count");
                if (!previous_metric_au || metric_frame != d.observed_au_seq) {
                    metrics[d.observed_au_seq] = FrameMetrics{};
                    legacy_pixels[d.observed_au_seq] = 0;
                    legacy_rgb_payload[d.observed_au_seq].clear();
                }
                metric_frame = d.observed_au_seq;
                if (d.observed_vcl) metrics[metric_frame].vcl = time / kSysPeriod;
            }
            metrics_active = d.observed_au_active;
            previous_metric_au = d.observed_au_active;
            if (metrics_active) {
                auto& m = metrics[metric_frame];
                if (d.perf_events & 1) m.promoted = time / kSysPeriod;
                if (d.perf_events & 2) m.copy = time / kSysPeriod;
                if (m.copy && !m.copy_done && d.publish_state == 7) m.copy_done = time / kSysPeriod;
                if (d.perf_events & 4) m.filter_start = time / kSysPeriod;
                if (d.perf_events & 8) m.filter_done = time / kSysPeriod;
                m.prediction_fetches += bool(d.perf_events & 16);
                m.filter_writes += bool(d.perf_events & 32);
                m.fractional_fetches += bool(d.perf_events & 64);
                m.nonzero_P_blocks += bool(d.perf_events & 128);
                m.controller_busy += bool(d.observed_decoder_busy);
                m.filter_busy += bool(d.filter_busy);
                m.publisher_busy += !d.idle;
                for (unsigned bit = 0; bit < 8; ++bit) m.stalls[bit] += (d.perf_stalls >> bit) & 1;
            }
        }
        bool ram = sys_rise && d.mem_rd && d.mem_ready && !FULL_AU;
        uint8_t ram_data = ram ? native(d.mem_addr) : 0;
        const uint32_t ram_address = d.mem_addr;
        if (ddr_rise) {
            if (delivered) {
                responses.pop_front();
                ++ddr_read_beats_returned;
            }
            if (!d.DDRAM_BUSY && d.DDRAM_RD) {
                check(responses.empty(), "overlapping DDR read ownership");
                ddr_read_beats_accepted += d.DDRAM_BURSTCNT;
                for (unsigned i = 0; i < d.DDRAM_BURSTCNT; ++i)
                    responses.push_back({ddr_cycles + 3 + i,
                        load(d.DDRAM_ADDR + i) ^ uint64_t(corrupt_copy_fence &&
                            d.DDRAM_ADDR + i == (0x30000000 + unsigned(d.published_bank) * 0x80000 + 115200 - 8) / 8),
                        d.DDRAM_ADDR + i});
            }
            if (!d.DDRAM_BUSY && d.DDRAM_WE) {
                ++ddr_writes_accepted;
                if (watch_write && d.DDRAM_ADDR == watched_address &&
                    d.DDRAM_DIN == watched_data) ++watched_writes;
                auto& value = memory[d.DDRAM_ADDR];
                for (unsigned i = 0; i < 8; ++i)
                    if (d.DDRAM_BE & (1u << i)) {
                        const uint64_t mask = UINT64_C(0xff) << (i * 8);
                        value = (value & ~mask) | (uint64_t(d.DDRAM_DIN) & mask);
                    }
                if (d.DDRAM_ADDR >= feedback && d.DDRAM_ADDR <= commit)
                    status_writes.emplace_back(d.DDRAM_ADDR, value);
            }
            check(ddr_read_beats_returned <= ddr_read_beats_accepted &&
                  ddr_read_beats_accepted - ddr_read_beats_returned == responses.size(),
                  "accepted DDR read/response conservation failed");
        }
        const bool overlay_in_valid = d.native_ce;
        const uint32_t overlay_in_rgb = d.pixel_rgb;
        const bool overlay_in_de = d.pixel_de, overlay_in_hs = d.native_hs, overlay_in_vs = d.native_vs;
        d.clk = time % kSysPeriod < kSysPeriod / 2;
        d.clk_ddr = time % kDdrPeriod < kDdrPeriod / 2;
        d.eval();
        if (sys_rise) {
            if (FULL_AU_NATIVE_BEAM && !d.reset) {
                check(bool(d.overlay_ce) == previous_overlay_valid,
                      "overlay CE latency changed with SYS/native ratio");
                if (previous_overlay_valid)
                    check(d.overlay_rgb == previous_overlay_rgb &&
                          bool(d.overlay_de) == previous_overlay_de &&
                          bool(d.overlay_hs) == previous_overlay_hs &&
                          bool(d.overlay_vs) == previous_overlay_vs,
                          "hidden overlay lost paired RGB/sync/DE timing");
                previous_overlay_valid = overlay_in_valid;
                previous_overlay_rgb = overlay_in_rgb;
                previous_overlay_de = overlay_in_de;
                previous_overlay_hs = overlay_in_hs;
                previous_overlay_vs = overlay_in_vs;
                if (d.native_ce) {
                    if (previous_native_ce_tick) {
                        const uint64_t gap = time - previous_native_ce_tick;
                        if (SIM_SYS_MHZ == 85)
                            check(gap == 4*kSysPeriod || gap == 5*kSysPeriod,
                                  "85MHz native CE did not use exact4/5-cycle gaps");
                        else
                            check(gap == kNativePixelTicks,
                                  "native pixel timebase changed with SYS clock");
                    }
                    if (++native_ce_count % kNativeDen == 0) {
                        if (native_ce_group_tick)
                            check(time-native_ce_group_tick == kNativeDen*kNativePixelTicks,
                                  "rational native pixel timebase drifted");
                        native_ce_group_tick = time;
                    }
                    previous_native_ce_tick = time;
                }
                if (d.native_frame_start) {
                    if (previous_native_frame_tick)
                        check(time - previous_native_frame_tick == kNativeFrameTicks,
                              "native raster timebase changed with SYS clock");
                    previous_native_frame_tick = time;
                }
            } else if (d.reset) {
                previous_overlay_valid = false;
                previous_native_ce_tick = previous_native_frame_tick = 0;
                native_ce_count = native_ce_group_tick = 0;
            }
            if (negative_guard) {
                check(!d.native_reference_ready && !d.decoded_picture_valid &&
                      !d.has_frame && !d.swap_pending && d.count == 0,
                      "rejected AU transiently completed DPB/source/display");
                if (load(commit) != 0) {
                    ring::VideoPresentation failed;
                    check(ring::decodeVideoPresentation(status(), epoch1, nonce1, failed) &&
                         failed.error && !failed.has_frame && !failed.has_audio_clock &&
                         failed.presentation_count == 0 && failed.error_code != 0,
                         "rejected AU committed success-shaped or torn feedback");
                }
            }
            if (FULL_AU_NATIVE_BEAM && !d.reset && d.frames_done > 0 && d.frames_done <= FULL_AU_FRAMES) {
                const unsigned frame = d.frames_done - 1;
                if (d.native_frame_start) native_complete[frame] = true;
                if (!native_complete[frame] && d.native_ce) {
                    if (d.pixel_de) {
                        native_pixels[frame].push_back(d.pixel_rgb);
                        ++native_line_length;
                    } else if (native_line_length) {
                        native_lines[frame].push_back(native_line_length);
                        native_line_length = 0;
                    }
                }
            }
            if (!d.reset && d.frames_done == uint16_t(previous_frames_done + 1))
                displayed_cycle = time / kSysPeriod;
            previous_frames_done = d.frames_done;
            if (!FULL_AU) {
                const uint64_t cycle = time / kSysPeriod;
                if (ram_due) {
                    check(cycle - ram_responses.front().accepted >= 2, "native response violated R2 latency");
                    if (ram_responses.front().painter) ++painter_returned;
                    else ++ram_returned;
                    ram_responses.pop_front();
                }
                if (ram || painter_request) {
                    check(ram_responses.empty(), "native port accepted two outstanding reads");
                    const unsigned delay = 2 + (ram_stress ? ((ram_random >> 8) % 6) : 0);
                    ram_responses.push_back({cycle + delay, cycle, ram_address,
                                             painter_request ? uint8_t(0x5a) : ram_data, painter_request});
                    if (painter_request) ++painter_accepted;
                    else {
                        if (ram_last_accept) {
                            ram_min_gap = std::min(ram_min_gap, cycle - ram_last_accept);
                            check(cycle - ram_last_accept >= 2, "native request violated R2 II2");
                        }
                        ram_last_accept = cycle;
                        ++ram_accepted;
                    }
                }
                check(ram_returned <= ram_accepted && ram_accepted - ram_returned <= 1,
                      "publisher response crossed owner or bounded retained tag");
            }
        }
    }
    void run(uint64_t ticks) { while (ticks--) tick(); }
    unsigned expected_negative_error() const {
        return (filter_metadata_fault || active_filter_fault) ? 21 : vcl_overflow ? 14 : bad_tail ? 15 : 16;
    }
    template<class Predicate> void until(Predicate done, const char* why) {
        for (uint64_t i = 0; i < (FULL_AU ? kEventBudget : kEventBudget / 20); ++i) {
            d.eval();
            if (done()) return;
            // Only the intentional negative's exact error may keep running
            // through the physical error-feedback fence. Other failures abort.
            // During explicit CTRL reset, old fatal telemetry may outlive the
            // cleared local code; recovery still requires its physical removal.
            if (FULL_AU && ((load(ring::kStat6Phys / 8) >>
                (ring::kStat6StateFlagsShift + ring::kStat6FatalFlagBit)) & 1) &&
                (!negative_guard ||
                 (d.observed_codec_error_code != expected_negative_error() &&
                  !(fault_reset_in_progress && d.observed_codec_error_code == 0)))) {
                std::cerr << "reader fatal STAT6=0x" << std::hex
                          << load(ring::kStat6Phys / 8) << std::dec
                          << " read=" << d.stream_read_count << '\n';
                throw std::runtime_error("actual AU reader rejected transport");
            }
            if (FULL_AU && d.decoder_error &&
                (!negative_guard || d.decoder_error != expected_negative_error())) {
                std::cerr << "decoder error=" << unsigned(d.decoder_error)
                          << " phase=" << unsigned(d.decoder_phase)
                          << " MB=" << d.decoder_mb << " bit_pos=" << d.decoder_bit_pos
                          << " sys_cycles=" << time / kSysPeriod
                          << " verified_frames=" << verified_frames
                          << " presented=" << d.count
                          << " dpb_reads=" << native_requests[0] << "/" << native_responses[0]
                          << " parameter_flags=0x" << std::hex << unsigned(d.parameter_flags)
                          << " parameter_values=0x" << d.parameter_values << std::dec
                          << " geometry=" << (d.coded_geometry & 0xffff) << "x"
                          << (d.coded_geometry >> 16)
                          << " header_state=" << unsigned(d.header_state)
                          << " header_cursor=" << d.header_cursor << '\n';
                for (const auto& capture : {std::make_pair("SPS", &captured_sps),
                                            std::make_pair("PPS", &captured_pps)}) {
                    std::cerr << "actual " << capture.first << " RBSP=" << std::hex;
                    for (auto byte : *capture.second)
                        std::cerr << std::setfill('0') << std::setw(2) << unsigned(byte);
                    std::cerr << std::dec << std::setfill(' ') << '\n';
                }
                throw std::runtime_error("actual AU decoder aborted");
            }
            tick();
        }
        std::cerr << "state=" << unsigned(d.publish_state) << " count=" << d.count
                  << " frames_done=" << d.frames_done << " has_frame=" << unsigned(d.has_frame)
                  << " pending=" << unsigned(d.swap_pending)
                  << " ready=" << unsigned(d.pending_ready)
                  << " decoder_phase=" << unsigned(d.decoder_phase)
                  << " MB=" << d.decoder_mb << " bit_pos=" << d.decoder_bit_pos
                  << " reader=" << d.stream_read_count
                  << " error=" << unsigned(d.error) << " responses=" << responses.size() << '\n';
        throw std::runtime_error(why);
    }
    std::array<uint64_t,9> status() {
        std::array<uint64_t,9> out{};
        for (unsigned i = 0; i < 9; ++i) out[i] = load(feedback + i);
        return out;
    }
    void begin_frame(uint64_t epoch, unsigned seq, int64_t pts) {
        until([&] { return d.frame_ready; }, "publisher not ready");
        d.session_id = epoch;
        d.seq = seq;
        d.pts = uint64_t(pts);
        d.tb_num = 1001;
        d.tb_den = 24000;
        d.frame_valid = 1;
        do { tick(); } while (time % kSysPeriod != 0);
        d.frame_valid = 0;
    }
};

using Bytes = std::vector<uint8_t>;
static Bytes read_bytes(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    check(bool(file), "missing composed-test input");
    return Bytes(std::istreambuf_iterator<char>(file), {});
}

static void decoded_access_units(Sim& s, const std::string& directory,
                                 const std::string& actual_path) {
    uint32_t producer = 0;
    bool ctrl_epoch = true;
    auto publish = [&] {
        s.memory[ring::kCtrlPhys / 8] = uint64_t(ctrl_epoch) << 63 |
            uint64_t(producer) << 32 | ring::kCtrlMagic;
    };
    auto append = [&](ring::Event event, uint64_t epoch, uint32_t seq, const Bytes& payload,
                      size_t fragment_bytes = 0) {
        Bytes bytes(ring::kRecordHeaderBytes + payload.size());
        ring::putLe32(bytes.data(), ring::kRecordMagic);
        bytes[4] = uint8_t(event);
        bytes[6] = 2;
        ring::putLe64(bytes.data() + 8, epoch);
        ring::putLe32(bytes.data() + 16, seq);
        ring::putLe32(bytes.data() + 20, uint32_t(payload.size()));
        std::copy(payload.begin(), payload.end(), bytes.begin() + ring::kRecordHeaderBytes);
        if (fragment_bytes) {
            check(fragment_bytes < bytes.size(), "partial AU must retain unsubmitted bytes");
            bytes.resize(fragment_bytes);
        }
        for (uint8_t byte : bytes) {
            const uint32_t offset = producer & (ring::kRingBytes - 1);
            auto& word = s.memory[(ring::kDataPhys + offset) / 8];
            const unsigned shift = 8 * (offset & 7);
            word = (word & ~(UINT64_C(255) << shift)) | uint64_t(byte) << shift;
            producer = (producer + 1) & ring::kCountMask;
        }
        publish();
    };
    const auto reference = read_bytes(directory + "/reference.yuv");
    const auto keyframes = read_bytes(directory + "/keyframes.bin");
    unsigned coded_w = 320, coded_h = 240, crop_l = 0, crop_r = 0, crop_t = 0, crop_b = 0;
    if (FULL_AU_RUNTIME_GEOMETRY) {
        std::ifstream geometry(directory + "/geometry.txt");
        check(bool(geometry >> coded_w >> coded_h >> crop_l >> crop_r >> crop_t >> crop_b),
              "missing independent coded/crop geometry");
        geometry >> std::ws;
        check(geometry.eof(), "extra independent geometry records");
    }
    check(coded_w && coded_w <= 320 && coded_h && coded_h <= 240 &&
          !(coded_w % 16) && !(coded_h % 16) &&
          crop_l + crop_r < coded_w && crop_t + crop_b < coded_h &&
          !((crop_l | crop_r | crop_t | crop_b) & 1),
          "unsupported independent coded/crop geometry");
    const unsigned visible_w = coded_w - crop_l - crop_r;
    const unsigned visible_h = coded_h - crop_t - crop_b;
    const unsigned visible_bytes = visible_w * visible_h * 3 / 2;
    const unsigned coded_bytes = coded_w * coded_h * 3 / 2;
    const auto coded_reference = FULL_AU_RUNTIME_GEOMETRY ?
        read_bytes(directory + "/reference-coded.yuv") : reference;
    s.legacy_oracle = &coded_reference;
    s.legacy_width = coded_w;
    s.legacy_height = coded_h;
    check(reference.size() == FULL_AU_FRAMES * visible_bytes &&
          coded_reference.size() == FULL_AU_FRAMES * coded_bytes,
          "independent visible/coded reference count does not match the selected frame count");
    check(keyframes.size() == FULL_AU_FRAMES, "missing original packet keyframe flags");
    struct Timing {
        int64_t pts, duration;
        uint32_t numerator, denominator;
    };
    Timing timing[FULL_AU_FRAMES];
    for (unsigned frame = 0; frame < FULL_AU_FRAMES; ++frame)
        timing[frame] = FULL_AU_JOINT_FILTER ? Timing{frame, 1, 1, 24} :
            Timing{-12345 + int64_t(frame) * 1001, 1001, 1, 24000};
    if (FULL_AU_ORIGINAL_TIMING) {
        std::ifstream input(directory + "/original-timing.txt");
        check(bool(input), "missing required original AU timing");
        for (auto& value : timing)
            check(bool(input >> value.pts >> value.duration >> value.numerator >> value.denominator),
                  "incomplete original AU timing");
        input >> std::ws;
        check(input.eof(), "extra original AU timing records");
    }
    publish();
    s.run(kSysPeriod * 1000);
    if (s.ingress_seek) {
        unsigned stages = (s.d.decoder_plane_state & 128) ? 5 : 3;
#if defined(FULL_AU_SEEK_STAGES) && FULL_AU_SEEK_STAGES
        check(FULL_AU_SEEK_STAGES <= stages, "unsupported explicit seek selector");
        stages = FULL_AU_SEEK_STAGES;
        std::cout << "SEEK_SCOPE stages=" << stages << " I4-read-selector=NOT_RUN\n";
#endif
        for (unsigned stage = 0; stage < stages; ++stage) {
            const uint64_t challenge = nonce1 + 100 + stage;
            const uint64_t session = epoch1 + 100 + stage;
            append(ring::Event::Probe, challenge, mailbox_abi::kFpgaVideoLayoutId, {});
            s.until([&] { return s.d.observed_nonce == challenge; },
                    "seek setup Probe did not commit");
            append(ring::Event::Begin, session, 0, {});
            s.until([&] { return s.d.stream_read_count == producer && s.d.stream_idle; },
                    "seek setup Begin did not retire");
            const auto encoded = read_bytes(directory + "/au0.264");
            ring::AccessUnit au;
            au.session_id = session;
            au.seq = 0;
            au.annexb = encoded.data();
            au.len = encoded.size();
            au.pts = timing[0].pts;
            au.duration = timing[0].duration;
            au.timebase_num = timing[0].numerator;
            au.timebase_den = timing[0].denominator;
            au.flags = ring::kAccessUnitKeyframe;
            const auto metadata = ring::encodeAccessUnitMetadata(au);
            Bytes payload(metadata.begin(), metadata.end());
            payload.insert(payload.end(), encoded.begin(), encoded.end());
            append(ring::Event::AccessUnit, session, 0, payload,
                   stage == 0 ? 64 + encoded.size() / 2 : 0);
            if (stage == 0) {
                s.until([&] { return s.d.observed_au_active &&
                                    s.d.stream_read_count == producer; },
                        "fragmented AU never reached actual whole-AU staging");
                check(s.d.native_sample_count == 0 && !s.d.observed_vcl,
                      "partial AU escaped whole-AU staging");
            } else if (stage == 1) {
                s.until([&] { return s.d.decoder_mb > 0 && s.d.native_sample_count > 0; },
                        "seek never reached in-flight native reconstruction");
                check(!s.d.decoded_picture_valid && !s.d.has_frame,
                      "seek setup already completed its native picture");
            } else if (stage == 2) {
                s.until([&] {
                    return s.d.DDRAM_WE && s.d.DDRAM_BUSY &&
                           s.d.DDRAM_ADDR >= 0x30000000 / 8 &&
                           s.d.DDRAM_ADDR < 0x300f0000 / 8;
                }, "seek never reached a BUSY-held real publisher DDR write");
                s.watched_address = s.d.DDRAM_ADDR;
                s.watched_data = s.d.DDRAM_DIN;
                s.watched_writes = 0;
                s.watch_write = true;
                s.force_busy = true;
            } else if (stage == 3) {
                s.until([&] {
                    const unsigned word = (s.d.decoder_plane_state >> 2) & 31;
                    return s.d.decoder_phase == 6 && word >= 8 && word <= 16;
                }, "seek never reached partially initialized real plane RAM");
                check(!s.d.decoded_picture_valid && !s.d.native_sample_count,
                      "partial plane initialization published pixels");
            } else {
                s.until([&] {
                    return s.d.decoder_phase == 15 && (s.d.decoder_plane_state & 3) == 2;
                }, "seek never reached owned I4 neighbour RAM reads");
                check(!s.d.decoded_picture_valid, "I4 RAM read setup already published");
            }
            s.d.clear = 1;
            s.run(kSysPeriod * 2);
            s.d.clear = 0;
            if (stage == 2) {
                s.run(kSysPeriod * 40);
                check(s.d.DDRAM_WE && s.d.DDRAM_ADDR == s.watched_address &&
                      s.d.DDRAM_DIN == s.watched_data && !s.watched_writes &&
                      s.d.stream_reset_pending && s.d.observed_nonce == challenge,
                      "seek abandoned a held publisher write or invalidated identity before retirement");
                s.force_busy = false;
            }
            bool noted_response_wait = false;
            s.until([&] {
                const bool retired = !s.d.stream_reset_pending && s.d.stream_idle && s.d.idle &&
                                     s.d.generation_idle && s.d.observed_nonce == 0 &&
                                     s.d.stream_read_count == producer && s.load(commit) == 0;
                if (retired && !s.responses.empty() && !noted_response_wait) {
                    std::cerr << "SEEK_RESPONSE_WAIT stage=" << stage
                              << " pending_read_address=0x" << std::hex << (s.responses.front().address << 3)
                              << " data=0x" << s.responses.front().data << std::dec << '\n';
                    noted_response_wait = true;
                }
                return retired && s.d.stream_transport_quiescent && s.responses.empty();
            }, "local seek did not retire actual ingress/decoder/publisher/display ownership");
            std::cerr << "SEEK_RETIRE_STATE stage=" << stage
                      << " ref=" << unsigned(s.d.native_reference_ready)
                      << " picture=" << unsigned(s.d.decoded_picture_valid)
                      << " frame=" << unsigned(s.d.has_frame)
                      << " swap=" << unsigned(s.d.swap_pending)
                      << " count=" << s.d.count << " frames_done=" << s.d.frames_done
                      << " transport_quiet=" << unsigned(s.d.stream_transport_quiescent)
                      << " queued_responses=" << s.responses.size()
                      << " reads=" << s.ddr_read_beats_accepted << '/' << s.ddr_read_beats_returned << '\n';
            check(!s.d.native_reference_ready && !s.d.decoded_picture_valid &&
                  !s.d.has_frame && !s.d.swap_pending && s.d.count == 0 &&
                  s.d.frames_done == 0 && s.responses.empty(),
                  "cancelled AU leaked a reference, display, feedback or accepted DDR response");
            if (stage == 2)
                check(s.watched_writes == 1, "seek did not retire the owned publisher write exactly once");
            s.watch_write = false;
            std::cout << "INGRESS_SEEK_PASS stage=" << stage
                      << " original_pts=" << timing[0].pts
                      << " no_stale_DPB_display_MVPS=1\n";
        }
    }
    append(ring::Event::Probe, nonce1, mailbox_abi::kFpgaVideoLayoutId, {});
    s.until([&] { return s.d.observed_nonce == nonce1; }, "composed Probe failed");
    std::array<uint64_t, 8> capability_words{};
    ring::VideoCapabilities capabilities;
    // SYS command acceptance can precede its physical DDR write. Qualify
    // the actual host-visible nonce/commit-last words, not the local signal.
    s.until([&] {
        for (unsigned i = 0; i < capability_words.size(); ++i)
            capability_words[i] = s.load(mailbox_abi::kVideoCapsAddr / 8 + i);
        return ring::decodeVideoCapabilities(capability_words, nonce1, capabilities);
    }, "fresh capability publication did not physically reach DDR");
    check(capabilities.max_au_bytes == (s.large_au || s.vcl_overflow ? 32768 : 8192) &&
          capabilities.max_width == 320 && capabilities.max_height == 240 &&
          capabilities.features == 0,
          "actual stream capability publication exceeded or understated its selected AU cohort");
    append(ring::Event::Begin, epoch1, 0, {});
    s.until([&] { return s.d.stream_read_count == producer && s.d.stream_idle; },
            "composed Begin did not retire");
    const uint32_t bytes_before = s.d.stream_bytes_out;
    uint32_t encoded_bytes = 0;
    append(ring::Event::Pause, epoch1, 0, {});
    append(ring::Event::Pause, epoch1, 0, {});
    s.until([&] {
        return s.d.stream_read_count == producer &&
               ((s.load(ring::kStat6Phys / 8) >>
                 (ring::kStat6StateFlagsShift + ring::kStat6PausedFlagBit)) & 1);
    }, "no-data repeated Pause did not retire through real CDC");
    const auto paused_read = producer;
    for (unsigned frame = 0; frame < FULL_AU_FRAMES; ++frame) {
        auto encoded = read_bytes(directory + "/au" + std::to_string(frame) + ".264");
        check(!encoded.empty() && encoded.size() <= 8192, "frozen AU exceeds the approved 8 KiB cohort");
        if (s.large_au) {
            // A valid filler NAL increases encoded AU size without changing
            // any original VCL byte, reconstruction work, or timestamp.
            Bytes filler(32768 - encoded.size(), 0xff);
            filler[0] = filler[1] = 0;
            filler[2] = 1;
            filler[3] = 0x0c;
            filler.back() = 0x80;
            encoded.insert(encoded.begin(), filler.begin(), filler.end());
        }
        encoded_bytes += encoded.size();
        ring::AccessUnit au;
        au.session_id = epoch1;
        au.seq = frame;
        au.annexb = encoded.data();
        au.len = encoded.size();
        au.pts = timing[frame].pts;
        au.duration = timing[frame].duration;
        au.timebase_num = timing[frame].numerator;
        au.timebase_den = timing[frame].denominator;
        au.flags = keyframes[frame] ? ring::kAccessUnitKeyframe : 0;
        check(ring::validAccessUnit(au), "invalid test AU metadata");
        const auto metadata = ring::encodeAccessUnitMetadata(au);
        Bytes payload(metadata.begin(), metadata.end());
        payload.insert(payload.end(), encoded.begin(), encoded.end());
        append(ring::Event::AccessUnit, epoch1, frame, payload);
    }
    s.run(kSysPeriod * 1000);
    check(s.d.stream_bytes_out == bytes_before && s.d.stream_read_count == paused_read && s.d.count == 0,
          "paused ring lookahead delivered or consumed a preserved AU");
    append(ring::Event::Resume, epoch1, 0, {});
    append(ring::Event::Drain, epoch1, 0, {});
    std::ofstream actual(actual_path, std::ios::binary);
    check(bool(actual), "cannot create actual DDR picture output");
    std::ofstream allocation_output(actual_path + ".allocation", std::ios::binary);
    check(bool(allocation_output), "cannot create actual DDR allocation output");
    std::ofstream metric_output(actual_path + ".metrics.csv");
    check(bool(metric_output), "cannot preserve measured SYS-cycle metrics");
    metric_output << "frame,vcl_cycle,promotion_cycle,copy_accept_cycle,display_cycle,publication_retired_cycle,"
                     "vcl_to_promotion,filter_cycles,copy_to_feedback,controller_busy,filter_busy,publisher_busy,"
                     "display_interval,prediction_fetches,fractional_fetches,nonzero_P_blocks,filter_writes,"
                     "recon_backpressure,publisher_native_wait,publisher_bus_busy,ingress_bus_busy,"
                     "filter_read_wait,encoded_staging_wait,native_lease_wait,scanner_boundary_wait,"
                     "SYS_Hz,DDR_Hz,base_Hz,native_divisor,native_divisor_den,checker_retired_cycle,checker_delay_after_feedback\n";
    uint64_t previous_display_cycle = 0;
    bool first_native_bank = false, first_ddr_bank = false;
    for (unsigned frame = 0; frame < FULL_AU_FRAMES; ++frame) {
        s.vsync_enabled = false;
        s.until([&] { return s.d.swap_pending; }, "decoded AU never reached pending display");
        check(s.d.count == frame && s.d.stream_read_count < producer,
              "copy counted as display or Drain retired before display");
        check(s.d.geometry_width == coded_w && s.d.geometry_height == coded_h &&
              s.d.geometry_left == crop_l && s.d.geometry_right == crop_r &&
              s.d.geometry_top == crop_t && s.d.geometry_bottom == crop_b,
              "completed picture geometry was lost before display");
        check(s.d.reference_width == coded_w && s.d.reference_height == coded_h &&
              s.d.native_sample_count == coded_bytes &&
              s.d.decoder_mb == (coded_w / 16) * (coded_h / 16),
              "decoder completion/reference bounds still use maximum or visible geometry");
        if (FULL_AU_JOINT_FILTER) {
            check(s.d.filter_starts == frame + 1 && s.d.filter_completions == frame + 1 &&
                  s.d.filter_stores > 0,
                  "joint picture reached publication without an actual completed filter job");
            if (frame == 1)
                check(!keyframes[frame] && s.d.prediction_fetches > 0,
                      "joint P picture did not exercise real reference prediction");
        }
        if (frame == 0)
            check(!s.d.has_frame && s.d.active_coded_width == 320 &&
                  s.d.active_coded_height == 240,
                  "pending copy changed active geometry before display ACK");
        Bytes allocation(115200);
        if (frame == 0) {
            first_native_bank = s.d.published_native_bank;
            first_ddr_bank = s.d.published_bank;
        }
        check(s.d.published_native_bank == (first_native_bank ^ bool(frame & 1)) &&
              s.d.published_bank == (first_ddr_bank ^ bool(frame & 1)),
              "native/DDR publication did not alternate and reuse its two banks");
        const uint32_t base = s.d.published_bank ? 0x30080000 : 0x30000000;
        if (frame >= 2)
            std::cout << "BANK_REUSE_PASS seq=" << frame
                      << " native_bank=" << unsigned(s.d.published_native_bank)
                      << " DDR_bank=" << unsigned(s.d.published_bank) << '\n';
        for (uint32_t i = 0; i < allocation.size(); ++i)
            allocation[i] = uint8_t(s.load((base + i) / 8) >> (8 * (i & 7)));
        allocation_output.write(reinterpret_cast<const char*>(allocation.data()), allocation.size());
        allocation_output.flush();
        check(bool(allocation_output), "cannot write actual DDR allocation output");
        Bytes pixels;
        pixels.reserve(visible_bytes);
        const unsigned allocation_bases[] = {0, 76800, 96000};
        const unsigned coded_bases[] = {0, coded_w * coded_h, coded_w * coded_h * 5 / 4};
        for (unsigned plane = 0; plane < 3; ++plane) {
            const unsigned divisor = plane ? 2 : 1;
            const unsigned stride = 320 / divisor;
            const unsigned rows = 240 / divisor;
            const unsigned cw = coded_w / divisor, ch = coded_h / divisor;
            for (unsigned y = 0; y < rows; ++y)
                for (unsigned x = 0; x < stride; ++x) {
                    const auto value = allocation[allocation_bases[plane] + y * stride + x];
                    const auto expected = x < cw && y < ch ?
                        coded_reference[frame * coded_bytes + coded_bases[plane] + y * cw + x] :
                        uint8_t(plane ? 128 : 16);
                    if (value != expected) {
                        std::cerr << "frame=" << frame << " plane=" << plane
                                  << " x=" << x << " y=" << y << " actual=" << unsigned(value)
                                  << " ffmpeg_or_padding=" << unsigned(expected) << '\n';
                        throw std::runtime_error("fixed-stride coded DDR picture differs from ordinary ffmpeg");
                    }
                }
            for (unsigned y = 0; y < visible_h / divisor; ++y)
                for (unsigned x = 0; x < visible_w / divisor; ++x)
                    pixels.push_back(allocation[allocation_bases[plane] +
                        (crop_t / divisor + y) * stride + crop_l / divisor + x]);
        }
        actual.write(reinterpret_cast<const char*>(pixels.data()), pixels.size());
        actual.flush();
        check(bool(actual), "cannot write actual DDR picture output");
        for (uint32_t i = 0; i < pixels.size(); ++i) {
            const auto expected = reference[frame * visible_bytes + i];
            if (pixels[i] != expected) {
                std::cerr << "frame=" << frame << " I420_byte=" << i
                          << " actual=" << unsigned(pixels[i])
                          << " ffmpeg=" << unsigned(expected) << '\n';
                throw std::runtime_error("actual decoded DDR picture differs from ordinary ffmpeg");
            }
        }
        s.vsync_enabled = true;
        s.until([&] { return s.d.idle && s.d.count == frame + 1; },
                "decoded safe-boundary MVPS publication failed");
        const auto publication_retired_cycle = s.time / kSysPeriod;
        s.vsync_enabled = false;
        check(s.d.active_coded_width == coded_w && s.d.active_coded_height == coded_h &&
              s.d.active_visible_width == visible_w && s.d.active_visible_height == visible_h,
              "display bank and geometry did not commit together");
        ring::VideoPresentation p;
        check(ring::decodeVideoPresentation(s.status(), epoch1, nonce1, p) &&
              p.seq == frame && p.pts == timing[frame].pts &&
              p.timebase_num == timing[frame].numerator && p.timebase_den == timing[frame].denominator &&
              p.presentation_count == frame + 1 && !p.has_audio_clock,
              "decoded AU metadata lost before actual presentation");
        const auto offset = frame * visible_bytes;
        const unsigned y_bytes = visible_w * visible_h;
        const unsigned c_bytes = y_bytes / 4;
        const unsigned origin_x = (320 - visible_w) / 2, origin_y = (240 - visible_h) / 2;
        if (FULL_AU_NATIVE_BEAM) {
            s.until([&] { return s.native_complete[frame]; },
                    "actual presenter did not finish the displayed native raster");
            std::vector<uint32_t> expected;
            unsigned line_width = 0;
            for (unsigned row = 0; row < 240 * (FULL_AU_SCANDOUBLE ? 2 : 1); ++row) {
                const unsigned py = FULL_AU_SCANDOUBLE ? row / 2 : row;
                if (py < origin_y || py >= origin_y + visible_h) continue;
                unsigned width = 0;
                for (unsigned hc = 0; hc < 529; ++hc) {
                    const unsigned px = std::min((hc * 39647) >> 16, 319u);
                    if (px < origin_x || px >= origin_x + visible_w) continue;
                    const unsigned x = px - origin_x, y = py - origin_y;
                    const unsigned yi = y * visible_w + x;
                    const unsigned ci = (y / 2) * (visible_w / 2) + x / 2;
                    expected.push_back(Sim::rgb601(reference[offset + yi],
                        reference[offset + y_bytes + ci],
                        reference[offset + y_bytes + c_bytes + ci]));
                    ++width;
                }
                line_width = width;
            }
            check(s.native_lines[frame].size() == visible_h * (FULL_AU_SCANDOUBLE ? 2 : 1),
                  "actual native DE height includes padding or loses cropped rows");
            for (auto width : s.native_lines[frame])
                check(width == line_width, "actual native DE width lost an edge or included padding");
            check(s.native_pixels[frame].size() == expected.size(),
                  "native CE/DE aperture does not match displayed geometry");
            for (size_t i = 0; i < expected.size(); ++i)
                if (s.native_pixels[frame][i] != expected[i]) {
                    std::cerr << "native frame=" << frame << " x=" << i % line_width
                              << " y=" << i / line_width << " RGB=0x" << std::hex
                              << s.native_pixels[frame][i] << " expected=0x" << expected[i]
                              << std::dec << '\n';
                    throw std::runtime_error("actual present_core CE/RGB differs from decoded reference");
                }
            std::ofstream rgb_output(actual_path + ".frame-" + std::to_string(frame) + ".native-rgb24",
                                     std::ios::binary);
            check(bool(rgb_output), "cannot retain actual native RGB payload");
            for (const auto pixel : s.native_pixels[frame]) {
                const char rgb[] = {char(pixel >> 16), char(pixel >> 8), char(pixel)};
                rgb_output.write(rgb, sizeof(rgb));
            }
            rgb_output.close();
            check(bool(rgb_output), "cannot finish actual native RGB payload");
            std::cout << "NATIVE_PASS seq=" << frame << " DE=" << line_width << "x"
                      << s.native_lines[frame].size() << " RGB_samples=" << expected.size()
                      << " scandouble=" << FULL_AU_SCANDOUBLE << " source_DAR=content-only\n";
        } else {
        for (const auto point : {std::pair<unsigned, unsigned>{0, 0},
                                 {visible_w - 1, 0}, {0, visible_h - 1},
                                 {visible_w - 1, visible_h - 1}}) {
            const auto yi = point.second * visible_w + point.first;
            const auto ci = (point.second / 2) * (visible_w / 2) + point.first / 2;
            s.check_pixel(origin_x + point.first, origin_y + point.second,
                          reference[offset + yi], reference[offset + y_bytes + ci],
                          reference[offset + y_bytes + c_bytes + ci]);
            check(s.d.pixel_de, "visible picture excluded from scaler content aperture");
        }
        if (origin_y) {
            s.check_pixel(origin_x, origin_y - 1, 16, 128, 128);
            check(!s.d.pixel_de, "upper allocation padding included in source DAR");
            s.check_pixel(origin_x, origin_y + visible_h, 16, 128, 128);
            check(!s.d.pixel_de, "lower allocation padding included in source DAR");
        }
        if (origin_x) {
            s.check_pixel(origin_x - 1, origin_y, 16, 128, 128);
            check(!s.d.pixel_de, "horizontal allocation padding included in source DAR");
        }
        }
        ++s.verified_frames;
        check(s.legacy_pixels[frame] == uint64_t(visible_w) * visible_h,
              "legacy RGB drain did not accept every visible source pixel exactly once");
        check(s.legacy_rgb_payload[frame].size() == s.legacy_pixels[frame],
              "legacy RGB payload lost an accepted sample");
        std::ofstream legacy_output(actual_path + ".frame-" + std::to_string(frame) + ".legacy-rgb565le",
                                    std::ios::binary);
        check(bool(legacy_output), "cannot retain accepted legacy RGB payload");
        for (const auto pixel : s.legacy_rgb_payload[frame]) {
            const char rgb[] = {char(pixel), char(pixel >> 8)};
            legacy_output.write(rgb, sizeof(rgb));
        }
        legacy_output.close();
        check(bool(legacy_output), "cannot finish accepted legacy RGB payload");
        std::cout << "LEGACY_RGB_PASS seq=" << frame << " pixels=" << s.legacy_pixels[frame] << '\n';
        const auto& metric = s.metrics[frame];
        check(metric.vcl && metric.promoted >= metric.vcl && metric.copy >= metric.promoted &&
              publication_retired_cycle >= metric.copy,
              "observational stage timestamps contradict actual ownership order");
        const auto filter_cycles = metric.filter_done ? metric.filter_done - metric.filter_start : 0;
        const auto display_interval = frame ? s.displayed_cycle - previous_display_cycle : 0;
        metric_output << frame << ',' << metric.vcl << ',' << metric.promoted << ',' << metric.copy << ','
                      << s.displayed_cycle << ',' << publication_retired_cycle << ','
                      << metric.promoted - metric.vcl << ',' << filter_cycles << ','
                      << publication_retired_cycle - metric.copy << ',' << metric.controller_busy << ','
                      << metric.filter_busy << ',' << metric.publisher_busy << ',' << display_interval << ','
                      << metric.prediction_fetches << ',' << metric.fractional_fetches << ','
                      << metric.nonzero_P_blocks << ',' << metric.filter_writes;
        for (auto value : metric.stalls) metric_output << ',' << value;
        metric_output << ',' << kSysHz << ",90000000," << kBaseHz << ',' << kNativeDivisor << ',' << kNativeDen
                      << ',' << s.time / kSysPeriod
                      << ',' << s.time / kSysPeriod - publication_retired_cycle << '\n';
        metric_output.flush();
        check(bool(metric_output), "cannot write measured SYS-cycle metrics");
        std::cout << "METRIC seq=" << frame << " copy_to_final_accept=" << metric.copy_done - metric.copy
                  << " vcl_to_promotion=" << metric.promoted - metric.vcl
                  << " filter_cycles=" << filter_cycles
                  << " copy_to_feedback=" << publication_retired_cycle - metric.copy
                  << " display_interval=" << display_interval
                  << " P_fetches=" << metric.prediction_fetches
                  << " fractional_fetches=" << metric.fractional_fetches
                  << " nonzero_P_blocks=" << metric.nonzero_P_blocks
                  << " SYS_cycles=observed model_periods_SYS_DDR=" << kSysPeriod << ':'
                  << kDdrPeriod << " SYS_Hz=" << kSysHz << " DDR_Hz=90000000"
                  << " checker_delay_after_feedback=" << s.time / kSysPeriod - publication_retired_cycle
                  << " native_period_SYS_cycles=" << kNativeFrameTicks / kSysPeriod << '\n';
        previous_display_cycle = s.displayed_cycle;
        std::cout << "FRAME_PASS seq=" << frame << " native_bytes=" << visible_bytes
                  << " presentation_count=" << p.presentation_count
                  << " pts=" << p.pts << " tb=" << p.timebase_num << "/"
                  << p.timebase_den << " sys_cycles=" << s.time / kSysPeriod
                  << " display_sys_cycles=" << s.displayed_cycle
                  << " coded_bytes=" << coded_bytes << " coded=" << coded_w << "x" << coded_h
                  << " visible=" << visible_w << "x" << visible_h << '\n';
    }
    s.vsync_enabled = true;
    s.until([&] { return s.d.stream_idle && s.d.stream_read_count == producer; },
            "Drain did not fence actual decoder and presentation");
    check(s.d.stream_bytes_out == bytes_before + encoded_bytes,
          "actual ring-to-staging byte count lost or duplicated an encoded AU");
    if (s.large_au)
        std::cout << "LARGE_AU_PASS encoded_bytes_per_AU=32768 RBSP_capacity=8192 "
                     "original_VCL_and_PTS_unchanged=1 total_bytes=" << encoded_bytes << '\n';
    s.run(s.vsync_period * kSysPeriod * 8);
    check(s.d.count == FULL_AU_FRAMES, "idle vsync fabricated another decoded presentation");
    for (unsigned client = 0; client < 2; ++client)
        check(s.native_requests[client] == s.native_responses[client],
              "native read response left outstanding after Drain");
    check(s.d.native_reference_ready && s.d.has_frame,
          "Drain flushed the native reference or displayed picture");
    const auto frames_before_flush = s.d.frames_done;
    append(ring::Event::Flush, epoch1, 0, {});
    publish();
    s.until([&] { return s.d.stream_read_count == producer && s.d.stream_idle &&
                        s.d.idle && s.load(commit) == 0; },
            "actual Flush did not fence generation retirement");
    s.run(s.vsync_period * kSysPeriod * 4);
    check(!s.d.native_reference_ready && !s.d.has_frame && !s.d.swap_pending &&
          s.d.count == 0 && s.d.frames_done == frames_before_flush,
          "actual Flush retained old DPB/display ownership");

    auto malformed = read_bytes(directory + "/au0.264");
    const auto filter_writes_before_negative = s.d.filter_stores;
    s.negative_guard = true;
    if (s.filter_metadata_fault || s.active_filter_fault) {
        check(malformed == read_bytes(directory + "/au0.264"),
              "filter-metadata negative changed the original Annex-B bytes");
    } else if (s.vcl_overflow) {
        malformed.insert(malformed.end(), 8193, 0x55);
        check(malformed.size() <= 32768, "VCL overflow negative exceeded encoded AU admission");
    } else if (s.bad_tail) {
        while (!malformed.empty() && malformed.back() == 0) malformed.pop_back();
        check(!malformed.empty() && !(malformed.back() & 1),
              "tail negative needs a nonzero final RBSP byte with an alignment-zero bit");
        // Change padding only, after every macroblock's syntax/reconstruction.
        malformed.back() ^= 1;
    } else {
    bool inserted = false;
    for (size_t i = 0; i + 4 < malformed.size(); ++i) {
        if (malformed[i] || malformed[i + 1]) continue;
        const size_t header = malformed[i + 2] == 1 ? i + 3 :
            (malformed[i + 2] == 0 && malformed[i + 3] == 1 ? i + 4 : 0);
        if (header && ((malformed[header] & 31) == 1 || (malformed[header] & 31) == 5)) {
            // Negative only: truncated PPS or valid PPS referencing unavailable SPS 1.
            const Bytes replacement = s.pps_mismatch ?
                Bytes{0, 0, 0, 1, 0x68, 0xa3, 0x8f, 0x20} :
                Bytes{0, 0, 0, 1, 0x68, 0x80};
            malformed.insert(malformed.begin() + i, replacement.begin(), replacement.end());
            inserted = true;
            break;
        }
    }
    check(inserted && malformed.size() <= 8192, "cannot construct bounded malformed-PPS AU");
    }
    ring::AccessUnit invalid_au;
    invalid_au.session_id = epoch1;
    invalid_au.seq = 0;
    invalid_au.annexb = malformed.data();
    invalid_au.len = malformed.size();
    invalid_au.pts = 0;
    invalid_au.duration = 1001;
    invalid_au.timebase_num = 1;
    invalid_au.timebase_den = 24000;
    invalid_au.flags = ring::kAccessUnitKeyframe;
    if (s.fault_recovery) {
        invalid_au.pts = timing[0].pts;
        invalid_au.duration = timing[0].duration;
        invalid_au.timebase_num = timing[0].numerator;
        invalid_au.timebase_den = timing[0].denominator;
    }
    check(ring::validAccessUnit(invalid_au), "decoder negative broke transport metadata");
    const auto bad_metadata = ring::encodeAccessUnitMetadata(invalid_au);
    Bytes bad_payload(bad_metadata.begin(), bad_metadata.end());
    bad_payload.insert(bad_payload.end(), malformed.begin(), malformed.end());
    append(ring::Event::AccessUnit, epoch1, 0, bad_payload);
    if (s.active_filter_fault) {
        s.until([&] { return s.d.decoder_phase == 29 && s.d.filter_busy &&
                            s.d.filter_read_outstanding &&
                            (s.d.native_transactions & 2) &&
                            s.d.filter_stores >= filter_writes_before_negative + 32; },
                "active fault did not reach phase29 after accepted filter writes with a read in flight");
        const auto reads_before = s.native_lifetime_requests[0];
        const auto writes_before = s.d.filter_stores - filter_writes_before_negative;
        s.d.inject_active_filter_fault = 1;
        s.run(kSysPeriod * 2);
        s.d.inject_active_filter_fault = 0;
        s.run(kSysPeriod * 2);
        check(s.d.active_filter_faults == 1 && s.d.active_filter_owned_read_witness &&
              s.d.filter_error && s.d.decoder_error == 21 &&
              s.d.native_sample_count == coded_bytes,
              "active filter-state upset did not produce actual error21 after full reconstruction");
        std::cout << "FILTER_ACTIVE_FAULT injected_state=15 phase=29 owned_read_witness=1"
                  << " prior_filter_writes=" << writes_before
                  << " lifetime_native_reads=" << reads_before
                  << " controller_error=21 test_only=1 natural_detection=not_exhaustive\n";
    } else if (s.filter_metadata_fault) {
        s.until([&] { return s.d.native_sample_count > 0 && s.d.decoder_mb > 0 &&
                            s.d.filter_meta_ready; },
                "metadata fault never reached real reconstruction/helper admission");
        s.d.inject_filter_metadata = 1;
        s.run(kSysPeriod * 2);
        s.d.inject_filter_metadata = 0;
        s.run(kSysPeriod * 2);
        check(s.d.injected_filter_metadata_accepts == 1 && s.d.filter_error &&
              s.d.decoder_error == 21 && s.d.native_sample_count > 0,
              "one invalid helper metadata record did not produce actual controller error21");
        std::cout << "FILTER_METADATA_FAULT injected_mode=7 accepted=1 controller_error=21 "
                     "test_only=1 production_fault_coverage=not_exhaustive\n";
    } else if (s.vcl_overflow) {
        s.until([&] { return s.d.decoder_error != 0; },
                "oversized VCL was concealed by larger encoded AU admission");
        check(s.d.decoder_error == 14 && s.d.native_sample_count == 0,
              "VCL overflow did not fail explicitly before native reconstruction");
        std::cout << "VCL_REJECT error=14 encoded_AU_within_32768=1 "
                     "RBSP_over_8192=1 native_writes=0 DPB_display=0\n";
    } else if (s.bad_tail) {
        s.until([&] { return s.d.decoder_error != 0; },
                "corrupted RBSP alignment did not abort after reconstruction");
        check(s.d.decoder_error == 15 && s.d.native_sample_count == coded_bytes &&
              s.d.decoder_mb == (coded_w / 16) * (coded_h / 16),
              "tail negative did not reach error15 after all coded native writes");
        std::cout << "TAIL_REJECT error=15 native_writes=" << s.d.native_sample_count
                  << " DPB/source/display_completion=0\n";
    } else {
    s.until([&] { return s.pps_mismatch ? s.d.parameter_id_mismatch :
                                        (s.d.parser_errors & 2) != 0; },
            "negative PPS did not reach parameter validation");
    if (s.pps_mismatch) check((s.d.parser_errors & 6) == 0,
                             "identity negative used malformed SPS/PPS instead");
    check(s.d.controller_header_error, "PPS parser error/identity mismatch did not reach controller abort");
    }
    s.until([&] { return s.d.observed_codec_error_committed && s.d.idle; },
            "decoder failure did not reach fenced MVPS error commit");
    ring::VideoPresentation failed;
    const unsigned expected_error = s.expected_negative_error();
    check(ring::decodeVideoPresentation(s.status(), epoch1, nonce1, failed) &&
          failed.error && !failed.active && !failed.has_frame && !failed.has_audio_clock &&
          failed.error_code == expected_error && failed.presentation_count == 0 &&
          failed.audio_samples_consumed == 0 && failed.seq == invalid_au.seq &&
          failed.pts == invalid_au.pts &&
          failed.timebase_num == invalid_au.timebase_num &&
          failed.timebase_den == invalid_au.timebase_den,
          "decoder error lost its AU identity or invented a display/audio ACK");
    s.run(kSysPeriod * 100000);
    check(s.d.decoder_error && !s.d.native_reference_ready && !s.d.has_frame &&
          !s.d.swap_pending && s.d.count == 0 &&
          s.d.frames_done == frames_before_flush,
          "rejected AU produced a reference or display");
    std::cout << "CODEC_ERROR_PASS code=" << failed.error_code
              << " fenced_MVPS=1 failed_AU_identity=1 display_audio_ACK=0\n";
    if (s.fault_recovery) {
        const auto failed_words = s.status();
        const uint64_t failed_commit = s.load(commit);
        const auto read_before_reset = s.d.stream_read_count;
        check(s.d.observed_session == epoch1 && s.d.observed_nonce == nonce1 &&
              ((s.load(ring::kErrPhys / 8) >> ring::kErrResetEpochBit) & 1) == ctrl_epoch,
              "committed error prematurely released the actual reader identity");
        s.until([&] { return s.responses.empty() && s.d.DDRAM_RD && !s.d.DDRAM_BUSY &&
                            s.d.DDRAM_ADDR == ring::kCtrlPhys / 8; },
                "reset test never reached a real CTRL read offer");
        s.hold_responses = true;
        s.until([&] { return !s.responses.empty(); }, "CTRL read was not physically accepted");
        const auto responses_before_reset = s.ddr_read_beats_returned;
        s.fault_reset_in_progress = true;
        ctrl_epoch = !ctrl_epoch;
        publish();
        s.run(kSysPeriod * 64);
        check(s.d.observed_nonce == nonce1 && s.d.observed_session == epoch1 &&
              s.d.stream_read_count == read_before_reset && s.load(commit) == failed_commit &&
              s.ddr_read_beats_returned == responses_before_reset && !s.responses.empty() &&
              ((s.load(ring::kErrPhys / 8) >> ring::kErrResetEpochBit) & 1) != ctrl_epoch,
              "unretired CTRL response acknowledged reset or released failed-session identity");
        s.hold_responses = false;
        s.until([&] {
            return !s.d.stream_reset_pending && s.d.stream_idle && s.d.idle &&
                   s.d.stream_transport_quiescent && s.d.generation_idle &&
                   s.d.observed_nonce == 0 && s.d.observed_session == 0 &&
                   s.d.stream_read_count == producer && s.load(commit) == 0 &&
                   ((s.load(ring::kErrPhys / 8) >> ring::kErrResetEpochBit) & 1) == ctrl_epoch &&
                   !((s.load(ring::kStat6Phys / 8) >>
                      (ring::kStat6StateFlagsShift + ring::kStat6FatalFlagBit)) & 1) &&
                   s.responses.empty();
        }, "committed-error CTRL reset did not fence real transaction/identity retirement");
        check(s.ddr_read_beats_accepted == s.ddr_read_beats_returned &&
              !s.d.native_reference_ready && !s.d.has_frame && !s.d.swap_pending &&
              !s.d.observed_codec_error_committed && !s.d.observed_codec_error_code &&
              !s.d.filter_busy && !s.d.filter_error,
              "error/reset retained a response, reference, filter fault or committed status");
        for (unsigned client = 0; client < 2; ++client)
            check(s.native_lifetime_requests[client] == s.native_lifetime_responses[client],
                  "reset hid an accepted native read instead of retiring it");
        s.fault_reset_in_progress = false;
        s.negative_guard = false;
        const uint64_t fresh_nonce = nonce1 + 0x1000, fresh_session = epoch1 + 0x1000;
        append(ring::Event::Probe, fresh_nonce, mailbox_abi::kFpgaVideoLayoutId, {});
        s.until([&] {
            for (unsigned i = 0; i < capability_words.size(); ++i)
                capability_words[i] = s.load(mailbox_abi::kVideoCapsAddr / 8 + i);
            return ring::decodeVideoCapabilities(capability_words, fresh_nonce, capabilities) &&
                   s.d.observed_nonce == fresh_nonce;
        }, "fresh recovery Probe did not physically commit its own capability nonce");
        check(capabilities.features == 0 && capabilities.max_au_bytes == 8192,
              "recovery capability changed the unqualified 8KiB profile");
        append(ring::Event::Begin, fresh_session, 0, {});
        s.until([&] { return s.d.stream_read_count == producer && s.d.stream_idle; },
                "fresh recovery Begin did not retire");
        ring::VideoPresentation stale;
        check(!ring::decodeVideoPresentation(failed_words, fresh_session, fresh_nonce, stale),
              "old committed failure was accepted as fresh-session feedback");
        const auto recovered_bytes = read_bytes(directory + "/au0.264");
        ring::AccessUnit recovered = invalid_au;
        recovered.session_id = fresh_session;
        recovered.annexb = recovered_bytes.data();
        recovered.len = recovered_bytes.size();
        const auto recovered_metadata = ring::encodeAccessUnitMetadata(recovered);
        Bytes recovered_payload(recovered_metadata.begin(), recovered_metadata.end());
        recovered_payload.insert(recovered_payload.end(), recovered_bytes.begin(), recovered_bytes.end());
        append(ring::Event::AccessUnit, fresh_session, 0, recovered_payload);
        append(ring::Event::Drain, fresh_session, 0, {});
        s.vsync_enabled = true;
        s.until([&] { return s.d.count == 1 && s.d.idle && s.d.stream_idle &&
                            s.d.stream_read_count == producer; },
                "fresh session did not decode/display/drain after committed-error reset");
        ring::VideoPresentation fresh;
        check(ring::decodeVideoPresentation(s.status(), fresh_session, fresh_nonce, fresh) &&
              fresh.active && fresh.has_frame && !fresh.error && !fresh.has_audio_clock &&
              fresh.audio_samples_consumed == 0 && fresh.presentation_count == 1 &&
              fresh.seq == 0 && fresh.pts == timing[0].pts &&
              fresh.timebase_num == timing[0].numerator &&
              fresh.timebase_den == timing[0].denominator &&
              fresh.publication != failed.publication &&
              s.d.frames_done == frames_before_flush + 1 &&
              !s.d.inject_filter_metadata && !s.d.inject_active_filter_fault &&
              s.d.injected_filter_metadata_accepts == (s.filter_metadata_fault ? 1u : 0u) &&
              s.d.active_filter_faults == (s.active_filter_fault ? 1u : 0u),
              "fresh recovery reused stale identity/publication, reinjected a fault or invented an ACK");
        const uint32_t recovered_base = s.d.published_bank ? 0x30080000 : 0x30000000;
        const unsigned plane_bases[] = {0, 76800, 96000};
        const unsigned coded_bases[] = {0, coded_w * coded_h, coded_w * coded_h * 5 / 4};
        Bytes recovered_visible;
        for (unsigned plane = 0; plane < 3; ++plane) {
            const unsigned divisor = plane ? 2 : 1, stride = 320 / divisor;
            for (unsigned y = 0; y < 240 / divisor; ++y)
                for (unsigned x = 0; x < stride; ++x) {
                    const uint32_t address = recovered_base + plane_bases[plane] + y * stride + x;
                    const auto value = uint8_t(s.load(address / 8) >> (8 * (address & 7)));
                    const auto expected = x < coded_w / divisor && y < coded_h / divisor ?
                        coded_reference[coded_bases[plane] + y * (coded_w / divisor) + x] :
                        uint8_t(plane ? 128 : 16);
                    check(value == expected, "fresh recovery coded/padding bytes differ from frozen oracle");
                    if (x >= crop_l / divisor && x < (coded_w - crop_r) / divisor &&
                        y >= crop_t / divisor && y < (coded_h - crop_b) / divisor)
                        recovered_visible.push_back(value);
                }
        }
        check(recovered_visible.size() == visible_bytes &&
              std::equal(recovered_visible.begin(), recovered_visible.end(), reference.begin()),
              "fresh recovery visible I420 differs from the original first frame");
        std::ofstream recovered_output(actual_path + ".recovery.i420", std::ios::binary);
        recovered_output.write(reinterpret_cast<const char*>(recovered_visible.data()), recovered_visible.size());
        check(bool(recovered_output), "cannot preserve recovered actual I420");
        s.until([&] { return s.d.stream_transport_quiescent && s.responses.empty(); },
                "fresh recovery left an accepted DDR command outstanding");
        check(s.ddr_read_beats_accepted == s.ddr_read_beats_returned,
              "recovery lost or fabricated a DDR response");
        std::cout << "FAULT_RECOVERY_PASS error=" << expected_error
                  << " fresh_physical_nonce=1 fresh_session=1 original_pts=" << fresh.pts
                  << " coded_bytes=" << coded_bytes << " visible_bytes=" << visible_bytes
                  << " accepted_DDR_responses=" << s.ddr_read_beats_returned
                  << " stale_ACKs=0 injected_reference_pixels=0\n";
    }
    std::cout << "PASS " << FULL_AU_FRAMES
              << " actual DDR-ring AUs -> decoder -> native I420 -> safe display -> MVPS; "
              << FULL_AU_FRAMES * visible_bytes << " visible bytes and " << FULL_AU_FRAMES * coded_bytes
              << " coded bytes exact ordinary ffmpeg, fixed strides/plane bases/padding, "
                 "Pause replay, held metadata, Drain fence and actual Flush reference/display "
                 "invalidation; decoder negative publishes only a fenced error; no glass claim\n";
}

static void copy_contract(Sim& s) {
    s.image = 4;
    s.d.nonce = nonce1;
    s.until([&] { return s.d.frame_ready; }, "copy contract initial invalidation");
    for (unsigned stress = 0; stress < 2; ++stress) {
        for (unsigned height : {240u, 224u}) {
            s.d.clear = 1; s.run(kSysPeriod); s.d.clear = 0;
            s.until([&] { return s.d.frame_ready; }, "copy contract clear retirement");
            s.ram_stress = stress; s.ddr_stress = stress;
            s.ram_random = 0x5754c111;
            s.ddr_random = 0x5754d00d;
            s.ram_min_gap = UINT64_MAX; s.ram_last_accept = 0;
            s.d.test_height = height; s.d.test_bottom = height == 224 ? 12 : 0;
            s.d.test_native_bank = height == 224;
            s.vsync_enabled = false;
            const auto requests = s.ram_accepted, returns = s.ram_returned;
            const auto paints = s.painter_returned;
            s.begin_frame(epoch1 + stress, height, 1001 * height);
            const auto start = s.time / kSysPeriod;
            s.until([&] { return s.d.publish_state == 7; }, "copy contract final-word fence");
            const auto cycles = s.time / kSysPeriod - start;
            s.until([&] { return s.d.swap_pending; }, "copy contract readback/swap");
            check(s.ram_accepted - requests == 320 * height * 3 / 2 &&
                  s.ram_returned - returns == s.ram_accepted - requests,
                  "coded reads missing, repeated or issued for allocation padding");
            const uint32_t bank_base = 0x30000000 + unsigned(s.d.published_bank) * 0x80000;
            for (uint32_t i = 0; i < 115200; ++i) {
                const unsigned plane = i < 76800 ? 0 : i < 96000 ? 1 : 2;
                const unsigned offset = i - (plane == 0 ? 0 : plane == 1 ? 76800 : 96000);
                const bool padding = offset / (plane ? 160 : 320) >= (plane ? height / 2 : height);
                const uint8_t expected = padding ? (plane ? 128 : 16) :
                    s.native(i + unsigned(s.d.test_native_bank) * 115200);
                check(uint8_t(s.load((bank_base + i) / 8) >> ((i & 7) * 8)) == expected,
                      "copy contract byte/plane/padding/bank/order mismatch");
            }
            check(!s.d.count && !s.load(commit), "copy fence fabricated presentation");
            s.vsync_enabled = true;
            s.until([&] { return s.d.idle && s.d.count == 1; }, "copy contract display/status ACK");
            check(s.d.active_coded_height == height &&
                  s.d.active_visible_height == (height == 224 ? 212 : 240),
                  "copy contract geometry did not survive actual display ACK");
            std::cout << "COPY_CONTRACT height=" << height << " visible=" << (height == 224 ? 212 : 240)
                      << " stress=" << stress << " native_bank=" << unsigned(s.d.test_native_bank)
                      << " cycles=" << cycles << " requests=" << s.ram_accepted - requests
                      << " responses=" << s.ram_returned - returns
                      << " min_request_gap=" << s.ram_min_gap
                      << " painter_responses=" << s.painter_returned - paints
                      << " sys_hz=" << kSysHz << " latency_min=2 bytes_checked=115200\n";
        }
    }
    s.ram_stress = false;
    for (unsigned reset = 0; reset < 3; ++reset) {
        s.d.clear = 1; s.run(kSysPeriod); s.d.clear = 0;
        s.until([&] { return s.d.frame_ready; }, "delayed read cancel setup");
        s.begin_frame(epoch1 + 2, reset, 0);
        s.until([&] { return s.ram_accepted != s.ram_returned; }, "no accepted native read to cancel");
        s.hold_ram = true;
        if (reset == 2) { s.d.test_codec_error = 1; s.d.test_codec_error_code = 8; }
        else if (reset) s.d.reset = 1; else s.d.clear = 1;
        s.run(kSysPeriod); s.d.reset = s.d.clear = 0;
        s.run(40 * kSysPeriod);
        check(!s.d.idle && !s.d.frame_ready && !s.d.count,
              "cancel abandoned the outstanding native response owner");
        s.hold_ram = false;
        if (reset == 2) {
            s.until([&] { return s.d.observed_codec_error_committed && s.d.idle; },
                    "codec error abandoned delayed native ownership");
            ring::VideoPresentation p;
            check(ring::decodeVideoPresentation(s.status(), epoch1 + 2, nonce1, p) &&
                  p.error && p.error_code == 8 && !p.has_frame && !p.presentation_count,
                  "codec error8 identity/status lost across native drain");
            s.d.test_codec_error = 0;
            s.d.clear = 1; s.run(kSysPeriod); s.d.clear = 0;
        }
        s.until([&] { return s.d.frame_ready; }, "delayed native response failed to drain after cancel");
        check(!s.d.count && !s.load(commit) && !s.d.has_frame,
              "cancelled native data committed across the epoch fence");
    }
    s.begin_frame(epoch1 + 3, 0, 0);
    s.corrupt_copy_fence = true;
    s.until([&] { return s.d.error; }, "corrupt final DDR word was accepted");
    check(!s.d.count && !s.d.has_frame && !s.load(commit), "bad DDR readback was presented");
    s.corrupt_copy_fence = false;
    s.d.clear = 1; s.run(kSysPeriod); s.d.clear = 0;
    s.until([&] { return s.d.frame_ready; }, "readback error failed to clear");
    s.d.test_width = 319;
    s.begin_frame(epoch1 + 3, 1, 1001);
    s.until([&] { return s.d.error; }, "invalid coded geometry was accepted");
    check(!s.d.count && !s.d.has_frame, "invalid coded geometry fabricated a frame");
    s.d.clear = 1; s.run(kSysPeriod); s.d.clear = 0;
    s.until([&] { return s.d.frame_ready; }, "geometry error failed to retire");
    std::cout << "PASS copy contract latency2/II2, delayed cancel/reset/error8, final readback/geometry errors, both banks, painter poisoning\n";
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        Sim s;
        s.d.clk = s.d.clk_ddr = 1;
        s.d.reset = 1;
        s.d.clear = 0;
        s.d.inject_filter_metadata = 0;
        s.d.inject_active_filter_fault = 0;
        s.d.nonce = 0;
        s.d.frame_valid = s.d.mem_valid = s.d.vsync = 0;
        s.d.sample_x = s.d.sample_y = 0;
        s.d.test_width = 320;
        s.d.test_height = 240;
        s.d.test_left = s.d.test_right = s.d.test_top = s.d.test_bottom = 0;
        s.d.mem_data = 0;
        s.d.mem_ready = 0;
        s.d.test_native_bank = 0;
        s.d.test_codec_error = s.d.test_codec_error_code = 0;
        s.d.DDRAM_BUSY = s.d.DDRAM_DOUT_READY = 0;
        s.d.DDRAM_DOUT = 0;
        s.memory[commit] = UINT64_C(0x123456784d565043);
        s.memory[0x300ff000 / 8] = UINT64_C(0x80000015504c584b);
        s.run(kSysPeriod * 40);
        s.d.reset = 0;
        check(s.d.clock_sys_hz == kSysHz && s.d.clock_native_divisor == kNativeDivisor &&
              s.d.clock_native_den == kNativeDen &&
              kBaseHz / kDdrPeriod == 90000000,
              "RTL selectors, simulated clocks and metric units disagree");
        if (FULL_AU) {
            check(argc >= 3 && argc <= 6,
                  "full-AU mode requires fixture directory, output path and optional VSync cycles");
            if (argc >= 4) {
                size_t consumed = 0;
                s.vsync_period = std::stoull(argv[3], &consumed);
                check(consumed == std::string(argv[3]).size() &&
                      s.vsync_period > 0 && s.vsync_period <= 1000000,
                      "VSync cycle interval outside bounded simulation range");
            }
            if (argc >= 5) {
                const std::string mode = argv[4];
                check(mode == "truncated" || mode == "sps-mismatch" || mode == "bad-tail" ||
                      mode == "vcl-overflow" || mode == "filter-metadata" || mode == "active-filter",
                      "unsupported decoder negative mode");
                s.pps_mismatch = mode == "sps-mismatch";
                s.bad_tail = mode == "bad-tail";
                s.vcl_overflow = mode == "vcl-overflow";
                s.filter_metadata_fault = mode == "filter-metadata";
                s.active_filter_fault = mode == "active-filter";
            }
            if (argc == 6) {
                const std::string mode = argv[5];
                check(mode == "ingress-seek" || mode == "large-au" || mode == "fault-recovery",
                      "unsupported ingress regression mode");
                s.ingress_seek = mode == "ingress-seek";
                s.large_au = mode == "large-au";
                s.fault_recovery = mode == "fault-recovery";
            }
            if (FULL_AU_NATIVE_BEAM)
                std::cout << "SIM_NATIVE sys_cycles=" << kNativeFrameTicks / kSysPeriod
                          << " SYS_Hz=" << kSysHz << " DDR_Hz=90000000 base_Hz=" << kBaseHz
                          << " scandouble=" << FULL_AU_SCANDOUBLE;
            else
                std::cout << "SIM_VSYNC sys_cycles=" << s.vsync_period;
            std::cout
                      << " timing=" << (FULL_AU_ORIGINAL_TIMING ? "original" : "synthetic-test-only")
                      << " negative=" << (s.active_filter_fault ? "injected-active-filter-state" :
                                         s.filter_metadata_fault ? "injected-filter-metadata" :
                                         s.vcl_overflow ? "vcl-overflow" : s.bad_tail ? "bad-tail" :
                                         s.pps_mismatch ? "sps-mismatch" : "truncated")
                      << " clock/rate/hardware qualification=none\n";
            decoded_access_units(s, argv[1], argv[2]);
            return 0;
        }
        s.d.nonce = nonce1;
        if (argc == 2 && std::string(argv[1]) == "copy-contract") {
            copy_contract(s);
            return 0;
        }
        s.until([&] { return s.d.frame_ready; }, "initial nonce invalidation timeout");
        check(s.load(commit) == 0 && !s.d.has_frame && s.d.count == 0,
              "stale boot frame/feedback accepted");
        s.begin_frame(epoch1, 7, -12345);
        s.until([&] { return s.d.swap_pending; }, "copied picture did not reach presenter");
        check(s.d.count == 0 && s.load(commit) == 0, "copy/reconstruction counted as display");
        for (uint32_t i = 0; i < 115200; ++i) {
            const auto got = uint8_t(s.load((0x30080000 + i) / 8) >> (8 * (i & 7)));
            check(got == s.native(i), "native I420 DDR publication mismatch");
        }
        s.vsync_enabled = true;
        s.until([&] { return s.d.idle && s.d.count == 1; }, "safe-boundary publication timeout");
        ring::VideoPresentation p;
        check(ring::decodeVideoPresentation(s.status(), epoch1, nonce1, p),
              "authoritative host MVPS decoder rejected publication");
        check(p.has_frame && p.active && !p.has_audio_clock && p.audio_samples_consumed == 0 &&
              p.seq == 7 && p.pts == -12345 && p.timebase_num == 1001 &&
              p.timebase_den == 24000 && p.presentation_count == 1,
              "presentation metadata mismatch");
        for (const auto point : std::array<std::pair<unsigned,unsigned>,4>{
                 {{0,0}, {319,0}, {0,239}, {319,239}}}) {
            const auto address = point.second * 320 + point.first;
            s.check_pixel(point.first, point.second, s.native(address),
                          s.native(76800), s.native(96000));
        }
        s.d.sample_x = s.d.sample_y = 0;
        check(s.status_writes.size() >= 10, "missing atomic publication writes");
        auto n = s.status_writes.size();
        check(s.status_writes[n-10].first == commit && s.status_writes[n-10].second == 0,
              "MVPS commit not invalidated before body");
        for (unsigned i = 0; i < 8; ++i)
            check(s.status_writes[n-9+i].first == feedback + i, "MVPS body order mismatch");
        check(s.status_writes.back().first == commit &&
              uint32_t(s.status_writes.back().second) == mailbox_abi::kVideoPresentationCommitMagic,
              "fresh MVPC commit was not last");
        const auto publication = p.publication;
        s.run(128 * kSysPeriod * 8);
        check(s.d.count == 1 && uint32_t(s.load(commit) >> 32) == publication,
              "timer/vsync falsely advanced displayed AU count");
        check(!ring::decodeVideoPresentation(s.status(), epoch1 + 1, nonce1, p),
              "stale epoch accepted");
        s.d.nonce = nonce1 + 1;
        s.until([&] { return s.d.frame_ready; }, "fresh probe invalidation timeout");
        check(s.load(commit) == 0, "new probe retained prior MVPS");
        s.run(128 * kSysPeriod * 4);
        check(s.d.count == 1 && s.load(commit) == 0, "last frame republished for fresh nonce");
        s.image = 1;
        s.begin_frame(epoch1 + 1, 0, 0);
        s.until([&] { return s.d.idle && s.d.count == 2; }, "second bank publication timeout");
        check(ring::decodeVideoPresentation(s.status(), epoch1 + 1, nonce1 + 1, p) &&
              p.seq == 0 && p.presentation_count == 2, "new epoch publication mismatch");
        s.vsync_enabled = false;
        s.begin_frame(epoch1 + 1, 1, 1001);
        s.until([&] { return s.d.swap_pending && s.d.pending_ready; },
                "seek test has no ready pending swap");
        s.run(kSysPeriod * 4);
        s.until([&] { return !s.responses.empty(); }, "seek has no accepted display read");
        const auto frames_before_clear = s.d.frames_done;
        s.hold_responses = true;
        s.d.clear = 1;
        s.run(104);
        s.d.clear = 0;
        s.run(5200);
        check(!s.d.idle && !s.d.generation_idle && !s.d.has_frame && !s.d.swap_pending,
              "seek discarded accepted display ownership or retained visible picture");
        s.hold_responses = false;
        s.vsync_enabled = true;
        s.until([&] { return s.d.idle && s.load(commit) == 0; },
                "seek did not retire/invalidate pending presentation");
        s.run(128 * kSysPeriod * 4);
        check(s.d.frames_done == frames_before_clear && !s.d.has_frame &&
              !s.d.swap_pending && s.d.count == 0,
              "cancelled old-epoch picture reached display after clear");

        s.vsync_enabled = false;
        s.begin_frame(epoch1 + 2, 0, 0);
        s.until([&] { return s.d.swap_pending && s.d.pending_ready; },
                "new generation did not acquire display ownership");
        s.run(kSysPeriod * 4);
        s.d.clear = 1;
        s.force_vsync = true;
        s.run(kSysPeriod);
        s.d.clear = 0;
        s.force_vsync = false;
        s.vsync_enabled = true;
        s.until([&] { return s.d.idle && s.load(commit) == 0; },
                "coincident clear/vsync did not retire");
        s.run(128 * kSysPeriod * 4);
        check(s.d.frames_done == frames_before_clear && !s.d.has_frame &&
              !s.d.swap_pending && s.d.count == 0,
              "clear lost priority over coincident safe-boundary swap");

        s.begin_frame(epoch1 + 2, 1, 1001);
        s.until([&] { return s.d.publish_state == 10; }, "no start-toggle in flight");
        check(!s.d.swap_pending, "start-toggle cancellation missed its CDC window");
        s.d.clear = 1;
        s.run(kSysPeriod);
        s.d.clear = 0;
        s.run(kSysPeriod);
        s.d.clear = 1;
        s.run(kSysPeriod);
        s.d.clear = 0;
        s.until([&] { return s.d.idle && s.load(commit) == 0; },
                "repeated clear did not retire in-flight start toggle");
        s.run(128 * kSysPeriod * 4);
        check(s.d.frames_done == frames_before_clear && !s.d.has_frame &&
              !s.d.swap_pending && s.d.count == 0,
              "late start/swap toggle resurrected cancelled picture");

        s.image = 2;
        s.begin_frame(epoch1 + 2, 2, 2002);
        s.until([&] { return s.d.idle && s.d.count == 1; },
                "fresh picture failed after functional cancellation");
        s.check_pixel(0, 0, 16, 128, 128);
        s.run(128 * kSysPeriod * 4);
        check(s.d.frames_done == frames_before_clear + 1 &&
              ring::decodeVideoPresentation(s.status(), epoch1 + 2, nonce1 + 1, p) &&
              p.seq == 2 && p.presentation_count == 1,
              "fresh generation inherited old display/cached pixels/feedback");
        const auto commit_before_same_epoch_clear = s.load(commit);

        s.until([&] { return s.d.DDRAM_WE; }, "no offered display write to cancel");
        s.watched_address = s.d.DDRAM_ADDR;
        s.watched_data = s.d.DDRAM_DIN;
        s.watch_write = true;
        s.force_busy = true;
        s.d.clear = 1;
        s.run(kSysPeriod);
        s.d.clear = 0;
        s.run(5200);
        check(!s.d.idle && !s.d.generation_idle && s.watched_writes == 0,
              "generation clear abandoned a held display write");
        s.force_busy = false;
        s.until([&] { return s.d.idle && s.load(commit) == 0; },
                "held display write failed to retire after clear");
        check(s.watched_writes == 1, "held display write was lost or repeated");
        s.watch_write = false;

        s.image = 3;
        s.begin_frame(epoch1 + 2, 0, 5005);
        s.until([&] { return s.d.idle && s.d.count == 1; },
                "same-epoch publication did not recover after clear");
        check(ring::decodeVideoPresentation(s.status(), epoch1 + 2, nonce1 + 1, p) &&
              p.seq == 0 && p.pts == 5005 && p.presentation_count == 1,
              "same-epoch post-clear metadata is not fresh");
        check(s.load(commit) != commit_before_same_epoch_clear,
              "MVPC token reused across clear permits a torn same-epoch snapshot");

        s.force_busy = true;
        s.begin_frame(epoch1 + 2, 3, 3003);
        s.until([&] { return s.d.copy_word_pending; }, "no publisher write to cancel");
        s.d.clear = 1;
        s.run(kSysPeriod);
        s.d.clear = 0;
        s.run(5200);
        check(!s.d.idle && !s.d.has_frame, "clear abandoned publisher DDR ownership");
        s.force_busy = false;
        s.until([&] { return s.d.frame_ready && s.load(commit) == 0; },
                "publisher write failed to retire after functional clear");
        check(s.d.count == 0 && !s.d.has_frame && !s.d.swap_pending,
              "partial copy was published after functional clear");

        s.force_busy = true;
        s.begin_frame(epoch1 + 2, 0, 0);
        s.run(5200);
        s.d.reset = 1;
        s.d.nonce = 0;
        s.run(1040);
        s.d.reset = 0;
        s.force_busy = false;
        s.d.nonce = nonce1 + 2;
        s.until([&] { return s.d.frame_ready && s.load(commit) == 0; },
                "reset lost accepted DDR transaction retirement");
        s.run(128 * kSysPeriod * 4);
        check(s.d.count == 0 && !s.d.has_frame && s.load(commit) == 0,
              "reset fabricated an initial/last frame");
        for (unsigned level = 2; level < 4; ++level) {
            s.image = level;
            s.begin_frame(epoch1 + 3, level - 2, int64_t(level - 2) * 1001);
            s.until([&] { return s.d.idle && s.d.count == level - 1; },
                    "limited-range endpoint frame did not present");
            s.check_pixel(0, 0, s.native(0), 128, 128);
            check(s.d.pixel_rgb == (level == 2 ? 0u : 0xffffffu),
                  "limited-range black/white endpoints were not preserved");
        }
        check(!s.d.error, "publisher error");
        s.image = 0;
        s.d.test_width = 288; s.d.test_height = 208;
        s.d.test_left = 2; s.d.test_right = 6;
        s.d.test_top = 8; s.d.test_bottom = 4;
        s.vsync_enabled = false;
        s.begin_frame(epoch1 + 3, 2, 2002);
        s.until([&] { return s.d.swap_pending && s.d.pending_ready; },
                "cropped pending bank did not prefetch");
        s.d.sample_x = 20; s.d.sample_y = 22;
        const auto before_crop = s.d.frames_done;
        s.vsync_enabled = true;
        s.until([&] { return s.d.frames_done == before_crop + 1; },
                "cropped bank never committed");
        s.run(kSysPeriod * 4);
        check(s.d.pixel_de &&
              s.d.pixel_rgb == Sim::rgb601(s.native(8 * 320 + 2), s.native(76800), s.native(96000)),
              "first cropped pixel was not prefetched/aligned at actual swap");
        s.until([&] { return s.d.idle && s.d.count == 3; },
                "cropped bank did not publish");
        check(s.d.active_coded_width == 288 && s.d.active_coded_height == 208 &&
              s.d.active_visible_width == 280 && s.d.active_visible_height == 196,
              "smaller coded/cropped geometry did not commit atomically");
        s.check_pixel(299, 217, s.native(203 * 320 + 281), s.native(76800), s.native(96000));
        check(s.d.pixel_de, "bottom-right cropped pixel excluded from DE");
        for (const auto point : {std::pair<unsigned, unsigned>{19, 22}, {300, 22},
                                 {20, 21}, {20, 218}}) {
            s.check_pixel(point.first, point.second, 16, 128, 128);
            check(!s.d.pixel_de, "allocation padding leaked into cropped content DE");
        }
        s.image = 4;
        s.d.test_width = 320; s.d.test_height = 240;
        s.d.test_left = s.d.test_right = s.d.test_top = s.d.test_bottom = 0;
        s.begin_frame(epoch1 + 3, 3, 3003);
        s.until([&] { return s.d.idle && s.d.count == 4; },
                "textured return-alignment picture did not publish");
        s.check_return_stream();
        std::cout << "PASS native I420 -> CDC DDR -> real frame-store safe swap -> MVPS; "
                     "115200 bytes, stalls, seek/reset retirement, stale epoch/nonce, "
                     "atomic commit, limited BT601 RGB corners, runtime crop/top-prefill/DE, "
                     "no timer/audio claims\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL publication composition: " << e.what() << '\n';
        return 1;
    }
}
