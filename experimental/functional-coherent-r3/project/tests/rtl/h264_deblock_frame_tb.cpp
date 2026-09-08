#include "Vh264_deblock_frame.h"
#include "verilated.h"
#include "libmisterplex/h264_recon.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int W=320,H=240,N=W*H*3/2;
void require(bool yes,const std::string& why) { if(!yes) throw std::runtime_error(why); }
int clamp(int x,int lo,int hi) { return std::clamp(x,lo,hi); }
int floorShift(int x,int n) { return x>=0 ? x/(1<<n) : -((-x+(1<<n)-1)/(1<<n)); }
struct Meta {
    int mode=0,qp=38,nz=0,mx=0,my=0,ref=0,slice=0,co=0,ao=0,bo=0,idc=0;
};
int address(int base,int p,int x,int y) {
    return base+(p==0?0:p==1?W*H:W*H*5/4)+y*(p?W/2:W)+x;
}
int chromaQp(int q,int offset) {
    static constexpr int hi[]={29,30,31,32,32,33,34,34,35,35,36,36,37,37,37,38,38,38,39,39,39,39};
    q=clamp(q+offset,0,51); return q<30?q:hi[q-30];
}
const int alpha[52]={0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    4,4,5,6,7,8,9,10,12,13,15,17,20,22,25,28,32,36,40,45,50,56,63,71,80,90,101,113,127,144,162,182,203,226,255,255};
const int beta[52]={0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    2,2,2,3,3,3,3,4,4,4,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18};
const int tc[36][3]={
    {0,0,0},{0,0,1},{0,0,1},{0,0,1},{0,0,1},{0,1,1},{0,1,1},{1,1,1},
    {1,1,1},{1,1,1},{1,1,1},{1,1,2},{1,1,2},{1,1,2},{1,1,2},{1,2,3},
    {1,2,3},{2,2,3},{2,2,4},{2,3,4},{2,3,4},{3,3,5},{3,4,6},{3,4,6},
    {4,5,7},{4,5,8},{4,6,9},{5,7,10},{6,8,11},{6,8,13},{7,10,14},{8,11,16},
    {9,12,18},{10,13,20},{11,15,23},{13,17,25}};
std::array<int,8> filter(std::array<int,8> s,bool chroma,int bs,int qp,int ao,int bo) {
    auto out=s;
    int a=alpha[clamp(qp+ao,0,51)], b=beta[clamp(qp+bo,0,51)];
    int p3=s[0],p2=s[1],p1=s[2],p0=s[3],q0=s[4],q1=s[5],q2=s[6],q3=s[7];
    if(!bs || abs(p0-q0)>=a || abs(p1-p0)>=b || abs(q1-q0)>=b) return out;
    bool ap=abs(p2-p0)<b, aq=abs(q2-q0)<b;
    if(bs==4) {
        bool strong=!chroma && abs(p0-q0)<a/4+2;
        if(strong && ap) {
            out[1]=(2*p3+3*p2+p1+p0+q0+4)/8;
            out[2]=(p2+p1+p0+q0+2)/4;
            out[3]=(p2+2*p1+2*p0+2*q0+q1+4)/8;
        } else out[3]=(2*p1+p0+q1+2)/4;
        if(strong && aq) {
            out[4]=(p1+2*p0+2*q0+2*q1+q2+4)/8;
            out[5]=(p0+q0+q1+q2+2)/4;
            out[6]=(p0+q0+q1+3*q2+2*q3+4)/8;
        } else out[4]=(2*q1+q0+p1+2)/4;
    } else {
        int ia=clamp(qp+ao,0,51), t0=ia<16?0:tc[ia-16][bs-1];
        int bound=t0+(chroma?1:int(ap)+int(aq));
        int delta=clamp(floorShift(4*(q0-p0)+p1-q1+4,3),-bound,bound);
        out[3]=clamp(p0+delta,0,255); out[4]=clamp(q0-delta,0,255);
        if(!chroma && ap) out[2]=clamp(p1+clamp(floorShift(p2+(p0+q0+1)/2-2*p1,1),-t0,t0),0,255);
        if(!chroma && aq) out[5]=clamp(q1+clamp(floorShift(q2+(p0+q0+1)/2-2*q1,1),-t0,t0),0,255);
    }
    return out;
}
void software(std::vector<uint8_t>& pixels,const std::vector<Meta>& tags,int width,int height,int base) {
    int cols=width/16;
    for(int mb=0;mb<(width/16)*(height/16);++mb) {
        const auto& q=tags[mb];
        if(q.idc==1) continue;
        int mx=mb%cols,my=mb/cols;
        for(int dir=0;dir<2;++dir) for(int p=0;p<3;++p) {
            int side=p?8:16, span=p?2:4;
            for(int e=0;e<side;e+=4) {
                bool ext=e==0;
                if(ext && (dir?my==0:mx==0)) continue;
                const auto& prev=tags[ext?mb-(dir?cols:1):mb];
                if(ext && q.idc==2 && prev.slice!=q.slice) continue;
                for(int seg=0;seg<4;++seg) {
                    int lumaEdge=p?e*2:e;
                    int qblock=dir?lumaEdge+seg:seg*4+lumaEdge/4;
                    int pedge=ext?3:lumaEdge/4-1;
                    int pblock=dir?pedge*4+seg:seg*4+pedge;
                    int bs;
                    if(q.mode>=2 || prev.mode>=2) bs=ext?4:3;
                    else if(((q.nz>>qblock)|(prev.nz>>pblock))&1) bs=2;
                    else bs=(q.ref!=prev.ref || abs(q.mx-prev.mx)>=4 || abs(q.my-prev.my)>=4)?1:0;
                    int qp=((p?chromaQp(q.qp,q.co):q.qp)+(p?chromaQp(prev.qp,prev.co):prev.qp)+1)/2;
                    for(int lane=0;lane<span;++lane) {
                        int x=mx*side+(dir?seg*span+lane:e), y=my*side+(dir?e:seg*span+lane);
                        std::array<int,8> src{};
                        for(int k=0;k<8;++k) src[k]=pixels.at(address(base,p,x+(dir?0:k-4),y+(dir?k-4:0)));
                        auto dst=filter(src,p!=0,bs,qp,q.ao,q.bo);
                        for(int k=1;k<7;++k) pixels.at(address(base,p,x+(dir?0:k-4),y+(dir?k-4:0)))=dst[k];
                    }
                }
            }
        }
    }
}
struct Sim {
    Vh264_deblock_frame t;
    std::vector<uint8_t> mem=std::vector<uint8_t>(2*N,0xd7);
    struct Write { uint32_t addr; uint8_t data; uint64_t due; };
    std::deque<Write> queued;
    uint64_t cycle=0,reads=0,writes=0,doneCount=0;
    bool pending=false,stalls=true,holdDrain=false,instant=false;
    uint64_t due=0;
    uint32_t readAddr=0, heldRa=0,heldWa=0;
    uint8_t heldWd=0;
    bool readHeld=false,writeHeld=false;
    int width=0,height=0,base=0;
    void validAddress(uint32_t a) {
        require(a>=uint32_t(base) && a<uint32_t(base+N),"request outside current bank");
        int pos=int(a)-base,p=pos<W*H?0:pos<W*H*5/4?1:2;
        pos-=p==0?0:p==1?W*H:W*H*5/4;
        int stride=p?W/2:W;
        require(pos%stride<(p?width/2:width) && pos/stride<(p?height/2:height),"request touched coded padding/another plane");
    }
    void tick() {
        while(!queued.empty() && queued.front().due<=cycle) {
            mem.at(queued.front().addr)=queued.front().data; queued.pop_front();
        }
        t.clk=0;
        t.mem_rready=!stalls || cycle%7<4;
        t.mem_wready=!stalls || cycle%5<3;
        t.mem_wdrained=queued.empty() && !holdDrain;
        t.mem_rvalid=pending && cycle>=due;
        t.mem_rdata=t.mem_rvalid?mem.at(readAddr):0;
        t.eval();
        bool cancel=t.frame_abort || t.frame_begin;
        if(readHeld && !cancel) require(t.mem_rd && t.mem_raddr==heldRa,"read changed while stalled");
        if(writeHeld && !cancel) require(t.mem_we && t.mem_waddr==heldWa && t.mem_wdata==heldWd,"write changed while stalled");
        readHeld=t.mem_rd && !t.mem_rready; heldRa=t.mem_raddr;
        writeHeld=t.mem_we && !t.mem_wready; heldWa=t.mem_waddr; heldWd=t.mem_wdata;
        bool rd=t.mem_rd && t.mem_rready, wr=t.mem_we && t.mem_wready;
        uint32_t ra=t.mem_raddr,wa=t.mem_waddr;
        uint8_t wd=t.mem_wdata;
        require(!rd || !pending,"multiple outstanding reads");
        if(rd) validAddress(ra);
        if(wr) validAddress(wa);
        if(rd && instant) { t.mem_rvalid=1; t.mem_rdata=mem.at(ra); t.eval(); }
        bool response=t.mem_rvalid;
        t.clk=1; t.eval();
        if(response) pending=false;
        if(rd) {
            ++reads;
            if(!instant) { pending=true; readAddr=ra; due=cycle+(stalls?1+reads%7:1); }
        }
        if(wr) {
            ++writes;
            queued.push_back({wa,wd,cycle+(stalls?3+writes%13:1)});
        }
        if(t.done) {
            ++doneCount;
            require(!pending && queued.empty() && !holdDrain && !t.error,"false completion before final accepted drain");
        }
        t.clk=0; t.eval(); ++cycle;
    }
    Sim() { t.reset=1; tick(); tick(); t.reset=0; tick(); }
    void begin(int w,int h,int bank=0) {
        width=w; height=h; base=bank;
        t.frame_width=w; t.frame_height=h; t.frame_base=bank;
        t.frame_begin=1; tick(); t.frame_begin=0; tick();
    }
    void metadata(int mb,const Meta& m) {
        require(t.meta_ready,"metadata unexpectedly blocked");
        t.meta_mb=mb; t.meta_mode=m.mode; t.meta_qp=m.qp;
        t.meta_luma_nonzero=m.nz; t.meta_mvx=uint16_t(m.mx); t.meta_mvy=uint16_t(m.my);
        t.meta_reference=m.ref; t.meta_slice=m.slice;
        t.meta_chroma_offset=m.co&31; t.meta_alpha_offset=m.ao&31; t.meta_beta_offset=m.bo&31;
        t.meta_disable_idc=m.idc; t.meta_valid=1; tick(); t.meta_valid=0;
    }
    void launch() { t.start=1; tick(); t.start=0; }
    void finish() {
        int guard=0;
        while(!t.done && !t.error) { tick(); require(++guard<4000000,"scheduler timeout"); }
        require(t.done && !t.error,"scheduler reported error instead of completion");
        tick(); require(!t.done && !t.busy,"completion is not a single pulse");
    }
};
void compare(const std::vector<uint8_t>& got,const std::vector<uint8_t>& want,const std::string& label) {
    require(got.size()==want.size(),"comparison size");
    for(size_t i=0;i<got.size();++i) if(got[i]!=want[i])
        throw std::runtime_error(label+" byte"+std::to_string(i)+" got"+std::to_string(got[i])+" want"+std::to_string(want[i]));
}
void fill(Sim& s) {
    for(int p=0;p<3;++p) for(int y=0;y<(p?s.height/2:s.height);++y)
        for(int x=0;x<(p?s.width/2:s.width);++x)
            s.mem[address(s.base,p,x,y)]=uint8_t(68+p*31+(x/4)*3+(y/4)*2+((x+y)%3));
}
void synthetic() {
    for(int variant=0;variant<5;++variant) {
        Sim s; s.instant=variant==3; s.begin(64,48,variant&1?N:0); fill(s);
        std::vector<Meta> m(12);
        for(int i=0;i<12;++i) {
            m[i].mode=i==5?2:i==10?3:i%3==0?1:0;
            m[i].qp=29+(i*7)%23; m[i].co=(i%5-2)*3;
            m[i].nz=m[i].mode==1?0:uint16_t(0x0101u<<((i*3)%8));
            m[i].mx=i%4==0?-32768:i%4==1?32767:i%4==2?3:4;
            m[i].my=i%3==0?-7:3;
            m[i].ref=i/3; m[i].slice=i/4;
            m[i].ao=(i%3-1)*6; m[i].bo=(i%3-1)*2;
            m[i].idc=variant==1?1:variant==2?2:variant==4?i%3:0;
            s.metadata(i,m[i]);
        }
        auto expected=s.mem;
        software(expected,m,s.width,s.height,s.base);
        s.holdDrain=true; s.launch();
        for(int i=0;i<12;++i) s.tick();
        require(!s.reads && !s.writes && !s.t.done,"filter read before reconstruction drain");
        s.holdDrain=false; s.finish();
        compare(s.mem,expected,"whole-picture scalar reference variant"+std::to_string(variant));
        require(variant==1 ? !s.reads&&!s.writes : s.writes>0,"missing actual filtering/bypass");
        std::cout<<"PASS synthetic frame variant"<<variant<<" accepted_reads="<<s.reads<<" writes="<<s.writes<<" cycles="<<s.cycle<<"\n";
    }
    Sim full; full.begin(320,224);
    Meta bypass; bypass.idc=1;
    for(int i=0;i<280;++i) full.metadata(i,bypass);
    full.launch(); full.finish();
    require(!full.reads && !full.writes,"coded320x224 bypass traffic");
    // Duplicate records must not replace missing metadata.
    Sim missing; missing.begin(32,16); missing.metadata(0,Meta{}); missing.metadata(0,Meta{});
    missing.launch(); require(missing.t.error && !missing.t.done && !missing.reads,"missing metadata completion");
    for(int kind=0;kind<8;++kind) {
        Sim bad; bad.begin(16,16); Meta m;
        if(kind==0) m.mode=4; if(kind==1) m.qp=52; if(kind==2) m.idc=3;
        if(kind==3) m.ao=1; if(kind==4) m.bo=14; if(kind==5) m.co=-13;
        if(kind==6) { m.mode=1; m.nz=1; }
        bad.metadata(kind==7?1:0,m); bad.launch();
        require(bad.t.error && !bad.t.done && !bad.reads && !bad.writes,"invalid metadata not fail-closed");
    }
    for(auto wh:std::vector<std::array<int,2>>{{0,16},{320,212},{336,240}}) {
        Sim bad; bad.begin(wh[0],wh[1]); bad.launch();
        require(bad.t.error && !bad.t.done && !bad.reads,"invalid coded geometry");
    }
    for(int abortWrite=0;abortWrite<2;++abortWrite) {
        Sim s; s.begin(32,32); fill(s);
        Meta m; m.mode=2; m.qp=42;
        for(int i=0;i<4;++i) s.metadata(i,m);
        s.launch();
        int guard=0;
        while(abortWrite?s.queued.empty():!s.pending) { s.tick(); require(++guard<10000,"abort trigger not reached"); }
        auto accepted=s.writes;
        s.t.frame_abort=1; s.tick(); s.t.frame_abort=0;
        while(s.t.busy) { s.tick(); require(++guard<11000,"abort drain timeout"); }
        require(s.t.error && !s.doneCount && s.writes==accepted && !s.pending && s.queued.empty(),
                "abort did not discard/drain current job");
    }
    // Existing payload must not make a missing record valid in a new frame.
    Sim reuse; reuse.begin(32,16);
    reuse.metadata(0,bypass); reuse.metadata(1,bypass); reuse.launch(); reuse.finish();
    reuse.begin(32,16); reuse.metadata(0,bypass); reuse.launch();
    require(reuse.t.error && !reuse.t.done && !reuse.reads,
            "old metadata payload escaped the new frame's validity generation");
    for(int doReset=0;doReset<2;++doReset) {
        Sim s; s.begin(16,16); fill(s);
        Meta filtered; filtered.mode=2; filtered.qp=42;
        s.metadata(0,filtered); s.launch();
        // PRE_DRAIN then LOAD_MB issues the real synchronous metadata read.
        s.tick(); s.tick();
        require(s.t.busy && !s.reads && !s.writes,"metadata-read cancellation setup");
        if(doReset) { s.t.reset=1; s.tick(); s.t.reset=0; }
        else { s.t.frame_abort=1; s.tick(); s.t.frame_abort=0; }
        int guard=0;
        while(s.t.busy) { s.tick(); require(++guard<64,"metadata-read cancellation failed to retire"); }
        require(!s.t.done && !s.reads && !s.writes,"cancelled metadata read started native work");
        s.begin(16,16); s.metadata(0,bypass); s.launch(); s.finish();
        require(!s.reads && !s.writes,"new bypass job consumed stale filtered metadata");
    }
    std::cout<<"PASS metadata RAM generation, pending-read abort/reset and fresh payload ownership\n";
}
std::vector<uint8_t> file(const std::string& path) {
    std::ifstream in(path,std::ios::binary);
    require(bool(in),"cannot open "+path);
    return {std::istreambuf_iterator<char>(in),{}};
}
void pipelineCancellation() {
    unsigned cases=0;
    for(unsigned mode=0;mode<3;++mode)for(unsigned cut=0;cut<5;++cut) {
        Sim s;s.stalls=false;s.instant=true;s.begin(16,16,(cut&1)?N:0);fill(s);
        Meta m;m.mode=3;m.qp=40;s.metadata(0,m);
        const auto unfiltered=s.mem;
        s.launch();
        unsigned guard=0;
        while(s.reads<32) {s.tick();require(++guard<10000,"first segment did not retire reads");}
        require(!s.pending&&!s.writes&&!s.doneCount,"sample pipeline boundary not isolated");
        for(unsigned i=0;i<cut;++i)s.tick();
        require(!s.writes&&!s.doneCount,"first filtered sample committed before cancellation cut");
        if(mode==0)s.t.frame_abort=1;
        else if(mode==1)s.t.reset=1;
        else s.t.frame_begin=1;
        s.tick();s.t.frame_abort=0;s.t.reset=0;s.t.frame_begin=0;
        for(unsigned i=0;i<64&&s.t.busy;++i)s.tick();
        for(unsigned i=0;i<5;++i)s.tick();
        require(!s.t.busy&&!s.doneCount&&!s.writes&&!s.pending&&s.queued.empty(),
                "canceled arithmetic pipeline wrote or completed");
        compare(s.mem,unfiltered,"canceled sample pipeline");
        s.begin(16,16,s.base);s.metadata(0,m);
        auto expected=s.mem;software(expected,std::vector<Meta>{m},16,16,s.base);
        s.launch();s.finish();
        compare(s.mem,expected,"fresh sample pipeline generation");
        require(s.doneCount==1&&s.writes,"fresh arithmetic result was lost after cancellation");
        ++cases;
    }
    std::cout<<"PASS frame arithmetic cancellation/fresh generations="<<cases
             <<" reset/abort/overlapping-frame-begin across capture, clip, apply, result and first-write cuts\n";
}

void ordinary(const std::string& stream,const std::string& unfiltered,const std::string& gold,int ao,int bo) {
    auto bytes=file(stream), before=file(unfiltered), after=file(gold);
    auto chain=misterplex::parseAnnexBChain(bytes.data(),bytes.size());
    require(chain.sps.valid && chain.pps.valid && chain.slice.valid && chain.slice.is_i_slice &&
            chain.slice.disable_deblocking_idc==0,"ordinary vector is not filter-on I picture");
    auto recon=misterplex::recon::reconISlice(bytes.data(),bytes.size(),nullptr);
    require(recon.mb_decoded==recon.mb_total,"metadata I-slice parser incomplete");
    int w=recon.width,h=recon.height;
    require(before.size()==size_t(w*h*3/2) && after.size()==before.size(),"ordinary vector size");
    require(before!=after,"ordinary vector does not exercise filtering");
    Sim s; s.begin(w,h,N);
    auto expected=s.mem;
    size_t k=0;
    for(int p=0;p<3;++p) for(int y=0;y<(p?h/2:h);++y) for(int x=0;x<(p?w/2:w);++x,++k) {
        s.mem[address(N,p,x,y)]=before[k]; expected[address(N,p,x,y)]=after[k];
    }
    int i4=0,i16=0;
    for(int mb=0;mb<recon.mb_total;++mb) {
        misterplex::recon::ReconTrace tr; tr.target_mb=mb;
        auto trace=misterplex::recon::reconISlice(bytes.data(),bytes.size(),&tr);
        require(trace.mb_decoded==trace.mb_total && tr.mb.valid && tr.mb.mb_type<=24,"unsupported metadata in ordinary fixture");
        Meta m; m.mode=tr.mb.mb_type==0?2:3; m.qp=tr.mb.qp; m.ao=ao; m.bo=bo;
        for(const auto& block:tr.mb.blocks) if(block.total_coeff)
            m.nz|=1<<((block.y/4)*4+block.x/4);
        if(m.mode==2) ++i4; else ++i16;
        s.metadata(mb,m);
    }
    s.launch(); s.finish();
    compare(s.mem,expected,"ordinary FFmpeg filtered whole picture");
    size_t changed=0; for(size_t i=0;i<before.size();++i) changed+=before[i]!=after[i];
    std::cout<<"PASS ordinary FFmpeg filter-on "<<w<<"x"<<h<<" I4="<<i4<<" I16="<<i16
             <<" changed_samples="<<changed<<" reads="<<s.reads<<" writes="<<s.writes<<" cycles="<<s.cycle
             <<" (unfiltered pixels are leaf inputs; not a composed decoder proof)\n";
}
}
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try {
        if(argc==1) {synthetic();pipelineCancellation();}
        else {
            require(argc==6,"usage: tb stream.264 unfiltered.yuv ordinary.yuv alpha_actual beta_actual");
            ordinary(argv[1],argv[2],argv[3],std::stoi(argv[4]),std::stoi(argv[5]));
        }
    } catch(const std::exception& e) { std::cerr<<"FAIL "<<e.what()<<"\n"; return 1; }
}
