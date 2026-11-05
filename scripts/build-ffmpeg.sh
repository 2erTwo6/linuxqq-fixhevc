#!/usr/bin/env bash
# 编译原生 HEVC 修复使用的 libffmpeg.so
#
# 产物：work/ffmpeg-<ver>/libffmpeg.so
#   * 内含 avcodec/avformat/avutil（静态），除 glibc 外无外部依赖
#   * 导出 qq 需要的全部 44 个符号，含 hevc 解码器
#
# 依赖：zig（提供 C 编译器）、GNU make、nasm —— 见 setup-toolchain.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$ROOT/work"

FFMPEG_VER="${FFMPEG_VER:-8.1.3}"
# 与包里其它二进制对齐：qq 主程序只要求 GLIBC_2.25，这里取 2.17 留足余量
GLIBC_VER="${GLIBC_VER:-2.17}"
JOBS="${JOBS:-$(nproc)}"

ZIG_DIR="$(ls -d "$WORK"/zig-*/ 2>/dev/null | head -1 || true)"
[ -n "$ZIG_DIR" ] && [ -x "${ZIG_DIR}zig" ] || { echo "缺少 zig，先执行 setup-toolchain.sh"; exit 1; }

export PATH="$WORK/ext/make/usr/bin:$WORK/ext/nasm/usr/bin:$PATH"
export ZIG_GLOBAL_CACHE_DIR="$WORK/.zig-cache-global"
export ZIG_LOCAL_CACHE_DIR="$WORK/.zig-cache-local"

CC_CMD="${ZIG_DIR}zig cc -target x86_64-linux-gnu.${GLIBC_VER}"

command -v make >/dev/null || { echo "缺少 make"; exit 1; }
command -v nasm >/dev/null || { echo "缺少 nasm"; exit 1; }

cd "$WORK"
if [ ! -d "ffmpeg-${FFMPEG_VER}" ]; then
  [ -f "ffmpeg-${FFMPEG_VER}.tar.xz" ] || \
    curl -fsSL -o "ffmpeg-${FFMPEG_VER}.tar.xz" "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"
  tar -xf "ffmpeg-${FFMPEG_VER}.tar.xz"
fi

cd "ffmpeg-${FFMPEG_VER}"

echo "==> [1/5] 打 av_stream_get_first_dts 补丁"
python3 "$HERE/patch-ffmpeg.py" "$WORK/ffmpeg-${FFMPEG_VER}"

echo "==> [2/5] configure"
./configure \
  --prefix="$WORK/prefix" \
  --cc="$CC_CMD" \
  --x86asmexe="$WORK/ext/nasm/usr/bin/nasm" \
  --enable-static --disable-shared \
  --enable-pic \
  --enable-runtime-cpudetect \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter --disable-swscale \
  --disable-network \
  --disable-autodetect \
  --disable-zlib --disable-bzlib --disable-lzma --disable-iconv \
  --disable-everything \
  --enable-avcodec --enable-avformat --enable-avutil --enable-swresample \
  --enable-decoder=h264,hevc,aac,mp3,flac,vorbis,opus \
  --enable-decoder=pcm_s16le,pcm_s16be,pcm_u8,pcm_mulaw,pcm_alaw \
  --enable-decoder=pcm_s32le,pcm_s24le,pcm_s24be,pcm_f32le \
  --enable-parser=h264,hevc,aac,mpegaudio,flac,vorbis,opus \
  --enable-demuxer=mov,matroska,mp3,flac,ogg,wav,aac,mpegts \
  --enable-protocol=file,pipe,data \
  --enable-bsf=hevc_mp4toannexb,h264_mp4toannexb,aac_adtstoasc \
  > "$WORK/configure.log" 2>&1 || { echo "configure 失败，见 work/configure.log"; tail -30 "$WORK/configure.log"; exit 1; }

# 关掉 sysctl 检测：该路径只对 BSD 有意义，且新版 glibc 已删除 sys/sysctl.h
sed -i 's/^#define HAVE_SYSCTL 1$/#define HAVE_SYSCTL 0/' config.h

echo "==> [3/5] make -j$JOBS"
make -j"$JOBS" > "$WORK/make.log" 2>&1 || { echo "编译失败，见 work/make.log"; tail -40 "$WORK/make.log"; exit 1; }

echo "==> [4/5] 链接成单个 libffmpeg.so"
# --whole-archive 保证所有目标文件进镜像（否则导出符号会被裁掉）
# -Bsymbolic 让库内跨目标文件的 PC32 重定位可解析（FFmpeg 的 x86 asm 需要）
$CC_CMD -shared -o libffmpeg.so \
  -Wl,--whole-archive \
    libavcodec/libavcodec.a libavformat/libavformat.a \
    libavutil/libavutil.a libswresample/libswresample.a \
  -Wl,--no-whole-archive \
  -Wl,-Bsymbolic \
  -Wl,-soname,libffmpeg.so \
  -lm -lpthread -ldl

echo "==> [5/5] strip"
strip --strip-unneeded libffmpeg.so

ls -lh libffmpeg.so
echo "==> 完成"
