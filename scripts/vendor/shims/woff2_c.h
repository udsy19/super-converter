/* C interface to google/woff2 (MIT), so Swift can call it without C++ interop. Built into WOFF2.xcframework by
   scripts/build-vendor.sh. Every function returns 0 on success and a non-zero code on failure. */
#ifndef SC_WOFF2_C_H
#define SC_WOFF2_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* TrueType/OpenType (SFNT) bytes -> WOFF2. `quality` is Brotli's 0...11; `allow_transforms` enables the glyf/loca
   and hmtx transforms (smaller output, the usual choice). On success *out is malloc'ed; release it with
   sc_woff2_free. */
int sc_woff2_encode(const uint8_t *sfnt, size_t sfnt_len, int quality, int allow_transforms,
                    uint8_t **out, size_t *out_len);

/* WOFF2 bytes -> SFNT. On success *out is malloc'ed; release it with sc_woff2_free. */
int sc_woff2_decode(const uint8_t *woff2, size_t woff2_len, uint8_t **out, size_t *out_len);

void sc_woff2_free(void *p);

#ifdef __cplusplus
}
#endif

#endif
