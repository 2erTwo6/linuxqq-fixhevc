# linuxqq-fixhevc

为 Linux 版 QQ AppImage 启用 HEVC/H.265 软件解码的构建脚本与二进制补丁工具。

QQ 的 Electron/Chromium 运行时具备 HEVC 容器解析和 `hvcC` 处理能力，但媒体层将
HEVC 当作平台硬件解码器处理。在没有相应 Linux 硬件解码能力时，媒体能力探测会
失败；即使进入 FFmpeg 解码路径，也会受到 H.264 专用门控和解码器白名单的限制。

本项目通过以下两步恢复 HEVC 软件解码：

1. 使用包含 HEVC 解码器的 FFmpeg 构建替换 QQ 自带的 `libffmpeg.so`；
2. 修改 `qq` 二进制中的少量媒体门控，使 HEVC 能够进入 FFmpeg 解码器。

```text
FFmpegDemuxer -> FFmpegVideoDecoder -> libavcodec HEVC 软件解码
```

本项目不转码、不修改视频文件，也不依赖 VA-API 硬件解码。

> 本仓库不包含 QQ 安装包、AppImage、解包后的 QQ 文件或其他第三方分发内容。
> 构建前请自行获取兼容版本的 Linux QQ AppImage。QQ 及相关资源归其权利人所有。

## 兼容性

| 项目 | 版本或范围 |
| --- | --- |
| QQ | 3.2.34-53644 AppImage |
| Electron | 40.0.0 |
| Chromium | 144.0.7559.60 |
| 架构 | x86_64 |

补丁依赖目标 `qq` 的具体二进制布局，仅适用于上述版本。补丁脚本会在写入前校验
目标字节；版本不匹配时会拒绝修改。QQ 升级后需要重新定位补丁地址。

## 环境要求

- x86_64 Linux 与 Bash；
- Python 3；
- `curl`、`tar`、`rpm2cpio`、`cpio`、`nproc` 等常用命令行工具；
- 首次构建时可访问脚本中配置的软件下载源；
- 与兼容性表匹配、可执行的原始 QQ AppImage。

`scripts/setup-toolchain.sh` 会将构建工具下载到项目的 `work/` 目录，不修改系统
工具链。构建过程需要安装 Zig、GNU make、NASM 和 squashfs-tools。

## 构建

将原始 AppImage 路径写入 `SRC_APPIMAGE`，然后依次执行：

```bash
export SRC_APPIMAGE=/absolute/path/to/QQ-3.2.34-53644-x86_64.AppImage

./scripts/setup-toolchain.sh
./scripts/build-ffmpeg.sh
./scripts/repack-appimage.sh
```

默认输出：

```text
dist/QQ-3.2.34-hevc-native-x86_64.AppImage
```

该文件包含原始 AppImage 中的 QQ/Electron 文件，不会提交到版本库，也不应公开
分发。可通过环境变量覆盖常用构建参数：

| 变量 | 作用 |
| --- | --- |
| `SRC_APPIMAGE` | 原始 QQ AppImage 路径 |
| `OUT` | 重打包产物路径 |
| `JOBS` | FFmpeg 并行编译任务数 |
| `FFMPEG_VER` | FFmpeg 源码版本，默认 `8.1.3` |
| `ZIG_VER` | Zig 版本，默认 `0.15.2` |
| `FEDORA_MIRROR` | 下载 make、NASM、squashfs-tools 的软件源 |

各步骤说明：

1. `setup-toolchain.sh` 准备本地工具链；
2. `build-ffmpeg.sh` 编译静态链接的 `libffmpeg.so`，并启用 HEVC 软解；
3. `repack-appimage.sh` 解包原始 AppImage、替换 `libffmpeg.so`、应用 `qq`
   二进制补丁并重新生成 AppImage。

## 运行

```bash
chmod +x dist/QQ-3.2.34-hevc-native-x86_64.AppImage
./dist/QQ-3.2.34-hevc-native-x86_64.AppImage
```

运行方式与原始 AppImage 相同。应用仍使用 QQ 自身的登录、账户和本地数据。

## 诊断与验证

可先检查二进制补丁状态：

```bash
./scripts/patch-qq-hevc-binary.py --dry-run work/AppDir/qq
```

更完整的补丁检查、FFmpeg 冒烟测试和运行时探针说明见
[`docs/DIAGNOSTICS.md`](docs/DIAGNOSTICS.md)。

## 项目结构

```text
.
├── README.md
├── LICENSE
├── docs/
│   ├── DIAGNOSTICS.md        # 诊断、验证与故障排查
│   └── PATCHES.md            # 二进制补丁与实现原理
├── scripts/
│   ├── setup-toolchain.sh    # 准备本地构建工具链
│   ├── build-ffmpeg.sh       # 构建含 HEVC 解码器的 libffmpeg.so
│   ├── patch-ffmpeg.py       # 为 FFmpeg 添加 Chromium 私有符号
│   ├── patch-qq-hevc-binary.py # 修改 qq 中的 HEVC 媒体门控
│   ├── repack-appimage.sh    # 重打包 AppImage
│   └── diagnostics/
│       ├── build-smoke-test.sh
│       ├── debug-playback.sh
│       ├── probe-avcodec.c
│       └── smoke-test.c
└── dist/                     # 本地构建产物，不纳入版本库
```

## 限制

- 当前方案使用软件解码，CPU 占用会高于硬件解码；高码率 4K 或 Main10 视频
  可能出现掉帧。
- 当前 `qq` 不包含完整的 Linux VA-API 硬件解码链路，不能通过少量二进制修改
  启用硬件解码。
- 补丁只面向上述固定版本的 x86_64 AppImage；其他发行方式、架构或 QQ 版本
  均未支持。
- QQ 更新后二进制地址和指令可能变化，需要重新分析并更新补丁。

## 隐私与发布

- `work/`、`dist/`、构建日志和诊断日志均在 `.gitignore` 中排除。
- 诊断日志可能包含本地文件路径、媒体文件名或运行信息，不应提交到版本库或
  公开发布。
- 提交前请使用 `git status --ignored` 或类似命令确认没有误加入原始 AppImage、
  解包文件、日志或其他本地数据。

## 许可证与声明

本项目以 MIT License 发布，详见 [`LICENSE`](LICENSE)。

本项目与腾讯无关联，也未获得其官方支持。使用者应自行确保对 QQ 的获取、修改
和使用符合所在地法律及软件许可条款。
