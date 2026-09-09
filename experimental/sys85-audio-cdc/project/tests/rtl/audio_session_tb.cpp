#include "Vaudio_session_tb_top.h"
#include "verilated.h"
#include "audio_session.hpp"
#include "ddr_bitstream_ring.hpp"
#include <array>
#include <algorithm>
#include <cstdint>
#include <deque>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <vector>

using misterplex::audio_session::Control;
namespace audio = misterplex::audio_session;
namespace abi = mailbox_abi;
namespace ring = misterplex::ddr_bitstream_ring;

static void require(bool ok, const char* text) {
    if (!ok) throw std::runtime_error(text);
}

class Bench {
public:
    Vaudio_session_tb_top d;
    uint64_t time = 0, sys_edges = 0, audio_edges = 0;
    unsigned sys_half, audio_half, shift;
    uint16_t wptr = 0, length = 32;
    bool wptr_half = false;
    uint64_t token = 0;
    uint32_t publication = 0;
    std::unordered_map<uint32_t, uint64_t> memory;
    std::vector<uint64_t> pcm_memory = std::vector<uint64_t>(65536);
    std::deque<uint32_t> expected;
    std::vector<uint32_t> heard;
    bool ram_toggle = false, ram_scheduled = false;
    bool stall_audio = false, stall_mailbox = false;
    bool response_pending = false;
    uint64_t response_at = 0, response_value = 0;
    uint64_t ram_at = 0, ram_value = 0;
    unsigned read_delay = 3, audio_delay = 9;
    unsigned reads = 0;
    bool check_samples = true;
    uint32_t video_written = 0;
    bool video_reset_epoch = false;
    bool legacy_toggle = false, legacy_scheduled = false;
    uint64_t legacy_at = 0, legacy_value = 0;
    unsigned legacy_reads = 0;
    std::vector<uint32_t> legacy_heard;
    bool event_driven = false, observed_bundles = false;
    bool held_command_toggle = false, held_snapshot_ack = false;
    std::array<uint32_t, 7> held_command{};
    std::array<uint32_t, 14> held_snapshot{};

    Bench(unsigned s, unsigned a, unsigned phase, bool real_reader = false,
          bool skip_empty = false)
        : sys_half(s), audio_half(a), shift(phase), event_driven(skip_empty) {
        d.clk_sys = 0; d.clk_audio = 0; d.reset = real_reader;
        d.use_real_reader = real_reader;
        d.session_epoch = 0x1234000012340001ULL;
        d.probe_nonce = 0xa6780000ffbb0011ULL;
        d.session_active = 1;
        d.ring_enable = 1;
        d.spi_ss = 1; d.spi_sck = 0; d.spi_mosi = 0;
        d.ram_ready = 0; d.ram_data = 0;
        d.legacy_ram_ready = 0; d.legacy_ram_data = 0;
        d.ddr_busy = 0; d.ddr_dout_ready = 0; d.ddr_dout = 0;
        d.eval();
        advance(50);
        if (real_reader) {
            d.reset = 0;
            advance(50);
        }
    }

    void tick() {
        if (event_driven)
            time = std::min((time / sys_half + 1) * sys_half,
                            ((time + shift) / audio_half + 1) * audio_half - shift);
        else ++time;
        bool next_sys = (time / sys_half) & 1;
        bool next_audio = ((time + shift) / audio_half) & 1;
        bool srise = next_sys && !d.clk_sys;
        bool arise = next_audio && !d.clk_audio;
        bool accept_read = false;
        bool deliver = false;
        uint32_t addr = 0;
        if (srise) {
            ++sys_edges;
            d.ddr_busy = stall_mailbox || (sys_edges % 7 == 0);
            deliver = response_pending && sys_edges >= response_at;
            d.ddr_dout_ready = deliver;
            if (deliver) d.ddr_dout = response_value;
            d.eval();
            accept_read = d.ddr_rd && !d.ddr_busy;
            addr = uint32_t(d.ddr_addr) << 3;
            if (d.ddr_we && !d.ddr_busy) memory[addr] = d.ddr_din;
            if (accept_read && read_delay == 0) {
                require(!response_pending, "overlapping zero-latency mailbox reads");
                d.ddr_dout_ready = 1;
                d.ddr_dout = memory[addr];
            }
        }
        if (arise) {
            ++audio_edges;
            d.ram_ready = ram_scheduled && !stall_audio && audio_edges >= ram_at;
            if (d.ram_ready) d.ram_data = ram_value;
            d.legacy_ram_ready = legacy_scheduled && audio_edges >= legacy_at;
            if (d.legacy_ram_ready) d.legacy_ram_data = legacy_value;
        }
        auto before = uint64_t(d.consumed);
        uint32_t legacy_before = (uint32_t(d.legacy_r) << 16) | d.legacy_l;
        d.clk_sys = next_sys;
        d.clk_audio = next_audio;
        d.eval();
        if (observed_bundles) {
            if (d.ctrl_toggle == held_command_toggle)
                require(std::equal(held_command.begin(), held_command.end(), &d.command_bus[0]),
                        "command payload changed without its request toggle");
            else require(d.ctrl_ack == held_command_toggle,
                         "command payload replaced before consumer acknowledgement");
            if (d.observed_snapshot_ack == held_snapshot_ack)
                require(std::equal(held_snapshot.begin(), held_snapshot.end(), &d.snapshot_bus[0]),
                        "snapshot payload changed without acknowledgement");
        }
        std::copy_n(&d.command_bus[0], held_command.size(), held_command.begin());
        std::copy_n(&d.snapshot_bus[0], held_snapshot.size(), held_snapshot.begin());
        held_command_toggle = d.ctrl_toggle;
        held_snapshot_ack = d.observed_snapshot_ack;
        observed_bundles = true;
        if (arise) {
            if (d.legacy_ram_ready) legacy_scheduled = false;
            if (d.legacy_ram_req != legacy_toggle) {
                require(!legacy_scheduled, "overlapping legacy requests");
                legacy_toggle = d.legacy_ram_req;
                legacy_scheduled = true;
                legacy_at = audio_edges + 5;
                legacy_value = pcm_memory.at(d.legacy_ram_address);
                ++legacy_reads;
            }
            uint32_t legacy_after = (uint32_t(d.legacy_r) << 16) | d.legacy_l;
            if (legacy_after != legacy_before) legacy_heard.push_back(legacy_after);
            if (d.ram_ready) ram_scheduled = false;
            if (d.ram_req != ram_toggle) {
                require(!ram_scheduled, "overlapping audio requests");
                ram_toggle = d.ram_req;
                ram_scheduled = true;
                ram_at = audio_edges + audio_delay;
                ram_value = pcm_memory.at(d.ram_address);
                ++reads;
            }
            if (d.consumed != before && d.consumed != 0) {
                require(d.consumed == before + 1, "non-unit media clock increment");
                uint32_t sample = (uint32_t(d.pcm_r) << 16) | d.pcm_l;
                if (check_samples) {
                    require(!expected.empty(), "consumed an unwritten sample");
                    if (sample != expected.front()) {
                        std::cerr << "PCM expected=" << expected.front() << " got=" << sample << "\n";
                        throw std::runtime_error("lost, duplicated, or stale PCM");
                    }
                    expected.pop_front();
                }
                heard.push_back(sample);
            }
        }
        if (srise) {
            if (deliver) response_pending = false;
            if (accept_read && read_delay != 0) {
                require(!response_pending, "overlapping mailbox reads");
                response_pending = true;
                response_at = sys_edges + read_delay;
                response_value = memory[addr];
            }
        }
    }
    void advance(uint64_t ticks) { while (ticks--) tick(); }
    void until(const std::function<bool()>& predicate, const char* failure,
               uint64_t limit = 200000) {
        while (limit-- && !predicate()) tick();
        require(predicate(), failure);
    }
    void spi() {
        std::array<bool, 96> bits{};
        bits[66] = wptr_half;
        for (unsigned bit = 0; bit < 16; ++bit) {
            bits[35 + bit] = (length >> bit) & 1;
            bits[67 + bit] = (wptr >> bit) & 1;
        }
        d.spi_ss = 1; d.spi_sck = 0; d.eval(); advance(9);
        d.spi_ss = 0; d.eval();
        for (unsigned count = 0; count < 128; ++count) {
            unsigned bit = (count & 0x78) | ((~count) & 7);
            d.spi_mosi = bit < 96 ? bits[bit] : 0;
            d.spi_sck = 0; d.eval(); advance(3);
            d.spi_sck = 1; d.eval(); advance(3);
        }
        d.spi_ss = 1; d.spi_sck = 0; d.eval(); advance(9);
    }
    void queue(unsigned pairs, uint32_t base, bool publish_metadata = true) {
        for (unsigned i = 0; i < pairs; ++i) {
            uint32_t sample = base + i;
            if (wptr_half) {
                pcm_memory[wptr] = uint32_t(pcm_memory[wptr]) | (uint64_t(sample) << 32);
                ++wptr;
                if (length && wptr >= length) wptr = 0;
            } else {
                pcm_memory[wptr] = (pcm_memory[wptr] & 0xffffffff00000000ULL) | sample;
            }
            wptr_half = !wptr_half;
            expected.push_back(sample);
        }
        if (publish_metadata) spi();
    }
    void publish(Control op, uint64_t use_token = 0, uint64_t epoch = 0, uint64_t nonce = 0) {
        if (!use_token) use_token = ++token;
        auto words = audio::encodeControl(epoch ? epoch : d.session_epoch,
            nonce ? nonce : d.probe_nonce, use_token, op, ++publication,
            (uint32_t(wptr) << 3) | (wptr_half ? 4u : 0u));
        memory[abi::kAudioControlCommitAddr] = 0;
        for (unsigned i = 0; i + 1 < words.size(); ++i)
            memory[abi::kAudioControlAddr + i*8] = words[i];
        memory[abi::kAudioControlCommitAddr] = words.back();
    }
    bool status(audio::Status& out) {
        std::array<uint64_t, 8> words{};
        for (unsigned i = 0; i < 8; ++i) words[i] = memory[abi::kAudioStatusAddr + i*8];
        return audio::decodeStatus(words, out);
    }
    void ack(Control op, uint64_t wanted_token = 0, bool successful = true) {
        if (!wanted_token) wanted_token = token;
        try {
        until([&] {
            audio::Status st;
            return status(st) && audio::matchesAck(st, d.session_epoch, d.probe_nonce,
                                                   wanted_token, op) &&
                   (successful ? audio::completed(st, op) : st.error != 0);
        }, "fresh hardware audio ACK timed out");
        } catch (...) {
            audio::Status st{};
            bool have = status(st);
            std::cerr << "ACK context op=" << unsigned(op) << " token=" << wanted_token
                      << " success=" << successful << " sys/audio=" << sys_half << "/" << audio_half
                      << " phase=" << shift << " state=" << unsigned(d.mailbox_state)
                      << " active/pending=" << unsigned(d.active) << "/" << unsigned(d.pending)
                      << " ctrl=" << unsigned(d.ctrl_toggle) << "/" << unsigned(d.ctrl_ack)
                      << " rptr/wptr=" << d.rptr << "/" << wptr << " status=" << have << "\n";
            throw;
        }
    }
    void command(Control op) {
        publish(op);
        // Real MrAudio has no periodic metadata writer. In the ordinary
        // quiesced path no SPI packet may follow this command.
        ack(op);
    }
    void videoReset(bool epoch) {
        video_written = 0;
        video_reset_epoch = epoch;
        memory[ring::kCtrlPhys] = ring::kCtrlMagic | (uint64_t(epoch) << 63);
    }
    bool videoResetAck() {
        const uint64_t read = memory[ring::kReadPhys], error = memory[ring::kErrPhys];
        return uint32_t(read) == ring::kReadMagic && (read >> 32) == 0 &&
               uint32_t(error) == ring::kErrMagic &&
               bool((error >> ring::kErrResetEpochBit) & 1) == video_reset_epoch;
    }
    void videoRecord(ring::Event event, uint64_t session, uint32_t sequence = 0) {
        const std::array<uint64_t, 4> header{{
            ring::kRecordMagic | (uint64_t(event) << 32) |
                (uint64_t(abi::kFpgaVideoAbiVersion) << 48),
            session, sequence, 0,
        }};
        for (uint64_t word : header) {
            memory[ring::kDataPhys + video_written] = word;
            video_written += 8;
        }
        memory[ring::kCtrlPhys] = ring::kCtrlMagic | (uint64_t(video_written) << 32) |
                                (uint64_t(video_reset_epoch) << 63);
    }
    void videoBegin() {
        videoRecord(ring::Event::Probe, d.probe_nonce, abi::kFpgaVideoLayoutId);
        until([&] { return d.reader_probe_nonce == d.probe_nonce; }, "real reader Probe failed");
        videoRecord(ring::Event::Begin, d.session_epoch);
        until([&] {
            return d.reader_active && d.reader_session_epoch == d.session_epoch &&
                   uint32_t(memory[ring::kReadPhys] >> 32) == video_written;
        }, "real reader Begin fence failed");
    }
};

static void core_reset_recovery(unsigned sys, unsigned aud, unsigned phase) {
    Bench b(sys, aud, phase, true);
    b.length = 0;
    b.wptr = 52640;
    b.wptr_half = true;
    b.videoReset(true);
    b.until([&] { return b.videoResetAck(); }, "bootstrap CTRL reset failed");
    auto unowned_toggle = b.d.ctrl_toggle;
    b.publish(Control::Reset);
    b.advance(4000);
    require(b.d.ctrl_toggle == unowned_toggle,
            "bootstrap snapshot authorized Reset for an unowned audio identity");
    b.videoBegin();
    b.command(Control::Begin);
    b.stall_audio = true;
    b.queue(5, 0x00a000a0);
    b.command(Control::Resume);
    b.until([&] { return b.d.read_pending; }, "real DMA request not owned");
    b.publish(Control::Reset);
    const auto failed_reset_token = b.token;
    b.until([&] { return b.d.pending; }, "first abort Reset did not reach actual ALSA");
    b.advance(4000);
    require(b.d.ctrl_ack != b.d.ctrl_toggle && !b.d.consumer_quiescent,
            "first abort Reset falsely completed with held DMA");
    const auto old_epoch = b.d.session_epoch, old_nonce = b.d.probe_nonce;
    b.d.reset = 1;
    b.advance(2000);
    require(b.d.reader_session_epoch == 0 && b.d.reader_probe_nonce == 0,
            "local reset did not erase video identity");
    require(b.d.read_pending && !b.d.consumer_quiescent,
            "local reset forgot an accepted DMA response");
    b.videoReset(false);
    b.d.reset = 0;
    b.until([&] { return b.d.reader_reset_pending; }, "fresh CTRL reset not observed");
    b.advance(3000);
    require(!b.videoResetAck(), "fresh CTRL ACK preceded actual DMA retirement");

    auto toggle = b.d.ctrl_toggle;
    for (Control op : {Control::Begin, Control::Pause, Control::Resume}) {
        b.publish(op);
        b.advance(4000);
        require(b.d.ctrl_toggle == toggle, "non-Reset used inactive consumer identity fallback");
    }
    b.publish(Control::Reset, 0, old_epoch + 1, old_nonce);
    b.advance(4000);
    require(b.d.ctrl_toggle == toggle, "unknown recovery epoch reached the consumer");
    b.publish(Control::Reset, 0, old_epoch, old_nonce + 1);
    b.advance(4000);
    require(b.d.ctrl_toggle == toggle, "unknown recovery nonce reached the consumer");

    // Host retains its original epoch/nonce after video reset. Real ALSA still
    // owns that identity and DDR response; only its completed Reset may ACK.
    b.publish(Control::Reset);
    b.until([&] { return b.d.pending; }, "old-session Reset blocked after video identity cleared");
    b.advance(4000);
    require(b.d.ctrl_ack != b.d.ctrl_toggle && !b.d.consumer_quiescent && !b.videoResetAck(),
            "recovery Reset or fresh CTRL acknowledged outstanding DMA");
    b.stall_audio = false;
    b.ack(Control::Reset);
    audio::Status recovered;
    require(b.status(recovered) && recovered.token > failed_reset_token && recovered.error == 0,
            "manual-reset recovery reused the failed abort token");
    b.expected.clear();
    b.until([&] { return b.videoResetAck(); }, "fresh CTRL did not complete after real audio Reset");
    require(b.d.consumer_quiescent && b.d.consumed == 0 && !b.d.prefetched &&
            b.d.rptr == b.wptr && b.d.rptr_half == b.wptr_half,
            "recovery did not discard/align old DMA state");

    b.d.session_epoch = old_epoch + 2;
    b.d.probe_nonce = old_nonce + 2;
    b.videoBegin();
    toggle = b.d.ctrl_toggle;
    b.publish(Control::Reset, 0, old_epoch, old_nonce);
    b.advance(4000);
    require(b.d.ctrl_toggle == toggle,
            "old consumer identity authorized Reset during a different active video session");
    b.command(Control::Begin);
    b.queue(3, 0x00a100a1);
    b.command(Control::Resume);
    b.until([&] { return b.expected.empty(); }, "new audio session failed after fenced recovery");
    require(b.d.consumed == 3, "old PCM leaked through local-reset recovery");
    std::cout << "real reader + ALSA local-reset recovery " << sys << "/" << aud << " passed\n";
}

static void legacy_scenario() {
    Bench b(3, 5, 1);
    b.spi();
    b.queue(4, 0x00700070);
    b.advance(20000);
    require(b.legacy_reads == 0 && b.legacy_heard.empty(),
            "legacy first-buffer synchronization changed");
    b.queue(6, 0x00800080);
    b.until([&] { return b.legacy_heard.size() == 6; }, "legacy PCM stalled");
    for (unsigned i = 0; i < 6; ++i)
        require(b.legacy_heard[i] == 0x00800080 + i, "legacy PCM order changed");
    require(b.d.legacy_ctrl_ack == 0 && b.d.legacy_snapshot_ack == 0,
            "legacy mode acknowledged session control");
    for (unsigned i = 0; i < 14; ++i)
        require(b.d.legacy_snapshot[i] == 0, "legacy mode advertised audio-clock support");
    std::cout << "default-off legacy ALSA compatibility passed\n";
}

static void scenario(unsigned sys, unsigned aud, unsigned shift, bool zero_latency) {
    Bench b(sys, aud, shift);
    if (zero_latency) b.read_delay = 0;
    b.until([&] { return b.d.consumer_quiescent; }, "bootstrap lacked real audio quiescence");
    require(!b.d.clock_valid, "bootstrap fabricated an active audio clock");
    // Cold-core regression using the lab-observed idle kernel wptr. No metadata
    // packet exists in the FPGA, and an open descriptor cannot publish one.
    b.length = 0;
    b.wptr = 421120 / 8;
    b.publish(Control::Begin);
    b.until([&] { return b.d.pending; }, "Begin did not reach audio domain");
    require(!b.d.consumer_quiescent, "pending Begin reused a stale quiescence snapshot");
    require(!b.d.clock_valid, "pending Begin reused a stale clock");
    b.ack(Control::Begin);
    require(b.d.active && b.d.paused && b.d.consumed == 0, "Begin not priming-paused");
    require(b.d.rptr == 421120 / 8, "Begin failed to align to the authoritative kernel pointer");
    require(!b.d.consumer_quiescent, "Begin retained an old quiescence proof");
    require(b.d.clock_valid && b.d.clock_paused, "Begin ACK lacked a valid priming clock");
    b.queue(20, 0x00010001, false);
    require(b.d.consumed == 0 && b.reads == 0, "priming consumed PCM");
    b.publish(Control::Resume);
    b.until([&] { return b.d.pending; }, "Resume not delivered");
    b.advance(5000);
    require(b.d.ctrl_ack != b.d.ctrl_toggle && b.d.consumed == 0 && b.reads == 0,
            "Resume used stale/uninitialized DMA metadata");
    require(!b.d.clock_valid, "pending Resume retained an old clock-valid assertion");
    b.spi();
    b.ack(Control::Resume);
    b.until([&] { return b.d.consumed >= 3; }, "no first-chunk audio");
    b.command(Control::Pause);
    auto frozen = b.d.consumed;
    auto retained = b.expected.size();
    require(retained != 0, "pause did not preserve queued PCM");
    b.advance(10000);
    require(b.d.consumed == frozen && b.d.pcm_l == 0 && b.d.pcm_r == 0,
            "paused output not silent/frozen");
    require(b.d.clock_valid && b.d.clock_paused, "paused consumed clock became invalid");
    b.d.ring_enable = 0; // Resume must not depend on resumed video ingress.
    b.command(Control::Resume);
    b.d.ring_enable = 1;
    b.until([&] { return b.expected.empty(); }, "resume lost tail samples");
    b.advance(3000);
    require(b.d.consumed == 20, "empty DMA ring advanced the media clock");
    const auto epoch = b.d.session_epoch, nonce = b.d.probe_nonce;
    b.d.session_epoch = epoch + 1;
    b.until([&] { return !b.d.clock_valid; }, "changed video epoch retained audio clock");
    b.advance(3000);
    require(!b.d.clock_valid, "old epoch snapshot revalidated an unrelated clock");
    b.d.session_epoch = epoch;
    b.until([&] { return b.d.clock_valid; }, "matching epoch snapshot did not recover");
    b.d.probe_nonce = nonce + 1;
    b.until([&] { return !b.d.clock_valid; }, "changed Probe nonce retained audio clock");
    b.advance(3000);
    require(!b.d.clock_valid, "old nonce snapshot revalidated an unrelated clock");
    b.d.probe_nonce = nonce;
    b.until([&] { return b.d.clock_valid; }, "matching nonce snapshot did not recover");
    b.d.session_active = 0;
    b.until([&] { return !b.d.clock_valid; }, "inactive video retained audio clock");
    b.d.session_active = 1;
    b.until([&] { return b.d.clock_valid; }, "active matching snapshot did not recover");

    // Pausing a toggled DDR read must retire it, retain both pairs, then ACK.
    b.stall_audio = true;
    b.queue(8, 0x00100010);
    b.until([&] { return b.d.read_pending; }, "no inflight audio read");
    b.publish(Control::Pause);
    b.until([&] { return b.d.pending; }, "pause CDC not delivered");
    frozen = b.d.consumed;
    b.advance(5000);
    require(b.d.ctrl_ack != b.d.ctrl_toggle, "pause acknowledged an outstanding DDR read");
    require(b.d.consumed == frozen, "pending pause consumed audio");
    require(!b.d.clock_valid, "pending Pause retained an old clock-valid assertion");
    b.stall_audio = false;
    b.ack(Control::Pause);
    require(b.d.prefetched == 2, "pause lost the returned prefetch");
    b.command(Control::Resume);
    b.until([&] { return b.expected.empty(); }, "inflight-pause sample loss");
    require(b.d.consumed == 28, "inflight-pause sample count wrong");

    // Reset may discard a response only after its owner actually retires it.
    b.stall_audio = true;
    b.queue(12, 0x00200020);
    b.until([&] { return b.d.read_pending; }, "no reset-inflight request");
    b.publish(Control::Reset);
    b.until([&] { return b.d.pending; }, "reset CDC not delivered");
    b.spi();
    b.advance(5000);
    require(b.d.ctrl_ack != b.d.ctrl_toggle, "reset acknowledged before DDR retirement");
    b.stall_audio = false;
    b.ack(Control::Reset);
    b.expected.clear();
    require(b.d.consumed == 0 && b.d.prefetched == 0 && b.d.rptr == b.wptr,
            "reset left old data or a stale pointer");
    b.advance(3000);
    require(b.d.consumed == 0, "old session resumed after reset");
    b.command(Control::Begin);
    b.queue(10, 0x00300030);
    b.command(Control::Resume);
    b.until([&] { return b.expected.empty(); }, "first new PCM chunk dropped");
    require(b.d.consumed == 10, "new-session counter wrong");

    // Old epoch/nonce must not reach ALSA; old tokens must NACK without changing state.
    auto prev_toggle = b.d.ctrl_toggle;
    const auto accepted_token = b.token;
    b.publish(Control::Reset, b.token + 1, b.d.session_epoch - 1);
    b.advance(12000);
    require(b.d.ctrl_toggle == prev_toggle && b.d.active, "stale epoch accepted");
    b.publish(Control::Reset, b.token + 1, 0, b.d.probe_nonce - 1);
    b.advance(12000);
    require(b.d.ctrl_toggle == prev_toggle && b.d.active, "stale nonce accepted");
    b.publish(Control::Reset);
    b.memory[abi::kAudioControlCommitAddr] = 0;
    b.advance(12000);
    require(b.d.ctrl_toggle == prev_toggle && b.d.active, "uncommitted command accepted");
    for (uint64_t bad_position : {uint64_t(1), uint64_t(524288), uint64_t(1) << 32}) {
        b.publish(Control::Reset);
        b.memory[abi::kAudioControlAddr + 32] = bad_position;
        b.advance(12000);
        require(b.d.ctrl_toggle == prev_toggle && b.d.active,
                "malformed producer cursor reached the DMA consumer");
    }
    b.publish(Control::Reset);
    b.memory[abi::kAudioControlAddr] =
        (b.memory[abi::kAudioControlAddr] & ~(uint64_t(0xffff) << 32)) | (uint64_t(1) << 32);
    b.advance(12000);
    require(b.d.ctrl_toggle == prev_toggle && b.d.active, "obsolete audio ABI1 accepted");
    b.publish(Control::Pause, accepted_token);
    b.ack(Control::Pause, accepted_token, false);
    require(!b.d.paused && b.d.consumed == 10, "stale token changed DMA state");
    require(!b.d.clock_valid, "rejected command published a valid clock");
    b.command(Control::Reset);

    // Hardware length zero means 65536 qwords (512 KiB), not an empty buffer.
    b.length = 0; b.wptr = 65534; b.spi();
    b.command(Control::Begin);
    b.queue(8, 0x00400040);
    require(b.wptr == 2, "producer did not wrap at 512 KiB");
    b.command(Control::Resume);
    b.until([&] { return b.expected.empty(); }, "512-KiB wrap lost PCM");
    require(b.d.consumed == 8 && b.d.rptr == 2, "512-KiB consumer wrap wrong");
    b.command(Control::Reset);

    // Maximum safe occupancy (one free qword) across repeated small-ring wraps.
    b.length = 8; b.wptr = 6; b.spi();
    b.command(Control::Begin);
    for (unsigned run = 0; run < 4; ++run) {
        b.queue(14, 0x00500050 + run*100);
        b.command(Control::Resume);
        b.until([&] { return b.expected.empty(); }, "full-safe ring lost samples");
        b.command(Control::Pause);
    }
    require(b.d.consumed == 56, "repeated wrap conservation failed");
    audio::Status st;
    require(b.status(st) && st.samples_consumed == 56 && st.paused,
            "coherent mailbox disagrees with consumed clock");
    require(b.d.ring_reads > 100, "audio mailbox starved continuous video DDR traffic");

    // Trim/EOF can leave a single stereo sample, not a full 64-bit DMA word.
    // Begin at the upper half must discard the old lower half, including wrap.
    for (uint16_t ring_length : {uint16_t(8), uint16_t(0)}) {
        b.command(Control::Reset);
        b.length = ring_length;
        b.wptr = ring_length ? ring_length - 1 : 65535;
        b.wptr_half = true;
        b.pcm_memory[b.wptr] = 0xdeadbeefbad0cafeULL;
        b.spi();
        b.command(Control::Begin);
        require(b.d.rptr_half, "Begin truncated half-qword producer pointer");
        b.queue(1, 0x00600060);
        b.stall_audio = true;
        b.command(Control::Resume);
        b.until([&] { return b.d.read_pending; }, "upper-half read not requested");
        b.publish(Control::Pause);
        b.until([&] { return b.d.pending; }, "upper-half Pause not received");
        b.advance(3000);
        require(b.d.ctrl_ack != b.d.ctrl_toggle, "upper-half Pause ACK preceded retirement");
        b.stall_audio = false;
        b.ack(Control::Pause);
        require(b.d.prefetched == 1 && b.d.consumed == 0,
                "upper-half Pause changed prefetch validity");
        b.command(Control::Resume);
        b.until([&] { return b.expected.empty(); }, "first upper-half sample was dropped");
        require(b.d.rptr == 0 && !b.d.rptr_half && b.d.consumed == 1,
                "upper-half cursor did not wrap");
        b.command(Control::Pause);
        b.queue(3, 0x00610061);
        b.command(Control::Resume);
        b.until([&] { return b.expected.empty(); }, "odd EOF tail was stranded");
        b.advance(3000);
        require(b.d.consumed == 4 && b.d.rptr_half,
                "unwritten upper-half PCM was consumed");
        b.command(Control::Pause);
        b.queue(1, 0x00620062);
        b.command(Control::Resume);
        b.until([&] { return b.expected.empty(); }, "later upper-half write was not reread");
        require(b.d.consumed == 5, "half-qword reread duplicated prior sample");
        b.command(Control::Pause);
        b.queue(5, 0x00630063);
        b.stall_audio = true;
        b.command(Control::Resume);
        b.until([&] { return b.d.read_pending; }, "odd reset missing in-flight read");
        b.publish(Control::Reset);
        b.until([&] { return b.d.pending; }, "odd reset command not received");
        b.spi();
        b.advance(3000);
        require(b.d.ctrl_ack != b.d.ctrl_toggle, "odd reset ACK preceded DDR retirement");
        b.stall_audio = false;
        b.ack(Control::Reset);
        b.expected.clear();
        require(b.d.rptr == b.wptr && b.d.rptr_half == b.wptr_half,
                "Reset did not align exact stereo-sample pointer");
        b.command(Control::Begin);
        b.queue(1, 0x00640064);
        b.command(Control::Resume);
        b.until([&] { return b.expected.empty(); }, "new session leaked pre-reset half-word");
        require(b.d.consumed == 1, "new half-word session counter mismatch");
    }
    b.command(Control::Reset);
    require(b.d.consumer_quiescent, "Reset ACK did not establish actual quiescence");
    require(!b.d.clock_valid, "Reset ACK retained an active audio clock");
    b.command(Control::Begin);
    b.stall_audio = true;
    b.queue(4, 0x00900090);
    b.command(Control::Resume);
    b.until([&] { return b.d.read_pending; }, "system reset missing DMA debt");
    b.d.reset = 1;
    b.advance(10 * aud);
    require(b.d.read_pending && !b.d.consumer_quiescent,
            "system reset fabricated quiescence by clearing DDR ownership");
    require(!b.d.clock_valid, "system reset retained an active audio clock");
    b.d.reset = 0;
    b.advance(3000);
    require(!b.d.consumer_quiescent, "quiescence ignored outstanding DDR response");
    b.stall_audio = false;
    b.until([&] { return b.d.consumer_quiescent; }, "reset DMA retirement never became quiescent");
    b.expected.clear();
    require(!b.d.active && !b.d.prefetched && !b.d.pcm_l && !b.d.pcm_r,
            "quiescent consumer retained audible/prefetched old-session PCM");

    // A Begin already crossing CDC must not wake a reset consumer afterwards.
    b.publish(Control::Begin);
    b.until([&] { return b.d.pending; }, "reset-cancel Begin not delivered");
    b.d.reset = 1;
    b.advance(10 * aud);
    b.d.reset = 0;
    b.ack(Control::Begin, 0, false);
    b.advance(3000);
    require(!b.d.active && b.d.consumer_quiescent, "old Begin resurrected audio after reset");
    b.command(Control::Begin);
    b.queue(3, 0x00910091);
    b.command(Control::Resume);
    b.until([&] { return b.expected.empty(); }, "post-reset new-session PCM did not recover");
    require(b.d.consumed == 3, "system-reset recovery consumed stale data");
    std::cout << "audio session clocks " << sys << "/" << aud << " phase " << shift
              << " zero-latency=" << zero_latency << " passed\n";
}

static void real_cdc(unsigned sys_half, unsigned audio_half, unsigned phase) {
    Bench b(sys_half, audio_half, phase, false, true);
    b.command(Control::Begin);
    b.queue(4, 0x00120012);
    b.command(Control::Resume);
    b.until([&] { return b.expected.empty(); }, "real-clock PCM ordering");
    require(b.d.consumed == 4, "real-clock sample count");
    b.command(Control::Pause);
    b.stall_audio = true;
    b.queue(4, 0x00130013);
    b.command(Control::Resume);
    b.until([&] { return b.d.read_pending; }, "real-clock DMA debt");
    auto toggle = b.d.ctrl_toggle;
    b.publish(Control::Pause);
    b.until([&] { return b.d.ctrl_toggle != toggle; }, "real-clock command launch");
    b.d.reset = 1;
    b.until([&] { return b.d.ctrl_ack == b.d.ctrl_toggle; }, "reset-time consumer acknowledgement");
    require(b.d.read_pending && !b.d.consumer_quiescent,
            "reset-time rejection discarded DMA debt");
    b.d.reset = 0;
    b.ack(Control::Pause, 0, false);
    b.stall_audio = false;
    b.until([&] { return b.d.consumer_quiescent; }, "real-clock reset retirement");
    b.expected.clear();
    toggle = b.d.ctrl_toggle;
    b.publish(Control::Begin);
    b.until([&] { return b.d.mailbox_state == 5; }, "field-validation dispatch state");
    b.d.probe_nonce ^= 0x100000000ULL;
    b.advance(200);
    require(b.d.ctrl_toggle == toggle, "pipelined validation dispatched a stale identity");
    b.command(Control::Begin);
    b.queue(3, 0x00140014);
    b.command(Control::Resume);
    b.until([&] { return b.expected.empty(); }, "real-clock fresh-generation PCM");
    require(b.d.consumed == 3, "real-clock generation counter");
    std::cout << "PASS real 20/85:24.576 CDC ratio " << sys_half << "/" << audio_half
              << " phase=" << phase << " delayed-bundles=one-destination-cycle"
              << " reset-before-capture/DMA-debt/dispatch-identity/PCM\n";
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
#ifdef AUDIO_REAL_CDC_CASES
        for (unsigned phase : {0u, 1u, 624u, 3071u}) real_cdc(768, 625, phase);
        for (unsigned phase : {0u, 1u, 3071u, 10624u}) real_cdc(3072, 10625, phase);
#else
        legacy_scenario();
        scenario(3, 5, 0, false);
        scenario(7, 3, 1, false);
        scenario(2, 7, 4, true);
        scenario(5, 4, 3, false);
        core_reset_recovery(3, 5, 1);
        core_reset_recovery(7, 3, 2);
#endif
    } catch (const std::exception& e) {
        std::cerr << "FAIL: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
