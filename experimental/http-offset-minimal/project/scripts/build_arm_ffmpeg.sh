#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
source="${FFMPEG_SOURCE:-build/deps/ffmpeg-8.1.2}"
build="$(realpath -m --relative-to="$root" "${FFMPEG_BUILD_DIR:-build/deps/ffmpeg-8.1.2-static-safe-build}")"
prefix="$(realpath -m --relative-to="$root" "${ARM_FFMPEG_PREFIX:-build/deps/ffmpeg-arm-static-safe}")"
for output in "$build" "$prefix"; do
    case "$output" in
        .|..|../*|/*) echo "FFmpeg outputs must stay inside this project" >&2; exit 1;;
    esac
    [[ ! -e "$output" && ! -L "$output" ]] || {
        echo "Refusing to overwrite an existing FFmpeg build/install: $output" >&2; exit 1;
    }
done
[[ -f "$source/configure" && -f "$source/RELEASE" &&
   "$(cat "$source/RELEASE")" == 8.1.2 ]] || {
    echo "FFMPEG_SOURCE must name an existing FFmpeg 8.1.2 source tree" >&2; exit 1;
}
source="$(realpath "$source")"
for output in "$build" "$prefix"; do
    case "$root/$output" in
        "$source"|"$source"/*)
            echo "FFmpeg outputs must not modify the source tree" >&2; exit 1;;
    esac
done
cross="${ARM_FFMPEG_CROSS:-}"
if [[ -z "$cross" ]]; then
    for compiler in arm-none-linux-gnueabihf-gcc arm-linux-gnueabihf-gcc \
        "${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}/arm-none-linux-gnueabihf-gcc"; do
        if compiler_path="$(command -v "$compiler")"; then
            cross="${compiler_path%gcc}"
            break
        fi
    done
fi
[[ -n "$cross" ]] && command -v "${cross}gcc" >/dev/null &&
    command -v "${cross}nm" >/dev/null || {
    echo "An existing ARM hard-float cross toolchain is required" >&2; exit 1;
}
jobs="${FFMPEG_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "FFMPEG_JOBS must be positive" >&2; exit 1; }
mkdir -p "$(dirname "$build")" "$(dirname "$prefix")"
mkdir "$build" "$build/obj" "$build/runtime"
export TMPDIR="$root/$build/runtime"
cp -a "$source" "$build/source"
if [[ -f "$build/source/ffbuild/config.mak" ]]; then
    make -s -C "$build/source" distclean
fi
cd "$build/obj"
../source/configure \
    --prefix="$root/$prefix" --arch=arm --cpu=cortex-a9 --target-os=linux \
    --enable-cross-compile --cross-prefix="$cross" \
    --enable-static --disable-shared --disable-programs --disable-doc --disable-debug \
    --disable-autodetect --disable-avdevice --disable-avfilter --disable-swscale \
    --disable-everything --disable-iconv \
    --enable-avcodec --enable-avformat --enable-avutil --enable-swresample --enable-network \
    --enable-protocol=file,http,tcp,pipe \
    --enable-demuxer=mov,mpegts,h264,matroska,mpegps,flv \
    --enable-parser=h264,aac,aac_latm,ac3,mpegaudio,flac,opus,vorbis \
    --enable-decoder=h264,aac,aac_latm,ac3,eac3,mp3,mp3float,flac,alac,opus,vorbis,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le \
    --enable-bsf=h264_mp4toannexb,extract_extradata
make -s -j"$jobs"
make -s install
python3 "$root/scripts/check_arm_ffmpeg_static.py" --prefix "$root/$prefix" --nm "${cross}nm"
