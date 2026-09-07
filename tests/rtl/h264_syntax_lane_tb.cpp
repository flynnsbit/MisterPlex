#include "Vh264_syntax_lane_tb_top.h"
#include "verilated.h"
#include "libmisterplex/h264_nal.hpp"
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using Dut = Vh264_syntax_lane_tb_top;
static void check(bool b, const char* what) { if (!b) throw std::runtime_error(what); }
static void tick(Dut& d) { d.clk=0; d.eval(); d.clk=1; d.eval(); }
struct Bits {
    std::vector<int> v;
    void u(uint64_t n, int count) { for (int i=count-1;i>=0;--i) v.push_back((n>>i)&1); }
    void ue(uint32_t n) {
        uint64_t code=uint64_t(n)+1; int len=0;
        for (uint64_t k=code;k;k>>=1) ++len;
        u(0,len-1); u(code,len);
    }
    void se(int n) { ue(n<=0 ? -2*n : 2*n-1); }
    void stop() { u(1,1); while(v.size()%8) u(0,1); }
    std::vector<uint8_t> bytes() const {
        std::vector<uint8_t> out((v.size()+7)/8);
        for(size_t i=0;i<v.size();++i) out[i/8] |= v[i]<<(7-i%8);
        return out;
    }
};
static void capture(Dut& d, int kind, const std::vector<uint8_t>& bytes) {
    static unsigned transfer=0;
    const bool simultaneous_last=(transfer++%2)==0 && !bytes.empty();
    d.kind=kind; d.cap_clear=1; tick(d); d.cap_clear=0;
    for(size_t i=0;i<bytes.size();++i) {
        d.cap_en=0; for(size_t j=0;j<i%3;++j) tick(d);
        d.cap_en=1; d.cap_data=bytes[i];d.cap_end=simultaneous_last&&i+1==bytes.size(); tick(d);
    }
    d.cap_en=0;
    if(!simultaneous_last) {d.cap_end=1;tick(d);}
    d.cap_end=0;
    for(int i=0;i<3000;++i) {
        tick(d);
        if (kind==0 ? (d.sps_valid||d.sps_error) :
            kind==1 ? (d.pps_valid||d.pps_error) : (d.hdr_valid||d.hdr_error)) return;
    }
    throw std::runtime_error("capture parser timeout");
}
static Bits sps(int poc=2, int profile=66, bool frame=true) {
    Bits b; b.u(profile,8); b.u(0xc0,8); b.u(30,8); b.ue(0); b.ue(0); b.ue(poc);
    if(poc==0) b.ue(0);
    b.ue(1); b.u(0,1); b.ue(19); b.ue(14); b.u(frame,1);
    if(!frame) b.u(0,1);
    b.u(1,1); b.u(0,1); b.u(0,1); b.stop(); return b;
}
static Bits sps_colour(bool full, int matrix, int top_loc=-1, int bottom_loc=-1) {
    Bits b; b.u(66,8); b.u(0xc0,8); b.u(30,8); b.ue(0); b.ue(0); b.ue(2);
    b.ue(1); b.u(0,1); b.ue(19); b.ue(14); b.u(1,1); b.u(1,1); b.u(0,1);
    b.u(1,1); // vui_parameters_present_flag
    b.u(0,1); b.u(0,1); // no SAR or overscan
    b.u(1,1); b.u(5,3); b.u(full,1); b.u(matrix>=0,1);
    if(matrix>=0) {b.u(1,8);b.u(1,8);b.u(matrix,8);}
    b.u(top_loc>=0,1);
    if(top_loc>=0) {b.ue(top_loc);b.ue(bottom_loc);}
    b.u(0,1); b.u(0,1); b.u(0,1); b.u(0,1); b.u(0,1);
    b.stop(); return b;
}
static Bits sps_geometry(int w,int h,int left=0,int top=0,int right=0,int bottom=0,
                         int sar_idc=-1,int sar_w=0,int sar_h=0) {
    Bits b;b.u(66,8);b.u(0xc0,8);b.u(30,8);b.ue(0);b.ue(0);b.ue(2);
    b.ue(1);b.u(0,1);b.ue(w/16-1);b.ue(h/16-1);b.u(1,1);b.u(1,1);
    bool cropped=left||top||right||bottom;
    b.u(cropped,1);
    if(cropped) {b.ue(left/2);b.ue(right/2);b.ue(top/2);b.ue(bottom/2);}
    b.u(sar_idc>=0,1);
    if(sar_idc>=0) {
        b.u(1,1);b.u(sar_idc,8);
        if(sar_idc==255) {b.u(sar_w,16);b.u(sar_h,16);}
        b.u(0,8); // overscan, video, chroma, timing, both HRDs, pic_struct, restriction
    }
    b.stop();return b;
}
static Bits pps(bool cabac=false, bool weighted=false, int chr=-12) {
    Bits b; b.ue(0); b.ue(0); b.u(cabac,1); b.u(0,1); b.ue(0);
    b.ue(0); b.ue(0); b.u(weighted,1); b.u(0,2); b.se(0); b.se(0);
    b.se(chr); b.u(1,1); b.u(0,1); b.u(0,1); b.stop(); return b;
}
static Bits header(bool idr, bool is_i, int poc, int deblock, int qp_delta=0,
                   bool override_ref=false, bool marking=false, bool listmod=false) {
    Bits b; b.ue(0); b.ue(is_i?2:0); b.ue(0); b.u(0,4);
    if(idr) b.ue(0);
    if(poc==0) b.u(3,4);
    if(!is_i) { b.u(override_ref,1); if(override_ref) b.ue(0); b.u(listmod,1); }
    if(idr) b.u(0,1);
    b.u(marking,1); b.se(qp_delta); b.ue(deblock);
    if(deblock!=1) { b.se(3); b.se(-6); }
    return b;
}
static void header_tests(Dut& d, const std::string& fixture) {
    capture(d,0,sps_geometry(320,224,0,0,0,12).bytes());
    check(d.sps_valid&&d.coded_width==320&&d.coded_height==224&&
          d.width==320&&d.height==212&&d.mb_width==20&&d.mb_height==14&&
          d.crop_left==0&&d.crop_right==0&&d.crop_top==0&&d.crop_bottom==12,
          "coded280 MB versus visible212 geometry");
    check(!d.sar_known&&d.sar_width==0&&d.sar_height==0,"absent SAR is unknown, not square");
    capture(d,0,sps_geometry(304,224,2,2,2,10,255,848,675).bytes());
    check(d.sps_valid&&d.coded_width==304&&d.coded_height==224&&
          d.width==300&&d.height==212&&d.mb_width==19&&d.mb_height==14&&
          d.crop_left==2&&d.crop_top==2&&d.crop_right==2&&d.crop_bottom==10,
          "narrow coded/cropped geometry");
    check(d.sar_known&&d.sar_width==848&&d.sar_height==675&&
          unsigned(d.width)*d.sar_width*9==unsigned(d.height)*d.sar_height*16,
          "extended anamorphic SAR gives16:9");
    const int sar_w[]={0,1,12,10,16,40,24,20,32,80,18,15,64,160,4,3,2};
    const int sar_h[]={0,1,11,11,11,33,11,11,11,33,11,11,33,99,3,2,1};
    for(int idc=0;idc<=16;++idc) {
        capture(d,0,sps_geometry(320,192,0,0,0,0,idc).bytes());
        check(d.sps_valid&&d.width==320&&d.height==192&&d.mb_height==12&&
              d.sar_known==(idc!=0)&&d.sar_width==sar_w[idc]&&d.sar_height==sar_h[idc],
              "standard SAR table and short coded frame");
    }
    capture(d,0,sps_geometry(320,192).bytes());
    check(d.sps_valid&&!d.sar_known&&d.sar_width==0&&d.sar_height==0&&
          d.crop_left==0&&d.crop_top==0&&d.crop_right==0&&d.crop_bottom==0,
          "new SPS clears previous crop and SAR");
    for(auto ratio : {std::pair<int,int>{0,1},{1,0},{0,0}}) {
        capture(d,0,sps_geometry(320,192,0,0,0,0,255,ratio.first,ratio.second).bytes());
        check(d.sps_valid&&!d.sar_known&&d.sar_width==0&&d.sar_height==0,
              "zero extended SAR remains unknown");
    }
    for(int idc : {17,254}) {
        capture(d,0,sps_geometry(320,224,0,0,0,0,idc).bytes());
        check(d.sps_error&&!d.sps_valid,"reserved SAR rejected");
    }
    capture(d,0,sps_geometry(320,224,160,0,160,0).bytes());
    check(d.sps_error&&!d.sps_valid,"empty cropped picture rejected");
    const auto extended=sps_geometry(304,224,2,2,2,10,255,848,675).bytes();
    for(size_t cut=0;cut<extended.size();++cut) {
        capture(d,0,{extended.begin(),extended.begin()+cut});
        check(d.sps_error&&!d.sps_valid,"truncated crop/extended SAR rejected");
    }
    for(bool full : {false,true}) for(int matrix : {-1,1,2,5,6}) {
        capture(d,0,sps_colour(full,matrix).bytes());
        check(d.sps_valid&&!d.sps_error,"supported VUI colour matrix");
        check(d.video_full_range_flag==full&&d.matrix_coefficients==(matrix<0?2:matrix),
              "VUI range/matrix export");
    }
    capture(d,0,sps().bytes());
    check(d.sps_valid&&!d.video_full_range_flag&&d.matrix_coefficients==2,
          "absent VUI resets range and unspecified matrix");
    for(int matrix : {0,3,4,7,9,255}) {
        capture(d,0,sps_colour(false,matrix).bytes());
        check(d.sps_error&&!d.sps_valid,"unsupported VUI matrix rejected");
    }
    capture(d,0,sps_colour(false,6,0,0).bytes());
    check(d.sps_valid&&!d.sps_error,"explicit default chroma phase");
    for(auto loc : {std::pair<int,int>{1,0},{0,1},{5,5}}) {
        capture(d,0,sps_colour(false,6,loc.first,loc.second).bytes());
        check(d.sps_error&&!d.sps_valid,"unsupported chroma phase rejected");
    }
    const auto vui=sps_colour(true,1,0,0).bytes();
    for(size_t cut=0;cut<vui.size();++cut) {
        capture(d,0,{vui.begin(),vui.begin()+cut});
        check(d.sps_error&&!d.sps_valid,"truncated VUI rejected");
    }
    for (int poc : {0,2}) {
        capture(d,0,sps(poc).bytes()); check(d.sps_valid&&!d.sps_error,"SPS syntax");
        check(d.width==320&&d.height==240,"SPS dimensions");
        capture(d,1,pps().bytes()); check(d.pps_valid&&!d.pps_error,"PPS syntax");
        check(static_cast<int8_t>(d.chroma_offset)==-12,"PPS chroma offset");
        for(bool intra : {false,true}) for(int db : {0,1,2}) {
            d.idr=intra; d.nal_ref=3;
            const auto b=header(intra,intra,poc,db,-2,!intra);
            capture(d,2,b.bytes());
            check(d.hdr_valid&&!d.hdr_error,"I/P header syntax");
            check(d.hdr_pos==b.v.size(),"header bit cursor");
            check(d.qp==24&&d.deblock==db,"QP and signaled deblock");
            if(db!=1) check(d.alpha==3&&static_cast<int8_t>(d.beta)==-6,"deblock offsets");
        }
    }
    d.idr=false; d.nal_ref=3;
    const auto non_idr_i=header(false,true,2,1);
    capture(d,2,non_idr_i.bytes());
    check(d.hdr_valid&&d.hdr_pos==non_idr_i.v.size(),"non-IDR I marking syntax");
    Bits nonref;
    nonref.ue(0);nonref.ue(0);nonref.ue(0);nonref.u(1,4);
    nonref.u(0,1);nonref.u(0,1);nonref.se(0);nonref.ue(1);
    d.nal_ref=0;capture(d,2,nonref.bytes());
    check(d.hdr_valid&&d.hdr_pos==nonref.v.size(),"non-reference P omits marking");
    d.nal_ref=3;
    for(auto b : {header(false,false,2,1,40), header(false,false,2,3),
                  header(false,false,2,1,0,false,true),
                  header(false,false,2,1,0,false,false,true)}) {
        capture(d,2,b.bytes()); check(d.hdr_error&&!d.hdr_valid,"unsupported header rejected");
    }
    Bits overflow;overflow.ue(65536);
    capture(d,2,overflow.bytes());check(d.hdr_error&&!d.hdr_valid,"header UE overflow");
    const auto full_header=header(false,false,2,0,-2,true).bytes();
    for(size_t cut=0;cut<full_header.size();++cut) {
        capture(d,2,{full_header.begin(),full_header.begin()+cut});
        check(d.hdr_error&&!d.hdr_valid,"truncated header rejected");
    }
    for(auto b : {sps(1),sps(3),sps(2,77),sps(2,66,false)}) {
        capture(d,0,b.bytes()); check(d.sps_error&&!d.sps_valid,"unsupported SPS rejected");
    }
    const auto good_sps=sps().bytes();
    auto oversize_sps=good_sps;oversize_sps.resize(49);
    capture(d,0,oversize_sps);check(d.sps_error&&!d.sps_valid,"SPS capacity overflow");
    for(size_t cut=0;cut<good_sps.size();++cut) {
        capture(d,0,{good_sps.begin(),good_sps.begin()+cut});
        check(d.sps_error&&!d.sps_valid,"truncated SPS rejected");
    }
    for(auto b : {pps(true),pps(false,true),pps(false,false,13)}) {
        capture(d,1,b.bytes()); check(d.pps_error&&!d.pps_valid,"unsupported PPS rejected");
    }
    const auto good_pps=pps().bytes();
    auto oversize_pps=good_pps;oversize_pps.resize(25);
    capture(d,1,oversize_pps);check(d.pps_error&&!d.pps_valid,"PPS capacity overflow");
    for(size_t cut=0;cut<good_pps.size();++cut) {
        capture(d,1,{good_pps.begin(),good_pps.begin()+cut});
        check(d.pps_error&&!d.pps_valid,"truncated PPS rejected");
    }
    std::ifstream f(fixture,std::ios::binary);
    std::vector<uint8_t> bytes{std::istreambuf_iterator<char>(f),{}};
    check(!bytes.empty(),"real320 fixture");
    const auto parsed=misterplex::parseAnnexBChain(bytes.data(),bytes.size());
    check(parsed.sps.valid&&parsed.pps.valid&&parsed.slice.valid&&parsed.poc_type==2,
          "real fixture independent Baseline chain");
    bool got_header=false;
    for(size_t i=0;i+4<bytes.size();) {
        size_t sc=0;
        if(bytes[i]==0&&bytes[i+1]==0&&bytes[i+2]==1) sc=3;
        else if(bytes[i]==0&&bytes[i+1]==0&&bytes[i+2]==0&&bytes[i+3]==1) sc=4;
        if(!sc) {++i;continue;}
        size_t j=i+sc+1;
        while(j+3<bytes.size() && !(bytes[j]==0&&bytes[j+1]==0&&
             (bytes[j+2]==1||(bytes[j+2]==0&&bytes[j+3]==1)))) ++j;
        if(j+3>=bytes.size()) j=bytes.size();
        const auto rbsp=misterplex::detail::removeEpb(bytes.data()+i+sc+1,j-i-sc-1);
        int type=bytes[i+sc]&31;
        if(type==7) {capture(d,0,rbsp);check(d.sps_valid,"real320 SPS");}
        if(type==8) {capture(d,1,rbsp);check(d.pps_valid,"real320 PPS");}
        if(type==5) {
            d.idr=1;d.nal_ref=bytes[i+sc]>>5;
            capture(d,2,rbsp);check(d.hdr_valid&&!d.hdr_error,"real320 header");
            misterplex::detail::BitReader br(rbsp.data(),rbsp.size());
            br.ue();br.ue();br.ue();br.u(parsed.log2_max_frame_num);br.ue();br.u(2);br.se();
            const auto db=br.ue();if(db!=1) {br.se();br.se();}
            check(d.hdr_pos==br.bit,"real320 independent header offset");
            check(d.qp==parsed.slice.slice_qp,"real fixture independent slice QP");
            const auto mt=br.ue();check(mt==0,"real320 IntraNxN MB0");
            std::cout<<"REAL320 header_bits="<<d.hdr_pos<<" MB0_type="<<mt
                     <<" filter_idc="<<int(d.deblock)<<" QP="<<int(d.qp)<<"\n";
            if (fixture.find("plex_real_baseline_320x240_1f.264")!=std::string::npos) {
                for(int k=0;k<3000&&!d.legacy_place_seen;++k) tick(d);
                check(d.legacy_place_seen&&d.legacy_csum==0x14&&
                      int8_t(d.legacy_dc)==-24&&d.legacy_qp==d.qp,
                      "legacy diagnostic residual handoff");
                std::cout<<"LEGACY_DIAGNOSTIC csum=0x14 dc=-24 QP="<<int(d.legacy_qp)<<"\n";
            }
            got_header=true;
        }
        i=j;
    }
    check(got_header,"real320 header exercised");
}
static void memory(Dut& d, int at, const std::vector<uint8_t>& data) {
    static int written=0;
    if(at==0||at<written||(d.capacity==8192&&d.physical_ram_done)) {
        d.wr_clear=1;tick(d);d.wr_clear=0;written=0;
    }
    d.wr_en=1;
    while(written<at) {d.wr_addr=written++;d.wr_data=0;tick(d);}
    for(auto b:data) {d.wr_addr=written++;d.wr_data=b;tick(d);}
    d.wr_en=0;
}
static void load(Dut& d,int pos,int len,bool final) {
    d.br_start_pos=pos;d.br_len=len;d.br_final=final;
    d.br_load=1;d.wr_end=final;tick(d);d.br_load=0;d.wr_end=0;
}
static void read_done(Dut& d) {
    for(int k=0;k<200;++k) {tick(d);if(d.br_done) return;}
    throw std::runtime_error("bit reader timeout");
}
static void reader_tests(Dut& d) {
    Bits b;b.ue(300);memory(d,0,{b.bytes()[0]});
    load(d,0,1,false);d.br_ue=1;tick(d);d.br_ue=0;
    for(int i=0;i<40;++i) tick(d);
    check(d.br_busy&&!d.br_error&&d.br_pos==8,"fragment wait preserves UE state");
    const auto fragmented=b.bytes();
    memory(d,1,{fragmented.begin()+1,fragmented.end()});
    d.br_len=b.bytes().size();d.br_final=1;read_done(d);
    check(d.br_ok&&d.br_value==300&&d.br_pos==b.v.size(),"skip run 300");
    for(int value : {0,1,255,300,65535,65536,70000}) {
        Bits v;v.ue(value);memory(d,0,v.bytes());load(d,0,v.bytes().size(),true);
        d.br_ue=1;tick(d);d.br_ue=0;read_done(d);
        check(value<=65535 ? (d.br_ok&&d.br_value==value) : d.br_error,"UE overflow bounds");
    }
    Bits truncated;truncated.ue(300);memory(d,0,truncated.bytes());load(d,0,1,true);
    d.br_ue=1;tick(d);d.br_ue=0;read_done(d);check(d.br_error&&!d.br_ok,"final EOF fatal");
    for(int i=0;i<10;++i) tick(d);
    check(d.br_error&&!d.br_busy,"fatal sticky");
    for(int value : {-32767,-12,0,12,32767,32768}) {
        Bits v;v.se(value);memory(d,0,v.bytes());load(d,0,v.bytes().size(),true);
        d.br_se=1;tick(d);d.br_se=0;read_done(d);
        check(value<32768 ? (d.br_ok&&int16_t(d.br_signed)==value) : d.br_error,"SE signed overflow");
    }
    memory(d,d.capacity-1,{0xa5});load(d,d.capacity*8-8,d.capacity,true);
    d.br_n=8;d.br_u=1;tick(d);d.br_u=0;read_done(d);
    check(d.br_ok&&d.br_value==0xa5&&d.br_pos==d.capacity*8&&d.br_eof,"one-past-capacity cursor");
    if(d.capacity==8192) {
        check(d.physical_ram_len==8192&&d.physical_ram_done&&!d.physical_ram_overflow,
              "actual RAM exact capacity/end");
        d.wr_en=1;d.wr_data=0;tick(d);d.wr_en=0;
        check(d.physical_ram_len==8192&&!d.physical_ram_overflow,"actual RAM frozen after end");
    }
    d.br_get=1;tick(d);d.br_get=0;check(d.br_error,"bit EOF fatal");
    load(d,0,1,true);d.br_n=17;d.br_u=1;tick(d);d.br_u=0;
    check(d.br_error,"fixed read width overflow");
    memory(d,0,{0xa5,0x69});load(d,0,2,true);
    int result=0;
    for(int n=0;n<16;++n) {
        d.br_get=0;for(int k=0;k<n%4+2;++k) tick(d);
        const auto saved=d.br_pos;tick(d);check(d.br_pos==saved,"consumer stall cursor stable");
        for(int k=0;k<5&&!d.br_ready;++k) tick(d);
        check(d.br_ready,"bit ready");
        d.br_get=1;tick(d);d.br_get=0;check(d.br_bit_valid,"bit handshake");
        result=(result<<1)|d.br_bit;
    }
    check(result==0xa569,"stalled bit stream");
    load(d,0,d.capacity+1,true);tick(d);
    check(d.br_error,"RAM byte-count capacity overflow");
    if(d.capacity==8192) {
        memory(d,0,std::vector<uint8_t>(8193,0));
        check(d.physical_ram_len==8192&&d.physical_ram_overflow&&!d.physical_ram_done,
              "actual RAM rejects oversized capture");
        std::cout<<"ACTUAL_RBSP_RAM PASS depth8192 synchronous_read_latency1 freeze/overflow\n";
    }
}
static void sequence_tests(Dut& d) {
    for(int i16=0;i16<2;++i16) for(int l=0;l<16;++l) for(int c=0;c<3;++c) {
        std::vector<int> expected;
        if(i16) expected.push_back(16);
        for(int i=0;i<16;++i) if(l&(1<<(i/4))) expected.push_back(i);
        if(c) {expected.push_back(17);expected.push_back(18);}
        if(c==2) for(int i=19;i<=26;++i) expected.push_back(i);
        d.seq_i16=i16;d.cbp_l=l;d.cbp_c=c;d.seq_start=1;tick(d);d.seq_start=0;
        for(auto id:expected) {
            for(int k=0;k<10&&!d.seq_valid;++k) tick(d);
            check(d.seq_valid&&!d.seq_done&&d.seq_id==id,"residual block order");
            int maxc=id==17||id==18?4:(id>=19||(i16&&id<16)?15:16);
            check(d.seq_max==maxc,"AC max15 / DC max4");
            if(id<16) check(d.seq_x==((id>>1)&2)+(id&1)&&d.seq_y==((id>>2)&2)+((id>>1)&1),"luma scan XY");
            check(d.seq_table==(maxc==4?4:7),"nC table source");
            for(int k=0;k<3;++k) {tick(d);check(d.seq_valid&&d.seq_id==id,"residual backpressure stable");}
            d.seq_advance=1;tick(d);d.seq_advance=0;
        }
        for(int k=0;k<10&&!d.seq_done;++k) tick(d);
        check(d.seq_done&&!d.seq_valid,"residual done");
    }
}
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try {
        check(argc==2,"fixture argument");
        Dut d;d.reset=1;tick(d);d.reset=0;
        header_tests(d,argv[1]);reader_tests(d);sequence_tests(d);
        std::cout<<"H264 SYNTAX LANE PASS capacity="<<d.capacity
                 <<" fragment/stall/EOF/overflow, 96 block sequences, coded/crop/SAR, VUI range/matrix/phase, real320/header negatives\n";
    } catch(const std::exception& e) {std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}
}
