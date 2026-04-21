/**
 * my ass c++ coding skills less gooooo
 */

#include "hxflac.hpp"
#include "flac_decoder.h"

#ifndef _WIN32
#include <strings.h>
#endif

#include <cstdlib>
#include <cstring>
#include <climits>
#include <cstdio>

#ifdef __cplusplus
extern "C" {
#endif
#include <FLAC/export.h>
#include <FLAC/metadata.h>
#ifdef __cplusplus
}
#endif

static int string_case_compare(const char* s1, const char* s2)
{
#ifdef _WIN32
    return _stricmp(s1, s2);
#else
    return strcasecmp(s1, s2);
#endif
}

static char* hxflac_strdup(const char* s)
{
    if (!s) return nullptr;

    size_t len = std::strlen(s);
    char* out = (char*)std::malloc(len + 1);
    if (!out) return nullptr;

    std::memcpy(out, s, len + 1);
    return out;
}

static const char* get_flac_version()
{
    return FLAC__VERSION_STRING;
}

typedef struct {
    const FLAC__byte* data;
    size_t size;
    size_t pos;
} MemoryReader;

static size_t memory_read(void* ptr, size_t size, size_t nmemb, FLAC__IOHandle handle)
{
    MemoryReader* reader = (MemoryReader*)handle;
    if (!reader || !ptr || size == 0 || nmemb == 0) {
        return 0;
    }

    if (reader->pos >= reader->size) {
        return 0;
    }

    if (size > SIZE_MAX / nmemb) {
        return 0;
    }

    size_t bytes_to_read = size * nmemb;
    size_t bytes_available = reader->size - reader->pos;

    if (bytes_to_read > bytes_available) {
        bytes_to_read = bytes_available;
    }

    std::memcpy(ptr, reader->data + reader->pos, bytes_to_read);
    reader->pos += bytes_to_read;

    return bytes_to_read / size;
}

static int memory_seek(FLAC__IOHandle handle, FLAC__int64 offset, int whence)
{
    MemoryReader* reader = (MemoryReader*)handle;
    if (!reader) {
        return -1;
    }

    FLAC__int64 base = 0;
    switch (whence) {
        case SEEK_SET:
            base = 0;
            break;
        case SEEK_CUR:
            if (reader->pos > (size_t)LLONG_MAX) return -1;
            base = (FLAC__int64)reader->pos;
            break;
        case SEEK_END:
            if (reader->size > (size_t)LLONG_MAX) return -1;
            base = (FLAC__int64)reader->size;
            break;
        default:
            return -1;
    }

    if ((offset > 0 && base > LLONG_MAX - offset) ||
        (offset < 0 && base < LLONG_MIN - offset)) {
        return -1;
    }

    FLAC__int64 new_pos_signed = base + offset;
    if (new_pos_signed < 0) {
        return -1;
    }

    unsigned long long new_pos_ull = (unsigned long long)new_pos_signed;
    if (new_pos_ull > (unsigned long long)reader->size) {
        return -1;
    }

    reader->pos = (size_t)new_pos_ull;
    return 0;
}

static FLAC__int64 memory_tell(FLAC__IOHandle handle)
{
    MemoryReader* reader = (MemoryReader*)handle;
    if (!reader) {
        return -1;
    }

    if (reader->pos > (size_t)LLONG_MAX) {
        return -1;
    }

    return (FLAC__int64)reader->pos;
}

static int memory_eof(FLAC__IOHandle handle)
{
    MemoryReader* reader = (MemoryReader*)handle;
    return !reader || reader->pos >= reader->size;
}

static int is_native_flac(const unsigned char* input_data, size_t input_length)
{
    return input_data && input_length >= 4 && std::memcmp(input_data, "fLaC", 4) == 0;
}

static int is_ogg_flac(const unsigned char* input_data, size_t input_length)
{
    #if defined(FLAC__HAS_OGG) && FLAC__HAS_OGG
    return input_data && input_length >= 4 && std::memcmp(input_data, "OggS", 4) == 0;
    #else
    (void)input_data;
    (void)input_length;
    return 0;
    #endif
}

static int extract_flac_metadata(
    const unsigned char* input_data,
    size_t input_length,
    const char** title,
    const char** artist,
    const char** album,
    const char** genre,
    const char** year,
    const char** track,
    const char** comment
) {
    if (!title || !artist || !album || !genre || !year || !track || !comment) {
        return 0;
    }

    *title = *artist = *album = *genre = *year = *track = *comment = nullptr;

    if (!input_data || input_length == 0) {
        return 0;
    }

    const FLAC__bool native_flac = is_native_flac(input_data, input_length);
    const FLAC__bool ogg_flac =
        #if defined(FLAC__HAS_OGG) && FLAC__HAS_OGG
        is_ogg_flac(input_data, input_length)
        #else
        false
        #endif
    ;

    if (!native_flac && !ogg_flac) {
        return 0;
    }

    FLAC__Metadata_Chain* chain = FLAC__metadata_chain_new();
    if (!chain) {
        return 0;
    }

    MemoryReader reader;
    reader.data = input_data;
    reader.size = input_length;
    reader.pos = 0;

    FLAC__IOCallbacks callbacks;
    callbacks.read = memory_read;
    callbacks.seek = memory_seek;
    callbacks.tell = memory_tell;
    callbacks.eof = memory_eof;
    callbacks.write = nullptr;

    FLAC__bool ok = false;

    #if defined(FLAC__HAS_OGG) && FLAC__HAS_OGG
    if (ogg_flac) {
        ok = FLAC__metadata_chain_read_ogg_with_callbacks(chain, &reader, callbacks);
    } else {
        ok = FLAC__metadata_chain_read_with_callbacks(chain, &reader, callbacks);
    }
    #else
    ok = FLAC__metadata_chain_read_with_callbacks(chain, &reader, callbacks);
    #endif

    if (!ok) {
        FLAC__metadata_chain_delete(chain);
        return 0;
    }

    FLAC__Metadata_Iterator* iterator = FLAC__metadata_iterator_new();
    if (!iterator) {
        FLAC__metadata_chain_delete(chain);
        return 0;
    }

    FLAC__metadata_iterator_init(iterator, chain);

    int metadata_found = 0;

    do {
        if (FLAC__metadata_iterator_get_block_type(iterator) == FLAC__METADATA_TYPE_VORBIS_COMMENT) {
            FLAC__StreamMetadata* block = FLAC__metadata_iterator_get_block(iterator);
            if (!block) {
                continue;
            }

            FLAC__StreamMetadata_VorbisComment* vorbis_comment = &block->data.vorbis_comment;

            for (unsigned i = 0; i < vorbis_comment->num_comments; i++) {
                FLAC__StreamMetadata_VorbisComment_Entry entry = vorbis_comment->comments[i];

                char* comment_str = (char*)std::malloc(entry.length + 1);
                if (!comment_str) {
                    continue;
                }

                std::memcpy(comment_str, entry.entry, entry.length);
                comment_str[entry.length] = '\0';

                char* equals = std::strchr(comment_str, '=');
                if (equals) {
                    *equals = '\0';
                    char* field_name = comment_str;
                    char* field_value = equals + 1;

                    if (string_case_compare(field_name, "TITLE") == 0 && !*title) {
                        *title = hxflac_strdup(field_value);
                    } else if (string_case_compare(field_name, "ARTIST") == 0 && !*artist) {
                        *artist = hxflac_strdup(field_value);
                    } else if (string_case_compare(field_name, "ALBUM") == 0 && !*album) {
                        *album = hxflac_strdup(field_value);
                    } else if (string_case_compare(field_name, "GENRE") == 0 && !*genre) {
                        *genre = hxflac_strdup(field_value);
                    } else if (
                        (string_case_compare(field_name, "DATE") == 0 ||
                         string_case_compare(field_name, "YEAR") == 0) && !*year
                    ) {
                        *year = hxflac_strdup(field_value);
                    } else if (string_case_compare(field_name, "TRACKNUMBER") == 0 && !*track) {
                        *track = hxflac_strdup(field_value);
                    } else if (string_case_compare(field_name, "COMMENT") == 0 && !*comment) {
                        *comment = hxflac_strdup(field_value);
                    }
                }

                std::free(comment_str);
            }

            metadata_found = 1;
            break;
        }
    } while (FLAC__metadata_iterator_next(iterator));

    FLAC__metadata_iterator_delete(iterator);
    FLAC__metadata_chain_delete(chain);

    return metadata_found;
}

typedef struct {
    hxflac_stream_callback callback;
    void* user_data;
} HXFLACStreamBridge;

static int hxflac_stream_bridge_callback(
    const unsigned char* data,
    size_t size,
    void* user_data
) {
    HXFLACStreamBridge* bridge = (HXFLACStreamBridge*)user_data;
    if (!bridge || !bridge->callback) {
        return 0;
    }

    return bridge->callback(data, size, bridge->user_data);
}

typedef struct {
    flac_stream_session* session;
} HXFLACSessionSlot;

static HXFLACSessionSlot g_hxflac_sessions[256] = {};

static int hxflac_alloc_session_slot(flac_stream_session* session)
{
    if (!session) {
        return -1;
    }

    for (int i = 0; i < 256; ++i) {
        if (g_hxflac_sessions[i].session == nullptr) {
            g_hxflac_sessions[i].session = session;
            return i + 1;
        }
    }

    return -1;
}

static flac_stream_session* hxflac_get_session(int handle)
{
    if (handle <= 0 || handle > 256) {
        return nullptr;
    }

    return g_hxflac_sessions[handle - 1].session;
}

static void hxflac_free_session_slot(int handle)
{
    if (handle <= 0 || handle > 256) {
        return;
    }

    g_hxflac_sessions[handle - 1].session = nullptr;
}

extern "C"
{
    const char* hxflac_get_version_string(void)
    {
        return get_flac_version();
    }

    void hxflac_free_result(unsigned char* data)
    {
        free_flac_decoded_data(data);
    }

    void hxflac_free_string(const char* str)
    {
        if (str) {
            std::free((void*)str);
        }
    }

    int hxflac_to_bytes(
        const unsigned char* input_data,
        size_t input_length,
        unsigned char** output_data,
        size_t* output_length,
        unsigned* sample_rate,
        unsigned* channels,
        unsigned* bits_per_sample
    ) {
        if (!output_data || !output_length || !sample_rate || !channels || !bits_per_sample) {
            return 0;
        }

        *output_data = nullptr;
        *output_length = 0;
        *sample_rate = 0;
        *channels = 0;
        *bits_per_sample = 0;

        if (!input_data || input_length == 0) {
            return 0;
        }

        return decode_flac_data(
            input_data,
            input_length,
            output_data,
            output_length,
            sample_rate,
            channels,
            bits_per_sample
        );
    }

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
    ) {
        return extract_flac_metadata(
            input_data,
            input_length,
            title,
            artist,
            album,
            genre,
            year,
            track,
            comment
        );
    }

    int hxflac_decode_streaming(
        const unsigned char* input_data,
        size_t input_length,
        hxflac_stream_callback callback,
        void* user_data,
        unsigned* sample_rate,
        unsigned* channels,
        unsigned* bits_per_sample
    ) {
        if (!callback || !sample_rate || !channels || !bits_per_sample) {
            return 0;
        }

        *sample_rate = 0;
        *channels = 0;
        *bits_per_sample = 0;

        if (!input_data || input_length == 0) {
            return 0;
        }

        HXFLACStreamBridge bridge;
        bridge.callback = callback;
        bridge.user_data = user_data;

        return decode_flac_data_streaming(
            input_data,
            input_length,
            hxflac_stream_bridge_callback,
            &bridge,
            sample_rate,
            channels,
            bits_per_sample
        );
    }

        int hxflac_stream_open(
        const unsigned char* input_data,
        size_t input_length
    ) {
        if (!input_data || input_length == 0) {
            return -1;
        }

        flac_stream_session* session = flac_stream_open(input_data, input_length);
        if (!session) {
            return -1;
        }

        int handle = hxflac_alloc_session_slot(session);
        if (handle < 0) {
            flac_stream_close(session);
            return -1;
        }

        return handle;
    }

    int hxflac_stream_get_info(
        int handle,
        unsigned* sample_rate,
        unsigned* channels,
        unsigned* bits_per_sample
    ) {
        flac_stream_session* session = hxflac_get_session(handle);
        if (!session) {
            return 0;
        }

        return flac_stream_get_info(session, sample_rate, channels, bits_per_sample);
    }

    size_t hxflac_stream_read(
        int handle,
        unsigned char* output,
        size_t output_capacity
    ) {
        flac_stream_session* session = hxflac_get_session(handle);
        if (!session) {
            return 0;
        }

        return flac_stream_read(session, output, output_capacity);
    }

    int hxflac_stream_finished(int handle) {
        flac_stream_session* session = hxflac_get_session(handle);
        if (!session) {
            return 1;
        }

        return flac_stream_finished(session);
    }

    int hxflac_stream_failed(int handle) {
        flac_stream_session* session = hxflac_get_session(handle);
        if (!session) {
            return 1;
        }

        return flac_stream_failed(session);
    }

    void hxflac_stream_close(int handle) {
        flac_stream_session* session = hxflac_get_session(handle);
        if (!session) {
            return;
        }

        flac_stream_close(session);
        hxflac_free_session_slot(handle);
    }
}