# 诊断、验证与故障排查

本页说明如何检查补丁状态、验证自建 `libffmpeg.so` 的 HEVC 解码能力，以及在
运行时确认 QQ 是否真正调用了 FFmpeg 的 HEVC 解码器。

这些步骤为手动诊断流程。执行运行时诊断会启动 QQ，并可能产生包含本地文件路径
和运行信息的日志。日志仅写入 `work/debug/`，该目录已被 `.gitignore` 排除；
请勿将日志提交到版本库或公开发布。

## 1. 检查 `qq` 二进制补丁状态

在重打包前或完成重打包后，可对解包目录中的 `qq` 执行 dry-run：

```bash
./scripts/patch-qq-hevc-binary.py --dry-run work/AppDir/qq
```

输出解读：

- 所有目标均为 `[skip]`，并报告将修改 0 处：补丁已经应用；
- 显示 `[ok]`：目标位置仍是未修补状态，dry-run 不会写入文件；
- 显示 `[错误]`：当前 `qq` 不是受支持的版本，脚本不会修改任何内容。

如果错误来自版本升级，需要重新分析新版本二进制的门控地址和指令，而不能直接
复用现有补丁。

## 2. 验证 `libffmpeg.so` 的 HEVC 解码能力

准备一个可用的 HEVC 视频文件，然后编译并运行最小解码测试：

```bash
./scripts/diagnostics/build-smoke-test.sh
work/ffmpeg-8.1.3/smoke /path/to/hevc.mp4
```

成功时，输出应包含 HEVC codec 信息、解码器名称以及至少一帧解码结果，例如：

```text
codec_id=173 (hevc)  1280x720
decoder=hevc (HEVC (High Efficiency Video Coding))
decoded frame 1: 1280x720 fmt=0
OK: 解码成功 3 帧
```

`codec_id=173` 对应 FFmpeg 的 `AV_CODEC_ID_HEVC`。如果测试报告
`no decoder for this codec`，说明替换用的 `libffmpeg.so` 未启用 HEVC 解码器；
如果 `avcodec_open2` 失败，应检查 FFmpeg 构建参数和链接结果。

## 3. 运行时探针

`debug-playback.sh` 使用 `LD_PRELOAD` 记录 QQ 向 `libffmpeg.so` 发起的解码器
请求。脚本默认使用：

```text
dist/QQ-3.2.34-hevc-native-x86_64.AppImage
```

也可以传入其他路径：

```bash
./scripts/diagnostics/debug-playback.sh /path/to/patched.AppImage
```

脚本会：

1. 使用宿主 `cc` 或 `work/` 中的 Zig 编译 `probe-avcodec.c`；
2. 通过 `LD_PRELOAD` 启动 QQ；
3. 将探针日志写入 `work/debug/qq_probe.log`；
4. 将 QQ 的 stderr 输出写入 `work/debug/qq_run.log`；
5. 退出后打印解码器请求和相关媒体日志摘要。

运行时需要可用的图形会话和 QQ 登录状态。启动后，在 QQ 中打开 HEVC 视频，等待
数秒并关闭 QQ，脚本即可输出摘要。

摘要中应出现：

```text
[find_decoder] id=173 -> FOUND
```

出现该行说明 QQ 已经请求 FFmpeg 的 HEVC 解码器。若只有其他 codec 的请求，
或者完全没有 `find_decoder` 记录，说明 HEVC 仍在更早的能力判断阶段被拒绝，
或补丁未作用于实际运行的 AppImage。

## 4. 常见问题

### `canPlayType()` 或媒体播放仍判断 HEVC 不支持

确认实际运行的 AppImage 是重打包后的产物，并检查 `work/AppDir/qq` 的补丁状态。
如果 dry-run 报告目标字节不匹配，说明 `qq` 版本与补丁不兼容。

### 已请求 HEVC 解码器但 `avcodec_open2` 失败

重点检查白名单补丁。FFmpeg 返回 `not on whitelist` 时，通常表示视频解码器白名单
仍只包含 `h264`，或 LEA 指令未指向包含 `h264,hevc` 的新字符串。

### 能播放但 CPU 占用高或掉帧

当前实现为软件解码，CPU 占用高属于预期行为。高分辨率、高码率或 Main10 视频
对 CPU 要求更高。本项目没有启用 Linux VA-API 硬件解码。

### 启动失败或媒体功能异常

先确认原始 AppImage 能正常运行，再检查重打包步骤是否完整替换了
`AppDir/libffmpeg.so`，以及 `qq` 补丁是否成功。诊断日志中的 Chromium 媒体
信息可用于定位失败阶段，但发布前必须清理其中可能包含的本地路径和运行信息。

## 5. 日志与隐私

- `work/` 和 `dist/` 不会提交到版本库；
- `*.log` 已加入 `.gitignore`；
- 探针日志可能包含媒体文件路径、进程信息和本地路径；
- QQ 运行日志可能包含账户或会话相关信息。

不要将未清理的日志、原始 AppImage 或解包后的 QQ 文件上传到公开仓库。
