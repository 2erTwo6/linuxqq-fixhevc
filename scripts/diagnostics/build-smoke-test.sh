#!/usr/bin/env bash
# 编译直接调用 libffmpeg.so 的 HEVC 冒烟测试。
#
# 用法：
#   ./scripts/diagnostics/build-smoke-test.sh
#   LD_LIBRARY_PATH=work/ffmpeg-8.1.3 work/ffmpeg-8.1.3/smoke /path/to/test.mp4
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FFMPEG_DIR="${FFMPEG_DIR:-$ROOT/work/ffmpeg-8.1.3}"
OUT="${OUT:-$FFMPEG_DIR/smoke}"

[ -f "$FFMPEG_DIR/libffmpeg.so" ] || {
  echo "缺少 $FFMPEG_DIR/libffmpeg.so，先执行 scripts/build-ffmpeg.sh"
  exit 1
}

if command -v cc >/dev/null 2>&1; then
  cc -O2 -I"$FFMPEG_DIR" -o "$OUT" "$HERE/smoke-test.c" \
    -L"$FFMPEG_DIR" -Wl,-rpath,'$ORIGIN' -lffmpeg
else
  ZIG_DIR="$(ls -d "$ROOT"/work/zig-*/ 2>/dev/null | head -1 || true)"
  ZIG="${ZIG_DIR}zig"
  [ -x "$ZIG" ] || { echo "缺少 C 编译器；先执行 scripts/setup-toolchain.sh"; exit 1; }
  export ZIG_GLOBAL_CACHE_DIR="$ROOT/work/.zig-cache-global"
  export ZIG_LOCAL_CACHE_DIR="$ROOT/work/.zig-cache-local"
  "$ZIG" cc -target x86_64-linux-gnu.2.17 -O2 -I"$FFMPEG_DIR" \
    -o "$OUT" "$HERE/smoke-test.c" -L"$FFMPEG_DIR" \
    -Wl,-rpath,'$ORIGIN' -lffmpeg
fi

echo "已生成: $OUT"
echo "运行: $OUT /path/to/test.mp4"
