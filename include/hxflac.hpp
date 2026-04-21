#ifndef HXFLAC_HPP
#define HXFLAC_HPP

#include <cstddef>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*hxflac_stream_callback)(const unsigned char* data, size_t size, void* user_data);

const char* hxflac_get_version_string(void);

void hxflac_free_result(unsigned char* data);
void hxflac_free_string(const char* str);

int hxflac_to_bytes(
    const unsigned char* input_data,
    size_t input_length,
    unsigned char** output_data,
    size_t* output_length,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
);

int hxflac_get_metadata(
    const unsigned char* input_data,
    size_t input_length,
    const char** title,
    const char** artist,
    const char** album,
    const char** genre,
    const char** year,
    const char** track,
    const char** comment
);

int hxflac_decode_streaming(
    const unsigned char* input_data,
    size_t input_length,
    hxflac_stream_callback callback,
    void* user_data,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
);

/* session api */

typedef int hxflac_stream_handle;

hxflac_stream_handle hxflac_stream_open(
    const unsigned char* input_data,
    size_t input_length
);

int hxflac_stream_get_info(
    hxflac_stream_handle handle,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
);

size_t hxflac_stream_read(
    hxflac_stream_handle handle,
    unsigned char* output,
    size_t output_capacity
);

int hxflac_stream_finished(hxflac_stream_handle handle);
int hxflac_stream_failed(hxflac_stream_handle handle);

void hxflac_stream_close(hxflac_stream_handle handle);

#ifdef __cplusplus
}
#endif

#endif