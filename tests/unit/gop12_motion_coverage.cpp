// Independent libavcodec observation only; these vectors never enter the RTL.
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/motion_vector.h>
}

#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {
void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
}

int main(int argc, char** argv) {
    AVFormatContext* input = nullptr;
    AVCodecContext* decoder = nullptr;
    AVPacket* packet = nullptr;
    AVFrame* frame = nullptr;
    int status = 0;
    try {
        require(argc == 2, "usage: gop12_motion_coverage input.264");
        require(avformat_open_input(&input, argv[1], nullptr, nullptr) >= 0, "open input failed");
        require(avformat_find_stream_info(input, nullptr) >= 0, "stream information failed");
        const int stream = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        require(stream >= 0, "video stream missing");
        require(input->streams[stream]->codecpar->codec_id == AV_CODEC_ID_H264, "expected H264");
        const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
        require(codec != nullptr, "ordinary H264 decoder missing");
        decoder = avcodec_alloc_context3(codec);
        require(decoder != nullptr, "decoder allocation failed");
        require(avcodec_parameters_to_context(decoder, input->streams[stream]->codecpar) >= 0,
                "decoder parameters failed");
        decoder->thread_count = 1;
        decoder->flags2 |= AV_CODEC_FLAG2_EXPORT_MVS;
        require(avcodec_open2(decoder, codec, nullptr) >= 0, "decoder open failed");
        packet = av_packet_alloc();
        frame = av_frame_alloc();
        require(packet && frame, "frame allocation failed");
        unsigned index = 0;
        auto receive = [&]() {
            int result;
            while ((result = avcodec_receive_frame(decoder, frame)) >= 0) {
                std::cout << "{\"index\":" << index++ << ",\"width\":" << frame->width
                          << ",\"height\":" << frame->height << ",\"pict_type\":\""
                          << av_get_picture_type_char(frame->pict_type)
                          << "\",\"libavcodec_version\":" << avcodec_version()
                          << ",\"pts\":";
                if (frame->pts == AV_NOPTS_VALUE) std::cout << "null";
                else std::cout << frame->pts;
                std::cout << ",\"vectors\":[";
                const AVFrameSideData* data = av_frame_get_side_data(frame, AV_FRAME_DATA_MOTION_VECTORS);
                if (data) {
                    require(data->size % sizeof(AVMotionVector) == 0, "malformed motion vector side data");
                    const auto* vectors = reinterpret_cast<const AVMotionVector*>(data->data);
                    for (size_t i = 0; i < data->size / sizeof(AVMotionVector); ++i) {
                        const auto& v = vectors[i];
                        if (i) std::cout << ',';
                        std::cout << "{\"source\":" << v.source
                                  << ",\"w\":" << unsigned(v.w) << ",\"h\":" << unsigned(v.h)
                                  << ",\"dst_x\":" << v.dst_x << ",\"dst_y\":" << v.dst_y
                                  << ",\"motion_x\":" << v.motion_x << ",\"motion_y\":" << v.motion_y
                                  << ",\"motion_scale\":" << v.motion_scale << '}';
                    }
                }
                std::cout << "]}\n";
                av_frame_unref(frame);
            }
            require(result == AVERROR(EAGAIN) || result == AVERROR_EOF, "ordinary decoding failed");
        };
        int read_result;
        while ((read_result = av_read_frame(input, packet)) >= 0) {
            if (packet->stream_index == stream) {
                int sent = avcodec_send_packet(decoder, packet);
                if (sent == AVERROR(EAGAIN)) {
                    receive();
                    sent = avcodec_send_packet(decoder, packet);
                }
                require(sent >= 0, "decoder packet rejected");
                receive();
            }
            av_packet_unref(packet);
        }
        require(read_result == AVERROR_EOF, "input read failed");
        require(avcodec_send_packet(decoder, nullptr) >= 0, "decoder flush failed");
        receive();
        require(index != 0 && std::cout.good(), "missing motion output");
    } catch (const std::exception& error) {
        std::cerr << "FAIL motion coverage: " << error.what() << '\n';
        status = 2;
    }
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&decoder);
    avformat_close_input(&input);
    return status;
}
