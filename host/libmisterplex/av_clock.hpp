#pragma once
// A/V presentation clock for the product cast path.
#include <cstdint>
namespace misterplex {
constexpr int kDefaultFpsNum = 24;
constexpr int kDefaultFpsDen = 1;
inline int64_t frameContentMs(int64_t frameIndex, int num, int den) {
    if (num <= 0 || den <= 0) { num = kDefaultFpsNum; den = kDefaultFpsDen; }
    return (frameIndex * 1000LL * static_cast<int64_t>(den)) / static_cast<int64_t>(num);
}
inline int64_t audioClockMs(int64_t audioBytes) {
    if (audioBytes <= 0) return 0;
    return (audioBytes * 1000LL) / (48000LL * 4LL);
}
inline int64_t avDriftMs(int64_t audioMs, int64_t frameMs) { return audioMs - frameMs; }
inline int64_t coArmedClockMs(int64_t rawAudibleMs, int64_t originMs) { return rawAudibleMs - originMs; }
// Daemon sign >0 audio leads. Grabber opposite — do not compare raw.
inline int64_t realContentOffsetMs(int64_t a, int64_t v) { return a - v; }
constexpr int64_t kAudioHoldCapMs = 2000;
constexpr int64_t kAudioHoldCapBytes = 48000LL * 4LL * (kAudioHoldCapMs / 1000);
constexpr int64_t kAudioHoldTimeoutMs = 1200;
enum class SessionHandoffKind { FreshPlay, SeekRestart, AutoNextRestart, PauseResume };
inline bool handoffReArmsAudioHold(SessionHandoffKind k) { return k != SessionHandoffKind::PauseResume; }
struct AudioReleaseCheck { bool ok=false; int64_t contentOriginMs=-1; int64_t audioBytesAtRelease=-1; int64_t heldMs=0; };
inline AudioReleaseCheck checkAudioReleaseOrigin(int64_t written, int64_t held) {
    AudioReleaseCheck c; c.audioBytesAtRelease = written < 0 ? 0 : written;
    if (held < 0) held = 0;
    c.heldMs = (held * 1000LL) / (48000LL * 4LL);
    c.contentOriginMs = (c.audioBytesAtRelease * 1000LL) / (48000LL * 4LL);
    c.ok = (c.audioBytesAtRelease == 0 && c.contentOriginMs == 0); return c;
}
struct PauseResumeHoldSim { bool gateOpenAfterResume=true; bool audioMutedAfterResume=false; };
inline PauseResumeHoldSim simulatePauseResumeHold(bool reArm) {
    PauseResumeHoldSim o; o.gateOpenAfterResume=!reArm; o.audioMutedAfterResume=reArm; return o;
}
struct HoldNoVideoSim { int64_t heldBytes=0; int64_t heldMs=0; bool wroteMrAudio=false; bool capped=false; bool timedOpen=false; int64_t droppedHeadBytes=0; };
inline HoldNoVideoSim simulateHoldNoVideo(int64_t incoming, int64_t waitMs=0,
    int64_t cap=kAudioHoldCapBytes, int64_t timeoutMs=kAudioHoldTimeoutMs) {
    HoldNoVideoSim o; if (cap<0) cap=0; if (incoming<0) incoming=0;
    if (incoming>cap) { o.droppedHeadBytes=incoming-cap; o.heldBytes=cap; o.capped=true; }
    else o.heldBytes=incoming;
    o.heldMs=(o.heldBytes*1000LL)/(48000LL*4LL); o.timedOpen=waitMs>=timeoutMs; o.wroteMrAudio=o.timedOpen; return o;
}
inline int64_t holdRingAppendDropHead(int64_t cur, int64_t add, int64_t cap) {
    if (cap<0) cap=0; if (cur<0) cur=0; if (add<0) add=0;
    const int64_t t=cur+add; return t>cap ? t-cap : 0;
}
enum class AvAction { Present, Hold, Drop };
inline AvAction avDecide(int64_t driftMs, int64_t leadMs, int64_t dropMs, int dropRun, int maxDropRun=1) {
    if (dropMs>0 && driftMs>dropMs && dropRun<maxDropRun) return AvAction::Drop;
    if (driftMs+leadMs<0) return AvAction::Hold; return AvAction::Present;
}
enum class StartupAudioMode { EarlyPlay, CoArmOrigin, HoldUntilVideo };
constexpr int64_t kStartupDropReclaimMs = 22;
struct StartupPacerSim { int drops=0,presents=0,holds=0,firstDriftMs=0,maxDropRun=0,firstRealOffsetMs=0,lastRealOffsetMs=0,steadyRealOffsetMs=0; };
inline StartupPacerSim simulateStartupPacer(int64_t audioMsAtFirstFrame, StartupAudioMode mode, int frames,
    int64_t leadMs=40, int64_t dropMs=80, int fpsNum=24, int fpsDen=1, int64_t dropReclaimMs=kStartupDropReclaimMs) {
    StartupPacerSim out{};
    const int64_t lead = (mode==StartupAudioMode::HoldUntilVideo)?0:audioMsAtFirstFrame;
    const int64_t origin = (mode==StartupAudioMode::CoArmOrigin)?audioMsAtFirstFrame:0;
    int64_t heard=lead, raw=lead; int dropRun=0; int64_t realSum=0; int realN=0;
    const int64_t period=(1000LL*fpsDen)/ (fpsNum>0?fpsNum:24);
    if (dropReclaimMs<0) dropReclaimMs=0; bool got=false;
    for (int i=1;i<=frames;++i) {
        const int64_t frameMs=frameContentMs(i,fpsNum,fpsDen);
        int64_t clock=coArmedClockMs(raw,origin); int64_t drift=avDriftMs(clock,frameMs);
        if (i==1) out.firstDriftMs=(int)drift;
        AvAction act=avDecide(drift,leadMs,dropMs,dropRun); int hg=0;
        while (act==AvAction::Hold && hg++<10000) {
            ++out.holds; raw+=2; heard+=2; clock=coArmedClockMs(raw,origin); drift=avDriftMs(clock,frameMs); act=avDecide(drift,leadMs,dropMs,dropRun);
        }
        if (act==AvAction::Drop) {
            ++out.drops; ++dropRun; if (dropRun>out.maxDropRun) out.maxDropRun=dropRun;
            raw+=period; heard+=period;
            if (heard>=dropReclaimMs) heard-=dropReclaimMs; else heard=0;
        } else {
            ++out.presents; dropRun=0; raw+=period; heard+=period;
            const int64_t ro=realContentOffsetMs(heard,frameMs); out.lastRealOffsetMs=(int)ro;
            if (!got){got=true; out.firstRealOffsetMs=(int)ro;}
            if (i>frames/2){realSum+=ro; ++realN;}
        }
    }
    out.steadyRealOffsetMs = realN? (int)(realSum/realN) : out.lastRealOffsetMs; return out;
}
inline StartupPacerSim simulateStartupPacer(int64_t a, bool coArm, int frames, int64_t leadMs=40, int64_t dropMs=80, int fpsNum=24, int fpsDen=1) {
    return simulateStartupPacer(a, coArm?StartupAudioMode::CoArmOrigin:StartupAudioMode::EarlyPlay, frames, leadMs, dropMs, fpsNum, fpsDen);
}
struct MultiSessionStartupSim { int sessions=0,totalDrops=0,worstSteadyRealMs=0,sessionsOriginNonZero=0; };
inline MultiSessionStartupSim simulateMultiSessionStartup(int sessions, int64_t audioLeadMs, StartupAudioMode mode, int framesPerSession=26) {
    MultiSessionStartupSim out{}; out.sessions=sessions<0?0:sessions;
    for (int s=0;s<out.sessions;++s) {
        auto one=simulateStartupPacer(audioLeadMs,mode,framesPerSession);
        out.totalDrops+=one.drops;
        if (one.steadyRealOffsetMs>out.worstSteadyRealMs) out.worstSteadyRealMs=one.steadyRealOffsetMs;
        if (one.firstRealOffsetMs>80) ++out.sessionsOriginNonZero;
    }
    return out;
}
inline bool rawVideoTerminalSignal(bool a,bool b,bool c,bool d,bool e){return a||b||c||d||e;}
inline int64_t eofStallAudioSilenceMs(bool wantAudio,bool audioSeen,int64_t noVideoMs,int64_t noAudioMs){
    return (!wantAudio||!audioSeen)?noVideoMs:noAudioMs;
}
inline bool knownDurationEofStall(int64_t startMs,int64_t durationMs,int64_t elapsedMs,int64_t partial,int64_t noVideoMs,int64_t noAudioMs,int64_t graceMs=5000){
    if (durationMs<=0||elapsedMs<0||partial<0) return false; if (graceMs<0) graceMs=0;
    const int64_t ov=graceMs*3; const bool aq=noAudioMs>=graceMs||noVideoMs>=ov;
    return startMs+elapsedMs>=durationMs+graceMs && noVideoMs>=graceMs && aq;
}
} // namespace misterplex
