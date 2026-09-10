#include "Vh264_iq_idct_4x4.h"
#include "verilated.h"

#include <array>
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct BlockGolden {
    int block = -1;
    int total_coeff = 0;
    std::array<int, 16> pred{};
    std::array<int, 16> dequant{};
    std::array<int, 16> idct{};
    std::array<int, 16> recon{};
};

std::string readText(const char* path) {
    std::ifstream in(path);
    if (!in) {
        throw std::runtime_error(std::string("cannot open fixture: ") + path);
    }
    return std::string(std::istreambuf_iterator<char>(in), {});
}

int parseIntAfter(const std::string& text, const std::string& key, std::size_t start = 0) {
    const std::string needle = "\"" + key + "\"";
    std::size_t p = text.find(needle, start);
    if (p == std::string::npos) {
        throw std::runtime_error("missing integer key: " + key);
    }
    p = text.find(':', p);
    if (p == std::string::npos) {
        throw std::runtime_error("malformed integer key: " + key);
    }
    ++p;
    while (p < text.size() && std::isspace(static_cast<unsigned char>(text[p]))) {
        ++p;
    }
    const char* begin = text.c_str() + p;
    char* end = nullptr;
    long value = std::strtol(begin, &end, 10);
    if (end == begin) {
        throw std::runtime_error("invalid integer value for key: " + key);
    }
    return static_cast<int>(value);
}

std::array<int, 16> parseArray16(const std::string& text, const std::string& key) {
    const std::string needle = "\"" + key + "\"";
    std::size_t p = text.find(needle);
    if (p == std::string::npos) {
        throw std::runtime_error("missing array key: " + key);
    }
    p = text.find('[', p);
    std::size_t q = text.find(']', p);
    if (p == std::string::npos || q == std::string::npos) {
        throw std::runtime_error("malformed array key: " + key);
    }
    std::array<int, 16> out{};
    int n = 0;
    const char* cur = text.c_str() + p + 1;
    const char* end = text.c_str() + q;
    while (cur < end) {
        while (cur < end && (std::isspace(static_cast<unsigned char>(*cur)) || *cur == ',')) {
            ++cur;
        }
        if (cur >= end) {
            break;
        }
        char* next = nullptr;
        long value = std::strtol(cur, &next, 10);
        if (next == cur) {
            throw std::runtime_error("invalid number in array: " + key);
        }
        if (n >= 16) {
            throw std::runtime_error("too many entries in array: " + key);
        }
        out[static_cast<std::size_t>(n++)] = static_cast<int>(value);
        cur = next;
    }
    if (n != 16) {
        std::ostringstream oss;
        oss << "array " << key << " has " << n << " entries, expected 16";
        throw std::runtime_error(oss.str());
    }
    return out;
}

std::vector<BlockGolden> parseBlocks(const std::string& json) {
    std::vector<BlockGolden> blocks;
    std::size_t p = json.find("\"blocks\"");
    if (p == std::string::npos) {
        throw std::runtime_error("fixture has no blocks array");
    }
    while (true) {
        p = json.find("\"block\"", p);
        if (p == std::string::npos) {
            break;
        }
        std::size_t next = json.find("\"block\"", p + 7);
        std::string chunk = json.substr(p, next == std::string::npos ? std::string::npos : next - p);
        BlockGolden b;
        b.block = parseIntAfter(chunk, "block");
        b.total_coeff = parseIntAfter(chunk, "total_coeff");
        b.pred = parseArray16(chunk, "pred");
        b.dequant = parseArray16(chunk, "dequant");
        b.idct = parseArray16(chunk, "idct");
        b.recon = parseArray16(chunk, "recon");
        blocks.push_back(b);
        if (next == std::string::npos) {
            break;
        }
        p = next;
    }
    return blocks;
}

int levelScale(int qp, int row, int col) {
    static constexpr int norm[6][3] = {
        {10, 13, 16}, {11, 14, 18}, {13, 16, 20},
        {14, 18, 23}, {16, 20, 25}, {18, 23, 29},
    };
    int mi = (((row & 1) + (col & 1)) == 0) ? 0 : ((((row & 1) + (col & 1)) == 1) ? 1 : 2);
    return norm[qp % 6][mi];
}

int dequantValue(int coeff, int qp, int pos) {
    int row = pos / 4;
    int col = pos % 4;
    int qmul = (levelScale(qp, row, col) * 16) << (qp / 6 + 2);
    return (coeff * qmul + 32) >> 6;
}

std::array<int, 16> deriveCoeffScan(const std::array<int, 16>& dequant, int qp) {
    static constexpr int zigzag[16] = {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};
    std::array<int, 16> coeff{};
    for (int scan = 0; scan < 16; ++scan) {
        int pos = zigzag[scan];
        int want = dequant[static_cast<std::size_t>(pos)];
        if (want == 0) {
            coeff[static_cast<std::size_t>(scan)] = 0;
            continue;
        }
        bool found = false;
        for (int candidate = -4096; candidate <= 4095; ++candidate) {
            if (dequantValue(candidate, qp, pos) == want) {
                coeff[static_cast<std::size_t>(scan)] = candidate;
                found = true;
                break;
            }
        }
        if (!found) {
            std::ostringstream oss;
            oss << "cannot derive coeff for scan=" << scan << " pos=" << pos << " dequant=" << want;
            throw std::runtime_error(oss.str());
        }
    }
    return coeff;
}

int signExtend(int value, int bits) {
    const int sign = 1 << (bits - 1);
    const int mask = (1 << bits) - 1;
    value &= mask;
    return (value ^ sign) - sign;
}

bool compareSignal(const char* name, int block, int index, int got, int want) {
    if (got == want) {
        return true;
    }
    std::cerr << "FAIL real RTL sim: block=" << block << " " << name << "[" << index
              << "] got " << got << " want " << want << '\n';
    return false;
}

    std::array<int64_t,16> inverse(const std::array<int64_t,16>& block) {
        std::array<int64_t,16> t{}, out{};
        for(int row=0;row<4;++row) {
            const int p=row*4;
            int64_t a=block[p]+block[p+2],b=block[p]-block[p+2];
            int64_t c=(block[p+1]>>1)-block[p+3],d=block[p+1]+(block[p+3]>>1);
            t[p]=a+d;t[p+1]=b+c;t[p+2]=b-c;t[p+3]=a-d;
        }
        for(int col=0;col<4;++col) {
            int64_t a=t[col]+t[col+8],b=t[col]-t[col+8];
            int64_t c=(t[col+4]>>1)-t[col+12],d=t[col+4]+(t[col+12]>>1);
            out[col]=(a+d+32)>>6;out[col+4]=(b+c+32)>>6;
            out[col+8]=(b-c+32)>>6;out[col+12]=(a-d+32)>>6;
        }
        return out;
    }

    std::array<int64_t,16> hadamard(const std::array<int64_t,16>& coeff,int qp) {
        static constexpr int zz[16]={0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15};
        static constexpr int scale[6]={10,11,13,14,16,18};
        std::array<int64_t,16> input{},t{},out{};
        for(int i=0;i<16;++i)input[(zz[i]>>2)|((zz[i]&3)<<2)]=coeff[i];
        for(int i=0;i<4;++i) {
            int p=i*4;
            int64_t a=input[p]+input[p+1],b=input[p]-input[p+1];
            int64_t c=input[p+2]-input[p+3],d=input[p+2]+input[p+3];
            t[p]=a+d;t[p+1]=a-d;t[p+2]=b-c;t[p+3]=b+c;
        }
        for(int i=0;i<4;++i) {
            int64_t a=t[i]+t[i+8],b=t[i]-t[i+8],c=t[i+4]-t[i+12],d=t[i+4]+t[i+12];
            out[i*4]=a+d;out[i*4+1]=b+c;out[i*4+2]=b-c;out[i*4+3]=a-d;
        }
        for(auto&v:out)v=(v*scale[qp%6]*(int64_t(1)<<(qp/6))+2)>>2;
        return out;
    }

    void fullRangeCases(Vh264_iq_idct_4x4& dut) {
        auto tick=[&] {dut.clk=0;dut.eval();dut.clk=1;dut.eval();};
        dut.reset=1;dut.start=0;tick();dut.reset=0;
        static constexpr int zigzag[16]={0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15};
        unsigned cases=0, max_cycles=0;
        uint32_t rng=0x12345678;
        for(int qp=0;qp<=51;++qp) for(int kind=0;kind<6;++kind) {
            std::array<int64_t,16> quantized{}, block{};
            std::array<uint8_t,16> pred{};
            int count=kind==2||kind==3?15:16;
            dut.qp=qp;dut.max_coeff=count;
            dut.use_dc=kind==2||kind==3;dut.dc_value=kind==2?100003:-170009;
            for(int i=0;i<16;++i) {
                rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;
                quantized[i]=kind==0 ? (i%2 ? -32768:32767) :
                             kind==1 ? (i==0 ? (qp%2 ? -1025:1025):0) :
                             kind==2 ? 0 :
                             kind==3 ? (i==14 ? -513:0) :
                             kind==4 ? int16_t(rng):int16_t(rng%1025)-512;
                dut.coeff[i]=int16_t(quantized[i]);pred[i]=uint8_t(rng>>16);dut.pred[i]=pred[i];
                if(i<count) {
                    int pos=zigzag[i+(count==15?1:0)];
                    block[pos]=quantized[i]*levelScale(qp,pos/4,pos%4)*(int64_t(1)<<(qp/6));
                }
            }
            dut.eval();
            auto residual=inverse(block);
            for(int i=0;i<16;++i) {
                if(int32_t(dut.dequant[i])!=block[i]||int32_t(dut.idct[i])!=residual[i]||
                   dut.recon[i]!=std::clamp<int64_t>(pred[i]+residual[i],0,255))
                    throw std::runtime_error("full signed transform mismatch qp="+std::to_string(qp)+
                                             " case="+std::to_string(kind)+" pixel="+std::to_string(i));
            }
            if(dut.use_dc)block[0]=int32_t(dut.dc_value);
            auto serial_residual=inverse(block);
            auto dc_expected=hadamard(quantized,qp);
            dut.start=1;tick();dut.start=0;
            // Inputs need not remain stable after accepted start.
            for(int i=0;i<16;++i){dut.coeff[i]=17;dut.pred[i]=3;}
            dut.qp=51;dut.dc_value=0;dut.use_dc=0;
            unsigned cycles=0;
            bool serial_finished=false,dc_finished=false;
            while((!serial_finished||!dc_finished) && cycles<100) {
                tick();++cycles;
                serial_finished|=dut.serial_done;
                dc_finished|=dut.dc_done;
            }
            if(!serial_finished||!dc_finished||!dut.serial_ok)
                throw std::runtime_error("serial transform did not complete");
            for(int i=0;i<16;++i)
                if(int32_t(dut.dc_out[i])!=dc_expected[i])
                    throw std::runtime_error("wide DC Hadamard mismatch qp="+std::to_string(qp)+
                                             " case="+std::to_string(kind)+" index="+std::to_string(i));
            for(int i=0;i<16;++i)
                if(dut.serial_recon[i]!=std::clamp<int64_t>(pred[i]+serial_residual[i],0,255))
                    throw std::runtime_error("serial signed transform mismatch qp="+std::to_string(qp)+
                                             " case="+std::to_string(kind)+" pixel="+std::to_string(i));
            max_cycles=std::max(max_cycles,cycles);++cases;tick();
        }
        std::cout<<"OK full-signed IQ/transform cases="<<cases<<" qp=0..51 max_cycles="<<max_cycles
                 <<" AC-only/DC-override/wide-Hadamard/latched-inputs verified\n";
    }

    void hadamardPipelineCases(Vh264_iq_idct_4x4& dut) {
        auto tick=[&] {dut.clk=0;dut.eval();dut.clk=1;dut.eval();};
        unsigned cases=0, max_cycles=0, canceled=0;
        uint32_t rng=0xb135face;
        auto accept=[&](const std::array<int64_t,16>& coeff,int qp) {
            dut.qp=qp;dut.max_coeff=16;dut.use_dc=0;
            for(int i=0;i<16;++i) {dut.coeff[i]=int16_t(coeff[i]);dut.pred[i]=128;}
            dut.start=1;tick();dut.start=0;
        };
        auto run=[&](const std::array<int64_t,16>& coeff,int qp) {
            auto expected=hadamard(coeff,qp);
            accept(coeff,qp);
            bool finished=false;
            unsigned cycles=0;
            while(!finished && cycles<100) {
                // Busy starts and changing every input cannot replace this block.
                dut.start=cycles==5||cycles==18;
                dut.qp=(qp+cycles+17)&63;
                for(int i=0;i<16;++i)dut.coeff[i]=uint16_t(i*8191+cycles*977);
                tick();++cycles;finished=dut.dc_done;
            }
            dut.start=0;
            if(!finished)throw std::runtime_error("Hadamard exceeded original 100-cycle budget");
            for(int i=0;i<16;++i)
                if(dut.dc_out[i]!=uint32_t(expected[i]))
                    throw std::runtime_error("Hadamard full-port/basis mismatch qp="+
                        std::to_string(qp)+" index="+std::to_string(i));
            max_cycles=std::max(max_cycles,cycles);
            ++cases;
            for(unsigned i=0;i<32;++i) {
                tick();
                if(dut.dc_done)throw std::runtime_error("Hadamard duplicated retirement");
            }
        };
        dut.reset=1;dut.start=0;tick();dut.reset=0;
        for(int qp=0;qp<64;++qp) {
            for(int pos=0;pos<16;++pos)for(int extreme:{-32768,32767}) {
                std::array<int64_t,16> coeff{};
                coeff[pos]=extreme;run(coeff,qp);
            }
            for(int kind=0;kind<5;++kind) {
                std::array<int64_t,16> coeff{};
                for(int i=0;i<16;++i) {
                    rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;
                    coeff[i]=kind==0?-32768:kind==1?32767:
                        kind==2?(i&1?-32768:32767):kind==3?int16_t(rng):0;
                }
                run(coeff,qp);
            }
        }
        // Every occupied cycle, including the done/consumer-retirement race.
        for(unsigned age=0;age<=max_cycles;++age) {
            std::array<int64_t,16> coeff{};
            coeff[age%16]=-32768;
            accept(coeff,63);
            for(unsigned n=0;n<age;++n)tick();
            dut.reset=1;tick();dut.reset=0;
            std::array<uint32_t,16> held{};
            for(int i=0;i<16;++i)held[i]=dut.dc_out[i];
            for(unsigned n=0;n<100;++n) {
                tick();
                if(dut.dc_done)throw std::runtime_error("canceled Hadamard completed");
                for(int i=0;i<16;++i)
                    if(dut.dc_out[i]!=held[i])
                        throw std::runtime_error("canceled Hadamard wrote a trailing coefficient");
            }
            coeff[15]=32767;run(coeff,51);++canceled;
        }
        std::cout<<"OK Hadamard pipeline cases="<<cases<<" qp=0..63 max_cycles="<<max_cycles
                 <<" reset_replays="<<canceled
                 <<" full_signed16_basis/full_signed32_DC/busy_start/input_churn/no_stale_retirement\n";
    }
} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc != 2) {
        std::cerr << "usage: " << argv[0] << " tests/fixtures/p3_host_recon/mb0_luma_v1.json\n";
        return 2;
    }

    try {
        const std::string json = readText(argv[1]);
        const int qp = parseIntAfter(json, "qp");
        const auto blocks = parseBlocks(json);
        if (blocks.size() != 16) {
            std::cerr << "FAIL real RTL sim: parsed " << blocks.size() << " blocks, expected 16\n";
            return 1;
        }

        Vh264_iq_idct_4x4 dut;
        for (unsigned q=0; q<64; ++q) {
            dut.qp=q; dut.eval();
            if (dut.qp_div6 != q/6 || dut.qp_mod6 != q%6)
                throw std::runtime_error("six-bit QP quotient/remainder mismatch");
        }
        std::cout << "PASS exact QP quotient/remainder all64 input values\n";
        int compared = 0;
        for (const auto& block : blocks) {
            const auto coeff = deriveCoeffScan(block.dequant, qp);
            dut.max_coeff = 16;
            dut.qp = static_cast<uint8_t>(qp);
            for (int i = 0; i < 16; ++i) {
                dut.coeff[i] = static_cast<int16_t>(coeff[static_cast<std::size_t>(i)]);
                dut.pred[i] = static_cast<uint8_t>(block.pred[static_cast<std::size_t>(i)]);
            }
            dut.eval();

            for (int i = 0; i < 16; ++i) {
                const int gotDequant = int32_t(dut.dequant[i]);
                const int gotIdct = int32_t(dut.idct[i]);
                const int gotRecon = static_cast<uint8_t>(dut.recon[i]);
                if (!compareSignal("dequant", block.block, i, gotDequant, block.dequant[static_cast<std::size_t>(i)]) ||
                    !compareSignal("idct", block.block, i, gotIdct, block.idct[static_cast<std::size_t>(i)]) ||
                    !compareSignal("recon", block.block, i, gotRecon, block.recon[static_cast<std::size_t>(i)])) {
                    return 1;
                }
                compared += 3;
            }
        }
        std::cout << "OK real RTL sim: h264_iq_idct_4x4 elaborated with Verilator; blocks="
                  << blocks.size() << " compared_values=" << compared << " qp=" << qp
                  << " fixture=" << argv[1] << '\n';
        fullRangeCases(dut);
        hadamardPipelineCases(dut);
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL real RTL sim: " << e.what() << '\n';
        return 1;
    }
}
