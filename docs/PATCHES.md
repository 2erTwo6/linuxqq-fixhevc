# 二进制补丁与实现原理

本页说明 `scripts/patch-qq-hevc-binary.py` 修改的媒体门控，以及 FFmpeg 侧所需的
兼容性补丁。相关地址和字节仅对“适用范围”中列出的 QQ 版本有效。

## 适用范围

- QQ：3.2.34-53644 AppImage
- Electron：40.0.0
- Chromium：144.0.7559.60
- 架构：x86_64

补丁脚本通过 ELF program header 将虚拟地址转换为文件偏移，并在写入前逐字节
校验原内容。只要任一目标位置与预期不符，脚本就会停止且不写入修改。重复执行时，
脚本能够识别已经应用过的补丁。

## 背景

目标 Electron/Chromium 构建已经包含以下 HEVC 相关能力：

- MP4 容器中的 HEVC codec 识别；
- `hvcC` / `HEVCDecoderConfigurationRecord` 解析；
- `HEVCBitstreamConverter` 与 `FFmpegH265ToAnnexBBitstreamConverter`；
- HEVC 的 `VideoCodec` / `AVCodecID` 映射。

问题位于运行时能力判断和 FFmpeg 视频解码器入口：HEVC 被视为需要平台硬件解码
支持的类型，而 Linux 上的平台解码器缓存为空。此外，FFmpeg 视频解码路径包含
H.264 专用的初始化条件、线程数分支和解码器白名单。

## `qq` 补丁一览

按写入点计，补丁脚本包含五个写入点，对应四个媒体门控：

| 编号 | 函数或目标 | 虚拟地址 | 作用 |
| --- | --- | --- | --- |
| 1 | `IsDefaultDecoderSupportedVideoType` | `0x3AAC9BC` | HEVC 直接返回支持 |
| 2 | `FFmpegVideoDecoder::Initialize` | `0x3F19878` | 允许 HEVC 进入解码器配置 |
| 3 | FFmpeg 视频解码器线程数选择 | `0x3F199E5` | 跳过非 H.264 的 `NOTREACHED()` 分支 |
| 4a | `ApplyCodecContextSecuritySettings` 代码洞 | `0x2676BB2` | 写入 `h264,hevc` 字符串 |
| 4b | `ApplyCodecContextSecuritySettings` | `0x3F2FB1E` | 视频解码器白名单指向新字符串 |

### 1. HEVC 能力判断

`IsDefaultDecoderSupportedVideoType` 在 HEVC 分支会查询
`SupplementalDecoderVideoProfileCache`。Linux 上没有对应的平台 HEVC 解码器，
缓存为空，因此 `canPlayType()` 对 HEVC MIME 类型返回空串。

补丁将 HEVC 分支改为直接跳到返回 `true` 的公共路径：

```text
原始：31 c0 80 7b 0c 00 74
补丁：b0 01 e9 f2 ff ff ff
```

对应语义：

```asm
mov al, 1
jmp <公共返回 true 路径>
```

### 2. 允许 HEVC 进入 FFmpeg 解码器初始化

`FFmpegVideoDecoder::Initialize()` 原本只接受 `kH264`，其他 codec 会进入
不支持分支。补丁保留 H.264 的原有行为，并增加 `kHEVC` 判断：

```text
原始：41 83 3c 24 01 75 0e bf 01 00 00 00 e8 a7 32 b9 ff 84 c0 75 70
补丁：41 83 3c 24 01 74 7e 41 83 3c 24 08 74 77 90 90 90 90 90 90 90
```

对应语义：

```asm
cmp dword ptr [r12], 1    ; kH264
je  <ConfigureDecoder>
cmp dword ptr [r12], 8    ; kHEVC
je  <ConfigureDecoder>
nop ...
```

### 3. 跳过线程数选择的 `NOTREACHED()` 分支

`GetFFmpegVideoDecoderThreadCount()` 的 switch 把 HEVC 当成不会编译进 FFmpeg
的 codec，并进入 `NOTREACHED()`；在优化后的二进制中，该路径包含 `ud2`。
补丁移除对应条件跳转，使 HEVC 落到默认线程数分支：

```text
原始：0f 82 28 01 00 00    ; jb <ud2>
补丁：90 90 90 90 90 90    ; nop
```

HEVC 随后使用默认的 `mov edi, 2` 并调用
`VideoDecoder::GetRecommendedThreadCount()`。

### 4. 扩展 FFmpeg 视频解码器白名单

`ApplyCodecContextSecuritySettings()` 会为 `AVCodecContext` 设置
`codec_whitelist`。视频分支固定使用字符串 `h264`，因此 FFmpeg 的
`avcodec_open2()` 会以如下错误拒绝 HEVC：

```text
Codec (hevc) not on whitelist 'h264'
```

补丁分为两个写入点：

1. 在 `0x2676BB2` 的函数对齐填充区写入新字符串：

   ```text
   h264,hevc\0
   ```

2. 修改 `0x3F2FB1E` 处的 LEA 指令，使视频白名单指向新字符串：

   ```text
   原始：48 8d 3d 57 34 3a fd
   补丁：48 8d 3d 8d 70 74 fe
   ```

音频分支继续使用原来的音频白名单，不受影响。

## FFmpeg 侧补丁

QQ 的 Chromium 构建将 `av_stream_get_first_dts` 作为导入符号使用，但上游 FFmpeg
并未提供该函数。`scripts/patch-ffmpeg.py` 在 FFmpeg 源码中插入声明与实现：

```c
int64_t av_stream_get_first_dts(const AVStream *st);
```

实现返回 demuxer 记录的 `first_dts`，行为与 Chromium 下游补丁一致。随后
`scripts/build-ffmpeg.sh` 静态链接生成 `libffmpeg.so`，并启用 HEVC decoder、
parser 及所需的 demuxer 和 bitstream filter。

## 关于 `major.node`

本方案不修改 `major.node` 的能力探测逻辑。能力探测最终仍由 Blink 的
`canPlayType()` / `MediaSource.isTypeSupported()` 决定；补丁使底层媒体能力和
解码通路真正可用，因此探测结果与解码行为保持一致。

## 验证方法

补丁脚本支持 dry-run：

```bash
./scripts/patch-qq-hevc-binary.py --dry-run work/AppDir/qq
```

已应用补丁时输出应包含五个 `[skip]`，并报告将修改 0 处。目标字节不匹配时，
脚本会输出错误且不会写入文件。进一步的检查与故障排查见
[`DIAGNOSTICS.md`](DIAGNOSTICS.md)。
