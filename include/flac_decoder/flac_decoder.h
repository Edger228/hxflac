#ifndef FLAC_DECODER_H
#define FLAC_DECODER_H

#include <stddef.h>
#include <FLAC/stream_decoder.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*flac_pcm_write_callback)(const unsigned char* data, size_t size, void* user_data);

typedef struct {
    const unsigned char* input_data;
    size_t input_length;
    size_t input_position;

    unsigned char* pcm_buffer;
    size_t pcm_buffer_size;
    size_t pcm_buffer_capacity;

    unsigned sample_rate;
    unsigned channels;
    unsigned bits_per_sample;

    int error;
    int consumer_aborted;
    char error_message[256];

    flac_pcm_write_callback pcm_callback;
    void* pcm_callback_user_data;
    int streaming_mode;
} flac_decoder_context;

int decode_flac_data(
    const unsigned char* input_data,
    size_t input_length,
    unsigned char** output_data,
    size_t* output_length,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
);

int decode_flac_data_streaming(
    const unsigned char* input_data,
    size_t input_length,
    flac_pcm_write_callback pcm_callback,
    void* pcm_callback_user_data,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
);

void free_flac_decoded_data(unsigned char* data);

/* session api */

typedef struct flac_stream_session flac_stream_session;

flac_stream_session* flac_stream_open(
    const unsigned char* input_data,
    size_t input_length
);

int flac_stream_get_info(
    flac_stream_session* session,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
);

size_t flac_stream_read(
    flac_stream_session* session,
    unsigned char* output,
    size_t output_capacity
);

int flac_stream_finished(flac_stream_session* session);
int flac_stream_failed(flac_stream_session* session);

void flac_stream_close(flac_stream_session* session);

#ifdef __cplusplus
}
#endif

#endif