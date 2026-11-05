#!/usr/bin/env python3
"""真正启用 Linux QQ 的 HEVC 软件解码。

QQ 3.2.34 的 Electron/Chromium 二进制虽然编译了 HEVC 容器和 hvcC 处理，
但媒体运行时只把 HEVC 当作“平台硬件解码器”支持：

  * media::IsDefaultDecoderSupportedVideoType(HEVC) 查询
    SupplementalDecoderVideoProfileCache；Linux 上没有平台 HEVC 解码器，
    缓存为空，于是 canPlayType() 返回空串。
  * FFmpegVideoDecoder::Initialize() 编译时只接受 H.264。
  * GetFFmpegVideoDecoderThreadCount() 对非 H.264 的 switch 分支会走
    NOTREACHED()，HEVC 进入解码器后会直接触发 ud2。
  * ApplyCodecContextSecuritySettings() 把视频 codec_whitelist 固定为
    "h264"，FFmpeg 的 avcodec_open2() 会拒绝 HEVC。

同时 QQ 自带的 libffmpeg.so 里没有 HEVC 解码器，因此还需要用
scripts/build-ffmpeg.sh 构建的 libffmpeg.so 替换它。

本脚本只改 qq 的 .text 代码，不碰 major.node，也不做运行时 hook：

  1) IsDefaultDecoderSupportedVideoType 的 HEVC case 直接返回 true。
  2) FFmpegVideoDecoder::Initialize 允许 HEVC(8) 进入 ConfigureDecoder。
  3) 跳过 FFmpegVideoDecoder 线程数 switch 中非 H.264 的 NOTREACHED 分支。
  4) 把 FFmpeg 视频解码器白名单从 "h264" 扩成 "h264,hevc"。

用法：
    ./scripts/patch-qq-hevc-binary.py work/AppDir/qq
    ./scripts/patch-qq-hevc-binary.py --dry-run work/AppDir/qq
"""
from __future__ import annotations

import argparse
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Patch:
    name: str
    va: int
    old: bytes
    new: bytes


PATCHES = (
    Patch(
        name="IsDefaultDecoderSupportedVideoType: HEVC 走“支持”分支",
        va=0x3AAC9BC,
        # xor eax,eax; cmp byte ptr [rbx+0xc],0; je ...
        old=bytes.fromhex("31 c0 80 7b 0c 00 74"),
        # mov al,1; jmp <公共返回 true 路径>
        new=bytes.fromhex("b0 01 e9 f2 ff ff ff"),
    ),
    Patch(
        name="FFmpegVideoDecoder::Initialize: 接受 H.264 和 HEVC",
        va=0x3F19878,
        # cmp dword ptr [r12],1; jne fail; mov edi,1; call ...
        old=bytes.fromhex(
            "41 83 3c 24 01 75 0e bf 01 00 00 00 e8 a7 32 b9 ff "
            "84 c0 75 70"
        ),
        # cmp codec,1; je success
        # cmp codec,8; je success
        # nop...
        new=bytes.fromhex(
            "41 83 3c 24 01 74 7e "
            "41 83 3c 24 08 74 77 "
            "90 90 90 90 90 90 90"
        ),
    ),
    Patch(
        name="FFmpegVideoDecoder 线程数选择: 跳过非 H.264 的 NOTREACHED",
        va=0x3F199E5,
        # jb <ud2>
        old=bytes.fromhex("0f 82 28 01 00 00"),
        # 让 HEVC 落到默认的 mov edi,2; jmp GetRecommendedThreadCount
        new=bytes.fromhex("90 90 90 90 90 90"),
    ),
    # Chromium 的 ApplyCodecContextSecuritySettings() 会给 AVCodecContext
    # 设置 codec_whitelist="h264"。FFmpeg 的 avcodec_open2() 会拒绝名称不在
    # 白名单里的解码器，因此必须把视频白名单扩充成 h264,hevc。
    Patch(
        name="FFmpeg 视频解码器白名单: h264 -> h264,hevc（写入代码洞）",
        va=0x2676BB2,
        # 函数末尾 ret 之后的 int3 对齐填充，不会被执行
        old=bytes.fromhex("cc " * 10),
        new=b"h264,hevc\x00",
    ),
    Patch(
        name="ApplyCodecContextSecuritySettings: 视频白名单指向新字符串",
        va=0x3F2FB1E,
        # lea rdi,[rip+...] -> "h264"
        old=bytes.fromhex("48 8d 3d 57 34 3a fd"),
        # lea rdi,[rip+...] -> 0x2676bb2 处的 "h264,hevc"
        new=bytes.fromhex("48 8d 3d 8d 70 74 fe"),
    ),
)


def va_to_file_offset(data: bytes, va: int) -> int:
    """把 ELF64 虚拟地址转换成文件偏移（使用 PT_LOAD 段）。"""
    if data[:4] != b"\x7fELF" or data[4] != 2:  # ELF64
        raise ValueError("不是 ELF64 文件")

    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
    e_phnum = struct.unpack_from("<H", data, 0x38)[0]

    for i in range(e_phnum):
        base = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", data, base)[0]
        if p_type != 1:  # PT_LOAD
            continue
        p_offset = struct.unpack_from("<Q", data, base + 0x08)[0]
        p_vaddr = struct.unpack_from("<Q", data, base + 0x10)[0]
        p_filesz = struct.unpack_from("<Q", data, base + 0x20)[0]
        if p_vaddr <= va < p_vaddr + p_filesz:
            return p_offset + (va - p_vaddr)

    raise ValueError(f"虚拟地址 0x{va:x} 不在任何 PT_LOAD 段内")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("qq", type=Path, help="AppDir/qq 可执行文件")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    data = bytearray(args.qq.read_bytes())
    changed = 0
    already = 0

    for patch in PATCHES:
        off = va_to_file_offset(data, patch.va)
        current = bytes(data[off : off + len(patch.old)])
        if current == patch.new:
            print(f"[skip] {patch.name}（已打过补丁）")
            already += 1
            continue
        if current != patch.old:
            print(
                f"[错误] {patch.name}\n"
                f"  VA=0x{patch.va:x} file=0x{off:x}\n"
                f"  期望: {patch.old.hex(' ')}\n"
                f"  实际: {current.hex(' ')}\n"
                "  这不是受支持的 qq 版本，未写入任何修改。",
                file=sys.stderr,
            )
            return 1
        print(f"[ok] {patch.name} @ VA 0x{patch.va:x} / file 0x{off:x}")
        if not args.dry_run:
            data[off : off + len(patch.new)] = patch.new
        changed += 1

    if args.dry_run:
        print(f"dry-run：将修改 {changed} 处，已存在 {already} 处")
        return 0

    if changed:
        args.qq.write_bytes(data)
        print(f"已写入 {args.qq}（修改 {changed} 处）")
    else:
        print("没有需要修改的内容")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
