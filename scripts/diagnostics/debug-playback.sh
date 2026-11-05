#!/usr/bin/env bash
# 用 LD_PRELOAD 探针记录 QQ 向 libffmpeg.so 发起的解码器请求。
#
# 期望结果：打开 HEVC 视频后，日志中出现
#   [find_decoder] id=173 -> FOUND
# id=173 是 AV_CODEC_ID_HEVC。若仍然没有，说明 QQ 在更早的位置拒绝了 HEVC。
#
# 用法：
#   ./scripts/diagnostics/debug-playback.sh [AppImage 路径]
# 启动后在 QQ 中打开 HEVC 视频，等待数秒并关闭 QQ；脚本会输出摘要。
# 日志仅保存在 work/debug/，不要提交或公开发布。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="${1:-$ROOT/dist/QQ-3.2.34-hevc-native-x86_64.AppImage}"
OUT="$ROOT/work/debug"
PROBE_SRC="$HERE/probe-avcodec.c"
PROBE="$OUT/libprobe.so"
mkdir -p "$OUT"

[ -f "$APP" ] || { echo "找不到 AppImage: $APP"; exit 1; }
[ -f "$PROBE_SRC" ] || { echo "找不到探针源码: $PROBE_SRC"; exit 1; }

# work/ 下的工具链由 setup-toolchain.sh 准备；宿主有 cc 时优先用宿主 cc。
if [ ! -f "$PROBE" ] || [ "$PROBE_SRC" -nt "$PROBE" ]; then
  if command -v cc >/dev/null 2>&1; then
    cc -shared -fPIC -O2 -o "$PROBE" "$PROBE_SRC" -ldl -lpthread || exit 1
  else
    ZIG_DIR="$(ls -d "$ROOT"/work/zig-*/ 2>/dev/null | head -1 || true)"
    ZIG="${ZIG_DIR}zig"
    [ -x "$ZIG" ] || { echo "缺少 C 编译器；先执行 scripts/setup-toolchain.sh"; exit 1; }
    "$ZIG" cc -target x86_64-linux-gnu.2.17 -shared -fPIC -O2 \
      -o "$PROBE" "$PROBE_SRC" -ldl -lpthread || exit 1
  fi
fi

LOG="$OUT/qq_probe.log"
RUN_LOG="$OUT/qq_run.log"

echo "==> 探针日志: $LOG"
echo "==> 运行日志: $RUN_LOG"
echo
echo "请在 QQ 里点开 HEVC 视频，等几秒，然后关闭 QQ。"
echo

rm -f "$LOG"

QQ_FFMPEG_PROBE_LOG="$LOG" \
LD_PRELOAD="$PROBE" \
"$APP" --no-sandbox \
  --enable-logging=stderr --v=0 \
  --vmodule=mime_util_internal=2,decoder_selector=2,ffmpeg_video_decoder=2,mp4_stream_parser=2 \
  2>&1 | tee "$RUN_LOG"

echo
echo "==================== 结果摘要 ===================="
echo "--- 是否向 ffmpeg 请求了 HEVC 解码器（id=173）---"
if grep -q 'find_decoder\] id=173' "$LOG" 2>/dev/null; then
  echo "  ✅ 有！HEVC 已经进入 FFmpeg 解码器"
else
  echo "  ❌ 没有。可能仍在更早的能力判断处被拒绝"
fi

echo "--- 所有解码器请求 ---"
grep -E 'find_decoder' "$LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -20

echo "--- 打开过的媒体文件 ---"
grep -E 'avformat_open_input' "$LOG" 2>/dev/null | tail -10

echo "--- Chromium 侧的媒体日志 ---"
grep -iE 'hevc|unsupported|codec|decoder' "$RUN_LOG" 2>/dev/null | grep -viE 'ibug|bugly' | head -20

echo "================================================="
