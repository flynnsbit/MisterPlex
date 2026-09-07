#include "Vh264_inter_reference_tb.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int W=320, H=240, N=W*H*3/2;
void check(bool ok, const std::string& why) { if (!ok) throw std::runtime_error(why); }
int floorDiv(int a, int b) { return a>=0 ? a/b : -((-a+b-1)/b); }
int clip(int a) { return std::clamp(a,0,255); }
int addr(int p,int x,int y,int codedW=W,int codedH=H) {
    int w=p ? codedW/2 : codedW, h=p ? codedH/2 : codedH;
    x=std::clamp(x,0,w-1); y=std::clamp(y,0,h-1);
    int stride=p ? W/2 : W;
    return (p==0 ? 0 : p==1 ? W*H : W*H*5/4)+y*stride+x;
}
uint8_t texture(int p,int x,int y,int generation) {
    return uint8_t((x*73+y*151+(x*y*13)^(x<<3)^(y<<5)) + p*67 + generation*29);
}
struct Sim {
    Vh264_inter_reference_tb t;
    std::vector<uint8_t> mem=std::vector<uint8_t>(2*N,0xe3);
    uint64_t cycles=0, reads=0, responses=0, writes=0, events=0, promotions=0;
    int pictureW=W,pictureH=H;
    bool pending=false, stalls=true, zeroLatency=false, drainAllowed=true, acceptOnResponse=true;
    bool forceReadStall=false;
    bool readHeld=false;
    uint32_t heldAddr=0;
    size_t capacity=2, maxOutstanding=0;
    bool trackPrediction=false;
    unsigned streamedY=0, streamedC=0;
    uint64_t concurrentPredictionCycles=0;
    std::array<uint8_t,256> streamY{};
    std::array<uint8_t,128> streamC{};
    unsigned writeLatency=0;
    struct Read { uint32_t addr; uint64_t due; };
    struct Write { uint32_t addr; uint8_t data; uint64_t due; };
    std::deque<Read> readQueue;
    std::deque<Write> writeQueue;
    bool tick() {
        while(!writeQueue.empty() && writeQueue.front().due<=cycles) {
            mem.at(writeQueue.front().addr)=writeQueue.front().data;
            writeQueue.pop_front();
        }
        bool oldResponse=!readQueue.empty() && cycles>=readQueue.front().due;
        t.clk=0;
        t.mem_wready=!stalls || cycles%5!=1;
        t.mem_wdrained=drainAllowed && writeQueue.empty();
        t.mem_rready=!forceReadStall && (!stalls || (cycles%7!=2 && cycles%7!=3)) &&
            (readQueue.size()<capacity || (acceptOnResponse && oldResponse));
        t.mem_rvalid=oldResponse;
        t.mem_rdata=oldResponse ? mem.at(readQueue.front().addr) : 0;
        t.eval();
        check(t.request_context_equivalent,"accepted raster context differs from V12 issue-index coordinates");
        if(readHeld && !t.frame_start && !t.idr_start && !t.frame_abort && !t.reset)
            check(t.mem_rd && t.mem_raddr==heldAddr,"request/address changed while not ready");
        readHeld=t.mem_rd && !t.mem_rready; heldAddr=t.mem_raddr;
        bool rd=t.mem_rd && t.mem_rready, wr=t.mem_we && t.mem_wready;
        uint32_t ra=t.mem_raddr, wa=t.mem_waddr;
        uint8_t wd=t.mem_wdata;
        bool accepted=t.filtered_sample_valid && t.filtered_sample_ready;
        check(!rd || readQueue.size()-(oldResponse?1:0)<capacity,"backend capacity exceeded");
        bool immediate=rd && zeroLatency && readQueue.empty();
        if (immediate) {
            t.mem_rvalid=1; t.mem_rdata=mem.at(ra); t.eval();
        }
        bool retire=t.mem_rvalid;
        if (trackPrediction) {
            if(t.pred_y_valid) {
                check(streamedY<256 && t.pred_y_index==streamedY,"MC luma stream order/length");
                streamY[streamedY++]=t.pred_y_sample;
            }
            if(t.pred_c_valid) {
                check(streamedC<128 && t.pred_c_index==(streamedC&63) &&
                      bool(t.pred_c_v)==(streamedC>=64),"MC U/V stream identity/order/length");
                streamC[streamedC++]=t.pred_c_sample;
            }
            concurrentPredictionCycles+=t.pred_y_valid && t.pred_c_valid;
        }
        t.clk=1; t.eval();
        if (wr) {
            if(writeLatency) writeQueue.push_back({wa,wd,cycles+writeLatency});
            else mem.at(wa)=wd;
            ++writes;
        }
        if(oldResponse) readQueue.pop_front();
        if(retire) ++responses;
        if (rd) {
            ++reads;
            if(!immediate) readQueue.push_back({ra,cycles+(stalls ? 1+(reads*7)%9 : 1)});
        }
        pending=!readQueue.empty();
        maxOutstanding=std::max(maxOutstanding,readQueue.size());
        check(reads==responses+readQueue.size(),"accepted request/response conservation");
        check(readQueue.size()<=2,"prefetch credit bound exceeded");
        events+=t.luma_window_valid+t.chroma_u_window_valid+t.chroma_v_window_valid;
        promotions+=t.frame_promoted;
        t.clk=0; t.eval(); ++cycles;
        return accepted;
    }
    Sim() {
        t.reset=1;
        t.frame_width=W; t.frame_height=H;
        t.fetch_part_w=16; t.fetch_part_h=16;
        tick(); tick(); t.reset=0; tick();
    }
    void begin(bool idr=false,int width=W,int height=H) {
        pictureW=width; pictureH=height;
        t.frame_width=width; t.frame_height=height;
        t.frame_start=1; t.idr_start=idr; tick();
        t.frame_start=0; t.idr_start=0; tick();
    }
    void sample(int mb,int p,int i,int gen) {
        int columns=pictureW/16;
        int x=mb%columns*(p?8:16)+(i%(p?8:16));
        int y=mb/columns*(p?8:16)+(i/(p?8:16));
        t.filtered_sample_valid=1;
        t.filtered_mb_x=mb%columns; t.filtered_mb_y=mb/columns;
        t.filtered_plane=p; t.filtered_sample_idx=i;
        t.filtered_sample=texture(p,x,y,gen);
        int guard=0;
        while (!tick()) check(++guard<20,"write backpressure deadlock");
        t.filtered_sample_valid=0;
    }
    void picture(int gen) {
        auto before=writes;
        for (int mb=0;mb<(pictureW/16)*(pictureH/16);++mb)
            for (int p=0;p<3;++p)
                for (int i=0;i<(p?64:256);++i) sample(mb,p,i,gen);
        check(writes-before==uint64_t(pictureW*pictureH*3/2),"coded rectangle accepted write count");
    }
    void promote() {
        uint32_t oldCurrent=t.current_base;
        auto oldPromotions=promotions;
        drainAllowed=false; t.frame_done=1;
        for(int i=0;i<6;++i) tick();
        check(t.current_base==oldCurrent && promotions==oldPromotions,"promotion before accepted writes drained");
        drainAllowed=true;
        tick(); tick();
        check(t.ref_ready && t.reference_base==oldCurrent,"complete frame was not promoted");
        check(t.reference_width==pictureW && t.reference_height==pictureH,"reference geometry not paired with bank promotion");
        for(int i=0;i<5;++i) tick();
        check(t.reference_base==oldCurrent && promotions==oldPromotions+1,"held frame_done toggled banks repeatedly");
        t.frame_done=0; tick();
    }
    uint64_t fetch(int mbx,int mby,int mx,int my,int expectedReads) {
        auto before=reads, returned=responses, e=events, c=cycles;
        t.fetch_mb_x=mbx; t.fetch_mb_y=mby;
        t.fetch_mv_x_qpel=uint16_t(mx); t.fetch_mv_y_qpel=uint16_t(my);
        t.fetch_start=1; tick(); t.fetch_start=0;
        int guard=0;
        while (!t.fetch_done) { tick(); check(++guard<16000,"fetch timeout"); }
        tick();
        check(!t.fetch_error_no_ref,"valid fetch rejected");
        check(reads-before==uint64_t(expectedReads),"accepted read traffic count");
        check(responses-returned==uint64_t(expectedReads) && !pending,"window completed before all responses");
        check(events-e==uint64_t(expectedReads),"lost/duplicated window sample");
        check(int16_t(t.luma_origin_x)==mbx*16+floorDiv(mx,4),"negative luma origin floor");
        check(int16_t(t.chroma_origin_y)==mby*8+floorDiv(my,8),"negative chroma origin floor");
        check(t.chroma_frac_x==(mx&7) && t.chroma_frac_y==(my&7),"chroma phases");
        return cycles-c;
    }
};

int six(const std::array<int,6>& p) { return p[0]-5*p[1]+20*p[2]+20*p[3]-5*p[4]+p[5]; }
int refY(const Sim& s,int x,int y,int fx,int fy) {
    auto pix=[&](int xx,int yy) {
        return int(s.mem.at(s.t.reference_base+addr(0,xx,yy,s.t.reference_width,s.t.reference_height)));
    };
    auto hr=[&](int xx,int yy) {
        std::array<int,6> a{}; for(int i=0;i<6;++i) a[i]=pix(xx+i-2,yy); return six(a);
    };
    auto hh=[&](int xx,int yy) { return clip(floorDiv(hr(xx,yy)+16,32)); };
    auto hv=[&](int xx,int yy) {
        std::array<int,6> a{}; for(int i=0;i<6;++i) a[i]=pix(xx,yy+i-2);
        return clip(floorDiv(six(a)+16,32));
    };
    std::array<int,6> a{}; for(int i=0;i<6;++i) a[i]=hr(x,y+i-2);
    int j=clip(floorDiv(six(a)+512,1024));
    int b=hh(x,y), h=hv(x,y), m=hv(x+1,y), ss=hh(x,y+1), g=pix(x,y);
    // Independent integer-grid reconstruction, not values read from DUT windows.
    std::array<int,16> grid={g,(g+b+1)/2,b,(b+pix(x+1,y)+1)/2,
        (g+h+1)/2,(b+h+1)/2,(b+j+1)/2,(b+m+1)/2,
        h,(h+j+1)/2,j,(j+m+1)/2,
        (h+pix(x,y+1)+1)/2,(ss+h+1)/2,(j+ss+1)/2,(ss+m+1)/2};
    return grid[fy*4+fx];
}
int refC(const Sim& s,int p,int x,int y,int fx,int fy) {
    int total=32;
    for(int j=0;j<2;++j) for(int i=0;i<2;++i)
        total+=(i?fx:8-fx)*(j?fy:8-fy)*s.mem.at(s.t.reference_base+
            addr(p,x+i,y+j,s.t.reference_width,s.t.reference_height));
    return total/64;
}
uint64_t predict(Sim& s,int mbx,int mby,int mx,int my) {
    auto& t=s.t;
    auto c=s.cycles;
    s.streamedY=s.streamedC=0; s.trackPrediction=true;
    t.mc_start=1; s.tick(); t.mc_start=0;
    int guard=0;
    while(!t.mc_done) { s.tick(); check(++guard<1060,"MC exceeded bounded cycle budget"); }
    check(s.streamedY==256 && s.streamedC==128,"MC done preceded real stream retirement");
    if(mx || my) check(t.legacy_mc_done,"default-reference MC retirement cycle changed");
    s.trackPrediction=false;
    if (!(mx&3) || !(my&3))
        check(s.cycles-c<=600,"axis-aligned phase ran unused six-tap direction");
    if ((mx&1) && (my&1))
        check(s.cycles-c<=953,"odd quarter phase computed unused center/halo rows");
    for(int i=0;i<256;++i) {
        int want=refY(s,mbx*16+floorDiv(mx,4)+i%16,mby*16+floorDiv(my,4)+i/16,mx&3,my&3);
        check(t.pred_y[i]==want,"luma six-tap/quarter mismatch MV="+std::to_string(mx)+","+
              std::to_string(my)+" index="+std::to_string(i)+" got="+std::to_string(t.pred_y[i])+
              " want="+std::to_string(want));
        check(s.streamY[i]==want,"MC luma sample stream differs from independent reference");
        if(mx || my) check(t.legacy_pred_y[i]==want,"default-reference MC luma mismatch");
    }
    for(int p=1;p<3;++p) for(int i=0;i<64;++i) {
        int want=refC(s,p,mbx*8+floorDiv(mx,8)+i%8,mby*8+floorDiv(my,8)+i/8,mx&7,my&7);
        check((p==1?t.pred_u[i]:t.pred_v[i])==want,"chroma eighth-sample mismatch");
        check(s.streamC[(p-1)*64+i]==want,"MC chroma sample stream differs from independent reference");
        if(mx || my) check((p==1?t.legacy_pred_u[i]:t.legacy_pred_v[i])==want,
                          "default-reference MC chroma mismatch");
    }
    return s.cycles-c;
}
void motionTests(Sim& s) {
    auto& t=s.t;
    t.avail_a=t.avail_b=t.avail_c=t.avail_d=1;
    t.mv_a_x=12; t.mv_b_x=20; t.mv_c_x=28; t.mv_d_x=uint16_t(-24);
    t.mvd_x=5; t.p_skip=0; t.eval();
    check(int16_t(t.mv_x)==25,"P16 median plus residual");
    t.intra_a=t.intra_c=1; t.eval();
    check(int16_t(t.mv_pred_x)==20,"single ref0 neighbor among intra");
    t.p_skip=1; t.eval();
    check(!t.skip_zero && int16_t(t.mv_x)==20,"intra A must not force skip zero; skip ignores MVD");
    t.intra_a=0; t.intra_c=1; t.eval();
    check(int16_t(t.mv_x)==12,"available intra C must not fall back to D");
    t.avail_c=0; t.eval();
    check(int16_t(t.mv_x)==12,"unavailable C falls back D");
    t.avail_a=0; t.eval(); check(t.skip_zero && t.mv_x==0,"absent A skip zero");
    t.avail_a=1; t.mv_b_x=0; t.eval(); check(t.skip_zero,"zero ref0 B skip zero");
    t.intra_b=1; t.eval(); check(!t.skip_zero,"intra B zero is not ref0 zero");
}
int cqp(int q,int off) {
    static const int high[]={29,30,31,32,32,33,34,34,35,35,36,36,37,37,37,38,38,38,39,39,39,39};
    int i=std::clamp(q+off,0,51); return i<30?i:high[i-30];
}
void filterTests(Sim& s) {
    auto& t=s.t;
    for(int p=0;p<52;++p) for(int q=0;q<52;++q) for(int off=-12;off<=12;++off) {
        t.is_chroma=1; t.qp_p=p; t.qp_q=q; t.chroma_qp_index_offset=off&31; t.eval();
        check(t.qp_avg==(cqp(p,off)+cqp(q,off)+1)/2,"nonlinear per-side chroma QP");
    }
    t.is_chroma=0; t.qp_p=t.qp_q=40; t.alpha_off=t.beta_off=0;
    t.p_intra=t.q_intra=t.p_nonzero=t.q_nonzero=0; t.p_ref=t.q_ref=0;
    t.p_mvx=t.p_mvy=t.q_mvx=t.q_mvy=0; t.eval(); check(t.bs==0,"actual bS0");
    t.q_mvx=3; t.eval(); check(t.bs==0,"MV delta3 below bS threshold");
    t.q_mvx=4; t.eval(); check(t.bs==1,"MV delta4 bS1");
    t.q_mvx=0; t.p_nonzero=1; t.eval(); check(t.bs==2,"nonzero bS2");
    t.p_intra=1; t.eval(); check(t.bs==3,"internal intra bS3");
    t.mb_boundary=1; t.eval(); check(t.bs==4,"external intra bS4");
    t.p_ref=3; t.eval(); check(!t.unsupported_ref,"intra ref sentinel irrelevant");
    for(int i=0;i<4;++i) {
        t.p3_in[i]=96; t.p2_in[i]=97; t.p1_in[i]=98; t.p0_in[i]=100;
        t.q0_in[i]=104; t.q1_in[i]=106; t.q2_in[i]=107; t.q3_in[i]=108;
    }
    t.eval();
    check(t.p2_out[0]==98 && t.p1_out[0]==100 && t.p0_out[0]==101 &&
          t.q0_out[0]==103 && t.q1_out[0]==104 && t.q2_out[0]==106,"strong filter both real p/q sides");
    t.p_intra=0; t.p_ref=0; t.eval();
    check(t.bs==2 && t.p0_out[0]==101 && t.q0_out[0]==103 &&
          t.p1_out[0]==99 && t.q1_out[0]==104,"normal filter both sides");
    t.is_chroma=1; t.chroma_qp_index_offset=0; t.eval();
    check(t.p1_out[0]==98 && t.q1_out[0]==106,"chroma cannot modify p1/q1");
    t.disable_all=1; t.eval();
    check(t.bs==0 && t.p0_out[0]==100 && t.q0_out[0]==104,"legal filter-off exact passthrough");
    t.disable_all=0; t.slice_boundary_blocked=1; t.eval(); check(t.bs==0,"idc2 blocked slice edge");
    t.slice_boundary_blocked=0; t.p_ref=2; t.eval();
    check(t.unsupported_ref && t.bs==0,"unsupported reference must not filter");
    t.p_ref=0;
    t.slice_boundary_blocked=0; t.is_chroma=0; t.qp_p=t.qp_q=0;
    t.alpha_off=uint8_t(-12)&31; t.beta_off=uint8_t(-12)&31; t.eval();
    check(t.alpha_dbg==0 && t.beta_dbg==0,"QP offset lower clipping");
    t.qp_p=t.qp_q=51; t.alpha_off=t.beta_off=12; t.eval();
    check(t.alpha_dbg==255 && t.beta_dbg==18,"QP offset upper clipping");
    t.qp_p=t.qp_q=40; t.alpha_off=t.beta_off=0;
    for(int i=0;i<4;++i) {
        t.p0_in[i]=100; t.p1_in[i]=108; t.p2_in[i]=108;
        t.q0_in[i]=130; t.q1_in[i]=138; t.q2_in[i]=138;
    }
    t.eval(); check(t.p0_out[0]!=100 && t.q0_out[0]!=130,"QP40 normal edge should filter");
    t.alpha_off=uint8_t(-12)&31; t.eval();
    check(t.p0_out[0]==100 && t.q0_out[0]==130,"negative actual alpha offset must block edge");
    t.alpha_off=0; t.beta_off=uint8_t(-12)&31; t.eval();
    check(t.p0_out[0]==100 && t.q0_out[0]==130,"negative actual beta offset must block edge");
}

void geometryTests() {
    Sim s;
    s.begin(true,320,224);
    check(!s.t.frame_error,"valid shorter coded rectangle rejected");
    s.t.frame_width=288; s.t.frame_height=208;
    s.picture(5);
    check(s.t.reference_width==0 && s.t.reference_height==0,"unpromoted geometry leaked to reference");
    s.promote();
    check(s.writes==107520,"320x224 coverage is not its coded sample count");
    for(int p=0;p<3;++p) {
        int firstPaddingRow=p ? 112 : 224;
        check(s.mem[addr(p,0,firstPaddingRow)]==0xe3,"short coded height overwrote allocation padding");
    }
    s.fetch(19,13,7,7,603); predict(s,19,13,7,7);
    s.fetch(0,13,-3,7,603); predict(s,0,13,-3,7);
    s.fetch(0,13,-3,7,0); predict(s,0,13,-3,7);

    auto priorBase=s.t.reference_base;
    s.begin(false,320,224); s.picture(6);
    check(s.t.reference_base==priorBase && s.t.reference_height==224 &&
          s.mem[priorBase]==texture(0,0,0,5),"current short picture changed prior reference/geometry");
    s.fetch(19,13,7,7,603); predict(s,19,13,7,7);
    s.promote();
    s.fetch(19,13,7,7,603); predict(s,19,13,7,7);

    s.begin(false,288,208);
    check(s.t.frame_error && !s.t.ref_ready,"non-IDR geometry change retained reference validity");
    auto beforeReads=s.reads;
    s.t.fetch_start=1; s.tick(); s.t.fetch_start=0;
    check(s.t.fetch_done && s.t.fetch_error_no_ref && s.reads==beforeReads,
          "incompatible geometry fetched old bank");
    s.begin(false,320,224);
    check(s.t.frame_error && !s.t.ref_ready,"returning to old geometry bypassed required IDR");

    // Reuse the same physical bank allocation, with old pixels still beyond
    // the new coded rectangle. A max-allocation clamp would leak those pixels.
    s.begin(true,288,208);
    check(!s.t.frame_error && !s.t.ref_ready,"IDR did not recover geometry");
    check(s.t.reference_width==320 && s.t.reference_height==224,"IDR changed reference geometry before promotion");
    auto narrowBase=s.t.current_base;
    auto paddingY=s.mem[narrowBase+addr(0,288,0)];
    auto paddingU=s.mem[narrowBase+addr(1,144,0)];
    auto beforeWrites=s.writes;
    s.picture(7); s.promote();
    check(s.writes-beforeWrites==89856,"288x208 coded coverage count");
    check(s.mem[narrowBase+addr(0,288,0)]==paddingY && s.mem[narrowBase+addr(1,144,0)]==paddingU,
          "narrow coded width changed storage stride or wrote right padding");
    for(auto v:std::vector<std::array<int,4>>{{17,12,7,7},{17,0,7,-3},{0,12,-7,7},
            {17,12,32767,32767},{0,0,-32768,-32768}}) {
        s.fetch(v[0],v[1],v[2],v[3],603); predict(s,v[0],v[1],v[2],v[3]);
    }
    s.fetch(17,12,0,0,384);
    for(int p=0;p<3;++p) for(int i=0;i<(p?64:256);++i) {
        int side=p?8:16;
        int expected=texture(p,17*side+i%side,12*side+i/side,7);
        check((p==0?s.t.win_y[i]:p==1?s.t.win_u[i]:s.t.win_v[i])==expected,
              "narrow packed prediction aliased fixed storage layout");
    }
    s.t.fetch_mv_x_qpel=11; s.t.fetch_start=1; s.tick(); s.t.fetch_start=0;
    int guard=0;
    while(!s.pending) { s.tick(); check(++guard<20,"geometry cancellation never issued a read"); }
    auto eventsBeforeChange=s.events;
    s.begin(false,320,224);
    guard=0;
    while(s.pending || s.t.fetch_busy) { s.tick(); check(++guard<30,"geometry cancellation failed to drain"); }
    check(s.t.frame_error && !s.t.ref_ready && s.events==eventsBeforeChange,
          "late old-geometry response escaped invalidation");
    auto beforeInvalid=s.writes;
    for(auto dimensions:std::vector<std::array<int,2>>{{0,224},{320,0},{318,224},{320,212},{336,224},{320,256}}) {
        s.begin(true,dimensions[0],dimensions[1]);
        check(s.t.frame_error && !s.t.ref_ready,"invalid coded geometry accepted");
        s.t.filtered_sample_valid=1; s.tick();
        check(!s.t.filtered_sample_ready && !s.t.mem_we,"invalid geometry accepted a write");
        s.t.filtered_sample_valid=0;
        s.begin(false,320,224);
        check(s.t.frame_error,"invalid geometry recovered without IDR");
    }
    check(s.writes==beforeInvalid,"rejected geometry modified bank storage");
    s.begin(true,16,16); s.picture(8); s.promote();
    s.fetch(0,0,7,7,603); predict(s,0,0,7,7);
    std::cout<<"PASS runtime geometry: 320x224 writes107520, 288x208 writes89856, 16x16 writes384;"
                " fixed320/160 strides+0/76800/96000 plane offsets; reference-bank geometry,"
                " fractional borders, invalid/change-until-IDR rejection\n";
}
void mcResetTests() {
    Sim s; s.stalls=false;
    s.begin(true,16,16); s.picture(10); s.promote();
    s.fetch(0,0,9,10,603);
    s.t.mc_start=1; s.tick(); s.t.mc_start=0;
    for(int i=0;i<100;++i) s.tick();
    check(!s.t.mc_done,"MC reset setup already completed");
    s.t.reset=1; s.tick(); s.t.reset=0; s.tick();
    check(!s.t.mc_done && !s.t.ref_ready,"reset retained partial MC/reference validity");
    s.begin(true,16,16); s.picture(11); s.promote();
    s.fetch(0,0,10,10,603); predict(s,0,0,10,10);
    check(s.reads==s.responses && !s.pending,"warm MC reset lost an accepted read");
    std::cout<<"PASS inter cache reset during partial diagonal work and fresh-reference recomputation\n";
    auto before=s.events;
    s.t.fetch_mv_x_qpel=11; s.t.fetch_mv_y_qpel=13;
    s.t.fetch_start=1; s.tick(); s.t.fetch_start=0;
    int guard=0;
    while(s.events-before<480 || !s.pending) {
        s.tick(); check(++guard<16000,"partial reference-window setup timeout");
    }
    check(!s.t.fetch_done,"partial chroma reference fill already completed");
    s.t.frame_abort=1; s.tick(); s.t.frame_abort=0;
    guard=0;
    while(s.pending || s.t.fetch_busy) {
        s.tick(); check(++guard<40,"partial reference-window abort failed to drain");
    }
    check(!s.t.ref_ready && !s.t.fetch_done,"partial reference RAM became reusable");
    s.begin(true,16,16); s.picture(12); s.promote();
    s.fetch(0,0,0,0,384); predict(s,0,0,0,0);
    s.fetch(0,0,11,13,603); predict(s,0,0,11,13);
    check(s.reads==s.responses && !s.pending,"reference RAM generation lost accepted traffic");
    std::cout<<"PASS partial U-window abort/drain then fresh packed and fractional generations\n";
    s.fetch(0,0,0,0,384);
    s.streamedY=s.streamedC=0; s.trackPrediction=true;
    s.t.mc_start=1; s.tick(); s.t.mc_start=0;
    guard=0;
    while(s.streamedY<17) { s.tick(); check(++guard<1060,"partial MC output setup timeout"); }
    check(!s.t.mc_done && s.streamedY%4==1,"partial MC packing group setup");
    s.t.reset=1; s.tick(); s.t.reset=0; s.tick();
    check(!s.t.mc_done && !s.t.pred_y_valid && !s.t.pred_c_valid,"reset retained active MC outputs");
    s.trackPrediction=false;
    s.begin(true,16,16); s.picture(13); s.promote();
    s.fetch(0,0,0,0,384); predict(s,0,0,0,0);
    std::cout<<"PASS reset after17 emitted luma samples; fresh complete MC stream generation\n";
}
void rasterContextTests() {
    unsigned cases=0;
    for (bool packed : {false,true}) {
        const std::vector<int> boundaries=packed ? std::vector<int>{0,15,16,255,256,319,320,383} :
                                                  std::vector<int>{0,20,21,440,441,521,522,602};
        for (int boundary : boundaries) for (int cancel=0;cancel<3;++cancel) {
            Sim s; s.stalls=false;
            s.begin(true,16,16); s.picture(14); s.promote();
            s.t.fetch_mv_x_qpel=packed ? 0 : uint16_t(-7);
            s.t.fetch_mv_y_qpel=packed ? 0 : 32767;
            s.t.fetch_start=1; s.tick(); s.t.fetch_start=0;
            int guard=0;
            while (s.reads<uint64_t(boundary)) {
                s.tick(); check(++guard<16000,"raster boundary setup timeout");
            }
            s.forceReadStall=true;
            for (int i=0;i<4;++i) s.tick();
            check(s.t.mem_rd && !s.pending && s.reads==uint64_t(boundary),
                  "held row/plane-boundary request was not exercised");
            const uint32_t held=s.t.mem_raddr;
            const uint64_t events=s.events;
            s.t.fetch_mb_x=255; s.t.fetch_mb_y=255;
            s.t.fetch_part_mode=1; s.t.fetch_part_w=8; s.t.fetch_part_h=8;
            s.t.fetch_mv_x_qpel=32767; s.t.fetch_mv_y_qpel=uint16_t(-32768);
            for (int i=0;i<4;++i) {
                s.tick();
                check(s.t.mem_rd && s.t.mem_raddr==held && s.events==events,
                      "unaccepted request used live next-fetch metadata");
            }
            s.t.frame_abort=cancel==0; s.t.frame_start=cancel==1; s.t.idr_start=cancel==2;
            s.tick(); s.t.frame_abort=s.t.frame_start=s.t.idr_start=0;
            s.forceReadStall=false;
            for (int i=0;i<4;++i) s.tick();
            check(!s.t.fetch_busy && !s.t.fetch_done && !s.t.mem_rd &&
                  s.events==events && s.reads==uint64_t(boundary),
                  "cancelled row/plane context escaped into the next epoch");
            s.t.fetch_mb_x=s.t.fetch_mb_y=0;
            s.t.fetch_part_mode=0; s.t.fetch_part_w=s.t.fetch_part_h=16;
            s.begin(true,16,16); s.picture(15); s.promote();
            s.fetch(0,0,0,0,384); predict(s,0,0,0,0);
            check(s.reads==s.responses && !s.pending,"raster restart lost accepted read ownership");
            ++cases;
        }
    }
    std::cout<<"PASS accepted raster context: "<<cases
             <<" packed/fractional row and Y/U/V boundaries; held-ready/live-input churn;"
               " abort/frame_start/IDR cancellation and fresh promoted reference\n";
}
}
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try {
        Sim s;
        motionTests(s); filterTests(s);
        s.t.fetch_start=1; s.tick(); s.t.fetch_start=0;
        check(s.t.fetch_done && s.t.fetch_error_no_ref && s.reads==0,"missing reference must fail closed");
        s.begin(true); s.picture(0); check(!s.t.ref_ready,"reference valid before complete promotion");
        s.promote();
        uint64_t maxFetch=0,maxMc=0,maxAxisMc=0,maxIntegerMc=0,maxOddMc=0;
        for(int fy=0;fy<8;++fy) for(int fx=0;fx<8;++fx) {
            // Offset the phase sweep so it exercises all 603-sample windows.
            int mx=fx+8, my=fy+8;
            maxFetch=std::max(maxFetch,s.fetch(7,5,mx,my,603));
            auto mc=predict(s,7,5,mx,my);
            maxMc=std::max(maxMc,mc);
            if (!(mx&3) || !(my&3)) maxAxisMc=std::max(maxAxisMc,mc);
            if (!(mx&3) && !(my&3)) maxIntegerMc=std::max(maxIntegerMc,mc);
            if ((mx&1) && (my&1)) maxOddMc=std::max(maxOddMc,mc);
        }
        for(auto v:std::vector<std::array<int,4>>{{0,0,-1,-1},{0,0,-7,-9},{0,0,-32768,-32768},
                {19,14,3,7},{19,14,32767,32767},{1,1,-4,-8},{5,7,-2,-3}}) {
            s.fetch(v[0],v[1],v[2],v[3],603); predict(s,v[0],v[1],v[2],v[3]);
            s.fetch(v[0],v[1],v[2],v[3],0); predict(s,v[0],v[1],v[2],v[3]);
        }
        s.fetch(2,3,0,0,384);
        for(int i=0;i<256;++i) check(s.t.win_y[i]==s.mem[addr(0,32+i%16,48+i/16)],"packed zero-MV Y");
        for(int p=1;p<3;++p) for(int i=0;i<64;++i)
            check((p==1?s.t.win_u[i]:s.t.win_v[i])==s.mem[addr(p,16+i%8,24+i/8)],"packed zero-MV UV");
        auto packedMc=predict(s,2,3,0,0);
        s.fetch(2,3,0,0,0);
        check(predict(s,2,3,0,0)==packedMc,"packed cache hit changed MC retirement");
        std::cout<<"PASS synchronous packed zero-MV and cache-hit predictions cycles="<<packedMc<<"\n";
        s.begin(); s.picture(1);
        s.fetch(7,5,11,13,603); predict(s,7,5,11,13);
        check(s.mem[0]==texture(0,0,0,0),"current reconstruction mutated previous picture");
        s.promote(); s.fetch(7,5,11,13,603); predict(s,7,5,11,13);
        check(s.t.reference_base==N,"second picture reference bank");
        s.stalls=false; s.begin();
        auto bramFetch=s.fetch(7,5,9,10,603), bramMc=predict(s,7,5,9,10);
        check(bramFetch<=607,"BRAM window fill lost one-byte-per-cycle pipeline: "+std::to_string(bramFetch));
        s.capacity=1; s.acceptOnResponse=false;
        auto serialFetch=s.fetch(7,5,10,10,603); predict(s,7,5,10,10);
        check(serialFetch>=1209,"capacity-one stalled backend was not exercised");
        s.capacity=2; s.acceptOnResponse=true;
        s.zeroLatency=true;
        s.fetch(7,5,10,11,603); predict(s,7,5,10,11); s.zeroLatency=false;
        s.begin(); s.sample(0,0,0,2);
        s.t.frame_done=1; s.tick(); s.tick(); s.tick(); s.t.frame_done=0;
        check(!s.t.ref_ready && s.t.frame_error,"failed partial frame became reference");
        // Exactly N accepted writes is insufficient: the last sample is missing,
        // replaced by a duplicate. A counter-only implementation would promote.
        s.begin(true);
        for(int mb=0;mb<300;++mb) for(int p=0;p<3;++p)
            for(int i=0;i<(p?64:256);++i)
                if (!(mb==299 && p==2 && i==63)) s.sample(mb,p,i,2);
        s.sample(299,2,62,2);
        s.t.frame_done=1; s.tick(); s.tick(); s.tick(); s.t.frame_done=0;
        check(s.t.frame_error && !s.t.ref_ready,"duplicate write covered a missing sample");
        s.begin(true);
        s.sample(0,0,1,2); // Out-of-order first write cannot establish coverage.
        check(s.t.frame_error,"write gap not rejected immediately");
        s.begin(true); s.picture(3); s.promote();
        // Cancel with a genuinely outstanding response, then start a new epoch.
        s.stalls=true; s.t.fetch_mv_x_qpel=17; s.t.fetch_start=1; s.tick(); s.t.fetch_start=0;
        while(!s.pending) s.tick();
        s.t.frame_abort=1; s.tick(); s.t.frame_abort=0; s.begin();
        while(s.pending || s.t.fetch_busy) s.tick();
        check(!s.t.ref_ready,"abort retained reference validity");
        s.t.fetch_start=1; s.tick(); s.t.fetch_start=0;
        check(s.t.fetch_error_no_ref,"aborted reference cache reused");
        // An epoch restart cannot let a delayed old write overwrite new pixels.
        s.stalls=false; s.writeLatency=30; s.begin(true);
        s.sample(0,0,0,4);
        check(!s.writeQueue.empty(),"delayed accepted write not exercised");
        s.t.frame_abort=1; s.tick(); s.t.frame_abort=0; s.begin(true);
        check(s.t.fetch_busy && !s.t.filtered_sample_ready,"abort did not fence accepted writes");
        int drainGuard=0;
        while(s.t.fetch_busy) { s.tick(); check(++drainGuard<40,"write abort drain timeout"); }
        check(s.writeQueue.empty(),"abort reopened writes before physical drain");
        s.writeLatency=0;
        s.sample(0,0,0,5);
        check(s.mem[s.t.current_base]==texture(0,0,0,5),"late old write corrupted restarted picture");
        check(s.maxOutstanding==2,"bounded prefetch never used two credits");
        check(s.concurrentPredictionCycles>0,"concurrent Y/U-V producers not exercised");
        geometryTests();
        mcResetTests();
        rasterContextTests();
        std::cout<<"PASS leaf DPB/inter/filter: 64 color phases + signed border/extreme MV, immutable prior bank,"
                    " missing/partial/abort fail-closed, stalls/zero-latency/drain, both p/q filter edges."
                 <<" reads="<<s.reads<<" responses="<<s.responses<<" max_outstanding="<<s.maxOutstanding<<" writes="<<s.writes
                 <<" max_variable_fetch_cycles="<<maxFetch<<" max_mc_cycles="<<maxMc
                 <<" max_axis_mc_cycles="<<maxAxisMc<<" max_integer_luma_mc_cycles="<<maxIntegerMc
                 <<" concurrent_MC_output_cycles="<<s.concurrentPredictionCycles
                 <<" max_odd_quarter_mc_cycles="<<maxOddMc
                 <<" BRAM_fetch_cycles="<<bramFetch<<" MC_cycles="<<bramMc
                 <<" capacity1_serial_fetch_cycles="<<serialFetch
                 <<" (leaf latency only; not decoder fps)\n";
    } catch(const std::exception& e) { std::cerr<<"FAIL "<<e.what()<<"\n"; return 1; }
}
