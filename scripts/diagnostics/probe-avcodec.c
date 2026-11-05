/*
 * LD_PRELOAD 探针：记录 QQ(Chromium) 向 libffmpeg.so 发起的解码器请求。
 *
 * 主要用于验证原生 HEVC 修复是否生效：
 *   - 出现 [find_decoder] id=173 -> FOUND
 *     说明 HEVC 已经进入 FFmpeg 解码器；
 *   - 没有这一行
 *     说明 Chromium 仍在更早的能力判断处拒绝了 HEVC。
 *
 * 推荐用法：
 *   ./scripts/diagnostics/debug-playback.sh
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>

static FILE *g_log;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void open_log(void) {
    const char *p = getenv("QQ_FFMPEG_PROBE_LOG");
    if (!p) p = "/tmp/qq_ffmpeg_probe.log";
    g_log = fopen(p, "a");
    if (g_log) {
        fprintf(g_log, "\n=== probe pid=%d start ===\n", getpid());
        fflush(g_log);
    }
}

#define LOG(...) do {                                   \
    pthread_once(&g_once, open_log);                    \
    if (g_log) { fprintf(g_log, __VA_ARGS__); fflush(g_log); } \
} while (0)

static void *next_sym(const char *n) { return dlsym(RTLD_NEXT, n); }

void *avcodec_find_decoder(int id) {
    static void *(*real)(int);
    if (!real) real = next_sym("avcodec_find_decoder");
    void *r = real ? real(id) : NULL;
    LOG("[find_decoder] id=%d -> %s\n", id, r ? "FOUND" : "NULL");
    return r;
}

void *avcodec_find_decoder_by_name(const char *name) {
    static void *(*real)(const char *);
    if (!real) real = next_sym("avcodec_find_decoder_by_name");
    void *r = real ? real(name) : NULL;
    LOG("[find_decoder_by_name] %s -> %s\n", name ? name : "(null)", r ? "FOUND" : "NULL");
    return r;
}

int avcodec_open2(void *ctx, const void *codec, void *opts) {
    static int (*real)(void *, const void *, void *);
    if (!real) real = next_sym("avcodec_open2");
    int r = real ? real(ctx, codec, opts) : -1;
    LOG("[avcodec_open2] codec=%p ret=%d\n", codec, r);
    return r;
}

int avformat_open_input(void **ps, const char *url, const void *fmt, void **opts) {
    static int (*real)(void **, const char *, const void *, void **);
    if (!real) real = next_sym("avformat_open_input");
    LOG("[avformat_open_input] %s\n", url ? url : "(null)");
    return real ? real(ps, url, fmt, opts) : -1;
}

int avcodec_send_packet(void *ctx, const void *pkt) {
    static int (*real)(void *, const void *);
    if (!real) real = next_sym("avcodec_send_packet");
    LOG("[avcodec_send_packet] called\n");
    return real ? real(ctx, pkt) : -1;
}

int avcodec_receive_frame(void *ctx, void *frame) {
    static int (*real)(void *, void *);
    if (!real) real = next_sym("avcodec_receive_frame");
    int r = real ? real(ctx, frame) : -1;
    LOG("[avcodec_receive_frame] ret=%d\n", r);
    return r;
}
