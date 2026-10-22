#include "unalz_c.h"

#include <limits.h>
#include <string.h>

#include "UnAlz.h"

using namespace UNALZ;

struct sc_alz {
    CUnAlz z;
    bool opened = false;
    char password[256] = {0};
};

extern "C" {

sc_alz *sc_alz_open(const char *path, int *error) {
    sc_alz *alz = new sc_alz();
    if (!alz->z.Open(path)) {
        if (error) *error = alz->z.GetLastErr();
        delete alz;
        return nullptr;
    }
    alz->opened = true;
    if (error) *error = 0;
    return alz;
}

void sc_alz_close(sc_alz *alz) {
    if (!alz) return;
    if (alz->opened) alz->z.Close();
    delete alz;
}

size_t sc_alz_count(const sc_alz *alz) { return alz ? const_cast<sc_alz *>(alz)->z.GetFileList()->size() : 0; }

static SAlzLocalFileHeader *entry(const sc_alz *alz, size_t index) {
    if (!alz) return nullptr;
    CUnAlz::FileList *list = const_cast<sc_alz *>(alz)->z.GetFileList();
    return index < list->size() ? &(*list)[index] : nullptr;
}

const char *sc_alz_name(const sc_alz *alz, size_t index) {
    SAlzLocalFileHeader *e = entry(alz, index);
    return e ? e->fileName : nullptr;
}

int64_t sc_alz_size(const sc_alz *alz, size_t index) {
    SAlzLocalFileHeader *e = entry(alz, index);
    return e ? (int64_t)e->uncompressedSize : -1;
}

int sc_alz_is_directory(const sc_alz *alz, size_t index) {
    SAlzLocalFileHeader *e = entry(alz, index);
    return e && (e->head.fileAttribute & ALZ_FILEATTR_DIRECTORY) ? 1 : 0;
}

int sc_alz_is_encrypted(const sc_alz *alz, size_t index) {
    SAlzLocalFileHeader *e = entry(alz, index);
    return e && (e->head.fileDescriptor & ALZ_FILE_DESCRIPTOR_ENCRYPTED) ? 1 : 0;
}

void sc_alz_set_password(sc_alz *alz, const char *password) {
    if (!alz || !password) return;
    strlcpy(alz->password, password, sizeof(alz->password));
    alz->z.SetPassword(alz->password);
}

int sc_alz_extract(sc_alz *alz, size_t index, uint8_t *buf, size_t buf_len) {
    SAlzLocalFileHeader *e = entry(alz, index);
    if (!e) return CUnAlz::ERR_GENERAL;
    if (buf_len > (size_t)INT_MAX || (int64_t)buf_len != (int64_t)e->uncompressedSize) return CUnAlz::ERR_GENERAL;
    CUnAlz::FileList *list = alz->z.GetFileList();
    alz->z.SetCurrentFile(list->begin() + index);
    if (buf_len == 0) return 0;
    return alz->z.ExtractCurrentFileToBuf(buf, (int)buf_len) ? 0 : (int)alz->z.GetLastErr();
}

const char *sc_alz_error_string(int error) {
    static CUnAlz probe;
    return probe.LastErrToStr((CUnAlz::ERR)error);
}

}
