#include "Vp2_chroma_pred_tb.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <random>
#include <stdexcept>

static int floor32(int v) {
    return v>=0 ? v/32 : -((-v+31)/32);
}

static int predict(const std::array<int,8>& above,const std::array<int,8>& left,
                   int tl,unsigned mode,bool ha,bool hl,unsigned x,unsigned y) {
    if(mode==1)return left[y];
    if(mode==2)return above[x];
    if(mode==0) {
        int sa[2]={},sl[2]={};
        for(unsigned i=0;i<8;++i) {sa[i/4]+=above[i];sl[i/4]+=left[i];}
        const unsigned bx=x/4,by=y/4;
        if(ha&&hl) {
            if(bx==by)return (sa[bx]+sl[by]+4)/8;
            return bx ? (sa[1]+2)/4 : (sl[1]+2)/4;
        }
        if(ha)return (sa[bx]+2)/4;
        if(hl)return (sl[by]+2)/4;
        return 128;
    }
    int h=0,v=0;
    for(int i=1;i<=4;++i) {
        h+=i*(above[3+i]-(i==4?tl:above[3-i]));
        v+=i*(left[3+i]-(i==4?tl:left[3-i]));
    }
    const int a=16*(above[7]+left[7]),b=floor32(17*h+16),c=floor32(17*v+16);
    return std::clamp(floor32(a+b*(int(x)-3)+c*(int(y)-3)+16),0,255);
}

int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try {
        Vp2_chroma_pred_tb d;
        std::mt19937 random(0x420320);
        unsigned blocks=0,low_clips=0,high_clips=0;
        for(unsigned sample=0;sample<4104;++sample) {
            std::array<int,8> above{},left{};
            for(unsigned i=0;i<8;++i) {
                above[i]=sample<8 ? ((sample&(1u<<(i%3)))?255:0) : random()%256;
                left[i]=sample<8 ? ((sample&(1u<<((i+1)%3)))?0:255) : random()%256;
                d.above[i]=above[i];d.left[i]=left[i];
            }
            d.top_left=sample<8 ? (sample&1?255:0) : random()%256;
            for(unsigned mode=0;mode<4;++mode)for(unsigned available=0;available<4;++available) {
                d.mode=mode;d.has_above=available&1;d.has_left=(available>>1)&1;
                d.block_x=0;d.block_y=0;d.eval();
                for(unsigned y=0;y<8;++y)for(unsigned x=0;x<8;++x) {
                    const int expected=predict(above,left,d.top_left,mode,d.has_above,d.has_left,x,y);
                    if(d.full_pred[y*8+x]!=expected)
                        throw std::runtime_error("full-plane chroma interface differs from scalar oracle");
                    if(mode==3) {low_clips+=expected==0;high_clips+=expected==255;}
                }
                for(unsigned block=0;block<4;++block) {
                    d.block_x=block&1;d.block_y=block>>1;d.eval();
                    for(unsigned y=0;y<4;++y)for(unsigned x=0;x<4;++x) {
                        const unsigned gx=d.block_x*4+x,gy=d.block_y*4+y;
                        const int expected=predict(above,left,d.top_left,mode,d.has_above,d.has_left,gx,gy);
                        if(d.block_pred[y*4+x]!=expected)
                            throw std::runtime_error("selected chroma block differs from scalar oracle");
                    }
                    ++blocks;
                }
            }
        }
        if(!low_clips||!high_clips)throw std::runtime_error("plane clipping was not exercised");
        std::cout<<"PASS "<<blocks<<" chroma blocks; all modes/availability/quadrants, clipping low="
                 <<low_clips<<" high="<<high_clips<<"\n";
        return 0;
    } catch(const std::exception& e) {
        std::cerr<<"FAIL "<<e.what()<<"\n";
        return 1;
    }
}
