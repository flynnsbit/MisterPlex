#include "Vp2_intra_controller_tb.h"
#include "verilated.h"
#include "libmisterplex/h264_sps.hpp"
#include <algorithm>
#include <array>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

static std::vector<uint8_t> read(const char* path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error(std::string("open: ")+path);
    return {std::istreambuf_iterator<char>(f), {}};
}
static uint16_t rgb(int y,int u,int v,bool full,int matrix) {
    y-=full?0:16;u-=128;v-=128;
    int ys=full?256:298;
    int rv=matrix==1?(full?403:459):(full?359:409);
    int gu=matrix==1?(full?48:55):(full?88:100);
    int gv=matrix==1?(full?120:136):(full?183:208);
    int bu=matrix==1?(full?475:541):(full?454:516);
    int r=std::clamp((ys*y+rv*v+128)>>8,0,255);
    int g=std::clamp((ys*y-gu*u-gv*v+128)>>8,0,255);
    int b=std::clamp((ys*y+bu*u+128)>>8,0,255);
    return ((r>>3)<<11)|((g>>2)<<5)|(b>>3);
}
struct Metadata {
    unsigned frame_bits=4,poc_bits=4,poc_type=2,mb_cols=0,mb_rows=0,max_refs=0;
    unsigned left=0,right=0,top=0,bottom=0,sar_w=0,sar_h=0;
    int qp=26,chroma_offset=0;
    bool deblock_control=false,constrained=false,sar_known=false;
    unsigned width() const {return mb_cols*16;}
    unsigned height() const {return mb_rows*16;}
    unsigned visible_w() const {return width()-left-right;}
    unsigned visible_h() const {return height()-top-bottom;}
    unsigned samples() const {return width()*height()*3/2;}
};
static unsigned native_offset(const Metadata& m,unsigned ordinal) {
    const unsigned y=m.width()*m.height();
    if(ordinal<y)return (ordinal/m.width())*320+ordinal%m.width();
    ordinal-=y;
    const unsigned base=ordinal<y/4?76800:96000;
    if(ordinal>=y/4)ordinal-=y/4;
    return base+(ordinal/(m.width()/2))*160+ordinal%(m.width()/2);
}
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    if(argc!=4&&argc!=6) {std::cerr<<"usage: encoded.264 ffmpeg.yuv actual.yuv [full_range matrix]\n";return 2;}
    try {
        auto encoded=read(argv[1]),gold=read(argv[2]);
        Vp2_intra_controller_tb d;
        Metadata current;
        unsigned expected_mbs=0,expected_samples=0,expected_pixels=0;
        const bool header_at_end=std::getenv("P2_HEADER_AT_END")!=nullptr;
        const bool fragment_capture=std::getenv("P2_FRAGMENT_CAPTURE")!=nullptr;
        const bool end_with_last=std::getenv("P2_END_WITH_LAST_BYTE")!=nullptr;
        const std::string cancel_mode=std::getenv("P2_NATIVE_CANCEL")?std::getenv("P2_NATIVE_CANCEL"):"";
        if(!cancel_mode.empty()&&cancel_mode!="reset"&&cancel_mode!="vcl")
            throw std::runtime_error("P2_NATIVE_CANCEL must be reset or vcl");
        const std::string chroma_cancel=std::getenv("P2_CHROMA_CANCEL")?std::getenv("P2_CHROMA_CANCEL"):"";
        const unsigned chroma_cancel_stage=std::getenv("P2_CHROMA_CANCEL_STAGE")?
            std::stoul(std::getenv("P2_CHROMA_CANCEL_STAGE")):1;
        if((!chroma_cancel.empty()&&chroma_cancel!="reset"&&chroma_cancel!="vcl")||
           chroma_cancel_stage>4||(!chroma_cancel.empty()&&!cancel_mode.empty()))
            throw std::runtime_error("invalid or overlapping chroma cancellation selector");
        bool chroma_canceled=false,chroma_outstanding=false;
        unsigned chroma_requests=0,chroma_retirements=0,chroma_cancellations=0;
        bool cancel_active=false,cancel_exercised=false;
        d.full_range=argc==6?std::stoi(argv[4]):0;
        d.matrix=argc==6?std::stoi(argv[5]):2;
        std::vector<uint8_t> actual(115200);
        std::vector<unsigned> visited(115200);
        uint64_t cycles=0,decode_cycles=0;
        unsigned writes=0,pixels=0,swaps=0,frame=0,promotions=0;
        bool final_stall=false;
        unsigned stalled=0;
        bool held=false;
        uint16_t held_pixel=0;
        unsigned native_bank=0,pub_requested=0,pub_responses=0,drain_wait=0;
        bool native_notified=false,drain_started=false,lease_released=false;
        std::deque<unsigned> pub_pending;
        uint64_t rgb_done_cycle=0,release_cycle=0;
        auto tick=[&] {
            d.pub_rd=0;d.native_release=0;
            d.clk=0;d.eval();
            if(d.reset||cancel_active)chroma_outstanding=false;
            else {
                if(d.chroma_start) {
                    if(chroma_outstanding)throw std::runtime_error("duplicate owned chroma request");
                    chroma_outstanding=true;++chroma_requests;
                }
                if(d.chroma_retire) {
                    if(!chroma_outstanding)throw std::runtime_error("unowned/stale chroma retirement");
                    chroma_outstanding=false;++chroma_retirements;
                }
            }
            if(d.static_idr_only_enabled&&(d.phase==24||d.phase==25))
                throw std::runtime_error("static IDR-only cut entered inter fetch");
            if(d.native_lease_enabled&&!d.reset&&!cancel_active&&d.native_valid&&!lease_released&&
               pub_requested<expected_samples&&((frame&1)||cycles%3!=0)) {
                d.pub_addr=d.native_base+native_offset(current,pub_requested);
                d.pub_rd=1;d.eval();
            }
            if(held&&!cancel_active && (!d.wr_en||d.wr_pixel!=held_pixel))
                throw std::runtime_error("output valid/data changed under backpressure");
            held=d.wr_en&&!d.wr_ready&&!cancel_active;held_pixel=d.wr_pixel;
            if(d.present_meta_valid&&!d.vcl) {
                if(d.present_coded_width!=current.width()||d.present_coded_height!=current.height()||
                   d.present_width!=current.visible_w()||d.present_height!=current.visible_h()||
                   d.present_crop_left!=current.left||d.present_crop_right!=current.right||
                   d.present_crop_top!=current.top||d.present_crop_bottom!=current.bottom||
                   d.present_sar_width!=current.sar_w||d.present_sar_height!=current.sar_h||
                   bool(d.present_sar_known)!=current.sar_known||
                   d.present_dar_num!=current.visible_w()*current.sar_w||
                   d.present_dar_den!=current.visible_h()*current.sar_h||
                   d.native_luma_stride!=320||d.native_chroma_stride!=160)
                    throw std::runtime_error("incorrect or unstable picture geometry metadata");
            }
            if(d.native_promoted) {
                if(writes!=expected_samples||d.mb_index!=expected_mbs)
                    throw std::runtime_error("native promotion before all accepted planes");
                ++promotions;
            }
            if(d.native_accept) {
                if(d.native_addr>=230400)throw std::runtime_error("out of range native write");
                unsigned addr=d.native_addr%115200;
                if(writes==0)native_bank=d.native_addr-addr;
                else if(d.native_addr-addr!=native_bank)throw std::runtime_error("native bank changed during writes");
                actual[addr]=d.native_data;
                ++visited[addr];++writes;
            }
            if(d.native_valid&&!native_notified) {
                if(promotions!=1||writes!=expected_samples||d.native_base!=native_bank)
                    throw std::runtime_error("native notification before valid picture promotion");
                native_notified=true;
            }
            if(d.native_lease_enabled&&native_notified&&!lease_released&&!cancel_active&&
               (!d.native_valid||!d.busy||d.native_base!=native_bank))
                throw std::runtime_error("native bank lease released before copy/drain");
            if(d.pub_rvalid) {
                if(pub_pending.empty())throw std::runtime_error("unexpected publisher read response");
                const unsigned offset=pub_pending.front();pub_pending.pop_front();
                if(d.pub_rdata!=actual[offset])throw std::runtime_error("publisher read changed leased native pixels");
                ++pub_responses;
            }
            if(d.pub_rd&&d.pub_ready) {
                pub_pending.push_back(native_offset(current,pub_requested));
                ++pub_requested;
            }
            if(d.native_lease_enabled&&native_notified&&!lease_released&&!cancel_active&&
               pub_responses==expected_samples&&pub_pending.empty()) {
                if(!drain_started) {drain_started=true;drain_wait=47;}
                else if(drain_wait)--drain_wait;
                else {d.native_release=1;lease_released=true;release_cycle=cycles+1;d.eval();}
            }
            if(d.wr_en&&d.wr_ready) {
                if(promotions!=1)throw std::runtime_error("RGB publication before native promotion");
                if(!d.present_meta_valid||pixels>=expected_pixels)
                    throw std::runtime_error("duplicate output pixel or missing geometry");
                unsigned x=current.left+pixels%current.visible_w();
                unsigned y=current.top+pixels/current.visible_w(),ci=(y/2)*160+x/2;
                if(d.wr_pixel!=rgb(actual[y*320+x],actual[76800+ci],actual[96000+ci],d.full_range,d.matrix))
                    throw std::runtime_error("RGB565 does not match reconstructed YUV");
                ++pixels;
            }
            if(d.swap_req&&d.wr_ready) {
                if(writes!=expected_samples||pixels!=expected_pixels||d.mb_index!=expected_mbs||promotions!=1)
                    throw std::runtime_error("partial picture swap");
                ++swaps;
            }
            if(d.frames_out>frame && (writes!=expected_samples||pixels!=expected_pixels||swaps!=1))
                throw std::runtime_error("early frame publication");
            d.clk=1;d.eval();++cycles;
            if(d.frames_out>frame&&!rgb_done_cycle)rgb_done_cycle=cycles;
        };
        d.reset=1;d.wr_ready=1;
        for(int i=0;i<4;++i)tick();
        d.reset=0;
        if(!cancel_mode.empty()&&!d.native_lease_enabled)
            throw std::runtime_error("native cancellation requires NATIVE_PUBLISH_LEASE=1");
        struct Slice {std::vector<uint8_t> rbsp;bool idr;unsigned nri;Metadata metadata;};
        std::vector<Slice> slices;
        Metadata metadata;
        for(size_t p=0;p+4<encoded.size();) {
            size_t sc=encoded[p]==0&&encoded[p+1]==0&&encoded[p+2]==1?3:
                encoded[p]==0&&encoded[p+1]==0&&encoded[p+2]==0&&encoded[p+3]==1?4:0;
            if(!sc){++p;continue;}
            size_t q=p+sc+1;
            while(q+3<encoded.size() && !(encoded[q]==0&&encoded[q+1]==0&&
                (encoded[q+2]==1||(encoded[q+2]==0&&encoded[q+3]==1))))++q;
            if(q+3>=encoded.size())q=encoded.size();
            auto r=misterplex::detail::removeEpb(encoded.data()+p+sc+1,q-p-sc-1);
            misterplex::detail::BitReader b(r.data(),r.size());
            const int type=encoded[p+sc]&31;
            if(type==7) {
                if(b.u(8)!=66)throw std::runtime_error("test requires Baseline SPS");
                b.u(16);b.ue();metadata.frame_bits=b.ue()+4;metadata.poc_type=b.ue();
                if(metadata.poc_type==0)metadata.poc_bits=b.ue()+4;
                else if(metadata.poc_type!=2)throw std::runtime_error("unsupported POC");
                metadata.max_refs=b.ue();b.u(1);
                metadata.mb_cols=b.ue()+1;metadata.mb_rows=b.ue()+1;
                if(!b.u(1))throw std::runtime_error("test requires progressive SPS");
                b.u(1);
                metadata.left=metadata.right=metadata.top=metadata.bottom=0;
                if(b.u(1)) {
                    metadata.left=b.ue()*2;metadata.right=b.ue()*2;
                    metadata.top=b.ue()*2;metadata.bottom=b.ue()*2;
                }
                metadata.sar_w=metadata.sar_h=0;metadata.sar_known=false;
                if(b.u(1)&&b.u(1)) {
                    unsigned aspect=b.u(8);
                    static constexpr unsigned sar[][2]={
                        {0,0},{1,1},{12,11},{10,11},{16,11},{40,33},{24,11},
                        {20,11},{32,11},{80,33},{18,11},{15,11},{64,33},
                        {160,99},{4,3},{3,2},{2,1}};
                    if(aspect==255) {metadata.sar_w=b.u(16);metadata.sar_h=b.u(16);}
                    else if(aspect<17) {metadata.sar_w=sar[aspect][0];metadata.sar_h=sar[aspect][1];}
                    else throw std::runtime_error("unsupported SPS aspect code");
                    metadata.sar_known=aspect!=0;
                    if(metadata.sar_known&&(!metadata.sar_w||!metadata.sar_h))
                        throw std::runtime_error("zero signaled SAR");
                }
            } else if(type==8) {
                if(b.ue()!=0||b.ue()!=0||b.u(1)!=0||b.u(1)!=0||b.ue()!=0)
                    throw std::runtime_error("unsupported PPS");
                if(b.ue()!=0)throw std::runtime_error("multiple references");
                b.ue();b.u(1);b.u(2);metadata.qp=26+b.se();b.se();
                metadata.chroma_offset=b.se();metadata.deblock_control=b.u(1);metadata.constrained=b.u(1);
            } else if(type==5||type==1) {
                slices.push_back({r,type==5,unsigned((encoded[p+sc]>>5)&3),metadata});
            }
            p=q;
        }
        size_t expected_gold=0;
        for(const auto& s:slices)expected_gold+=s.metadata.samples();
        if(slices.empty()||gold.size()!=expected_gold)
            throw std::runtime_error("test expects one complete slice per FFmpeg frame");
        std::ofstream out(argv[3],std::ios::binary);
        size_t gold_offset=0;
        for(frame=0;frame<slices.size();) {
        current=slices[frame].metadata;
        expected_mbs=current.mb_cols*current.mb_rows;
        expected_samples=current.samples();
        expected_pixels=current.visible_w()*current.visible_h();
        d.frame_bits=current.frame_bits;d.poc_bits=current.poc_bits;d.poc_type=current.poc_type;
        d.initial_qp=current.qp;d.chroma_offset=current.chroma_offset;
        d.deblock_control=current.deblock_control;d.constrained_intra=current.constrained;
        d.mb_cols=current.mb_cols;d.mb_rows=current.mb_rows;
        d.crop_left=current.left;d.crop_right=current.right;d.crop_top=current.top;d.crop_bottom=current.bottom;
        d.sar_width=current.sar_w;d.sar_height=current.sar_h;d.sar_known=current.sar_known;
        d.geometry_valid=std::getenv("P2_REJECT_GEOMETRY")==nullptr;
        unsigned admitted_refs=current.max_refs;
        if(const char* refs=std::getenv("P2_SPS_MAX_REFS"))admitted_refs=std::stoul(refs);
        d.max_refs=admitted_refs;
        d.idr_only=std::getenv("P2_IDR_ONLY")!=nullptr;
        if(std::getenv("P2_ODD_CROP"))d.crop_left|=1;
        if(const char* sar_fault=std::getenv("P2_BAD_SAR")) {
            if(std::string(sar_fault)=="known-zero") {d.sar_known=1;d.sar_width=0;}
            else if(std::string(sar_fault)=="unknown-nonzero") {d.sar_known=0;d.sar_width=1;d.sar_height=1;}
            else throw std::runtime_error("unknown SAR fault mode");
        }
        if(const char* offset=std::getenv("P2_INVALID_CHROMA_OFFSET"))
            d.chroma_offset=std::stoi(offset);
        const auto& rbsp=slices[frame].rbsp;
        if(rbsp.empty()||rbsp.size()>1048576)throw std::runtime_error("test transport length exceeded");
        d.idr=slices[frame].idr;d.nri=slices[frame].nri;
        writes=0;pixels=0;swaps=0;promotions=0;final_stall=false;stalled=0;decode_cycles=0;
        pub_requested=0;pub_responses=0;drain_wait=0;
        native_notified=false;drain_started=false;lease_released=false;rgb_done_cycle=0;release_cycle=0;
        pub_pending.clear();
        std::fill(actual.begin(),actual.end(),0);std::fill(visited.begin(),visited.end(),0);
        uint64_t start_cycles=cycles;
        d.vcl=1;d.clear=1;tick();d.vcl=0;d.clear=0;
        d.rbsp_len=std::min<size_t>(rbsp.size(),2*d.rbsp_capacity-1);
        for(size_t i=0;i<rbsp.size();++i) {
            d.byte_en=1;d.byte_data=rbsp[i];
            d.rbsp_end=end_with_last&&i+1==rbsp.size();
            tick();d.rbsp_end=0;
            if(!header_at_end && (i==47 || (i+1==rbsp.size() && rbsp.size()<48))) {
                d.byte_en=0;d.header_end=1;tick();d.header_end=0;
            }
            if(fragment_capture&&i%257==0) {
                d.byte_en=0;tick();tick();
            }
        }
        if(header_at_end) {d.byte_en=0;d.header_end=1;tick();d.header_end=0;}
        d.byte_en=0;d.rbsp_end=!end_with_last;tick();d.rbsp_end=0;
        if(!d.capture_done||d.capture_len!=std::min<size_t>(rbsp.size(),d.rbsp_capacity)||
           d.capture_count!=d.capture_len||d.capture_first!=rbsp.front()||
           bool(d.capture_overflow)!=(rbsp.size()>d.rbsp_capacity)) {
            std::cerr<<"CAPTURE capacity="<<d.rbsp_capacity<<" payload="<<rbsp.size()
                     <<" stored="<<d.capture_len<<" controller_count="<<d.capture_count
                     <<" done="<<unsigned(d.capture_done)<<" overflow="<<unsigned(d.capture_overflow)
                     <<" first="<<unsigned(d.capture_first)<<" expected_first="<<unsigned(rbsp.front())<<"\n";
            throw std::runtime_error("capture capacity/count/overflow mismatch");
        }
        if(rbsp.size()>=d.rbsp_capacity&&d.capture_last!=rbsp[d.rbsp_capacity-1])
            throw std::runtime_error("last RAM byte lost or overwritten at capacity");
        bool metadata_changed=false,canceled=false;
        for(unsigned n=0;n<12000000&&(d.frames_out==frame||(d.native_lease_enabled&&d.busy));++n) {
            if(!chroma_cancel.empty()&&!chroma_canceled&&d.chroma_pending&&
               d.chroma_stage==chroma_cancel_stage&&(chroma_cancel_stage!=0||d.chroma_done)) {
                if(!chroma_outstanding)throw std::runtime_error("chroma cancellation missed owned request");
                cancel_active=true;chroma_canceled=true;++chroma_cancellations;
                d.wr_ready=0;held=false;
                if(chroma_cancel=="reset") {
                    d.reset=1;for(unsigned i=0;i<3;++i)tick();d.reset=0;
                } else {d.vcl=1;tick();d.vcl=0;}
                for(unsigned i=0;i<1000&&d.busy;++i)tick();
                for(unsigned i=0;i<4;++i)tick();
                if(d.busy||d.chroma_pending||d.chroma_done||d.chroma_start||
                   d.native_valid||d.present_meta_valid||d.done||d.frames_out!=frame||
                   swaps||pixels||promotions||d.prediction_reference_valid||
                   (chroma_cancel=="vcl"&&d.error!=12))
                    throw std::runtime_error("canceled chroma request survived or published");
                std::cout<<"CHROMA_CANCEL mode="<<chroma_cancel<<" stage="<<chroma_cancel_stage
                         <<" frames="<<d.frames_out<<" requests="<<chroma_requests
                         <<" retirements="<<chroma_retirements<<"\n";
                cancel_active=false;canceled=true;break;
            }
            if(!cancel_mode.empty()&&!cancel_exercised&&native_notified&&pub_requested>=64) {
                cancel_active=true;cancel_exercised=true;d.wr_ready=0;held=false;
                if(cancel_mode=="reset") {
                    d.reset=1;for(unsigned i=0;i<3;++i)tick();d.reset=0;
                } else {d.vcl=1;tick();d.vcl=0;}
                for(unsigned i=0;i<1000&&d.busy;++i)tick();
                for(unsigned i=0;i<4;++i)tick();
                if(d.busy||d.native_valid||d.present_meta_valid||d.done||d.frames_out!=frame||
                   swaps||d.prediction_reference_valid||!pub_pending.empty()||
                   (cancel_mode=="vcl"&&d.error!=12))
                    throw std::runtime_error("canceled native lease survived or published");
                std::cout<<"NATIVE_CANCEL mode="<<cancel_mode<<" requests="<<pub_requested
                         <<" responses="<<pub_responses<<" frames="<<d.frames_out<<"\n";
                cancel_active=false;canceled=true;break;
            }
            if(d.phase==6&&!metadata_changed) {
                // Input buses can move after header acceptance; the in-flight
                // picture's geometry, crop, SAR and reference epoch cannot.
                d.mb_cols=1;d.mb_rows=1;d.geometry_valid=0;
                d.crop_left=1;d.sar_width=0;d.sar_known=!d.sar_known;d.idr=!d.idr;d.nri=0;
                d.max_refs=2;d.idr_only=!d.idr_only;
                metadata_changed=true;
            }
            if(d.phase==21&&!decode_cycles)decode_cycles=cycles-start_cycles;
            if(pixels==expected_pixels-1&&!final_stall) {final_stall=true;stalled=150;}
            d.wr_ready=stalled ? 0 : ((n%13)!=0);
            if(stalled) {
                --stalled;
                if(d.frames_out>frame||d.done||swaps)throw std::runtime_error("completion during final-pixel stall");
            }
            tick();
            if(!d.busy&&d.frames_out==frame)break;
        }
        if(canceled)continue;
        if(current.width()<=320&&current.height()<=240)
            for(unsigned plane=0;plane<3;++plane) {
                unsigned stride=plane?160:320,base=plane==0?0:plane==1?76800:96000;
                for(unsigned row=0;row<(current.height()>>(plane!=0));++row)
                    out.write(reinterpret_cast<char*>(actual.data()+base+row*stride),current.width()>>(plane!=0));
            }
        out.flush();
        std::cout<<"GEOMETRY coded="<<current.width()<<"x"<<current.height()
                 <<" crop="<<current.left<<","<<current.right<<","<<current.top<<","<<current.bottom
                 <<" visible="<<current.visible_w()<<"x"<<current.visible_h()
                 <<" sar="<<current.sar_w<<":"<<current.sar_h<<" strides=320/160"
                 <<" chroma_offset="<<current.chroma_offset
                 <<" sar_known="<<current.sar_known
                 <<" sps_max_refs="<<current.max_refs<<"\n";
        std::cout<<"CONTROLLER cycles="<<cycles-start_cycles<<" decode_cycles="<<decode_cycles
                 <<" mb="<<d.mb_index<<" phase="<<unsigned(d.phase)
                 <<" bit="<<d.bit_pos<<" error="<<unsigned(d.error)
                 <<" header_error="<<unsigned(d.header_error)
                 <<" header_at_end="<<header_at_end
                 <<" filter_idc="<<unsigned(d.filter_idc)
                 <<" writes="<<writes<<" pixels="<<pixels<<" frames="<<d.frames_out<<"\n";
        std::cout<<"RBSP capacity="<<d.rbsp_capacity<<" payload="<<rbsp.size()
                 <<" stored="<<d.capture_len<<" bits="<<d.bit_length
                 <<" cursor="<<d.bit_pos<<" eof="<<unsigned(d.reader_eof)
                 <<" overflow="<<unsigned(d.capture_overflow)<<"\n";
        if(d.native_lease_enabled)
            std::cout<<"NATIVE_LEASE requested="<<pub_requested<<" responses="<<pub_responses
                     <<" released="<<lease_released<<" rgb_done_cycles="<<(rgb_done_cycle?rgb_done_cycle-start_cycles:0)
                     <<" release_cycles="<<(release_cycle?release_cycle-start_cycles:0)
                     <<" busy="<<unsigned(d.busy)<<"\n";
        std::cout<<"COVERAGE coeff_abs="<<d.max_abs_coeff<<" i4_modes="<<d.i4_modes
                 <<" i16_modes="<<unsigned(d.i16_modes)<<" chroma_modes="<<unsigned(d.chroma_modes)
                 <<" chroma_ac_blocks="<<d.chroma_ac_blocks<<" intra_in_p="<<d.intra_in_p
                 <<" qpel_phases="<<d.qpel_phases<<" mc_borders="<<unsigned(d.mc_borders)<<"\n";
        if(d.header_error)throw std::runtime_error("invalid slice header rejected");
        if(d.static_idr_only_enabled&&!slices[frame].idr) {
            if(d.error!=19||writes||pixels||swaps||promotions||native_notified||
               d.native_valid||d.busy||d.frames_out!=frame)
                throw std::runtime_error("static IDR-only cut accepted non-IDR work");
            std::cout<<"STATIC_NON_IDR_REJECT runtime_policy="<<unsigned(d.idr_only)<<"\n";
            return 5;
        }
        if(d.filter_idc!=1) {
            if(d.frames_out>frame||writes||pixels||swaps||promotions)
                throw std::runtime_error("unsupported filter wrote or published a picture");
            std::cout<<"EXPLICIT_FILTER_REJECT\n";return 3;
        }
        if(d.frames_out!=frame+1||writes!=expected_samples||pixels!=expected_pixels||swaps!=1||!final_stall)
            throw std::runtime_error("incomplete picture");
        if(!native_notified||(d.native_lease_enabled&&(!lease_released||d.native_valid||d.busy||
                                                     pub_responses!=expected_samples||!pub_pending.empty())))
            throw std::runtime_error("incomplete immutable native-picture handoff");
        if(d.native_lease_enabled&&expected_pixels==76800&&
           ((frame&1)?release_cycle>=rgb_done_cycle:release_cycle<=rgb_done_cycle))
            throw std::runtime_error("native lease did not exercise the intended early/late release");
        if(d.bit_pos!=rbsp.size()*8||d.bit_length!=rbsp.size()*8||!d.reader_eof||d.reader_error)
            throw std::runtime_error("incorrect terminal bit cursor or EOF");
        if(bool(d.prediction_reference_valid)!=(admitted_refs==1))
            throw std::runtime_error("display-bank promotion changed SPS reference eligibility");
        std::array<unsigned,3> mismatch{};
        unsigned packed=0;
        for(unsigned plane=0;plane<3;++plane) {
          unsigned stride=plane?160:320,base=plane==0?0:plane==1?76800:96000;
          for(unsigned row=0;row<(current.height()>>(plane!=0));++row)
           for(unsigned col=0;col<(current.width()>>(plane!=0));++col,++packed) {
            unsigned i=base+row*stride+col;
            if(visited[i]!=1)throw std::runtime_error("missing or duplicate native pixel");
            if(actual[i]!=gold[gold_offset+packed]) {
                ++mismatch[plane];
                if(mismatch[0]+mismatch[1]+mismatch[2]<=12)
                    std::cout<<"DIFF frame="<<frame<<" offset="<<i<<" got="<<unsigned(actual[i])
                             <<" want="<<unsigned(gold[gold_offset+packed])<<"\n";
            }
           }
        }
        std::cout<<"YUV mismatches="<<mismatch[0]<<","<<mismatch[1]<<","<<mismatch[2]<<"\n";
        if(mismatch[0]||mismatch[1]||mismatch[2])return 1;
        gold_offset+=expected_samples;
        ++frame;
        }
        if(!cancel_mode.empty()&&!cancel_exercised)
            throw std::runtime_error("native cancellation was not exercised");
        if(!chroma_cancel.empty()&&!chroma_canceled)
            throw std::runtime_error("owned chroma cancellation was not exercised");
        if(chroma_outstanding||chroma_requests!=chroma_retirements+chroma_cancellations)
            throw std::runtime_error("chroma request/retirement/cancellation conservation");
        std::cout<<"CHROMA_TRANSACTIONS requests="<<chroma_requests<<" retired="<<chroma_retirements
                 <<" canceled="<<chroma_cancellations<<" core_cycles=5\n";
        return 0;
    } catch(const std::exception&e) {std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}
}
