#include "Vddr_bitstream_reader_transport_tb_top.h"
#include "verilated.h"
#include "ddr_bitstream_ring.hpp"
#include "audio_session.hpp"
#include "ddr_bitstream_ring_bfm.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace ring = misterplex::ddr_bitstream_ring;
namespace abi = mailbox_abi;
namespace audio = misterplex::audio_session;
using Bytes = std::vector<uint8_t>;
constexpr uint64_t session = 0x1928374655647382ull;
constexpr uint64_t nonce = 0xEFFE10203040ABCDull;
constexpr size_t configuredMaxAuBytes = TEST_MAX_AU_BYTES;

void require(bool ok, const std::string& message) {
    if (!ok)
        throw std::runtime_error(message);
}

Bytes record(ring::Event event, uint64_t epoch, uint32_t seq = 0,
             const Bytes& payload = {}, uint16_t version = 2) {
    return misterplex::test::encodeRingRecord(event, epoch, seq, payload, version,
                                              event == ring::Event::Nal ? 0x65 : 0);
}

Bytes accessUnit(const Bytes& encoded, uint32_t seq = 0, uint64_t epoch = session) {
    ring::AccessUnit au;
    au.session_id = epoch;
    au.seq = seq;
    au.annexb = encoded.data();
    au.len = encoded.size();
    au.pts = -9001 + int64_t(seq) * 3000;
    au.duration = 3000;
    au.timebase_num = 1;
    au.timebase_den = 90000;
    au.flags = seq == 0 ? ring::kAccessUnitKeyframe : 0;
    return misterplex::test::encodeAccessUnitRecord(au);
}

struct Metadata {
    uint64_t session_id, pts, duration;
    uint32_t seq, num, den, flags;
    bool operator==(const Metadata& other) const {
        return session_id == other.session_id && pts == other.pts &&
               duration == other.duration && seq == other.seq &&
               num == other.num && den == other.den && flags == other.flags;
    }
};

struct Sim {
    Vddr_bitstream_reader_transport_tb_top dut;
    misterplex::test::DdrBitstreamRingBfm ddr;
    std::unordered_map<uint32_t, uint64_t>& mem = ddr.words;
    struct Write { uint32_t addr; uint64_t value; };
    std::vector<Write> capsWrites;
    misterplex::test::DdrBitstreamRingBfm::Pending& pending = ddr.pending;
    Bytes accepted, drained;
    std::vector<size_t> lasts;
    std::vector<Metadata> metadata;
    std::vector<uint64_t> audioResponses;
    uint64_t cycles = 0;
    uint32_t wr = 0;
    bool epoch = true;
    bool randomStalls = true;
    bool forceBusy = false;
    bool heldByte = false, heldMeta = false;
    uint8_t priorByte = 0;
    bool priorLast = false;
    Metadata priorMeta{};
    unsigned flushes = 0, fullCycles = 0;
    unsigned& reads = ddr.reads;
    unsigned& writes = ddr.writes;
    unsigned& busyOffers = ddr.busyOffers;
    audio::Status audioState;
    std::array<uint32_t, 7> audioCommand{};
    bool audioConsumerBlocked = false, audioApplying = false, audioSnapshotPending = false;
    bool audioCommandToggle = false, audioSnapshotToggle = false;
    unsigned audioApplyDelay = 0, audioSnapshotDelay = 0;
    unsigned audioCommandsSeen = 0, audioCommandsApplied = 0;
    uint32_t audioPublication = 0;
    uint32_t audioExpectedProducerPosition = 0;
    uint64_t audioTime = 0, audioEdges = 0, dmaDue = 0, dmaData = 0;
    unsigned audioHalfPeriod = 7, audioPhase = 1;
    unsigned dmaRequests = 0, dmaResponses = 0;
    uint32_t dmaAddress = 0;
    bool dmaToggle = false, dmaScheduled = false, holdDma = false;
    bool enforceResetFence = false;
    std::array<uint64_t, 32> pcmMemory{};
    std::vector<uint32_t> heard;

    Sim() {
        dut.clk_audio = 0;
        dut.core_local_reset = 0;
        dut.route_core_audio_reset = 1;
        dut.audio_spi_ss = 1;
        dut.audio_spi_sck = 0;
        dut.audio_spi_mosi = 0;
        dut.audio_ram_ready = 0;
        dut.audio_ram_data = 0;
        dut.audio_mailbox_mode = 0;
        dut.audio_ctrl_ack_toggle = 0;
        dut.audio_snapshot_ack_toggle = 0;
        for (unsigned i = 0; i < 14; ++i)
            dut.audio_snapshot_data[i] = 0;
        audioState.supported = true;
    }

    // Only model the consumer-side completion/snapshot interface here. The
    // real mailbox and mux are instantiated; ALSA DMA/prefetch/PCM causality
    // is separately tested by the audio owner's test_audio_session.sh.
    // No PCM is supplied, so samples_consumed must stay zero.
    void serviceAudioConsumer() {
        if (REAL_ALSA_TEST || !dut.audio_mailbox_mode)
            return;
        if (!audioApplying && dut.audio_ctrl_toggle != dut.audio_ctrl_ack_toggle) {
            for (unsigned i = 0; i < audioCommand.size(); ++i)
                audioCommand[i] = dut.audio_ctrl_data[i];
            audioCommandToggle = dut.audio_ctrl_toggle;
            audioApplying = true;
            audioApplyDelay = unsigned(11 + cycles % 23);
            ++audioCommandsSeen;
        }
        if (audioApplying) {
            require(bool(dut.audio_ctrl_toggle) == audioCommandToggle,
                    "mailbox changed outstanding audio command toggle");
            for (unsigned i = 0; i < audioCommand.size(); ++i)
                require(dut.audio_ctrl_data[i] == audioCommand[i],
                        "mailbox changed outstanding audio command fields");
            if (!audioConsumerBlocked && --audioApplyDelay == 0) {
                const auto word64 = [&](unsigned word) {
                    return uint64_t(audioCommand[word]) |
                           (uint64_t(audioCommand[word + 1]) << 32);
                };
                const uint64_t epoch = word64(0), challenge = word64(2), token = word64(4);
                const auto command = audio::Control(uint8_t(audioCommand[6]));
                const uint32_t producerCursor = (audioCommand[6] >> 8) & 0x1ffffu;
                require(epoch == dut.video_session_id && challenge == dut.video_nonce &&
                        token != 0 && token != audioState.token && audio::validControl(command),
                        "audio mailbox delivered stale/malformed command identity");
                require(producerCursor == (audioExpectedProducerPosition >> 2),
                        "audio mailbox truncated/misconverted the 17-bit expected producer cursor");
                if (command == audio::Control::Pause || command == audio::Control::Resume)
                    require(audioState.active && audioState.session_id == epoch &&
                            audioState.nonce == challenge, "audio lifecycle lost consumer ownership");
                audioState.session_id = audioState.ack_session_id = epoch;
                audioState.nonce = audioState.ack_nonce = challenge;
                audioState.token = token;
                audioState.command = command;
                audioState.error = 0;
                switch (command) {
                case audio::Control::Begin:
                    audioState.active = true; audioState.paused = true; break;
                case audio::Control::Pause: audioState.paused = true; break;
                case audio::Control::Resume: audioState.paused = false; break;
                case audio::Control::Reset:
                    audioState.active = false; audioState.paused = true; break;
                }
                dut.audio_ctrl_ack_toggle = audioCommandToggle;
                audioApplying = false;
                ++audioCommandsApplied;
            }
        }
        if (!audioSnapshotPending &&
            dut.audio_snapshot_toggle != dut.audio_snapshot_ack_toggle) {
            const uint8_t flags = audio::kSupported |
                (audioState.active ? audio::kActive : 0) |
                (audioState.paused ? audio::kPaused : 0);
            const std::array<uint64_t, 7> words{{
                (uint64_t(flags) << 40) | (uint64_t(uint8_t(audioState.command)) << 48),
                audioState.session_id, audioState.nonce, audioState.token,
                audioState.samples_consumed, audioState.ack_session_id, audioState.ack_nonce
            }};
            for (unsigned i = 0; i < words.size(); ++i) {
                dut.audio_snapshot_data[2 * i] = uint32_t(words[i]);
                dut.audio_snapshot_data[2 * i + 1] = uint32_t(words[i] >> 32);
            }
            audioSnapshotToggle = dut.audio_snapshot_toggle;
            audioSnapshotPending = true;
            audioSnapshotDelay = unsigned(3 + cycles % 4);
        }
        if (audioSnapshotPending && --audioSnapshotDelay == 0) {
            dut.audio_snapshot_ack_toggle = audioSnapshotToggle;
            audioSnapshotPending = false;
        }
    }

    void advanceAudio(unsigned ticks) {
        if (!REAL_ALSA_TEST)
            return;
        while (ticks--) {
            const bool next = ((++audioTime + audioPhase) / audioHalfPeriod) & 1;
            const bool rising = next && !dut.clk_audio;
            const uint64_t consumed = dut.audio_actual_consumed;
            bool returning = false;
            if (rising) {
                ++audioEdges;
                returning = dmaScheduled && !holdDma && audioEdges >= dmaDue;
                dut.audio_ram_ready = returning;
                if (returning)
                    dut.audio_ram_data = dmaData;
                if (dmaScheduled)
                    require(dut.audio_ram_address == dmaAddress &&
                            bool(dut.audio_ram_req) == dmaToggle,
                            "actual ALSA changed an owned DMA while its response was held");
            }
            dut.clk_audio = next;
            dut.eval();
            if (!rising)
                continue;
            if (returning) {
                require(dmaScheduled, "unowned audio DMA response");
                dmaScheduled = false;
                ++dmaResponses;
            }
            if (bool(dut.audio_ram_req) != dmaToggle) {
                require(!dmaScheduled, "actual ALSA overlapped owned DMA requests");
                dmaToggle = dut.audio_ram_req;
                dmaAddress = dut.audio_ram_address;
                require(dmaAddress < pcmMemory.size(), "audio DMA escaped test PCM ring");
                dmaData = pcmMemory[dmaAddress];
                dmaDue = audioEdges + 5 + audioEdges % 13;
                dmaScheduled = true;
                ++dmaRequests;
            }
            if (dut.audio_actual_consumed != consumed && dut.audio_actual_consumed != 0) {
                require(dut.audio_actual_consumed == consumed + 1,
                        "actual consumed-sample counter skipped a stereo pair");
                heard.push_back(uint32_t(dut.audio_pcm_l) |
                                (uint32_t(dut.audio_pcm_r) << 16));
            }
        }
    }
    void publishPcmPointer(uint16_t qwords) {
        std::array<bool, 96> bits{};
        for (unsigned bit = 0; bit < 16; ++bit) {
            bits[35 + bit] = (pcmMemory.size() >> bit) & 1;
            bits[67 + bit] = (qwords >> bit) & 1;
        }
        dut.audio_spi_ss = 1;
        dut.audio_spi_sck = 0;
        run(3);
        dut.audio_spi_ss = 0;
        for (unsigned count = 0; count < 128; ++count) {
            const unsigned bit = (count & 0x78) | ((~count) & 7);
            dut.audio_spi_mosi = bit < bits.size() ? bits[bit] : 0;
            dut.audio_spi_sck = 0;
            run(3);
            dut.audio_spi_sck = 1;
            run(3);
        }
        dut.audio_spi_ss = 1;
        dut.audio_spi_sck = 0;
        run(20);
    }
    uint64_t load(uint32_t addr) const {
        return ddr.load(addr);
    }
    Metadata meta() const {
        return {dut.au_session_id, dut.au_pts, dut.au_duration, dut.au_seq,
                dut.au_timebase_num, dut.au_timebase_den, dut.au_flags};
    }
    void ctrl() {
        ddr.publishCtrl(wr, epoch);
    }
    void append(const Bytes& bytes, bool publish = true) {
        ddr.append(wr, bytes);
        if (publish)
            ctrl();
    }
    void tick() {
        ++cycles;
        serviceAudioConsumer();
        dut.clk = 0;
        dut.eval();
        advanceAudio(5);
        const auto transfer = ddr.beforePosedge(dut, cycles, forceBusy, randomStalls);
        if (transfer.read)
            require(dut.bus_want, "bus ownership released before acceptance");
        if (pending.valid)
            require(dut.bus_want, "outstanding read lost response ownership");
        const bool takeAudio = (dut.audio_rd || dut.audio_we) && !dut.audio_busy;
        if (dut.audio_dout_ready)
            audioResponses.push_back(dut.audio_dout);
        if (!dut.reset && !dut.core_local_reset) {
            if (heldByte && !dut.out_flush)
                require(dut.out_valid && dut.out_byte == priorByte &&
                        bool(dut.out_last) == priorLast, "held payload changed under stall");
            if (heldMeta && !dut.out_flush)
                require(dut.au_valid && meta() == priorMeta, "held metadata overwritten");
            heldByte = dut.out_valid && dut.out_full;
            heldMeta = dut.au_valid && !dut.au_ready;
            priorByte = dut.out_byte;
            priorLast = dut.out_last;
            priorMeta = meta();
            if (heldByte)
                ++fullCycles;
            if (dut.au_valid && dut.au_ready)
                metadata.push_back(meta());
            if (dut.out_valid && !dut.out_full) {
                accepted.push_back(dut.out_byte);
                if (dut.out_last)
                    lasts.push_back(accepted.size());
            }
            if (dut.out_flush)
                ++flushes;
        } else {
            heldByte = heldMeta = false;
        }
        const bool takeSink = dut.sink_read && !dut.sink_empty &&
                              !dut.reset && !dut.core_local_reset && !dut.out_flush;
        dut.clk = 1;
        dut.eval();
        if (takeAudio)
            dut.audio_rd = dut.audio_we = 0;
        if (takeSink)
            drained.push_back(dut.sink_byte);
        ddr.afterPosedge();
        if (transfer.write) {
            if (transfer.address >= abi::kVideoCapsAddr >> 3 &&
                transfer.address <= abi::kVideoCapsCommitAddr >> 3)
                capsWrites.push_back({transfer.address, transfer.data});
        }
        if (enforceResetFence && ddr.resetAcknowledged(0, epoch))
            require(dut.audio_consumer_quiescent && !dut.audio_actual_active &&
                    !dut.audio_actual_read_pending && !dut.audio_actual_prefetched &&
                    !dmaScheduled,
                    "fresh CTRL ACK preceded actual audio DMA/prefetch retirement");
        advanceAudio(5);
    }
    void run(unsigned count) { while (count--) tick(); }
    void until(const std::function<bool()>& predicate, const std::string& message,
               unsigned limit = 200000) {
        while (limit-- && !predicate())
            tick();
        require(predicate(), message + " at cycle " + std::to_string(cycles) +
                " read=" + std::to_string(dut.fpga_read_count) +
                " host=" + std::to_string(dut.host_write_count) +
                (REAL_ALSA_TEST ? " audio_active=" + std::to_string(dut.audio_actual_active) +
                 " audio_dma=" + std::to_string(dut.audio_actual_read_pending) +
                 " audio_prefetch=" + std::to_string(dut.audio_actual_prefetched) +
                 " consumer_quiescent=" + std::to_string(dut.audio_consumer_quiescent) : ""));
    }
    uint64_t audioRead(uint32_t address) {
        const size_t before = audioResponses.size();
        dut.audio_addr = address;
        dut.audio_rd = 1;
        dut.audio_we = 0;
        until([&] { return audioResponses.size() == before + 1; },
              "independent audio DDR read starved or lost ownership", 1000);
        return audioResponses.back();
    }
    void audioWrite(uint32_t address, uint64_t data) {
        dut.audio_addr = address;
        dut.audio_din = data;
        dut.audio_rd = 0;
        dut.audio_we = 1;
        until([&] { return !dut.audio_we; },
              "independent audio DDR write starved", 1000);
    }
    void publishAudioCommand(audio::Control command, uint64_t token,
                             uint32_t producerPosition = 0) {
        require(dut.audio_mailbox_mode, "actual audio mailbox is not selected");
        require(producerPosition <= 524284 && (producerPosition & 3) == 0,
                "invalid producer byte position in audio test command");
        audioExpectedProducerPosition = producerPosition;
        const auto words = audio::encodeControl(dut.video_session_id, dut.video_nonce,
                                                token, command, ++audioPublication,
                                                producerPosition);
        mem[abi::kAudioControlCommitAddr >> 3] = 0;
        for (unsigned i = 0; i < words.size(); ++i)
            mem[(abi::kAudioControlAddr >> 3) + i] = words[i];
    }
    bool audioAcknowledgedFor(audio::Control command, uint64_t token,
                              uint64_t expectedEpoch, uint64_t expectedNonce) const {
        std::array<uint64_t, 8> words{};
        for (unsigned i = 0; i < words.size(); ++i)
            words[i] = load((abi::kAudioStatusAddr >> 3) + i);
        audio::Status status;
        return audio::decodeStatus(words, status) &&
               audio::matchesAck(status, expectedEpoch, expectedNonce, token, command) &&
               audio::completed(status, command);
    }
    bool audioAcknowledged(audio::Control command, uint64_t token) const {
        return audioAcknowledgedFor(command, token, dut.video_session_id, dut.video_nonce);
    }
    void applyAudioCommand(audio::Control command, uint64_t token,
                           uint32_t producerPosition = 0) {
        publishAudioCommand(command, token, producerPosition);
        until([&] { return audioAcknowledged(command, token); },
              "actual audio mailbox failed nonce/token-bound completion", 20000);
    }
    void boot(uint32_t initial = 0) {
        wr = initial;
        ctrl();
        dut.reset = 1;
        dut.enable = 1;
        dut.flush = 0;
        dut.sink_block = 0;
        dut.sink_read = 1;
        dut.decoder_idle = 1;
        dut.au_ready = 1;
        dut.audio_rd = 0;
        dut.audio_we = 0;
        run(4);
        dut.reset = 0;
        until([&] {
            return ddr.resetAcknowledged(initial, epoch) &&
                   dut.fpga_read_count == initial;
        }, "CTRL baseline/epoch not acknowledged");
        run(100);
    }
    bool fatal() const {
        return (load(ring::kStat6Phys >> 3) >>
                (ring::kStat6StateFlagsShift + ring::kStat6FatalFlagBit)) & 1;
    }
    uint32_t publishedRead() const { return uint32_t(load(ring::kReadPhys >> 3) >> 32); }
    void ack() {
        until([&] { return publishedRead() == wr; }, "record consumer ACK timed out");
    }
    std::array<uint64_t, 8> caps() const {
        std::array<uint64_t, 8> words{};
        for (unsigned i = 0; i < words.size(); ++i)
            words[i] = load((abi::kVideoCapsAddr >> 3) + i);
        return words;
    }
    void probe(uint64_t challenge = nonce) {
        append(record(ring::Event::Probe, challenge, abi::kFpgaVideoLayoutId));
        until([&] {
            ring::VideoCapabilities result;
            return ddr.capabilitiesFor(challenge, result);
        }, "fresh Probe did not publish");
        ack();
        require(dut.video_nonce == challenge, "committed Probe nonce was not exported");
    }
    void begin(bool v2 = true, uint64_t useSession = session) {
        append(record(ring::Event::Begin, useSession, 0, {}, v2 ? 2 : 0));
        until([&] { return dut.active && publishedRead() == wr; }, "Begin failed");
        require(dut.video_session_id == useSession, "Begin epoch not exported before first AU");
    }
};

enum class ResetAudioState { Running, PausePending, Paused };

void testActualAudioReset(bool framework, ResetAudioState state,
                          unsigned audioHalfPeriod, bool routeCoreReset) {
    Sim s;
    s.audioHalfPeriod = audioHalfPeriod;
    s.audioPhase = audioHalfPeriod - 1;
    s.dut.route_core_audio_reset = routeCoreReset;
    s.dut.audio_mailbox_mode = 1;
    s.boot();
    s.probe();
    s.begin();
    s.publishPcmPointer(0);
    s.applyAudioCommand(audio::Control::Begin, 101);
    require(s.dut.audio_actual_active && s.dut.audio_actual_paused,
            "real ALSA did not enter priming-paused before AU0");
    s.pcmMemory[0] = 0x0012001200110011ull;
    s.pcmMemory[1] = 0x0014001400130013ull;
    s.publishPcmPointer(2);
    s.holdDma = true;
    s.applyAudioCommand(audio::Control::Resume, 102, 16);
    s.until([&] { return s.dmaScheduled && s.dut.audio_actual_read_pending; },
            "real ALSA never issued the DMA to hold");
    require(s.dmaRequests == 1 && s.dmaResponses == 0 && s.heard.empty(),
            "held-DMA setup consumed or retired PCM");
    if (state != ResetAudioState::Running) {
        s.append(record(ring::Event::Pause, session));
        s.ack();
        s.publishAudioCommand(audio::Control::Pause, 103, 16);
        s.until([&] { return s.dut.audio_actual_pending; },
                "Pause did not reach real ALSA while DMA was held");
        if (state == ResetAudioState::Paused) {
            // A completed Pause cannot still own a DMA. Retire it first and
            // keep its actual prefetched pairs, rather than forcing RTL state.
            s.holdDma = false;
            s.until([&] { return s.audioAcknowledged(audio::Control::Pause, 103); },
                    "real Pause ACK did not follow DMA retirement");
            require(s.dut.audio_actual_paused && s.dut.audio_actual_prefetched != 0 &&
                    !s.dut.audio_actual_read_pending && !s.dmaScheduled,
                    "completed Pause lost its retained PCM prefetch");
        }
    }
    require(s.dut.audio_actual_active && !s.dut.audio_consumer_quiescent &&
            s.heard.empty(), "reset did not start from owned old-session audio");
    const unsigned requestsBeforeReset = s.dmaRequests;
    const unsigned responsesBeforeReset = s.dmaResponses;
    s.epoch = !s.epoch;
    s.wr = 0;
    s.ctrl(); // Preserve old ring, capability, audio command and status DDR.
    s.enforceResetFence = true;
    if (framework)
        s.dut.reset = 1;
    else
        s.dut.core_local_reset = 1;
    s.dut.eval();
    if (framework || routeCoreReset)
        require(s.dut.audio_reset, "audio reset did not assert asynchronously");
    s.run(19);
    require(s.dut.video_session_id == 0 && s.dut.video_nonce == 0,
            "core reset did not clear video identity");
    s.dut.reset = 0;
    s.dut.core_local_reset = 0;
    s.dut.eval();
    if (framework || routeCoreReset) {
        for (unsigned i = 0, edges = 0; edges < 2; ++i) {
            require(i < 100, "audio reset release clock did not advance");
            const uint64_t before = s.audioEdges;
            s.advanceAudio(1);
            if (s.audioEdges != before) {
                ++edges;
                require(bool(s.dut.audio_reset) == (edges < 2),
                        "audio reset release was not synchronized through two audio edges");
            } else {
                require(s.dut.audio_reset, "audio reset released between audio clock edges");
            }
        }
    }
    s.until([&] { return s.dut.reset_pending; }, "reader did not enter fresh CTRL fence");
    if (state != ResetAudioState::Paused) {
        for (unsigned i = 0; i < 3000; ++i) {
            s.tick();
            require(s.dmaScheduled && s.dut.audio_actual_read_pending &&
                    s.dmaRequests == requestsBeforeReset &&
                    s.dmaResponses == responsesBeforeReset &&
                    !s.dut.audio_consumer_quiescent &&
                    !s.ddr.resetAcknowledged(0, s.epoch) && s.heard.empty(),
                    "held old DMA was lost, duplicated, played, or acknowledged across reset");
        }
        s.holdDma = false;
    }
    s.until([&] { return s.dmaResponses == requestsBeforeReset; },
            "owned old audio DMA did not retire exactly once");
    s.until([&] { return s.ddr.resetAcknowledged(0, s.epoch); },
            "core-local reset stranded actual ALSA: no physical quiescence/fresh CTRL ACK",
            30000);
    require(!s.dut.audio_actual_active && !s.dut.audio_actual_read_pending &&
            !s.dut.audio_actual_prefetched && s.dut.audio_consumer_quiescent &&
            s.dmaRequests == requestsBeforeReset && s.heard.empty(),
            "reset ACK retained or replayed old-session PCM");
    require(!s.dut.audio_clock_valid && s.dut.video_nonce == 0,
            "reset retained an old clock/capability binding");
    s.enforceResetFence = false;

    const uint64_t newNonce = nonce + 100 + audioHalfPeriod;
    const uint64_t newSession = session + 100 + audioHalfPeriod;
    ring::VideoCapabilities caps;
    require(!s.ddr.capabilitiesFor(newNonce, caps), "stale DDR qualified a fresh Probe");
    s.probe(newNonce);
    s.begin(true, newSession);
    s.applyAudioCommand(audio::Control::Begin, 201, 16);
    s.pcmMemory[2] = 0x0022002200210021ull;
    s.publishPcmPointer(3);
    s.applyAudioCommand(audio::Control::Resume, 202, 24);
    s.until([&] { return s.heard.size() == 2; }, "new-session PCM did not resume");
    require(s.heard == std::vector<uint32_t>{0x00210021, 0x00220022},
            "fresh Begin replayed old PCM after reset");
    const Bytes encoded{0, 0, 1, 0x65, 0x88, 0x80};
    s.append(accessUnit(encoded, 0, newSession));
    s.append(record(ring::Event::Drain, newSession));
    s.until([&] { return s.drained == encoded; }, "fresh Begin did not recover AU ingress");
    s.ack();
    require(s.dut.audio_actual_active && !s.dut.audio_consumer_quiescent &&
            s.dut.audio_clock_valid && s.dut.audio_clock_epoch == newSession &&
            s.dut.audio_clock_nonce == newNonce,
            "normal Drain blocked active recovered audio or used a stale clock");
    s.applyAudioCommand(audio::Control::Reset, 203, 24);
    require(s.dmaRequests == s.dmaResponses && !s.dmaScheduled,
            "composed reset test left an owned DMA");
    std::cout << "PASS real reader/mailbox/ALSA " << (framework ? "framework" : "core-local")
              << " reset, "
              << (state == ResetAudioState::Running ? "running-held-DMA" :
                  state == ResetAudioState::PausePending ? "pending-Pause-held-DMA" :
                                                         "paused-retained-prefetch")
              << ", audio half-period=" << audioHalfPeriod
              << ", CTRL fence -> fresh Probe/Begin/AU/PCM/Drain\n";
}

void testCaps() {
    Sim s;
    // A fully valid stale reply is deliberately present at boot.
    const std::array<uint32_t, 8> magics{abi::kVideoCapsMagic, abi::kVideoFeaturesMagic,
        abi::kVideoDimensionsMagic, abi::kVideoAuLimitMagic, abi::kVideoBuildMagic,
        abi::kVideoNonceLowMagic, abi::kVideoNonceHighMagic, abi::kVideoCapsCommitMagic};
    for (unsigned i = 0; i < magics.size(); ++i)
        s.mem[(abi::kVideoCapsAddr >> 3) + i] = 0x1234567800000000ull | magics[i];
    s.boot();
    require(s.capsWrites.empty(), "capabilities published without Probe");
    require(s.dut.video_nonce == 0, "stale DDR qualified the feedback nonce at boot");
    require(s.dut.video_session_id == 0, "stale DDR qualified the session epoch at boot");
    ring::VideoCapabilities result;
    require(!ring::decodeVideoCapabilities(s.caps(), nonce, result), "stale nonce qualified");
    s.probe();
    require(s.dut.video_session_id == 0, "Probe nonce was mistaken for a session epoch");
    require(s.capsWrites.size() == 9, "Probe did not invalidate then publish exactly eight words");
    require(s.capsWrites[0].addr == abi::kVideoCapsCommitAddr >> 3 &&
            s.capsWrites[0].value >> 32 == 0, "old publication not invalidated first");
    for (unsigned i = 0; i < magics.size(); ++i)
        require(s.capsWrites[i + 1].addr == (abi::kVideoCapsAddr >> 3) + i &&
                uint32_t(s.capsWrites[i + 1].value) == magics[i],
                "capability address/magic/order differs from authoritative host ABI");
    require(ring::decodeVideoCapabilities(s.caps(), nonce, result), "host failed caps decode");
    require(result.abi_version == abi::kFpgaVideoAbiVersion &&
            result.layout_id == abi::kFpgaVideoLayoutId &&
            result.max_au_bytes == configuredMaxAuBytes &&
            result.max_au_bytes <= ring::kMaxAccessUnitBytes &&
            result.max_width == 640 && result.max_height == 480,
            "RTL capability fields differ from host contract/default parameters");
    require(result.features == (AU_MODE ? ring::AccessUnits : 0) &&
            result.build_id == (AU_MODE ? 0xA1B2C3D4u : 0u) && !result.supportsVideo(),
            "reader falsely advertised decoder/color/commit");
    s.run(500);
    require(s.capsWrites.size() == 9, "capabilities republished on byte/telemetry path");
    s.append(record(ring::Event::Probe, nonce + 1, abi::kFpgaVideoLayoutId));
    s.until([&] { return s.capsWrites.size() == 17; }, "nonce words were not published");
    s.forceBusy = true;
    s.run(100);
    require(!ring::decodeVideoCapabilities(s.caps(), nonce + 1, result),
            "new nonce qualified before accepted final publication write");
    require(s.dut.video_nonce == 0, "uncommitted Probe leaked a feedback nonce");
    s.forceBusy = false;
    s.ack();
    require(s.dut.video_nonce == nonce + 1, "final commit did not export new feedback nonce");
    require(s.capsWrites.size() == 18, "second fresh challenge did not republish");
    require(!ring::decodeVideoCapabilities(s.caps(), nonce, result), "old challenge still matched");
    s.append(record(ring::Event::Probe, nonce + 1, abi::kFpgaVideoLayoutId));
    s.until([&] { return s.fatal(); }, "replayed Probe not rejected");
    require(s.capsWrites.size() == 18, "rejected Probe echoed a nonce");
    require(s.dut.video_nonce == nonce + 1, "rejected Probe changed the accepted feedback binding");
    require(s.busyOffers > 0, "DDR busy test never rejected an offered command");
    std::cout << "PASS caps ABI addresses/magics/order, nonce, non-decoder/default flags\n";
}

void testLegacy() {
    Sim s;
    s.boot(ring::kCountMask - 20);
    s.begin(false);
    Bytes encoded{0, 0, 1, 0x65, 1, 2, 3, 4, 0, 0, 3, 1, 0x80};
    s.append(record(ring::Event::Nal, session, 0, encoded, 0));
    s.until([&] { return s.drained.size() == encoded.size(); }, "legacy NAL not delivered");
    s.ack();
    require(s.accepted == encoded && s.drained == encoded && s.lasts == std::vector<size_t>{encoded.size()},
            "legacy ABI0 bytes/boundary changed");
    require(s.metadata.empty() && s.dut.overrun_count == 0, "legacy wrap generated AU/overrun");
    require(s.wr < 256 && s.publishedRead() == s.wr, "2^31 counter failed to wrap");
    std::cout << "PASS legacy ABI0, ring wrap and modulo-2^31 counter conservation\n";
}

void testAuStallsAndDrain() {
    Sim s;
    s.boot();
    s.probe();
    s.begin();
    Bytes first{0, 0, 0, 1, 0x67, 0x21, 0, 0, 1, 0x68, 0x31,
                0, 0, 1, 0x65, 0x88, 0, 0, 3, 1, 0x80};
    Bytes second{0, 0, 1, 0x41, 0x98, 0x40};
    s.dut.au_ready = 0;
    s.dut.sink_read = 0;
    s.dut.decoder_idle = 0;
    s.append(accessUnit(first));
    s.append(accessUnit(second, 1));
    const uint32_t drainStart = s.wr;
    s.append(record(ring::Event::Drain, session));
    s.until([&] { return s.dut.au_valid; }, "AU metadata missing");
    const Metadata held = s.meta();
    s.run(500);
    require(s.accepted.empty() && s.meta() == held, "encoded bytes preceded metadata accept");
    require(held.session_id == session && int64_t(held.pts) == -9001 &&
            held.duration == 3000 && held.num == 1 && held.den == 90000 &&
            held.flags == ring::kAccessUnitKeyframe, "metadata offsets/signedness incorrect");
    s.dut.au_ready = 1;
    s.until([&] { return s.accepted.size() == 8; }, "tiny FIFO never filled");
    s.run(1000);
    require(s.accepted.size() == 8 && s.fullCycles > 0, "backpressure failed to hold payload");
    const uint64_t audioWord = 0x0123456789ABCDEFull;
    s.mem[abi::kAudioControlAddr >> 3] = audioWord;
    require(s.audioRead(abi::kAudioControlAddr >> 3) == audioWord,
            "full video FIFO blocked or corrupted independent audio control read");
    s.dut.sink_read = 1;
    s.dut.sink_block = 1;
    s.run(200);
    require(s.accepted.size() == 8, "sink_block did not retain pending byte");
    s.dut.sink_block = 0;
    s.until([&] { return s.drained.size() == first.size() + second.size(); },
            "composed FIFO/read stalls lost AU bytes");
    s.run(800);
    require(s.dut.fpga_read_count == ((drainStart + 31) & ring::kCountMask) &&
            ring::countDistance(s.publishedRead(), drainStart) < 32,
            "Drain last header byte published before decoder retired");
    require(s.metadata.size() == 2 && s.metadata[1].seq == 1, "metadata handshake count/order");
    Bytes both = first;
    both.insert(both.end(), second.begin(), second.end());
    require(s.drained == both && s.accepted == both &&
            s.lasts == std::vector<size_t>{first.size(), both.size()},
            "AU bytes/EPB/final AU without following startcode corrupted");
    const unsigned flushes = s.flushes;
    s.dut.decoder_idle = 1;
    s.ack();
    s.run(100);
    require(s.flushes == flushes && s.dut.active, "EOF Drain discarded final picture/session");
    std::cout << "PASS AU metadata-before-bytes, composed full/stalls, multi-NAL/final-AU, Drain fence\n";
}

void testFences() {
    Sim s;
    s.boot(); s.probe();
    s.dut.decoder_idle = 0;
    s.append(record(ring::Event::Begin, session));
    s.run(3000);
    require(!s.dut.active && s.dut.fpga_read_count == s.wr - 1 &&
            s.publishedRead() < s.wr, "Begin did not fence old decoder transactions");
    s.dut.decoder_idle = 1;
    s.ack();
    require(s.dut.active, "Begin did not release after decoder idle");
    const Bytes encoded{0, 0, 1, 0x65, 0x80};
    s.append(accessUnit(encoded));
    s.until([&] { return s.drained.size() == encoded.size(); }, "pre-Flush AU missing");
    s.dut.decoder_idle = 0;
    s.append(record(ring::Event::Flush, session));
    s.run(3000);
    require(s.dut.fpga_read_count == s.wr - 1 && s.publishedRead() < s.wr, "Flush ACK unfenced");
    const unsigned flushes = s.flushes;
    s.dut.decoder_idle = 1;
    s.ack(); s.run(5);
    require(s.flushes == flushes + 1, "Flush did not clear after drain");
    s.append(accessUnit(encoded)); // Flush restarts AU sequence at zero.
    s.until([&] { return s.drained.size() == encoded.size() * 2; }, "Flush did not reset AU sequence");
    s.dut.decoder_idle = 0;
    s.append(record(ring::Event::End, session));
    s.run(3000);
    require(s.dut.active && s.publishedRead() < s.wr, "End ACK retired early");
    s.dut.decoder_idle = 1; s.ack();
    require(!s.dut.active, "End never retired");
    require(s.dut.video_session_id == session, "End lost epoch needed for final feedback");
    std::cout << "PASS Begin/Flush/End decoder/write fence and Flush sequence reset\n";
}

void testPause() {
    Sim s;
    s.boot(); s.probe(); s.begin();
    s.append(record(ring::Event::Pause, session));
    s.ack();
    const uint32_t pauseAck = s.wr;
    const Bytes first{0, 0, 1, 0x41, 1, 2, 3, 4, 5, 0x80};
    const Bytes second{0, 0, 1, 0x41, 6, 7, 8, 0x80};
    const Bytes pending = accessUnit(first);
    s.append(Bytes(pending.begin(), pending.begin() + 40));
    s.run(1500); // Partial paused record must poll, not mistake payload for a header.
    require(s.accepted.empty() && s.dut.fpga_read_count == pauseAck, "Pause consumed/dropped pending AU");
    s.append(Bytes(pending.begin() + 40, pending.end()));
    s.append(accessUnit(second, 1));
    s.run(3000);
    require(s.accepted.empty() && s.publishedRead() == pauseAck, "paused data was acknowledged");
    s.append(record(ring::Event::Resume, session));
    s.until([&] { return s.drained.size() == first.size() + second.size(); }, "Resume behind pending P frames deadlocked");
    s.ack();
    Bytes both = first; both.insert(both.end(), second.begin(), second.end());
    require(s.drained == both && s.metadata.size() == 2 && !s.fatal(), "Pause replay dropped/reordered P frames");
    // Empty paused sessions still accept control fences; Stop while paused
    // cannot require a nonexistent extra Resume.
    s.append(record(ring::Event::Pause, session)); s.ack();
    s.append(record(ring::Event::Pause, session)); s.ack();
    s.append(record(ring::Event::Flush, session)); s.ack();
    s.append(record(ring::Event::Drain, session)); s.ack();
    s.append(record(ring::Event::End, session)); s.ack();
    require(!s.dut.active, "End while paused with no queued AU deadlocked");
    std::cout << "PASS Pause/partial AU/backpressure/Resume lookahead with byte-preserving replay\n";
}

void testLargeAu() {
    Sim s;
    s.boot(ring::kRingBytes - 100); s.probe(); s.begin();
    Bytes encoded(configuredMaxAuBytes, 0x55);
    encoded[0] = encoded[1] = encoded[2] = 0; encoded[3] = 1; encoded[4] = 0x65;
    encoded.back() = 0x80;
    s.append(accessUnit(encoded));
    for (unsigned n = 0; n < 6000000 && s.drained.size() != encoded.size(); ++n) {
        s.dut.sink_read = n % 101 > 19;
        s.dut.sink_block = n % 37 < 3;
        s.tick();
    }
    s.dut.sink_read = 1; s.dut.sink_block = 0;
    s.until([&] { return s.drained.size() == encoded.size(); }, "maximum AU did not drain");
    s.ack();
    require(s.accepted == encoded && s.drained == encoded &&
            s.lasts == std::vector<size_t>{encoded.size()} && s.dut.overrun_count == 0,
            "maximum AU failed wrap/conservation");
    require(s.capsWrites.size() == 9, "maximum AU triggered per-byte capability writes");
    std::cout << "PASS maximum " << configuredMaxAuBytes
              << "-byte AU, physical wrap and variable FIFO/DDR stalls\n";
}

void testPausedAudioLane() {
    Sim s;
    s.boot(); s.probe(); s.begin();
    s.dut.audio_mailbox_mode = 1;
    uint64_t audioToken = 0x1234567800000000ull;
    s.applyAudioCommand(audio::Control::Begin, ++audioToken, 0x40004);
    s.append(record(ring::Event::Pause, session));
    s.ack();
    const uint32_t pausedCount = s.wr;
    Bytes expected;
    // 32 records * 8191 bytes = 262112, leaving exactly one 32-byte control
    // slot. Every encoded AU fits the conservative integrated 8192 limit.
    constexpr size_t records = 32;
    const size_t encodedLength =
        (ring::kRingBytes - ring::kControlReserveBytes) / records -
        ring::kRecordHeaderBytes - ring::kAccessUnitMetadataBytes;
    for (size_t i = 0; i < records; ++i) {
        Bytes encoded(encodedLength, uint8_t(0x40 + i));
        encoded[0] = encoded[1] = 0; encoded[2] = 1;
        encoded[3] = i ? 0x41 : 0x65;
        encoded.back() = 0x80;
        expected.insert(expected.end(), encoded.begin(), encoded.end());
        const auto bytes = accessUnit(encoded, uint32_t(i));
        require(s.ddr.canAppend(s.wr, bytes.size()), "shared BFM rejected available AU capacity");
        s.append(bytes, false);
    }
    s.ctrl();
    require(!s.ddr.canAppend(s.wr, ring::kRecordHeaderBytes + ring::kAccessUnitMetadataBytes + 1) &&
            s.ddr.canAppend(s.wr, ring::kRecordHeaderBytes, false),
            "shared BFM did not preserve exactly one control slot");
    s.run(6000);
    require(s.publishedRead() == pausedCount && s.accepted.empty() &&
            ring::countDistance(s.wr, pausedCount) ==
                ring::kRingBytes - ring::kControlReserveBytes,
            "paused ring did not preserve payload and the single control reserve");
    for (auto command : {audio::Control::Pause, audio::Control::Resume,
                         audio::Control::Pause, audio::Control::Reset}) {
        const unsigned before = s.audioCommandsSeen;
        s.audioConsumerBlocked = true;
        s.publishAudioCommand(command, ++audioToken,
                              command == audio::Control::Reset ? 524284 : 0x40004);
        s.until([&] { return s.audioCommandsSeen == before + 1; },
                "real mailbox command starved behind paused/full video");
        s.run(200);
        require(!s.audioAcknowledged(command, audioToken) &&
                s.audioCommandsApplied == before && !s.dut.audio_clock_valid,
                "mailbox acknowledged audio control before consumer completion");
        s.audioConsumerBlocked = false;
        s.until([&] { return s.audioAcknowledged(command, audioToken); },
                "audio control completion lost while video paused");
        require(bool(s.dut.audio_clock_valid) == (command != audio::Control::Reset),
                "coherent audio clock validity did not follow Pause/Resume/Reset completion");
        require(s.publishedRead() == pausedCount && s.accepted.empty(),
                "audio Pause/Resume/Reset consumed/dropped paused video");
    }
    require(s.dut.active && s.dut.video_session_id == session &&
            s.dut.video_nonce == nonce && !s.dut.audio_clock_active &&
            !s.dut.audio_clock_valid && s.dut.audio_clock_samples == 0,
            "audio Reset corrupted independent video lifecycle or fabricated PCM progress");
    s.dut.sink_read = 0;
    s.append(record(ring::Event::Resume, session));
    require(ring::countDistance(s.wr, pausedCount) == ring::kRingBytes,
            "Resume did not use exactly the reserved 32 bytes");
    s.until([&] { return s.accepted.size() == 8 && s.dut.out_full; },
            "resumed video FIFO did not reach backpressure");
    for (auto command : {audio::Control::Begin, audio::Control::Resume,
                         audio::Control::Pause, audio::Control::Reset}) {
        s.applyAudioCommand(command, ++audioToken, 0x20008);
        require(s.accepted.size() == 8 && s.drained.empty(),
                "audio command cleared/overran a backpressured video FIFO");
    }
    require(s.audioCommandsSeen == 9 && s.audioCommandsApplied == 9 &&
            s.dut.audio_clock_epoch == session && s.dut.audio_clock_nonce == nonce &&
            s.dut.audio_clock_samples == 0,
            "audio mailbox duplicated commands or lost epoch/nonce/64-bit token");
    s.dut.sink_read = 1;
    s.until([&] { return s.drained.size() == expected.size(); },
            "full-ring Resume replay did not drain", 12000000);
    s.ack();
    require(s.drained == expected && s.accepted == expected &&
            s.metadata.size() == records && s.lasts.size() == records &&
            s.dut.overrun_count == 0 && !s.fatal(),
            "paused video lost bytes/ownership while audio DDR progressed");
    ring::Status transport;
    require(s.ddr.readStatus(transport) && transport.consumer_seq == records - 1 &&
            transport.session_id == session && !transport.desync,
            "shared BFM transport status omitted sequence/session fields");
    std::cout << "PASS real reader+mux+mailbox: causal Audio Pause/Resume/Reset under pause/full/stalls, reserve32\n";
}

void testLiveBeginIdentityBeforeAu() {
    Sim s;
    s.boot(); s.probe();
    require(s.dut.video_session_id == 0 && s.dut.video_nonce == nonce &&
            s.dut.au_session_id == 0 && !s.dut.au_valid,
            "Probe was mistaken for a live Begin/AU identity");
    s.dut.decoder_idle = 0;
    s.append(record(ring::Event::Begin, session));
    s.until([&] { return s.dut.fpga_read_count == s.wr - 1; }, "pre-AU Begin fence not reached");
    s.run(200);
    require(!s.dut.active && s.dut.video_session_id == 0,
            "live Begin epoch became valid before actual retirement fence");
    s.dut.decoder_idle = 1;
    s.until([&] { return s.dut.active && s.publishedRead() == s.wr; }, "pre-AU Begin not acknowledged");
    require(s.dut.video_session_id == session && s.dut.video_nonce == nonce &&
            s.dut.au_session_id == 0 && s.metadata.empty() && s.accepted.empty(),
            "accepted Begin epoch depends on AU0/presentation metadata");

    s.dut.audio_mailbox_mode = 1;
    s.applyAudioCommand(audio::Control::Begin, 0xC012345600000001ull, 524284);
    require(s.audioState.session_id == session && s.audioState.nonce == nonce &&
            s.audioState.active && s.audioState.paused && s.dut.audio_clock_valid &&
            s.dut.au_session_id == 0,
            "real audio mailbox could not bind before AU0");
    s.append(record(ring::Event::Pause, session)); s.ack();
    require(s.dut.video_session_id == session && s.dut.video_nonce == nonce,
            "Pause changed live video identity before AU0");
    s.applyAudioCommand(audio::Control::Reset, 0xC012345600000002ull, 20);
    s.append(record(ring::Event::End, session)); s.ack();
    require(!s.dut.active && s.dut.video_session_id == session &&
            s.dut.video_nonce == nonce && s.dut.au_session_id == 0,
            "End failed to preserve identity for bound final feedback/reset");

    s.dut.decoder_idle = 0;
    s.epoch = !s.epoch; s.wr = 0; s.ctrl();
    s.until([&] { return s.dut.reset_pending; }, "pre-AU CTRL reset not observed");
    require(s.dut.video_session_id == session && s.dut.video_nonce == nonce &&
            s.dut.transport_quiescent, "pending reset lost recovery identity before retirement");
    s.run(200);
    require(s.dut.reset_pending, "pre-AU reset ignored actual retirement fence");
    s.dut.decoder_idle = 1;
    s.until([&] {
        ring::Status status;
        return audio::completed(s.audioState, audio::Control::Reset) &&
               ring::decodeErrStatusWord(s.load(ring::kErrPhys >> 3), status) &&
               s.publishedRead() == 0 && !status.active && status.reset_epoch == s.epoch;
    }, "pre-AU reset lacked verified audio/CTRL completion");
    require(s.dut.video_session_id == 0 && s.dut.video_nonce == 0 &&
            !s.dut.reset_pending && s.metadata.empty() && s.accepted.empty(),
            "fenced CTRL reset failed to invalidate pre-AU live identity");
    std::cout << "PASS live Begin epoch/nonce BEFORE AU0: real mailbox Begin and pause/end/reset identity\n";
}

void testDrainVersusAudioResetFence() {
    Sim s;
    s.dut.audio_mailbox_mode = 1;
    s.boot(); s.probe(); s.begin();
    require(s.dut.audio_consumer_quiescent && !s.dut.audio_clock_valid,
            "bootstrap confused inactive retirement with a valid playback clock");
    uint64_t token = 0xA123456700000001ull;
    s.applyAudioCommand(audio::Control::Begin, token, 0x40004);
    require(!s.dut.audio_consumer_quiescent && s.dut.audio_clock_active &&
            s.dut.audio_clock_paused && s.dut.audio_clock_valid,
            "Audio Begin did not establish a valid paused clock independently of reset quiescence");

    const Bytes encoded{0, 0, 1, 0x65, 0x88, 0x80};
    const unsigned initialFlushes = s.flushes;
    s.append(accessUnit(encoded));
    s.append(record(ring::Event::Drain, session));
    s.ack();
    require(s.drained == encoded && !s.dut.audio_consumer_quiescent &&
            s.dut.audio_clock_valid,
            "video Drain wrongly required inactive paused audio");
    s.applyAudioCommand(audio::Control::Resume, ++token);
    s.append(record(ring::Event::Drain, session)); s.ack();
    require(s.dut.audio_clock_active && !s.dut.audio_clock_paused &&
            !s.dut.audio_consumer_quiescent && s.flushes == initialFlushes,
            "video Drain stopped active audio or flushed the final AU");
    s.applyAudioCommand(audio::Control::Pause, ++token);

    // Force the recovery ordering too: the observed video reset must retain
    // old identity and wait, allowing independent bound AudioReset to finish.
    s.epoch = !s.epoch; s.wr = 0; s.ctrl();
    s.until([&] { return s.dut.reset_pending; }, "audio-fenced CTRL reset not observed");
    s.run(250);
    require(!s.ddr.resetAcknowledged(0, s.epoch) && s.dut.reset_pending &&
            s.dut.video_session_id == session && s.dut.video_nonce == nonce &&
            !s.dut.audio_clock_valid && !s.dut.audio_consumer_quiescent,
            "CTRL reset ACK bypassed actual audio quiescence");
    s.audioConsumerBlocked = true;
    s.publishAudioCommand(audio::Control::Reset, ++token, 524284);
    s.until([&] { return s.audioApplying; }, "AudioReset not reachable during video reset");
    s.run(200);
    require(!s.dut.audio_consumer_quiescent && !s.ddr.resetAcknowledged(0, s.epoch),
            "CTRL reset treated AudioReset dispatch as completion");
    s.audioConsumerBlocked = false;
    s.until([&] {
        return s.audioAcknowledgedFor(audio::Control::Reset, token, session, nonce) &&
               s.ddr.resetAcknowledged(0, s.epoch);
    }, "actual consumer quiescence did not release fenced CTRL reset");
    require(s.dut.audio_consumer_quiescent && !s.dut.reset_pending &&
            s.dut.video_session_id == 0 && s.dut.video_nonce == 0 &&
            !s.dut.audio_clock_valid,
            "retired reset did not invalidate the old video identity");
    std::cout << "PASS normal Drain with active/paused audio; CTRL reset waits real mailbox quiescence\n";
}

void reject(const std::string& label, const std::function<void(Bytes&)>& mutation,
            bool start = true) {
    Sim s;
    s.boot(); s.probe();
    if (start) s.begin();
    Bytes bad = accessUnit(Bytes{0, 0, 1, 0x65, 0x80});
    mutation(bad);
    const size_t capsCount = s.capsWrites.size();
    s.append(bad);
    s.until([&] { return s.fatal(); }, "malformed record accepted: " + label);
    require(s.accepted.empty() && s.metadata.empty(), "rejected record emitted bytes/metadata: " + label);
    require(s.capsWrites.size() == capsCount, "rejected record published capabilities: " + label);
}

void testRejected() {
    reject("ABI", [](Bytes& b) { b[6] = 3; });
    reject("reserved header28", [](Bytes& b) { b[28] = 1; });
    reject("old epoch", [](Bytes& b) { b[8] ^= 1; });
    reject("sequence", [](Bytes& b) { b[16] = 1; });
    reject("NAL in v2", [](Bytes& b) { b[4] = uint8_t(ring::Event::Nal); });
    reject("zero timebase numerator", [](Bytes& b) { ring::putLe32(b.data() + 40, 0); });
    reject("zero timebase denominator", [](Bytes& b) { ring::putLe32(b.data() + 44, 0); });
    reject("timebase highbit", [](Bytes& b) { ring::putLe32(b.data() + 44, 0x80000000); });
    reject("no timestamp", [](Bytes& b) { ring::putLe64(b.data() + 32, uint64_t(ring::kNoTimestamp)); });
    reject("negative duration", [](Bytes& b) { ring::putLe64(b.data() + 48, ~uint64_t(0)); });
    reject("flags", [](Bytes& b) { b[56] = 2; });
    reject("reserved metadata", [](Bytes& b) { b[60] = 1; });
    reject("empty AU", [](Bytes& b) { ring::putLe32(b.data() + 20, 32); });
    reject("oversized AU", [](Bytes& b) { ring::putLe32(b.data() + 20, configuredMaxAuBytes + 33); });
    reject("active Probe", [](Bytes& b) { b = record(ring::Event::Probe, nonce + 55, abi::kFpgaVideoLayoutId); });
    reject("zero Begin session", [](Bytes& b) { b = record(ring::Event::Begin, 0); }, false);
    reject("Probe layout", [](Bytes& b) { b = record(ring::Event::Probe, nonce + 55, 2); }, false);
    reject("Probe zero nonce", [](Bytes& b) { b = record(ring::Event::Probe, 0, 1); }, false);
    std::cout << "PASS malformed/unsupported ABI, epoch, sequence, length and metadata fail closed\n";
}

void testResetOwnership() {
    Sim s;
    s.boot(); s.probe(); s.begin();
    // A long accepted read is still outstanding at the reset edge.
    s.until([&] { return s.pending.valid && s.pending.delay > 4; }, "no in-flight response for reset");
    const unsigned readCount = s.reads;
    s.dut.reset = 1;
    s.run(2);
    s.dut.reset = 0;
    s.run(50);
    require(s.reads >= readCount && s.accepted.empty(), "reset lost/consumed stale response");
    s.run(1000);
    require(!s.dut.active && s.dut.fpga_read_count == s.wr, "reset replayed stale DDR records");
    require(s.dut.video_nonce == 0, "reset retained old feedback nonce");
    ring::VideoCapabilities result;
    require(!ring::decodeVideoCapabilities(s.caps(), nonce + 100, result), "stale DDR caps qualified reset boot");
    s.probe(nonce + 100);
    require(!s.fatal(), "fresh post-reset challenge failed");

    // Disable cannot abandon an accepted read, and re-enable must not pair
    // the retired response with a newly issued command.
    s.until([&] { return s.pending.valid && s.pending.delay > 4; }, "no response for disable");
    s.dut.enable = 0;
    s.run(80);
    require(!s.pending.valid && !s.dut.DDRAM_RD && !s.dut.DDRAM_WE, "disabled reader left command owned");
    s.dut.enable = 1;
    s.begin();
    // External flush waits for old decoder/write ownership, even when its
    // request arrives while CTRL has a delayed DDR response.
    s.until([&] { return s.pending.valid && s.pending.delay > 4; }, "no response for flush");
    s.dut.decoder_idle = 0;
    s.dut.flush = 1; s.tick(); s.dut.flush = 0;
    s.run(200);
    require(s.dut.active, "external flush bypassed decoder fence");
    s.dut.decoder_idle = 1;
    s.until([&] { return !s.dut.active && !s.pending.valid; }, "external flush did not retire");
    s.probe(nonce + 101); s.begin();

    s.dut.decoder_idle = 0;
    s.epoch = !s.epoch;
    s.wr = 0; // Host resets producer, but leaves every old ring byte intact.
    s.ctrl();
    s.run(1000);
    require(s.dut.active && s.dut.fpga_read_count != s.wr &&
            bool((s.load(ring::kErrPhys >> 3) >> ring::kErrResetEpochBit) & 1) != s.epoch,
            "CTRL reset epoch acknowledged before decoder write drain");
    s.dut.decoder_idle = 1;
    s.until([&] {
        ring::Status status;
        return ring::decodeErrStatusWord(s.load(ring::kErrPhys >> 3), status) &&
               s.publishedRead() == 0 && !status.active && status.reset_epoch == s.epoch;
    }, "host READ=0/inactive/acknowledged-epoch reset handshake failed");
    require(!s.dut.active, "CTRL epoch reset failed to retire prior session");
    require(s.dut.video_nonce == 0, "CTRL epoch reset retained old feedback nonce");
    require(s.dut.video_session_id == 0, "CTRL reset retained old audio/feedback session epoch");
    s.probe(nonce + 102);
    std::cout << "PASS in-flight reset/disable retirement, stale DDR baseline and fresh post-reset Probe\n";
}

void testResetOfferedWrite() {
    Sim s;
    s.boot();
    s.append(record(ring::Event::Probe, nonce, abi::kFpgaVideoLayoutId));
    s.until([&] { return s.capsWrites.size() == 2; }, "Probe write setup failed");
    s.forceBusy = true;
    s.until([&] { return s.dut.DDRAM_WE; }, "no offered write under busy");
    s.dut.reset = 1; s.run(3); s.dut.reset = 0;
    s.run(30);
    require(s.dut.DDRAM_WE && s.capsWrites.size() == 2, "reset abandoned unaccepted write");
    s.forceBusy = false;
    s.run(2000);
    require(s.capsWrites.size() == 3, "reset duplicated/continued cancelled capability publication");
    require((s.caps()[7] >> 32) == 0, "cancelled Probe falsely committed");
    require(s.dut.video_nonce == 0, "cancelled Probe exported a feedback nonce");
    s.probe(nonce + 200);
    require(!s.fatal(), "post-write-reset fresh Probe failed");

    Sim stale;
    stale.epoch = false;
    stale.append(record(ring::Event::Probe, nonce, abi::kFpgaVideoLayoutId));
    stale.append(record(ring::Event::Begin, session));
    stale.boot(stale.wr); // Same epoch bit as reset state: must still baseline.
    stale.run(1000);
    require(stale.capsWrites.empty() && !stale.dut.active,
            "boot replayed stale same-epoch Probe/Begin from DDR");
    stale.probe(nonce + 201);
    std::cout << "PASS busy write/reset conservation, cancelled publication and stale same-epoch boot\n";
}

void testBlockedResetRecovery() {
    const Bytes encoded{0, 0, 1, 0x65, 1, 2, 3, 4, 5, 0x80};
    for (unsigned stage = 0; stage < 3; ++stage) {
        Sim s;
        s.boot(); s.probe(); s.begin();
        if (stage == 0) {
            s.dut.sink_block = 1;
            s.append(accessUnit(encoded));
            s.until([&] { return s.dut.out_valid && s.dut.out_full; }, "byte-stall setup failed");
        } else if (stage == 1) {
            s.dut.au_ready = 0;
            s.append(accessUnit(encoded));
            s.until([&] { return s.dut.au_valid; }, "metadata-stall setup failed");
        } else {
            s.dut.decoder_idle = 0;
            s.append(record(ring::Event::Drain, session));
            s.until([&] { return s.dut.fpga_read_count == s.wr - 1; }, "control-fence setup failed");
        }
        s.dut.decoder_idle = 0; // An accepted old decoder/audio write still owns state.
        const unsigned beforeFlush = s.flushes;
        s.epoch = !s.epoch;
        s.wr = 0;
        s.ctrl(); // Fresh out-of-band reset; leave blocked ring bytes intact.
        s.until([&] { return s.flushes > beforeFlush; },
                "blocked parser never observed CTRL reset at stage " + std::to_string(stage), 5000);
        const auto acknowledged = [&] {
            ring::Status status;
            return ring::decodeErrStatusWord(s.load(ring::kErrPhys >> 3), status) &&
                   s.publishedRead() == 0 && !status.active &&
                   status.reset_epoch == s.epoch;
        };
        s.run(200);
        require(!acknowledged(), "blocked reset ACK bypassed decoder/audio retirement");
        require(s.dut.reset_pending && s.dut.transport_quiescent,
                "top-level reset/quiescence fence was not exported while decoder remained busy");
        s.dut.sink_block = 0;
        s.dut.au_ready = 1;
        s.dut.decoder_idle = 1;
        s.until(acknowledged, "blocked reset did not ACK after actual retirement");
        require(!s.dut.reset_pending, "acknowledged reset left pending asserted");
        s.probe(nonce + 400 + stage); s.begin();
        s.append(accessUnit(encoded));
        s.until([&] { return s.drained.size() == encoded.size(); }, "post-abort AU failed");
        require(s.drained == encoded && !s.fatal(), "blocked abort leaked old AU bytes");
    }
    // Metadata can be accepted while a background CTRL read is outstanding.
    // The reader must observe that handshake exactly once, not on return only.
    Sim s;
    s.boot(); s.probe(); s.begin();
    s.dut.au_ready = 0;
    s.append(accessUnit(encoded));
    s.until([&] { return s.dut.au_valid; }, "metadata/poll setup failed");
    s.until([&] { return s.pending.valid && s.pending.delay > 4; },
            "held metadata did not continue CTRL polling", 5000);
    s.dut.au_ready = 1;
    s.run(3);
    require(s.metadata.size() == 1 && !s.dut.au_valid,
            "metadata handshake duplicated/lost during CTRL response wait");
    s.until([&] { return s.drained.size() == encoded.size(); }, "metadata/poll AU did not resume");
    require(s.drained == encoded && s.metadata.size() == 1, "metadata poll corrupted stream");
    std::cout << "PASS blocked byte/metadata/control CTRL-reset recovery and concurrent metadata handshake\n";
}

void testBootstrapEpochFence() {
    Sim s;
    s.wr = 100;
    s.epoch = true;
    s.ctrl();
    const bool oldEpoch = s.load(ring::kCtrlPhys >> 3) >> 63;
    s.mem[ring::kReadPhys >> 3] = (uint64_t(s.wr) << 32) | ring::kReadMagic;
    s.mem[ring::kErrPhys >> 3] = ring::kErrMagic |
        (uint64_t(1) << ring::kErrActiveBit) |
        (uint64_t(oldEpoch) << ring::kErrResetEpochBit);
    // Exactly the host bootstrap: opposite current CTRL epoch, producer zero,
    // no ring/telemetry clearing. The new epoch deliberately equals RTL's
    // reset_seen power-up value, so publishing defaults would falsely ACK it.
    s.epoch = !oldEpoch;
    s.wr = 0;
    s.ctrl();
    s.dut.reset = 1;
    s.dut.enable = 1;
    s.dut.flush = 0;
    s.dut.sink_block = 0;
    s.dut.sink_read = 1;
    s.dut.au_ready = 1;
    s.dut.decoder_idle = 0;
    s.run(4);
    s.dut.reset = 0;
    const auto acknowledged = [&] {
        ring::Status status;
        return ring::decodeErrStatusWord(s.load(ring::kErrPhys >> 3), status) &&
               s.publishedRead() == 0 && !status.active &&
               status.reset_epoch == s.epoch;
    };
    for (unsigned i = 0; i < 1000; ++i) {
        s.tick();
        require(!acknowledged(), "bootstrap default telemetry ACKed epoch before decoder fence");
    }
    require(s.capsWrites.empty(), "bootstrap published unsolicited capabilities");
    s.dut.decoder_idle = 1;
    s.until(acknowledged, "bootstrap epoch did not ACK after decoder retirement");
    s.probe(nonce + 300);
    std::cout << "PASS host bootstrap opposite-epoch/producer-zero/no-clear handshake and decoder fence\n";
}

void testTelemetry() {
    Sim s;
    s.boot(); s.begin(false);
    const Bytes encoded{0, 0, 1, 0x65, 0x80};
    s.append(record(ring::Event::Nal, session, 0, encoded, 0));
    s.until([&] { return s.drained == encoded && s.dut.underrun_count != 0; },
            "underrun was not reported");
    s.ack();
    s.wr = (s.wr + ring::kRingBytes + 1) & ring::kCountMask;
    s.ctrl();
    s.until([&] {
        ring::Status status;
        return ring::decodeErrStatusWord(s.load(ring::kErrPhys >> 3), status) &&
               ring::decodeStat5StatusWord(s.load(ring::kStat5Phys >> 3), status) &&
               ring::decodeStat6StatusWord(s.load(ring::kStat6Phys >> 3), status) &&
               status.active && status.underrun && status.overrun && status.reset_epoch &&
               status.underrun_count != 0 && status.overrun_count != 0;
    }, "telemetry bit widths/counts disagree with host decoder");
    std::cout << "PASS authoritative host ERR/STAT flags, epoch and underrun/overrun widths\n";
}

void testDisabledAuRejects() {
    Sim s;
    s.boot(); s.probe();
    s.append(record(ring::Event::Begin, session));
    s.until([&] { return s.fatal(); }, "disabled AU protocol accepted ABI2 Begin");
    require(!s.dut.active, "disabled AU protocol created an incompatible session");
    std::cout << "PASS disabled AU mode rejects ABI2 session start\n";
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
#if REAL_ALSA_TEST
        const bool disconnected = argc == 2 && std::string(argv[1]) == "--disconnect-core-audio-reset";
        if (disconnected) {
            testActualAudioReset(false, ResetAudioState::Running, 7, false);
        } else {
            for (const unsigned half : {3u, 7u, 11u}) {
                testActualAudioReset(false, ResetAudioState::Running, half, true);
                testActualAudioReset(false, ResetAudioState::PausePending, half, true);
                testActualAudioReset(false, ResetAudioState::Paused, half, true);
                testActualAudioReset(true, ResetAudioState::Running, half, true);
            }
        }
#else
        testCaps();
        testLegacy();
        testTelemetry();
#if AU_MODE
        testLiveBeginIdentityBeforeAu();
        testDrainVersusAudioResetFence();
        testBootstrapEpochFence();
        testAuStallsAndDrain();
        testFences();
        testPause();
        testPausedAudioLane();
        testLargeAu();
        testRejected();
        testResetOwnership();
        testResetOfferedWrite();
        testBlockedResetRecovery();
#else
        testDisabledAuRejects();
#endif
#endif
        std::cout << "PASS reader transport suite ENABLE_AU_PROTOCOL=" << AU_MODE
                  << " maxAU=" << configuredMaxAuBytes
                  << " realALSA=" << REAL_ALSA_TEST
                  << " (transport composition only; not decoder/product acceptance)\n";
    } catch (const std::exception& e) {
        std::cerr << "FAIL reader transport: " << e.what() << "\n";
        return 1;
    }
}
