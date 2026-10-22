#include "woff2_c.h"

#include <stdlib.h>
#include <woff2/decode.h>
#include <woff2/encode.h>

extern "C" {

int sc_woff2_encode(const uint8_t *sfnt, size_t sfnt_len, int quality, int allow_transforms,
                    uint8_t **out, size_t *out_len) {
    if (!sfnt || !sfnt_len || !out || !out_len) return 1;
    woff2::WOFF2Params params;
    params.brotli_quality = quality;
    params.allow_transforms = allow_transforms != 0;
    size_t capacity = woff2::MaxWOFF2CompressedSize(sfnt, sfnt_len);
    uint8_t *buffer = static_cast<uint8_t *>(malloc(capacity));
    if (!buffer) return 2;
    size_t used = capacity;
    if (!woff2::ConvertTTFToWOFF2(sfnt, sfnt_len, buffer, &used, params)) {
        free(buffer);
        return 3;
    }
    *out = buffer;
    *out_len = used;
    return 0;
}

int sc_woff2_decode(const uint8_t *woff2_data, size_t woff2_len, uint8_t **out, size_t *out_len) {
    if (!woff2_data || !woff2_len || !out || !out_len) return 1;
    size_t capacity = woff2::ComputeWOFF2FinalSize(woff2_data, woff2_len);
    if (capacity == 0) return 3;
    uint8_t *buffer = static_cast<uint8_t *>(malloc(capacity));
    if (!buffer) return 2;
    if (!woff2::ConvertWOFF2ToTTF(buffer, capacity, woff2_data, woff2_len)) {
        free(buffer);
        return 3;
    }
    *out = buffer;
    *out_len = capacity;
    return 0;
}

void sc_woff2_free(void *p) { free(p); }

}
