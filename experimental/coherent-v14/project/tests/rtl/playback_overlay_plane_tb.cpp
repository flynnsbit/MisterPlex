#include "Vplayback_overlay_plane.h"
#include "fpga_playback_overlay.hpp"
#include "verilated.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <vector>

namespace ui = misterplex::fpga_overlay;
#ifndef OVERLAY_NATIVE_DIVISOR
#define OVERLAY_NATIVE_DIVISOR 1
#endif
static_assert(OVERLAY_NATIVE_DIVISOR == 1 || OVERLAY_NATIVE_DIVISOR == 6);
static unsigned checks = 0;
#define REQUIRE(x) do { ++checks; if (!(x)) { \
    std::fprintf(stderr, "overlay:%d: %s\n", __LINE__, #x); std::exit(1); } } while (0)

class Bench {
public:
    Vplayback_overlay_plane dut;
    ui::Packet shown{};
    bool expected_visible = false;
    bool previous_valid = false;
    uint32_t previous_rgb = 0;
    bool previous_hs = false, previous_vs = false, previous_de = false;
    std::vector<uint32_t> reference;

    Bench() : reference(320 * 240) {
        for (size_t i = 0; i < reference.size(); ++i)
            reference[i] = uint32_t(i * 197 + 0x17425c) & 0xffffff;
        dut.reset = 1;
        for (int i = 0; i != 8; ++i) { sys(); pixel(false); }
        dut.reset = 0;
        previous_valid = false;
        blank(8);
    }
    void sys() {
        dut.clk_sys = 0; dut.eval();
        dut.clk_sys = 1; dut.eval();
    }
    void pixel(bool ce, uint32_t rgb = 0, bool hs = false, bool vs = false,
               bool de = false, uint32_t expected = 0) {
        for (unsigned cycle = 0; cycle < OVERLAY_NATIVE_DIVISOR; ++cycle)
            pixelClock(cycle == 0 && ce, rgb, hs, vs, de, expected);
    }
    void pixelClock(bool ce, uint32_t rgb, bool hs, bool vs, bool de, uint32_t expected) {
        // Same SYS/pixel fabric clock; native pixels arrive on sparse CE.
        // Standalone sys() calls retain the existing stopped-pixel-clock cases.
        dut.clk_sys = 0;
        dut.clk_pix = 0;
        dut.ce_in = ce; dut.r_in = rgb >> 16; dut.g_in = rgb >> 8; dut.b_in = rgb;
        dut.hs_in = hs; dut.vs_in = vs; dut.de_in = de; dut.eval();
        dut.clk_sys = 1;
        dut.clk_pix = 1; dut.eval();
        if (!dut.reset) {
            REQUIRE(bool(dut.ce_out) == previous_valid);
            if (previous_valid) {
                const uint32_t got = (uint32_t(dut.r_out) << 16) |
                                     (uint32_t(dut.g_out) << 8) | dut.b_out;
                if (got != previous_rgb)
                    std::fprintf(stderr, "got %06x expected %06x\n", got, previous_rgb);
                REQUIRE(got == previous_rgb);
                REQUIRE(bool(dut.hs_out) == previous_hs);
                REQUIRE(bool(dut.vs_out) == previous_vs);
                REQUIRE(bool(dut.de_out) == previous_de);
            }
        }
        previous_valid = ce;
        previous_rgb = expected;
        previous_hs = hs; previous_vs = vs; previous_de = de;
    }
    void blank(unsigned n = 8) {
        for (unsigned i = 0; i < n; ++i) pixel(true);
    }
    void frameEdge() {
        blank();
        pixel(true, 0, false, true);
        blank();
    }
    void session(uint64_t epoch, uint64_t nonce, bool active = true) {
        dut.session_epoch = epoch; dut.session_nonce = nonce; dut.session_active = active;
        blank();
        frameEdge();
        blank();
        expected_visible = false;
        REQUIRE(!dut.visible);
    }
    void send(const ui::Packet& packet, size_t length = ui::kPacketBytes,
              int corrupt_address = -1, unsigned index = 6) {
        dut.ioctl_index = index; dut.ioctl_download = 1; dut.ioctl_wr = 0; sys();
        for (size_t i = 0; i < length; ++i) {
            dut.ioctl_wr = 1;
            dut.ioctl_addr = i + (int(i) == corrupt_address ? 1 : 0);
            dut.ioctl_dout = packet[i % packet.size()];
            sys();
            dut.ioctl_wr = 0; sys();
        }
        dut.ioctl_download = 0; sys(); sys();
    }
    unsigned sendHonoringWait(const ui::Packet& packet, bool allow_wait = true,
                             const std::function<void(size_t)>& before_byte = {}) {
        unsigned waited = 0;
        dut.ioctl_index = 6; dut.ioctl_download = 1; dut.ioctl_wr = 0; sys();
        for (size_t i = 0; i < packet.size(); ++i) {
            if (before_byte) before_byte(i);
            dut.eval();
            unsigned stalled = 0;
            while (dut.ioctl_wait) {
                // Inactive/invalid traffic must drain even with the pixel clock
                // completely stopped. Valid traffic may await a native VS ACK.
                REQUIRE(allow_wait);
                REQUIRE(++stalled < 128);
                ++waited;
                pixel(true, 0, false, (stalled % 32) == 16);
            }
            dut.ioctl_wr = 1; dut.ioctl_addr = i; dut.ioctl_dout = packet[i]; sys();
            dut.ioctl_wr = 0; sys();
        }
        dut.ioctl_download = 0; sys(); sys();
        return waited;
    }
    void apply(const ui::Packet& packet) {
        send(packet);
        REQUIRE(dut.accepted_sequence == ui::get32(packet.data() + 24));
        frameEdge();
        shown = packet;
        expected_visible = (packet[28] & ui::Visible) && packet[30] != 0;
        REQUIRE(bool(dut.visible) == expected_visible);
    }
    uint32_t composite(unsigned x, unsigned y, uint32_t original) const {
        if (!expected_visible) return original;
        const unsigned ox = ui::get16(shown.data() + 32);
        const unsigned oy = ui::get16(shown.data() + 34);
        if (x < ox || y < oy) return original;
        x = (x - ox) / shown[31]; y = (y - oy) / shown[31];
        if (x >= ui::get16(shown.data() + 52) || y >= 24) return original;
        const auto color = [&](unsigned offset) {
            return ui::get32(shown.data() + offset) & 0xffffff;
        };
        if ((y < 8 && (shown[28] & ui::Title)) ||
            (y >= 8 && y < 16 && (shown[28] & ui::Status))) {
            const bool ink = shown[64 + y * 32 + x / 8] & (1 << (7 - (x & 7)));
            return color(ink ? 40 : 44);
        }
        if (y >= 20 && y < 23 && (shown[28] & ui::Progress))
            return color(x < ui::get16(shown.data() + 36) ? 48 : 44);
        return original;
    }
    void raster(bool new_frame = true, const ui::Packet* mid_frame = nullptr,
                unsigned width = 320, unsigned height = 240) {
        if (new_frame) frameEdge();
        const auto immutable = reference;
        for (unsigned y = 0; y < height; ++y) {
            for (unsigned x = 0; x < width; ++x) {
                if (mid_frame && x == 120 && y == 30)
                    send(*mid_frame);
                const uint32_t rgb = reference[(y * width + x) % reference.size()];
                pixel(true, rgb, false, false, true, composite(x, y, rgb));
                if ((x % 37) == 3) {
                    // CE gaps must not advance RAM, coordinates or pixel DE.
                    pixel(false, 0xffffff, true, true, false);
                    pixel(false);
                }
            }
            pixel(true, 0x123456, true, false, false, 0x123456);
            pixel(true);
        }
        blank();
        REQUIRE(reference == immutable);
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Bench b;
    b.raster();
    b.session(7, 99);
    ui::Model model;
    model.flags &= ~ui::AutoFit;
    model.state = ui::State::Playing;
    model.title = "Actual library title";
    model.position_ms = 30000; model.duration_ms = 120000;
    model.x = 8; model.y = 204;
    auto packet = ui::encode(7, 99, 1, model);
    b.apply(packet);
    b.raster();

    // Partial, out-of-order, bad version/size/nonce/epoch/sequence never commit.
    unsigned rejected = b.dut.rejected_packets;
    for (size_t length : {size_t(0), size_t(1), size_t(63), size_t(575), size_t(577)}) {
        b.send(packet, length);
        REQUIRE(b.dut.rejected_packets == ++rejected);
        REQUIRE(b.dut.accepted_sequence == 1);
    }
    packet = ui::encode(7, 99, 2, model);
    for (unsigned offset : {0u, 4u, 6u, 8u, 16u, 38u, 43u, 52u, 54u, 56u, 60u}) {
        auto bad = packet; bad[offset] ^= 0x80;
        b.send(bad);
        REQUIRE(b.dut.rejected_packets == ++rejected);
        REQUIRE(b.dut.accepted_sequence == 1);
    }
    b.send(packet, packet.size(), 200);
    REQUIRE(b.dut.rejected_packets == ++rejected);
    b.send(ui::encode(7, 99, 1, model));
    REQUIRE(b.dut.rejected_packets == ++rejected);
    b.send(packet, packet.size(), -1, 4);
    REQUIRE(b.dut.rejected_packets == rejected);
    b.raster();

    // Pixel clock can stop throughout a transfer: old plane remains immutable.
    model.state = ui::State::Paused;
    model.title = "Paused frame still a reference";
    model.transport = "<< 30S";
    packet = ui::encode(7, 99, 2, model);
    b.raster(true, &packet);
    REQUIRE(b.dut.accepted_sequence == 2);
    for (unsigned i = 0; i != 100; ++i) b.sys();
    REQUIRE(b.dut.visible);
    b.send(ui::encode(7, 99, 3, model)); // Busy mailbox cannot clobber held RAM.
    REQUIRE(b.dut.rejected_packets == ++rejected);
    // The mid-frame transfer above must leave every remaining pixel on the old
    // plane; only the upcoming VS can expose the paused title and transport.
    b.blank();
    b.frameEdge();
    b.shown = packet;
    b.raster(false);

    model.state = ui::State::Buffering;
    model.flags = ui::Visible | ui::Status;
    model.x = 0; model.y = 0; model.scale = 2;
    b.apply(ui::encode(7, 99, 3, model));
    b.raster();
    model.state = ui::State::Error;
    model.flags = ui::Visible | ui::Title | ui::Status | ui::Progress;
    model.scale = 4; model.position_ms = INT64_MAX;
    b.apply(ui::encode(7, 99, 4, model));
    b.raster();
    model.state = ui::State::Hidden;
    b.apply(ui::encode(7, 99, 5, model));
    b.raster();

    // Epoch/nonce change with a pending update must clear, not resurrect it.
    model.state = ui::State::Paused;
    auto stale = ui::encode(7, 99, 6, model);
    b.send(stale);
    b.dut.session_active = 0;
    b.blank();
    REQUIRE(!b.dut.visible);
    b.frameEdge(); b.frameEdge();
    b.session(8, 100);
    b.send(stale);
    REQUIRE(b.dut.accepted_sequence == 0);
    b.raster();
    b.send(ui::encode(8, 99, 100, model)); // Correct epoch, stale fresh-Probe nonce.
    REQUIRE(b.dut.accepted_sequence == 0);
    b.apply(ui::encode(8, 100, 1, model));
    b.raster();
    for (const auto geometry : {std::pair<unsigned, unsigned>{320, 212},
                               {128, 192}, {212, 80}}) {
        REQUIRE(ui::fitToViewport(model, geometry.first, geometry.second));
        model.position_ms = 17000; model.duration_ms = 43000;
        const auto fitted = ui::encode(8, 100, b.dut.accepted_sequence + 1, model);
        b.apply(fitted);
        b.raster();
    }
    b.session(8, 100, false);
    b.send(ui::encode(8, 100, 2, model));
    b.raster();
    REQUIRE(!b.dut.visible);

    // AutoFit does not require ARM to guess Template DE/scandoubling or add a
    // geometry mailbox. The first complete native frame establishes placement;
    // runtime size changes move the whole UI at the following VS without a send.
    Bench measured;
    measured.session(10, 200);
    ui::Model automatic;
    automatic.state = ui::State::Paused;
    automatic.title = "Native beam not coded frame";
    automatic.transport = "<< 30S";
    automatic.position_ms = 37000; automatic.duration_ms = 93000;
    const auto automatic_packet = ui::encode(10, 200, 1, automatic);
    measured.send(automatic_packet);
    measured.frameEdge();
    measured.shown = automatic_packet;
    measured.expected_visible = false;
    REQUIRE(!measured.dut.visible);
    measured.raster(false, nullptr, 529, 240);
    auto fitMeasured = [&](unsigned width, unsigned height) {
        measured.frameEdge();
        ui::Model layout;
        REQUIRE(ui::fitToViewport(layout, width, height));
        measured.shown = automatic_packet;
        ui::put16(measured.shown.data() + 32, layout.x);
        ui::put16(measured.shown.data() + 34, layout.y);
        ui::put16(measured.shown.data() + 52, layout.width);
        measured.shown[31] = layout.scale;
        ui::put16(measured.shown.data() + 36,
                  (ui::get16(automatic_packet.data() + 36) * layout.width) >> 8);
        measured.expected_visible = true;
        REQUIRE(measured.dut.visible);
        measured.raster(false, nullptr, width, height);
    };
    fitMeasured(529, 240);
    for (const auto geometry : {std::pair<unsigned, unsigned>{529, 480},
                               {212, 320}, {128, 96}, {320, 212}}) {
        measured.frameEdge();
        measured.raster(false, nullptr, geometry.first, geometry.second);
        fitMeasured(geometry.first, geometry.second);
    }
    REQUIRE(measured.dut.accepted_sequence == 1);

    Bench flow;
    ui::Model flow_model;
    flow_model.flags &= ~ui::AutoFit;
    flow_model.state = ui::State::Paused;
    flow_model.title = "Retained plane";
    flow.session(20, 200);
    flow.apply(ui::encode(20, 200, 1, flow_model));
    unsigned flow_rejected = flow.dut.rejected_packets;
    ui::Model hidden;
    hidden.state = ui::State::Hidden;
    flow.dut.session_active = 0;
    flow.sys(); flow.sys();
    // End retains epoch/nonce, but the final late Hidden must not wedge ioctl.
    REQUIRE(flow.sendHonoringWait(ui::encode(20, 200, 2, hidden), false) == 0);
    REQUIRE(flow.dut.rejected_packets == ++flow_rejected);
    REQUIRE(flow.dut.accepted_sequence == 1);
    flow.blank(); flow.frameEdge();
    flow.expected_visible = false;
    REQUIRE(!flow.dut.visible);
    flow.raster();

    // Missing committed identity is also a reject, not a readiness dependency.
    for (const auto identity : {std::pair<uint64_t, uint64_t>{0, 210}, {21, 0}}) {
        flow.dut.session_epoch = identity.first;
        flow.dut.session_nonce = identity.second;
        flow.dut.session_active = 1;
        flow.sys(); flow.sys();
        REQUIRE(flow.sendHonoringWait(ui::encode(20, 200, 3, hidden), false) == 0);
        REQUIRE(flow.dut.rejected_packets == ++flow_rejected);
        flow.frameEdge(); flow.frameEdge();
    }
    flow.session(22, 220);
    const auto first = ui::encode(22, 220, 1, flow_model);
    flow.send(first); // Whole bank held until pixel frame boundary.
    flow_model.title = "Second plane after wait";
    const auto second = ui::encode(22, 220, 2, flow_model);
    REQUIRE(flow.sendHonoringWait(second) > 0);
    REQUIRE(flow.dut.rejected_packets == flow_rejected);
    REQUIRE(flow.dut.accepted_sequence == 2);
    flow.shown = first;
    flow.expected_visible = true;
    flow.raster(false); // Waiting sender must not overwrite the displayed bank.
    flow.frameEdge();
    flow.shown = second;
    flow.raster(false);

    // Begin's pending fence-clear is transient: the first byte waits, then the
    // entire valid packet must be received, not poisoned at download assertion.
    flow.dut.session_epoch = 23; flow.dut.session_nonce = 230;
    flow.sys();
    const auto fresh = ui::encode(23, 230, 1, flow_model);
    REQUIRE(flow.sendHonoringWait(fresh) > 0);
    REQUIRE(flow.dut.rejected_packets == flow_rejected);
    REQUIRE(flow.dut.accepted_sequence == 1);
    flow.frameEdge(); flow.shown = fresh;
    flow.raster(false);
    REQUIRE(flow.sendHonoringWait(second, false) == 0);
    REQUIRE(flow.dut.rejected_packets == ++flow_rejected);
    REQUIRE(flow.dut.accepted_sequence == 1);

    // The top qualifies session_active with !reset_pending && !video_clear.
    // That qualification can fall after the host's guard and mid-body.
    REQUIRE(flow.sendHonoringWait(ui::encode(23, 230, 2, flow_model), false,
        [&](size_t byte) { if (byte == 200) flow.dut.session_active = 0; }) == 0);
    REQUIRE(flow.dut.rejected_packets == ++flow_rejected);
    REQUIRE(flow.dut.accepted_sequence == 1);
    flow.blank(); flow.frameEdge(); flow.expected_visible = false;
    REQUIRE(!flow.dut.visible);
    flow.raster();
    flow.session(24, 240);
    REQUIRE(flow.sendHonoringWait(ui::encode(24, 240, 1, flow_model), false,
        [&](size_t byte) { if (byte == 300) flow.dut.session_nonce = 0; }) == 0);
    REQUIRE(flow.dut.rejected_packets == ++flow_rejected);
    flow.blank(); flow.frameEdge();
    REQUIRE(!flow.dut.visible);
    flow.raster();

    Bench pulse;
    pulse.session(30, 300);
    ui::Model before_flush = flow_model;
    before_flush.title = "Must not resurrect after Flush";
    const auto before_flush_packet = ui::encode(30, 300, 1, before_flush);
    pulse.send(before_flush_packet);
    REQUIRE(pulse.dut.accepted_sequence == 1);
    REQUIRE(!pulse.dut.visible); // Descriptor awaits its first pixel-frame ACK.
    // Exactly one clk_sys rising edge sees inactive. Epoch and committed nonce
    // never change; the pixel clock is stalled until after activity has returned.
    pulse.dut.session_active = 0; pulse.sys();
    pulse.dut.session_active = 1; pulse.sys();
    pulse.blank();
    REQUIRE(!pulse.dut.visible);
    pulse.frameEdge(); // Old descriptor ACK arrives only after the pulse is gone.
    REQUIRE(!pulse.dut.visible);
    REQUIRE(pulse.dut.accepted_sequence == 1);
    const unsigned pulse_rejected = pulse.dut.rejected_packets;
    ui::Model after_flush = flow_model;
    after_flush.title = "Fresh UI after Flush retirement";
    after_flush.position_ms = 24000; after_flush.duration_ms = 60000;
    const auto after_flush_packet = ui::encode(30, 300, 2, after_flush);
    // Retirement still owns the mailbox until the clear's separate frame ACK.
    REQUIRE(pulse.sendHonoringWait(after_flush_packet) > 0);
    REQUIRE(pulse.dut.rejected_packets == pulse_rejected);
    REQUIRE(pulse.dut.accepted_sequence == 2);
    REQUIRE(!pulse.dut.visible);
    pulse.raster(false); // Fresh descriptor is pending; old bank stays invisible.
    pulse.frameEdge();
    pulse.shown = after_flush_packet;
    pulse.expected_visible = true;
    REQUIRE(pulse.dut.visible);
    pulse.raster(false);
    REQUIRE(pulse.sendHonoringWait(before_flush_packet, false) == 0);
    REQUIRE(pulse.dut.rejected_packets == pulse_rejected + 1);
    REQUIRE(pulse.dut.accepted_sequence == 2);
    pulse.raster();
    std::printf("playback_overlay_plane: OK (%u checks, 1024-byte text RAM, native divisor=%u)\n",
                checks, unsigned(OVERLAY_NATIVE_DIVISOR));
}
