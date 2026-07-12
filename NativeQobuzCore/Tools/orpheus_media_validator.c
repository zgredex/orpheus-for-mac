#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/log.h>
#include <stdio.h>

static void print_error(const char *context, int code) {
    char message[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, message, sizeof(message));
    fprintf(stderr, "%s: %s\n", context, message);
}

static int decode(AVCodecContext *codec, AVPacket *packet, AVFrame *frame) {
    int result = avcodec_send_packet(codec, packet);
    if (result < 0) {
        print_error("Could not submit audio packet", result);
        return result;
    }
    while (result >= 0) {
        result = avcodec_receive_frame(codec, frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return 0;
        if (result < 0) {
            print_error("Audio decode failed", result);
            return result;
        }
        av_frame_unref(frame);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: orpheus-media-validator <audio-file>\n");
        return 64;
    }

    av_log_set_level(AV_LOG_ERROR);
    AVFormatContext *format = NULL;
    AVCodecContext *codec = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    int audio_stream = -1;
    int result = avformat_open_input(&format, argv[1], NULL, NULL);
    if (result < 0) {
        print_error("Could not open media", result);
        goto cleanup;
    }
    result = avformat_find_stream_info(format, NULL);
    if (result < 0) {
        print_error("Could not read media stream", result);
        goto cleanup;
    }
    result = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (result < 0) {
        print_error("No audio stream found", result);
        goto cleanup;
    }
    audio_stream = result;

    const AVCodec *decoder = avcodec_find_decoder(format->streams[audio_stream]->codecpar->codec_id);
    if (!decoder) {
        fprintf(stderr, "No bundled decoder supports this audio stream\n");
        result = AVERROR_DECODER_NOT_FOUND;
        goto cleanup;
    }
    codec = avcodec_alloc_context3(decoder);
    if (!codec) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    result = avcodec_parameters_to_context(codec, format->streams[audio_stream]->codecpar);
    if (result < 0 || (result = avcodec_open2(codec, decoder, NULL)) < 0) {
        print_error("Could not initialize decoder", result);
        goto cleanup;
    }

    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (!packet || !frame) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    while ((result = av_read_frame(format, packet)) >= 0) {
        if (packet->stream_index == audio_stream && decode(codec, packet, frame) < 0) {
            result = AVERROR_INVALIDDATA;
            goto cleanup;
        }
        av_packet_unref(packet);
    }
    if (result != AVERROR_EOF) {
        print_error("Media read failed", result);
        goto cleanup;
    }
    result = decode(codec, NULL, frame);

cleanup:
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&codec);
    avformat_close_input(&format);
    return result < 0 ? 1 : 0;
}
