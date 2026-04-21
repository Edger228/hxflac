#include "flac_decoder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdarg.h>

static const size_t INITIAL_BUFFER_CAPACITY = 256 * 1024;

#if defined(FLAC_DEBUG) && FLAC_DEBUG
#define DEBUG_PRINT(...) fprintf(stderr, __VA_ARGS__)
#else
#define DEBUG_PRINT(...)
#endif

static size_t get_bytes_per_sample(unsigned bits_per_sample) {
    return (bits_per_sample + 7u) / 8u;
}

static int set_error(flac_decoder_context* context, const char* fmt, ...) {
    va_list args;
    context->error = 1;
    va_start(args, fmt);
    vsnprintf(context->error_message, sizeof(context->error_message), fmt, args);
    va_end(args);
    DEBUG_PRINT("[HXFLAC] %s\n", context->error_message);
    return 0;
}

static int safe_add_size(size_t a, size_t b, size_t* out) {
    if (a > SIZE_MAX - b) {
        return 0;
    }
    *out = a + b;
    return 1;
}

static int safe_mul_size(size_t a, size_t b, size_t* out) {
    if (a != 0 && b > SIZE_MAX / a) {
        return 0;
    }
    *out = a * b;
    return 1;
}

static int ensure_buffer_capacity(flac_decoder_context* context, size_t additional_bytes) {
    size_t required_size = 0;

    if (!safe_add_size(context->pcm_buffer_size, additional_bytes, &required_size)) {
        return set_error(context, "[HXFLAC] PCM buffer size overflow (current=%zu, add=%zu)",
                         context->pcm_buffer_size, additional_bytes);
    }

    if (required_size <= context->pcm_buffer_capacity) {
        return 1;
    }

    size_t new_capacity = context->pcm_buffer_capacity;
    if (new_capacity == 0) {
        new_capacity = INITIAL_BUFFER_CAPACITY;
    }

    while (new_capacity < required_size) {
        if (new_capacity > SIZE_MAX / 2) {
            new_capacity = required_size;
            break;
        }
        new_capacity *= 2;
    }

    if (new_capacity < required_size) {
        new_capacity = required_size;
    }

    unsigned char* new_buffer = (unsigned char*)realloc(context->pcm_buffer, new_capacity);
    if (!new_buffer) {
        return set_error(context, "[HXFLAC] Memory allocation failed for %zu bytes", new_capacity);
    }

    DEBUG_PRINT("[HXFLAC] Buffer reallocated: %zu -> %zu bytes\n",
                context->pcm_buffer_capacity, new_capacity);

    context->pcm_buffer = new_buffer;
    context->pcm_buffer_capacity = new_capacity;
    return 1;
}

static void write_sample_le(FLAC__int32 sample, unsigned bytes_per_sample, unsigned char** output) {
    for (unsigned byte = 0; byte < bytes_per_sample; ++byte) {
        *(*output)++ = (unsigned char)((sample >> (byte * 8u)) & 0xFF);
    }
}

static void convert_samples_packed_le(
    const FLAC__int32* const* buffers,
    unsigned channels,
    unsigned samples,
    unsigned bytes_per_sample,
    unsigned char* output
) {
    unsigned char* out = output;

    for (unsigned i = 0; i < samples; ++i) {
        for (unsigned ch = 0; ch < channels; ++ch) {
            write_sample_le(buffers[ch][i], bytes_per_sample, &out);
        }
    }
}

static int validate_streaminfo(
    flac_decoder_context* context,
    unsigned sample_rate,
    unsigned channels,
    unsigned bits_per_sample
) {
    if (sample_rate == 0) {
        return set_error(context, "[HXFLAC] Invalid FLAC sample rate: 0");
    }

    if (channels == 0) {
        return set_error(context, "[HXFLAC] Invalid FLAC channel count: 0");
    }

    if (bits_per_sample == 0 || bits_per_sample > 32) {
        return set_error(context, "[HXFLAC] Unsupported bits per sample: %u", bits_per_sample);
    }

    if (context->sample_rate == 0) {
        context->sample_rate = sample_rate;
        context->channels = channels;
        context->bits_per_sample = bits_per_sample;
        return 1;
    }

    if (context->sample_rate != sample_rate ||
        context->channels != channels ||
        context->bits_per_sample != bits_per_sample) {
        return set_error(
            context,
            "[HXFLAC] FLAC stream format changed mid-stream "
            "(expected %u Hz, %u ch, %u bps; got %u Hz, %u ch, %u bps)",
            context->sample_rate,
            context->channels,
            context->bits_per_sample,
            sample_rate,
            channels,
            bits_per_sample
        );
    }

    return 1;
}

static int deliver_pcm(flac_decoder_context* context, const unsigned char* data, size_t size) {
    if (size == 0) {
        return 1;
    }

    if (context->streaming_mode) {
        if (!context->pcm_callback) {
            return set_error(context, "[HXFLAC] Streaming mode enabled but PCM callback is NULL");
        }

        if (!context->pcm_callback(data, size, context->pcm_callback_user_data)) {
            context->consumer_aborted = 1;
            return set_error(context, "[HXFLAC] PCM consumer aborted streaming decode");
        }

        return 1;
    }

    if (!ensure_buffer_capacity(context, size)) {
        return 0;
    }

    memcpy(context->pcm_buffer + context->pcm_buffer_size, data, size);
    context->pcm_buffer_size += size;
    return 1;
}

FLAC__StreamDecoderWriteStatus write_callback(
    const FLAC__StreamDecoder* decoder,
    const FLAC__Frame* frame,
    const FLAC__int32* const buffers[],
    void* client_data
) {
    (void)decoder;

    flac_decoder_context* context = (flac_decoder_context*)client_data;

    const unsigned channels = frame->header.channels;
    const unsigned samples = frame->header.blocksize;
    const unsigned bits_per_sample = frame->header.bits_per_sample;
    const unsigned sample_rate = frame->header.sample_rate;
    const unsigned bytes_per_sample = (unsigned)get_bytes_per_sample(bits_per_sample);

    DEBUG_PRINT("[HXFLAC] Frame: %u samples, %u channels, %u bps, %u Hz\n",
                samples, channels, bits_per_sample, sample_rate);

    if (!validate_streaminfo(context, sample_rate, channels, bits_per_sample)) {
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    size_t sample_count = 0;
    size_t frame_size = 0;

    if (!safe_mul_size((size_t)samples, (size_t)channels, &sample_count)) {
        set_error(context, "[HXFLAC] Frame sample count overflow (%u * %u)", samples, channels);
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    if (!safe_mul_size(sample_count, (size_t)bytes_per_sample, &frame_size)) {
        set_error(context, "[HXFLAC] Frame byte size overflow (%zu * %u)", sample_count, bytes_per_sample);
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    if (context->streaming_mode) {
        unsigned char* temp = (unsigned char*)malloc(frame_size);
        if (!temp) {
            set_error(context, "[HXFLAC] Memory allocation failed for frame buffer of %zu bytes", frame_size);
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
        }

        convert_samples_packed_le(buffers, channels, samples, bytes_per_sample, temp);

        if (!deliver_pcm(context, temp, frame_size)) {
            free(temp);
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
        }

        free(temp);
    } else {
        if (!ensure_buffer_capacity(context, frame_size)) {
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
        }

        unsigned char* dst = context->pcm_buffer + context->pcm_buffer_size;
        convert_samples_packed_le(buffers, channels, samples, bytes_per_sample, dst);
        context->pcm_buffer_size += frame_size;
    }

    DEBUG_PRINT("[HXFLAC] Delivered frame: %zu bytes\n", frame_size);
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

void metadata_callback(
    const FLAC__StreamDecoder* decoder,
    const FLAC__StreamMetadata* metadata,
    void* client_data
) {
    (void)decoder;

    flac_decoder_context* context = (flac_decoder_context*)client_data;

    if (metadata->type == FLAC__METADATA_TYPE_STREAMINFO) {
        const unsigned sample_rate = metadata->data.stream_info.sample_rate;
        const unsigned channels = metadata->data.stream_info.channels;
        const unsigned bits_per_sample = metadata->data.stream_info.bits_per_sample;

        if (!validate_streaminfo(context, sample_rate, channels, bits_per_sample)) {
            return;
        }

        DEBUG_PRINT("[HXFLAC] Stream info: %u Hz, %u channels, %u bps, %llu total samples\n",
                    context->sample_rate,
                    context->channels,
                    context->bits_per_sample,
                    (unsigned long long)metadata->data.stream_info.total_samples);
    }
}

void error_callback(
    const FLAC__StreamDecoder* decoder,
    FLAC__StreamDecoderErrorStatus status,
    void* client_data
) {
    (void)decoder;

    flac_decoder_context* context = (flac_decoder_context*)client_data;
    set_error(context, "[HXFLAC] FLAC decoder error: %s",
              FLAC__StreamDecoderErrorStatusString[status]);
}

FLAC__StreamDecoderReadStatus read_callback(
    const FLAC__StreamDecoder* decoder,
    FLAC__byte buffer[],
    size_t* bytes,
    void* client_data
) {
    (void)decoder;

    flac_decoder_context* context = (flac_decoder_context*)client_data;

    if (*bytes == 0) {
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }

    if (context->input_position >= context->input_length) {
        *bytes = 0;
        DEBUG_PRINT("[HXFLAC] READ: End of stream reached\n");
        return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
    }

    size_t bytes_available = context->input_length - context->input_position;
    size_t bytes_to_read = (*bytes < bytes_available) ? *bytes : bytes_available;

    memcpy(buffer, context->input_data + context->input_position, bytes_to_read);
    context->input_position += bytes_to_read;
    *bytes = bytes_to_read;

    DEBUG_PRINT("[HXFLAC] READ: %zu bytes (position: %zu/%zu)\n",
                bytes_to_read, context->input_position, context->input_length);

    return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
}

FLAC__StreamDecoderSeekStatus seek_callback(
    const FLAC__StreamDecoder* decoder,
    FLAC__uint64 absolute_byte_offset,
    void* client_data
) {
    (void)decoder;

    flac_decoder_context* context = (flac_decoder_context*)client_data;

    if (absolute_byte_offset > (FLAC__uint64)context->input_length) {
        return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR;
    }

    context->input_position = (size_t)absolute_byte_offset;
    return FLAC__STREAM_DECODER_SEEK_STATUS_OK;
}

FLAC__StreamDecoderTellStatus tell_callback(
    const FLAC__StreamDecoder* decoder,
    FLAC__uint64* absolute_byte_offset,
    void* client_data
) {
    (void)decoder;

    flac_decoder_context* context = (flac_decoder_context*)client_data;
    *absolute_byte_offset = (FLAC__uint64)context->input_position;
    return FLAC__STREAM_DECODER_TELL_STATUS_OK;
}

FLAC__StreamDecoderLengthStatus length_callback(
    const FLAC__StreamDecoder* decoder,
    FLAC__uint64* stream_length,
    void* client_data
) {
    (void)decoder;

    flac_decoder_context* context = (flac_decoder_context*)client_data;
    *stream_length = (FLAC__uint64)context->input_length;
    return FLAC__STREAM_DECODER_LENGTH_STATUS_OK;
}

FLAC__bool eof_callback(const FLAC__StreamDecoder* decoder, void* client_data) {
    (void)decoder;

    flac_decoder_context* context = (flac_decoder_context*)client_data;
    return context->input_position >= context->input_length;
}

static int is_native_flac(const unsigned char* input_data, size_t input_length) {
    return input_data != NULL && input_length >= 4 && memcmp(input_data, "fLaC", 4) == 0;
}

static int is_ogg_flac(const unsigned char* input_data, size_t input_length) {
    return input_length >= 4 && memcmp(input_data, "OggS", 4) == 0;
}

static int decode_flac_internal(
    const unsigned char* input_data,
    size_t input_length,
    unsigned char** output_data,
    size_t* output_length,
    flac_pcm_write_callback pcm_callback,
    void* pcm_callback_user_data,
    int streaming_mode,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
) {
    DEBUG_PRINT("[HXFLAC] Starting FLAC decode: %zu bytes input\n", input_length);

    if (!input_data || input_length == 0 || !sample_rate || !channels || !bits_per_sample) {
        fprintf(stderr, "[HXFLAC] Invalid arguments to decode_flac_internal\n");
        return 0;
    }

    if (streaming_mode) {
        if (!pcm_callback) {
            fprintf(stderr, "[HXFLAC] Streaming decode requires a non-NULL PCM callback\n");
            return 0;
        }
    } else {
        if (!output_data || !output_length) {
            fprintf(stderr, "[HXFLAC] Buffered decode requires output_data and output_length\n");
            return 0;
        }
        *output_data = NULL;
        *output_length = 0;
    }

    const int native_flac = is_native_flac(input_data, input_length);
    #if defined(FLAC__HAS_OGG) && FLAC__HAS_OGG
    const int ogg_flac = is_ogg_flac(input_data, input_length);
    #else
    const int ogg_flac = 0;
    #endif

    if (!native_flac && !ogg_flac) {
        #if defined(FLAC__HAS_OGG) && FLAC__HAS_OGG
        fprintf(stderr, "[HXFLAC] Unsupported FLAC container (expected native FLAC or Ogg FLAC)\n");
        #else
        fprintf(stderr, "[HXFLAC] Unsupported FLAC container (expected native FLAC)\n");
        #endif
        return 0;
    }

    FLAC__StreamDecoder* decoder = FLAC__stream_decoder_new();
    if (!decoder) {
        fprintf(stderr, "[HXFLAC] Unable to create FLAC decoder\n");
        return 0;
    }

    flac_decoder_context context;
    memset(&context, 0, sizeof(context));

    context.input_data = input_data;
    context.input_length = input_length;
    context.input_position = 0;
    context.streaming_mode = streaming_mode;
    context.pcm_callback = pcm_callback;
    context.pcm_callback_user_data = pcm_callback_user_data;

    if (!streaming_mode) {
        if (!ensure_buffer_capacity(&context, INITIAL_BUFFER_CAPACITY)) {
            fprintf(stderr, "[HXFLAC] %s\n", context.error_message);
            FLAC__stream_decoder_delete(decoder);
            return 0;
        }
    }

    FLAC__StreamDecoderInitStatus init_status;

    #if defined(FLAC__HAS_OGG) && FLAC__HAS_OGG
    if (ogg_flac) {
        init_status = FLAC__stream_decoder_init_ogg_stream(
            decoder,
            read_callback,
            seek_callback,
            tell_callback,
            length_callback,
            eof_callback,
            write_callback,
            metadata_callback,
            error_callback,
            &context
        );
    } else {
        init_status = FLAC__stream_decoder_init_stream(
            decoder,
            read_callback,
            seek_callback,
            tell_callback,
            length_callback,
            eof_callback,
            write_callback,
            metadata_callback,
            error_callback,
            &context
        );
    }
    #else
    init_status = FLAC__stream_decoder_init_stream(
        decoder,
        read_callback,
        seek_callback,
        tell_callback,
        length_callback,
        eof_callback,
        write_callback,
        metadata_callback,
        error_callback,
        &context
    );
    #endif

    if (init_status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        fprintf(stderr, "[HXFLAC] Initializing decoder failed: %s\n",
                FLAC__StreamDecoderInitStatusString[init_status]);
        free(context.pcm_buffer);
        FLAC__stream_decoder_delete(decoder);
        return 0;
    }

    DEBUG_PRINT("[HXFLAC] Decoder initialized successfully, starting processing...\n");

    FLAC__bool success = FLAC__stream_decoder_process_until_end_of_stream(decoder);

    if (!success) {
        FLAC__StreamDecoderState state = FLAC__stream_decoder_get_state(decoder);
        fprintf(stderr, "[HXFLAC] Decoding failed: %s\n",
                FLAC__StreamDecoderStateString[state]);

        if (context.error) {
            fprintf(stderr, "[HXFLAC] Context error: %s\n", context.error_message);
        }
    }

    FLAC__stream_decoder_finish(decoder);
    FLAC__stream_decoder_delete(decoder);

    if (context.error || !success) {
        free(context.pcm_buffer);
        return 0;
    }

    if (context.sample_rate == 0 || context.channels == 0 || context.bits_per_sample == 0) {
        fprintf(stderr, "[HXFLAC] Decoder finished but stream info is missing\n");
        free(context.pcm_buffer);
        return 0;
    }

    if (!streaming_mode && context.pcm_buffer_size == 0) {
        fprintf(stderr, "[HXFLAC] Decoding produced no PCM output\n");
        free(context.pcm_buffer);
        return 0;
    }

    *sample_rate = context.sample_rate;
    *channels = context.channels;
    *bits_per_sample = context.bits_per_sample;

    if (!streaming_mode) {
        *output_data = context.pcm_buffer;
        *output_length = context.pcm_buffer_size;
    }

    DEBUG_PRINT("[HXFLAC] Decode successful: %u Hz, %u channels, %u bps\n",
                context.sample_rate, context.channels, context.bits_per_sample);

    return 1;
}

int decode_flac_data(
    const unsigned char* input_data,
    size_t input_length,
    unsigned char** output_data,
    size_t* output_length,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
) {
    return decode_flac_internal(
        input_data,
        input_length,
        output_data,
        output_length,
        NULL,
        NULL,
        0,
        sample_rate,
        channels,
        bits_per_sample
    );
}

int decode_flac_data_streaming(
    const unsigned char* input_data,
    size_t input_length,
    flac_pcm_write_callback pcm_callback,
    void* pcm_callback_user_data,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
) {
    return decode_flac_internal(
        input_data,
        input_length,
        NULL,
        NULL,
        pcm_callback,
        pcm_callback_user_data,
        1,
        sample_rate,
        channels,
        bits_per_sample
    );
}

void free_flac_decoded_data(unsigned char* data) {
    free(data);
}

typedef struct {
    unsigned char* data;
    size_t size;
    size_t capacity;
    size_t read_offset;
} flac_session_queue;

struct flac_stream_session {
    FLAC__StreamDecoder* decoder;
    flac_decoder_context context;

    flac_session_queue queue;

    int initialized;
    int finished;
    int failed;
    int reached_streaminfo;
};

static int queue_reserve(flac_session_queue* queue, size_t additional) {
    size_t required = 0;
    if (!safe_add_size(queue->size, additional, &required)) {
        return 0;
    }

    if (required <= queue->capacity) {
        return 1;
    }

    size_t new_capacity = queue->capacity == 0 ? INITIAL_BUFFER_CAPACITY : queue->capacity;
    while (new_capacity < required) {
        if (new_capacity > SIZE_MAX / 2) {
            new_capacity = required;
            break;
        }
        new_capacity *= 2;
    }

    unsigned char* new_data = (unsigned char*)realloc(queue->data, new_capacity);
    if (!new_data) {
        return 0;
    }

    queue->data = new_data;
    queue->capacity = new_capacity;
    return 1;
}

static void queue_compact(flac_session_queue* queue) {
    if (queue->read_offset == 0) {
        return;
    }

    if (queue->read_offset >= queue->size) {
        queue->read_offset = 0;
        queue->size = 0;
        return;
    }

    memmove(queue->data, queue->data + queue->read_offset, queue->size - queue->read_offset);
    queue->size -= queue->read_offset;
    queue->read_offset = 0;
}

static int queue_push(flac_session_queue* queue, const unsigned char* data, size_t size) {
    if (size == 0) {
        return 1;
    }

    queue_compact(queue);

    if (!queue_reserve(queue, size)) {
        return 0;
    }

    memcpy(queue->data + queue->size, data, size);
    queue->size += size;
    return 1;
}

static size_t queue_available(const flac_session_queue* queue) {
    if (queue->size < queue->read_offset) {
        return 0;
    }
    return queue->size - queue->read_offset;
}

static size_t queue_pop(flac_session_queue* queue, unsigned char* output, size_t output_capacity) {
    size_t available = queue_available(queue);
    size_t to_copy = available < output_capacity ? available : output_capacity;

    if (to_copy == 0) {
        return 0;
    }

    memcpy(output, queue->data + queue->read_offset, to_copy);
    queue->read_offset += to_copy;

    if (queue->read_offset == queue->size) {
        queue->read_offset = 0;
        queue->size = 0;
    }

    return to_copy;
}

static FLAC__StreamDecoderWriteStatus session_write_callback(
    const FLAC__StreamDecoder* decoder,
    const FLAC__Frame* frame,
    const FLAC__int32* const buffers[],
    void* client_data
) {
    (void)decoder;

    flac_stream_session* session = (flac_stream_session*)client_data;
    flac_decoder_context* context = &session->context;

    const unsigned channels = frame->header.channels;
    const unsigned samples = frame->header.blocksize;
    const unsigned bits_per_sample = frame->header.bits_per_sample;
    const unsigned sample_rate = frame->header.sample_rate;
    const unsigned bytes_per_sample = (unsigned)get_bytes_per_sample(bits_per_sample);

    if (!validate_streaminfo(context, sample_rate, channels, bits_per_sample)) {
        session->failed = 1;
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    session->reached_streaminfo = 1;

    size_t sample_count = 0;
    size_t frame_size = 0;

    if (!safe_mul_size((size_t)samples, (size_t)channels, &sample_count) ||
        !safe_mul_size(sample_count, (size_t)bytes_per_sample, &frame_size)) {
        set_error(context, "[HXFLAC] Session frame size overflow");
        session->failed = 1;
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    unsigned char* temp = (unsigned char*)malloc(frame_size);
    if (!temp) {
        set_error(context, "[HXFLAC] Session temp buffer allocation failed");
        session->failed = 1;
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    convert_samples_packed_le(buffers, channels, samples, bytes_per_sample, temp);

    if (!queue_push(&session->queue, temp, frame_size)) {
        free(temp);
        set_error(context, "[HXFLAC] Session queue allocation failed");
        session->failed = 1;
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    free(temp);
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

static void session_metadata_callback(
    const FLAC__StreamDecoder* decoder,
    const FLAC__StreamMetadata* metadata,
    void* client_data
) {
    (void)decoder;

    flac_stream_session* session = (flac_stream_session*)client_data;
    flac_decoder_context* context = &session->context;

    if (metadata->type == FLAC__METADATA_TYPE_STREAMINFO) {
        const unsigned sample_rate = metadata->data.stream_info.sample_rate;
        const unsigned channels = metadata->data.stream_info.channels;
        const unsigned bits_per_sample = metadata->data.stream_info.bits_per_sample;

        if (!validate_streaminfo(context, sample_rate, channels, bits_per_sample)) {
            session->failed = 1;
            return;
        }

        session->reached_streaminfo = 1;
    }
}

static void session_error_callback(
    const FLAC__StreamDecoder* decoder,
    FLAC__StreamDecoderErrorStatus status,
    void* client_data
) {
    (void)decoder;

    flac_stream_session* session = (flac_stream_session*)client_data;
    set_error(&session->context, "[HXFLAC] Session decoder error: %s",
              FLAC__StreamDecoderErrorStatusString[status]);
    session->failed = 1;
}

static int session_process_until_queue_has_data(flac_stream_session* session) {
    if (!session || session->failed || session->finished) {
        return 0;
    }

    while (queue_available(&session->queue) == 0 && !session->finished && !session->failed) {
        FLAC__bool ok = FLAC__stream_decoder_process_single(session->decoder);
        if (!ok) {
            session->failed = 1;
            break;
        }

        FLAC__StreamDecoderState state = FLAC__stream_decoder_get_state(session->decoder);
        if (state == FLAC__STREAM_DECODER_END_OF_STREAM) {
            session->finished = 1;
            break;
        }
    }

    return session->failed ? 0 : 1;
}

flac_stream_session* flac_stream_open(
    const unsigned char* input_data,
    size_t input_length
) {
    if (!input_data || input_length == 0) {
        return NULL;
    }

    int native_flac = is_native_flac(input_data, input_length);
#if defined(FLAC__HAS_OGG) && FLAC__HAS_OGG
    int ogg_flac = is_ogg_flac(input_data, input_length);
#else
    int ogg_flac = 0;
#endif

    if (!native_flac && !ogg_flac) {
        return NULL;
    }

    flac_stream_session* session = (flac_stream_session*)calloc(1, sizeof(flac_stream_session));
    if (!session) {
        return NULL;
    }

    session->decoder = FLAC__stream_decoder_new();
    if (!session->decoder) {
        free(session);
        return NULL;
    }

    session->context.input_data = input_data;
    session->context.input_length = input_length;
    session->context.input_position = 0;

    FLAC__StreamDecoderInitStatus init_status;

    #if defined(FLAC__HAS_OGG) && FLAC__HAS_OGG
    if (ogg_flac) {
        init_status = FLAC__stream_decoder_init_ogg_stream(
            session->decoder,
            read_callback,
            seek_callback,
            tell_callback,
            length_callback,
            eof_callback,
            session_write_callback,
            session_metadata_callback,
            session_error_callback,
            session
        );
    } else {
        init_status = FLAC__stream_decoder_init_stream(
            session->decoder,
            read_callback,
            seek_callback,
            tell_callback,
            length_callback,
            eof_callback,
            session_write_callback,
            session_metadata_callback,
            session_error_callback,
            session
        );
    }
    #else
    init_status = FLAC__stream_decoder_init_stream(
        session->decoder,
        read_callback,
        seek_callback,
        tell_callback,
        length_callback,
        eof_callback,
        session_write_callback,
        session_metadata_callback,
        session_error_callback,
        session
    );
    #endif

    if (init_status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        FLAC__stream_decoder_delete(session->decoder);
        free(session);
        return NULL;
    }

    session->initialized = 1;

    while (!session->reached_streaminfo && !session->failed && !session->finished) {
        FLAC__bool ok = FLAC__stream_decoder_process_single(session->decoder);
        if (!ok) {
            session->failed = 1;
            break;
        }

        FLAC__StreamDecoderState state = FLAC__stream_decoder_get_state(session->decoder);
        if (state == FLAC__STREAM_DECODER_END_OF_STREAM) {
            session->finished = 1;
            break;
        }
    }

    if (session->failed) {
        flac_stream_close(session);
        return NULL;
    }

    return session;
}

int flac_stream_get_info(
    flac_stream_session* session,
    unsigned* sample_rate,
    unsigned* channels,
    unsigned* bits_per_sample
) {
    if (!session || !sample_rate || !channels || !bits_per_sample) {
        return 0;
    }

    if (session->context.sample_rate == 0 ||
        session->context.channels == 0 ||
        session->context.bits_per_sample == 0) {
        return 0;
    }

    *sample_rate = session->context.sample_rate;
    *channels = session->context.channels;
    *bits_per_sample = session->context.bits_per_sample;
    return 1;
}

size_t flac_stream_read(
    flac_stream_session* session,
    unsigned char* output,
    size_t output_capacity
) {
    if (!session || !output || output_capacity == 0 || session->failed) {
        return 0;
    }

    if (queue_available(&session->queue) == 0 && !session->finished) {
        if (!session_process_until_queue_has_data(session)) {
            return 0;
        }
    }

    return queue_pop(&session->queue, output, output_capacity);
}

int flac_stream_finished(flac_stream_session* session) {
    if (!session) {
        return 1;
    }

    return session->finished && queue_available(&session->queue) == 0;
}

int flac_stream_failed(flac_stream_session* session) {
    return session ? session->failed : 1;
}

void flac_stream_close(flac_stream_session* session) {
    if (!session) {
        return;
    }

    if (session->decoder) {
        FLAC__stream_decoder_finish(session->decoder);
        FLAC__stream_decoder_delete(session->decoder);
    }

    free(session->queue.data);
    free(session);
}