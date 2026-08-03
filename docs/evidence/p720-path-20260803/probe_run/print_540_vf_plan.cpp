#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/yuv420p_chroma_health.hpp"
#include <cstdio>
int main() {
  using namespace misterplex;
  FfmpegVfRequest r;
  r.coded_w = 960; r.coded_h = 540; r.display_w = 960; r.display_h = 540;
  r.source_w = 960; r.source_h = 540;
  r.delivery_geometry_verified = false;
  r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true);
  auto p = buildFfmpegVideoFilter(r);
  std::printf("unverified force: scale_applied=%d identity_skip=%d reason=%s vf=%s\n",
              p.scale_applied?1:0, p.identity_skip?1:0, p.reason.c_str(),
              p.vf.empty()?"(none)":p.vf.c_str());
  r.delivery_geometry_verified = true;
  p = buildFfmpegVideoFilter(r);
  std::printf("verified force:   scale_applied=%d identity_skip=%d reason=%s vf=%s\n",
              p.scale_applied?1:0, p.identity_skip?1:0, p.reason.c_str(),
              p.vf.empty()?"(none)":p.vf.c_str());
  // 360
  r.coded_w=640; r.coded_h=360; r.display_w=640; r.display_h=360;
  r.source_w=640; r.source_h=360; r.delivery_geometry_verified=false;
  p = buildFfmpegVideoFilter(r);
  std::printf("360 unverified:   scale_applied=%d identity_skip=%d reason=%s vf=%s\n",
              p.scale_applied?1:0, p.identity_skip?1:0, p.reason.c_str(),
              p.vf.empty()?"(none)":p.vf.c_str());
  return 0;
}
