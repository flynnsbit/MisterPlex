// COMPILE-FAIL probe: bare ints must not bind to setDecodeSize after conf seal.
// Built by tests/unit/test_geometry_type_safety.sh — must NOT successfully compile.
//
// Mirrors MediaPlayer::setDecodeSize API surface (CodedWidth/CodedHeight/CodedSize
// only). Including the full MediaPlayer pulls SPI/fb deps; the signature contract
// lives here so the proof stays host-local and matches media_player.hpp.

#include "libmisterplex/coded_size.hpp"

namespace misterplex {

// Keep this declaration in lockstep with MediaPlayer::setDecodeSize.
// If someone re-adds setDecodeSize(int,int) on MediaPlayer, add it here too —
// this mutant must then start failing the RED gate (rc=0) and force a fix.
struct DecodeSizeBoundary {
    void setDecodeSize(CodedWidth w, CodedHeight h);
    void setDecodeSize(CodedSize size) { setDecodeSize(size.width, size.height); }
};

} // namespace misterplex

int main() {
    misterplex::DecodeSizeBoundary sink;
    // Classic conf hole: sscanf ints fed straight into setDecodeSize.
    int decodeW = 624;
    int decodeH = 480;
    sink.setDecodeSize(decodeW, decodeH);
    return 0;
}
