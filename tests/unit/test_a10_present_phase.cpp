#include "libmisterplex/a10_present_phase.hpp"
#include <cassert>
#include <cstdio>

using namespace misterplex;
using namespace misterplex::a10_phase;
static Input input() {
    Input x;
    x.capsRead = x.bankRead = x.frameRead = x.mastRead = x.mvpsRead = true;
    x.caps.abi_version = mailbox_abi::kFpgaVideoAbiVersion;
    x.caps.layout_id = mailbox_abi::kFpgaVideoLayoutId;
    x.caps.features = ddr_bitstream_ring::kRequiredVideoFeatures;
    x.caps.max_width = 320; x.caps.max_height = 240; x.caps.max_au_bytes = 8192;
    x.caps.build_id = kBuild; x.caps.nonce = 123; x.caps.publication = 1;
    x.mast.session_id = 456; x.mast.nonce = 123;
    x.mast.publication = 1; x.mast.active = x.mast.supported = true;
    x.mast.paused = false; x.mast.samples_consumed = 7000;
    x.bank.frames_done = 10; x.bank.free_bank_mask = 2;
    x.mvps.session_id = 456; x.mvps.nonce = 123;
    x.mvps.active = x.mvps.has_frame = x.mvps.has_audio_clock = true;
    x.mvps.presentation_count = 1; x.mvps.publication = 1;
    x.mvps.audio_samples_consumed = 4000;
    x.mvps.timebase_num = 1; x.mvps.timebase_den = 90000; x.mvps.pts = 129754;
    return x;
}
int main() {
    Observer observer;
    auto x = input();
    auto a = observer.sample(x, 1, 2);
    assert((a.valid & (Caps|Mast|Mvps|FrozenAck)) == (Caps|Mast|Mvps|FrozenAck));
    assert(!(a.valid & (LiveEpoch|BankRefreshObserved)));
    assert(a.liveConsumed == 7000 && a.frozenAtAck == 4000);
    ++x.mast.publication;
    ++x.bank.frames_done;
    auto b = observer.sample(x, 1001, 1002);
    assert((b.valid & (LiveEpoch|BankRefreshObserved)) == (LiveEpoch|BankRefreshObserved));
    assert(b.refreshCount == 11 && b.presentationCount == 1); // Refresh is NOT a swap.
    x.bank.swap_pending = true; x.bank.free_bank_mask = 0;
    ++x.mast.publication;
    auto pending = observer.sample(x, 2001, 2002);
    assert(pending.bankBits == 8 && pending.presentationCount == 1);
    ++x.bank.frames_done; ++x.mast.publication;
    auto held = observer.sample(x, 18001, 18002);
    assert(held.refreshCount == 12 && held.bankBits == 8 && held.presentationCount == 1);
    x.bank.swap_pending = false; x.bank.disp_bank = 1; x.bank.free_bank_mask = 1;
    ++x.bank.frames_done; ++x.mast.publication;
    ++x.mvps.presentation_count; ++x.mvps.publication;
    auto picked = observer.sample(x, 35001, 35002);
    assert(picked.bankBits == 5 && picked.presentationCount == 2 && picked.refreshCount == 13);

    x.mastRead = false;
    auto missing = observer.sample(x, 36001, 36002);
    assert(!(missing.valid & (Mast|Mvps|LiveEpoch|BankRefreshObserved|FrozenAck)));
    assert(missing.liveConsumed == 0 && missing.frozenAtAck == 0); // Invalid, never serialized as zero.
    x.mastRead = true;
    auto restarting = observer.sample(x, 37001, 37002);
    assert(!(restarting.valid & LiveEpoch));
    x.caps.nonce = x.mast.nonce = 789;
    auto epoch = observer.sample(x, 38001, 38002);
    assert(!(epoch.valid & (LiveEpoch|BankRefreshObserved|Mvps|FrozenAck)));
    x.mvps.nonce = 789;
    x.mvps.has_audio_clock = false;
    ++x.mast.publication;
    auto noFrozen = observer.sample(x, 39001, 39002);
    assert(noFrozen.valid & Mvps);
    assert(!(noFrozen.valid & FrozenAck));
    x.mvps.has_audio_clock = true; x.mvps.audio_samples_consumed = UINT64_MAX;
    auto fullWidth = observer.sample(x, 40001, 40002);
    assert((fullWidth.valid & FrozenAck) && fullWidth.frozenAtAck == UINT64_MAX);
    x.mast.active = false;
    auto inactive = observer.sample(x, 41001, 41002);
    assert(!(inactive.valid & (LiveEpoch|BankRefreshObserved|Mvps)));
    x.caps.build_id ^= 1;
    auto wrongCore = observer.sample(x, 42001, 42002);
    assert(!(wrongCore.valid & (Caps|Mast|Mvps|LiveEpoch)));
    x.bank.free_bank_mask = 3;
    auto invalidBank = observer.sample(x, 43001, 43002);
    assert(!(invalidBank.valid & (Bank|BankRefreshObserved)));

    Collector<3> collector;
    collector.add(b);
    auto unchanged = b; unchanged.afterUs += 1; unchanged.liveConsumed += 50;
    collector.add(unchanged);
    collector.add(pending);
    collector.add(held);
    collector.add(picked);
    assert(collector.attempted == 5 && collector.retained == 3 &&
           collector.sampledOut == 1 && collector.dropped == 1);
    assert(collector.records[0].presentationCount == 1 &&
           collector.records[2].presentationCount == 1);
    std::printf("Phase observer tests PASS: no writes/control, nonce/liveness/refresh/validity/bounds; record=%zu\n",
                sizeof(Record));
}
