#!/usr/bin/env bash
# 重打包原生 HEVC 软解版 QQ AppImage
#
# 做法：复用原包的 AppImage runtime（前 N 字节），替换 libffmpeg.so，
# 对 AppDir/qq 应用原生 HEVC 门控补丁，然后重新生成 squashfs 并拼接。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$ROOT/work"
SRC_APPIMAGE="${SRC_APPIMAGE:-}"
NEW_LIBFFMPEG="${NEW_LIBFFMPEG:-$WORK/ffmpeg-8.1.3/libffmpeg.so}"
OUT="${OUT:-$ROOT/dist/QQ-3.2.34-hevc-native-x86_64.AppImage}"

MKSQUASHFS="$WORK/ext/squashfs/usr/bin/mksquashfs"
[ -x "$MKSQUASHFS" ] || { echo "缺少 mksquashfs，先执行 setup-toolchain.sh"; exit 1; }
[ -n "$SRC_APPIMAGE" ] || {
  echo "请通过 SRC_APPIMAGE 指定原始 QQ AppImage"
  exit 1
}
[ -f "$SRC_APPIMAGE" ] || { echo "找不到原始 AppImage: $SRC_APPIMAGE"; exit 1; }
[ -f "$NEW_LIBFFMPEG" ] || { echo "找不到新 libffmpeg.so，先执行 build-ffmpeg.sh"; exit 1; }

OFFSET="$("$SRC_APPIMAGE" --appimage-offset)"
echo "==> 原包 runtime 段: $OFFSET 字节"

APPDIR="$WORK/AppDir"
if [ ! -d "$APPDIR" ]; then
  echo "==> 解包原 AppImage 到 AppDir（首次较慢）"
  mkdir -p "$APPDIR"
  ( cd "$WORK" && "$SRC_APPIMAGE" --appimage-extract >/dev/null 2>&1 )
  cp -a "$WORK/squashfs-root/." "$APPDIR/"
fi

echo "==> 替换 libffmpeg.so"
cp -f "$NEW_LIBFFMPEG" "$APPDIR/libffmpeg.so"
chmod 755 "$APPDIR/libffmpeg.so"

echo "==> 对 qq 应用原生 HEVC 补丁"
python3 "$HERE/patch-qq-hevc-binary.py" "$APPDIR/qq"

# 统一权限：AppImage 内文件通常属 root，目录 755
echo "==> 规范化权限"
chmod -R a+rX "$APPDIR"
find "$APPDIR" -type d -exec chmod 755 {} +
find "$APPDIR" -type f -perm -u+x -exec chmod 755 {} +

echo "==> 生成 squashfs"
rm -f "$WORK/payload.squashfs"
"$MKSQUASHFS" "$APPDIR" "$WORK/payload.squashfs" \
  -comp gzip -b 131072 -no-fragments -all-root -no-xattrs \
  -processors "$(nproc)" -no-progress >/dev/null

echo "==> 拼接 runtime + squashfs"
mkdir -p "$(dirname "$OUT")"
head -c "$OFFSET" "$SRC_APPIMAGE" > "$OUT"
cat "$WORK/payload.squashfs" >> "$OUT"
chmod 755 "$OUT"

echo "==> 完成: $OUT"
ls -lh "$OUT"
echo "--- 自检 ---"
"$OUT" --appimage-offset && echo "runtime 偏移正常"
