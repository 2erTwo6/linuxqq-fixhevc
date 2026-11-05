#!/usr/bin/env python3
"""给 FFmpeg 源码补上 Chromium 私有符号 av_stream_get_first_dts。

QQ(Chromium 144) 的 qq 可执行文件把 av_stream_get_first_dts 作为强依赖导入，
但上游 FFmpeg 并没有这个函数——它是 Chromium 的下游补丁。
语义与 Chromium 一致：返回 demuxer 记录的 first_dts。
"""
import sys, pathlib

root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("ffmpeg-8.1.3")

DECL = """
/**
 * Get the first dts of a stream, as recorded by the demuxer.
 *
 * Chromium downstream addition; consumed by media/filters/ffmpeg_demuxer.cc
 * when AVStream.start_time is unset.
 */
int64_t av_stream_get_first_dts(const AVStream *st);
"""

IMPL = """
int64_t av_stream_get_first_dts(const AVStream *st)
{
    if (!st)
        return AV_NOPTS_VALUE;
    return cffstream(st)->first_dts;
}
"""

def patch(path: pathlib.Path, anchor: str, insert: str, mode: str) -> bool:
    text = path.read_text()
    if "av_stream_get_first_dts" in text:
        print(f"  [skip] {path} 已打过补丁")
        return False
    if mode == "after":
        assert anchor in text, f"锚点缺失: {path}"
        text = text.replace(anchor, anchor + insert, 1)
    else:  # append
        text = text + insert
    path.write_text(text)
    print(f"  [ok]   {path}")
    return True

h = root / "libavformat" / "avformat.h"
c = root / "libavformat" / "demux.c"

patch(h, "struct AVCodecParserContext *av_stream_get_parser(const AVStream *s);\n", DECL, "after")
patch(c, None, IMPL, "append")
print("源码补丁完成")
