#!/usr/bin/env bash
# 准备本地构建工具链：Zig（C 编译器）、GNU make、NASM 和 squashfs-tools。
#
# 下载与解包结果全部位于 work/，不修改宿主的系统工具链。
# curl 会自动读取 https_proxy、http_proxy 等标准代理环境变量。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$ROOT/work"

ZIG_VER="${ZIG_VER:-0.15.2}"
FEDORA_MIRROR="${FEDORA_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/fedora/releases/44/Everything/x86_64/os/Packages}"

mkdir -p "$WORK"/{rpms,ext,tool}
cd "$WORK"

echo "==> zig ${ZIG_VER}"
if [ ! -x "$(ls -d "$WORK"/zig-*/ 2>/dev/null | head -1)zig" ]; then
  [ -f zig.tar.xz ] || curl -fsSL --retry 5 --retry-all-errors \
    -o zig.tar.xz "https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz"
  tar -xf zig.tar.xz
fi
"$(ls -d "$WORK"/zig-*/ | head -1)zig" version

# Fedora 的 make / nasm / mksquashfs 都是普通 glibc 程序，抽出来即可直接跑
fetch_rpm() { # $1=子目录名 $2=包名前缀 $3=本地名
  local dir="$1" pkg="$2" out="$3" file
  file="$(curl -fsSL "$FEDORA_MIRROR/$dir/" | grep -oE "${pkg}-[0-9][^\"]*\.x86_64\.rpm" | sort -u | tail -1)"
  [ -n "$file" ] || { echo "镜像里找不到 $pkg"; return 1; }
  echo "    $file"
  curl -fsSL -o "rpms/$out.rpm" "$FEDORA_MIRROR/$dir/$file"
  mkdir -p "ext/$out"
  ( cd "ext/$out" && rpm2cpio "../../rpms/$out.rpm" | cpio -idm --quiet )
}

echo "==> make"
[ -x ext/make/usr/bin/make ] || fetch_rpm m make make
echo "==> nasm"
[ -x ext/nasm/usr/bin/nasm ] || fetch_rpm n nasm nasm
echo "==> squashfs-tools"
[ -x ext/squashfs/usr/bin/mksquashfs ] || fetch_rpm s squashfs-tools squashfs-tools

echo
echo "==> 工具链就绪"
export PATH="$WORK/ext/make/usr/bin:$WORK/ext/nasm/usr/bin:$PATH"
make --version | head -1
nasm -v
"$WORK/ext/squashfs/usr/bin/mksquashfs" -version 2>&1 | head -1
