/* 冒烟测试：用被替换的 libffmpeg.so 真实解码一个 HEVC 文件 */
#include <stdio.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>

int main(int argc, char **argv) {
    AVFormatContext *fc = NULL;
    if (avformat_open_input(&fc, argv[1], NULL, NULL) < 0) { printf("open fail\n"); return 1; }
    if (avformat_find_stream_info(fc, NULL) < 0) { printf("info fail\n"); return 1; }

    int vs = av_find_best_stream(fc, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vs < 0) { printf("no video stream\n"); return 1; }
    AVCodecParameters *par = fc->streams[vs]->codecpar;
    printf("codec_id=%d (%s)  %dx%d\n", par->codec_id,
           avcodec_get_name(par->codec_id), par->width, par->height);

    const AVCodec *dec = avcodec_find_decoder(par->codec_id);
    if (!dec) { printf("FAIL: no decoder for this codec\n"); return 2; }
    printf("decoder=%s (%s)\n", dec->name, dec->long_name);

    AVCodecContext *c = avcodec_alloc_context3(dec);
    avcodec_parameters_to_context(c, par);
    if (avcodec_open2(c, dec, NULL) < 0) { printf("FAIL: avcodec_open2\n"); return 3; }

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frm = av_frame_alloc();
    int got = 0;
    while (av_read_frame(fc, pkt) >= 0 && got < 3) {
        if (pkt->stream_index != vs) { av_packet_unref(pkt); continue; }
        if (avcodec_send_packet(c, pkt) == 0)
            while (avcodec_receive_frame(c, frm) == 0) {
                printf("decoded frame %d: %dx%d fmt=%d\n", ++got, frm->width, frm->height, frm->format);
                av_frame_unref(frm);
            }
        av_packet_unref(pkt);
    }
    printf(got ? "OK: 解码成功 %d 帧\n" : "FAIL: 一帧都没解出来\n", got);
    return got ? 0 : 4;
}
