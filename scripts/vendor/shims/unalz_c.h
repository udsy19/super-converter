/* C interface to unalz (zlib licence), the ALZ reader, so Swift can call it without C++ interop. Built into
   UnALZ.xcframework by scripts/build-vendor.sh. Names are converted from CP949 to UTF-8. */
#ifndef SC_UNALZ_C_H
#define SC_UNALZ_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sc_alz sc_alz;

/* Opens and indexes an ALZ archive; NULL on failure with *error set (a CUnAlz::ERR code, see sc_alz_error_string). */
sc_alz *sc_alz_open(const char *path, int *error);
void sc_alz_close(sc_alz *alz);

size_t sc_alz_count(const sc_alz *alz);
const char *sc_alz_name(const sc_alz *alz, size_t index);           /* UTF-8, valid until sc_alz_close */
int64_t sc_alz_size(const sc_alz *alz, size_t index);               /* uncompressed bytes */
int sc_alz_is_directory(const sc_alz *alz, size_t index);
int sc_alz_is_encrypted(const sc_alz *alz, size_t index);

void sc_alz_set_password(sc_alz *alz, const char *password);

/* Decompresses entry `index` into buf (exactly sc_alz_size bytes). Returns 0 on success or an error code. */
int sc_alz_extract(sc_alz *alz, size_t index, uint8_t *buf, size_t buf_len);

const char *sc_alz_error_string(int error);

#ifdef __cplusplus
}
#endif

#endif
