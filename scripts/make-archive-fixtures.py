"""Writes the 7zz smoke-test fixtures into the directory given as argv[1] (run with `python3 -I`).

No archiver for these formats exists on a stock Mac, so the files are built here from their published layouts, with
the data stored uncompressed: a RAR 5 archive, an ARJ archive and a FAT12 floppy image. Each holds `hello.txt`
(FAT: HELLO.TXT) with the same bytes as `payload/hello.txt`. 7zz must extract them byte for byte.

With `--corpus DIR` it writes the quality bench's archive corpus instead (see "The archive corpus" below):
`python3 -I scripts/make-archive-fixtures.py --corpus Tests/Corpus/generated/archives`.
"""
import struct
import sys
import time
import zlib
from pathlib import Path

PAYLOAD = b"Hello from Super Converter.\n" * 40
NAME = b"hello.txt"


def vint(n: int) -> bytes:
    out = bytearray()
    while True:
        low = n & 0x7F
        n >>= 7
        out.append(low | (0x80 if n else 0))
        if not n:
            return bytes(out)


def rar5() -> bytes:
    """RAR 5.0: signature, main header, one stored file header + data, end-of-archive header."""
    def block(body: bytes) -> bytes:
        sized = vint(len(body)) + body
        return struct.pack("<I", zlib.crc32(sized)) + sized

    main = block(vint(1) + vint(0) + vint(0))                       # type 1, flags 0, archive flags 0
    file_flags = 0x04                                               # CRC32 of the data follows
    body = (vint(2) + vint(0x02) + vint(len(PAYLOAD))               # type 2, header flags: data area present, data size
            + vint(file_flags) + vint(len(PAYLOAD)) + vint(0o100644)  # file flags, unpacked size, Unix mode
            + struct.pack("<I", zlib.crc32(PAYLOAD))
            + vint(0)                                               # compression info: version 0, method 0 (stored)
            + vint(1) + vint(len(NAME)) + NAME)                     # host OS (Unix), name
    file = block(body) + PAYLOAD
    end = block(vint(5) + vint(0) + vint(0))
    return b"Rar!\x1a\x07\x01\x00" + main + file + end


def arj() -> bytes:
    """ARJ: main header, one stored file (method 0), end marker."""
    def header(first: bytes, name: bytes) -> bytes:
        basic = first + name + b"\0" + b"\0"                        # name and (empty) comment, NUL-terminated
        return (b"\x60\xea" + struct.pack("<H", len(basic)) + basic
                + struct.pack("<I", zlib.crc32(basic)) + struct.pack("<H", 0))

    dos_time = (2025 - 1980) << 25 | 1 << 21 | 1 << 16             # 2025-01-01 00:00:00
    main_first = struct.pack("<BBBBBBBB IIII HH BB", 30, 6, 1, 0, 0, 0, 2, 0,
                             dos_time, dos_time, 0, 0, 0, 0, 0, 0)
    file_first = struct.pack("<BBBBBBBB IIII HHH", 30, 6, 1, 0, 0, 0, 0, 0,
                             dos_time, len(PAYLOAD), len(PAYLOAD), zlib.crc32(PAYLOAD), 0, 0x20, 0)
    return (header(main_first, b"fixture.arj") + header(file_first, NAME) + PAYLOAD
            + b"\x60\xea" + struct.pack("<H", 0))


def fat12() -> bytes:
    """A 1.44 MB FAT12 floppy image holding HELLO.TXT in the root directory."""
    sector = 512
    total = 2880
    fat_sectors = 9
    root_sectors = 14
    image = bytearray(total * sector)
    boot = (b"\xeb\x3c\x90" + b"MSDOS5.0"
            + struct.pack("<HBHBHHBHHHII", sector, 1, 1, 2, 224, total, 0xF0, fat_sectors, 18, 2, 0, 0)
            + struct.pack("<BBBI11s8s", 0, 0, 0x29, 0x12345678, b"SCFIXTURE  ", b"FAT12   "))
    image[:len(boot)] = boot
    image[510:512] = b"\x55\xaa"
    clusters = -(-len(PAYLOAD) // sector)
    fat = bytearray(fat_sectors * sector)
    entries = [0xFF0, 0xFFF] + [c + 3 for c in range(clusters - 1)] + [0xFFF]   # clusters 2.. chained, last = EOF
    for i, value in enumerate(entries):
        offset = i * 3 // 2
        if i % 2 == 0:
            fat[offset] = value & 0xFF
            fat[offset + 1] = (fat[offset + 1] & 0xF0) | (value >> 8)
        else:
            fat[offset] = (fat[offset] & 0x0F) | ((value & 0x0F) << 4)
            fat[offset + 1] = value >> 4
    for copy in range(2):
        start = (1 + copy * fat_sectors) * sector
        image[start:start + len(fat)] = fat
    root = (1 + 2 * fat_sectors) * sector
    date = (2025 - 1980) << 9 | 1 << 5 | 1
    image[root:root + 32] = struct.pack("<11sBBBHHHHHHHI", b"HELLO   TXT", 0x20, 0, 0, 0, date, date, 0, 0, date, 2,
                                        len(PAYLOAD))
    data = root + root_sectors * sector
    image[data:data + len(PAYLOAD)] = PAYLOAD
    return bytes(image)


# MARK: - The archive corpus of the quality bench (quality §8 "Every reader": one fixture per archive format)
#
# `--corpus DIR` writes one fixture per archive format of formats §1 into DIR (Tests/Corpus/generated/archives/) and, for
# each, `expected/<fixture>.json`: the manifest an extraction must reproduce (path, kind, size, SHA-256, link target, and
# for formats that keep them, permissions and modification times). Python's standard library writes ZIP, TAR, gzip,
# bzip2, xz and LZMA; the others are laid out here from their published descriptions; 7Z, ISO, UDF and DMG come from the
# bundled 7zz and macOS's hdiutil. Every fixture is read back by an independent tool (bsdtar, 7zz) where one reads it.
# The bytes repeat on every run except for what 7zz and hdiutil randomise (encryption salts, volume identifiers); the
# contents, and so the expected manifests, always repeat. LZO and rzip fixtures use stored and bzip2 blocks (real lzop
# output is in the self-test's fixtures).

import bz2
import gzip
import hashlib
import io
import json
import lzma
import os
import shutil
import subprocess
import tarfile
import tempfile
import unicodedata
import zipfile

MTIME = 1_700_000_000          # 2023-11-14 22:13:20 UTC: even seconds, so DOS times hold it exactly
SEVENZIP = Path(os.environ.get("SEVENZIP", Path(__file__).resolve().parent.parent / "Vendor/Tools/7zz"))
PASSWORD = "sesame"


def noise(count: int, seed: int = 1) -> bytes:
    """LCG bytes (x = x * 1103515245 + 12345, byte = x >> 16): incompressible but reproducible."""
    out = bytearray()
    x = seed
    for _ in range(count):
        x = (x * 1103515245 + 12345) & 0xFFFFFFFF
        out.append((x >> 16) & 0xFF)
    return bytes(out)


class Item:
    def __init__(self, path: str, kind: str = "file", data: bytes = b"", mode: int = 0o644, link: str = ""):
        self.path = unicodedata.normalize("NFC", path)
        self.kind = kind
        self.data = data
        self.mode = mode if kind != "directory" else 0o755
        self.link = link


# The full tree: folders (one empty), a Unicode name, an executable, an incompressible file and a relative symlink.
FULL = [
    Item("hello.txt", data=PAYLOAD),
    Item("docs", "directory"),
    Item("docs/readme.md", data=b"# Read me\n\nArchive fixture for the Super Converter quality bench.\n"),
    Item("docs/empty", "directory"),
    Item("data", "directory"),
    Item("data/noise.bin", data=noise(32768)),
    Item("tools", "directory"),
    Item("tools/run.sh", data=b"#!/bin/sh\necho run\n", mode=0o755),
    Item("café", "directory"),
    Item("café/naïve résumé.txt", data="Unicode names survive: café, naïve, résumé.\n".encode()),
    Item("link-to-hello", "symlink", link="hello.txt"),
]
# What DOS and Windows formats hold: files in folders, ASCII names, no links, no empty folders.
DOS = [Item("hello.txt", data=PAYLOAD), Item("docs", "directory"), Item("docs/readme.md", data=FULL[2].data),
       Item("data", "directory"), Item("data/noise.bin", data=FULL[5].data)]
# 8.3 names in one folder (ARC).
FLAT = [Item("HELLO.TXT", data=PAYLOAD), Item("README.MD", data=FULL[2].data), Item("NOISE.BIN", data=FULL[5].data)]
SINGLE = [Item("hello.txt", data=PAYLOAD)]


def files_of(items):
    return [i for i in items if i.kind == "file"]


def manifest(items, modes: bool, times: bool) -> dict:
    """Every path an extraction holds, parent folders included."""
    entries = {}
    for i in items:
        parts = i.path.split("/")
        for n in range(1, len(parts)):
            entries.setdefault("/".join(parts[:n]), {"path": "/".join(parts[:n]), "kind": "directory"})
        e = {"path": i.path, "kind": i.kind}
        if i.kind == "file":
            e["size"] = len(i.data)
            e["sha256"] = hashlib.sha256(i.data).hexdigest()
            if modes:
                e["permissions"] = i.mode
            if times:
                e["modified"] = MTIME
        if i.kind == "symlink":
            e["link"] = i.link
        entries[i.path] = e
    return {"modes": modes, "times": times, "entries": sorted(entries.values(), key=lambda e: e["path"])}


def materialise(items, root: Path) -> Path:
    """Lays the items out as real files with the fixed modes and times."""
    root.mkdir(parents=True)
    for i in items:
        p = root / i.path
        if i.kind == "directory":
            p.mkdir(parents=True, exist_ok=True)
        elif i.kind == "symlink":
            p.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(i.link, p)
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(i.data)
            os.chmod(p, i.mode)
    for i in sorted(items, key=lambda i: -i.path.count("/")):
        os.utime(root / i.path, (MTIME, MTIME), follow_symlinks=False)
    return root


def run(*args, cwd=None, stdin=None):
    subprocess.run([str(a) for a in args], cwd=cwd, input=stdin, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# MARK: Writers (standard library)

def zip_bytes(items, extra_files=()) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as z:
        ut = b"UT" + struct.pack("<HBI", 5, 1, MTIME)       # extended timestamp: modification time in Unix seconds
        for name, data in extra_files:
            info = zipfile.ZipInfo(name, time.gmtime(MTIME)[:6])
            info.extra = ut
            info.external_attr = (0o100644 << 16)
            z.writestr(info, data, zipfile.ZIP_DEFLATED)
        for i in items:
            info = zipfile.ZipInfo(i.path + ("/" if i.kind == "directory" else ""), time.gmtime(MTIME)[:6])
            info.extra = ut
            info.create_system = 3
            if i.kind == "directory":
                info.external_attr = (0o040755 << 16) | 0x10
                z.writestr(info, b"")
            elif i.kind == "symlink":
                info.external_attr = (0o120777 << 16)
                z.writestr(info, i.link.encode(), zipfile.ZIP_STORED)
            else:
                info.external_attr = ((0o100000 | i.mode) << 16)
                z.writestr(info, i.data, zipfile.ZIP_DEFLATED)
    return buffer.getvalue()


def tar_bytes(items, prefix: str = "") -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as t:
        for i in items:
            info = tarfile.TarInfo(prefix + i.path)
            info.mtime = MTIME
            info.mode = i.mode
            info.uname = info.gname = ""
            if i.kind == "directory":
                info.type = tarfile.DIRTYPE
                t.addfile(info)
            elif i.kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = i.link
                info.mode = 0o777
                t.addfile(info)
            else:
                info.size = len(i.data)
                t.addfile(info, io.BytesIO(i.data))
    return buffer.getvalue()


def gzip_bytes(data: bytes, name: str = "") -> bytes:
    buffer = io.BytesIO()
    with gzip.GzipFile(filename=name, mode="wb", fileobj=buffer, mtime=MTIME) as g:
        g.write(data)
    return buffer.getvalue()


def compress_z(data: bytes, scratch: Path) -> bytes:
    """Unix compress (LZW) through /usr/bin/compress."""
    source = scratch / "z-input"
    source.write_bytes(data)
    out = subprocess.run(["/usr/bin/compress", "-c", "-f", str(source)], check=True, capture_output=True).stdout
    source.unlink()
    return out


def lzip_bytes(data: bytes) -> bytes:
    """lzip member: "LZIP", version 1, dictionary size 1 MiB, an LZMA stream with its end marker, CRC-32, sizes."""
    stream = lzma.compress(data, format=lzma.FORMAT_RAW,
                           filters=[{"id": lzma.FILTER_LZMA1, "dict_size": 1 << 20, "lc": 3, "lp": 0, "pb": 2}])
    member = b"LZIP\x01\x14" + stream + struct.pack("<I", zlib.crc32(data)) + struct.pack("<Q", len(data))
    return member + struct.pack("<Q", len(member) + 8)


def lzop_bytes(data: bytes, name: str) -> bytes:
    """lzop 1.04 container with stored blocks (what lzop writes for data that does not compress); Adler-32 per block."""
    header = struct.pack(">HHHBBI", 0x1040, 0x20A0, 0x0940, 1, 5, 0x1)       # versions, LZO1X-1, level 5, F_ADLER32_D
    header += struct.pack(">III", 0o100644, MTIME, 0) + bytes([len(name)]) + name.encode()
    out = b"\x89LZO\x00\r\n\x1a\n" + header + struct.pack(">I", zlib.adler32(header))
    for start in range(0, len(data), 256 * 1024):
        block = data[start:start + 256 * 1024]
        out += struct.pack(">III", len(block), len(block), zlib.adler32(block)) + block
    return out + struct.pack(">I", 0)


def rzip_bytes(data: bytes) -> bytes:
    """rzip 2.1: 24-byte header, one chunk of literal commands whose control and literal streams are bzip2 blocks."""
    control = bytearray()
    for start in range(0, len(data), 0xFFFF):
        run_ = data[start:start + 0xFFFF]
        control += bytes([0]) + struct.pack("<H", len(run_))
    control += bytes([0, 0, 0]) + struct.pack("<I", zlib.crc32(data))
    blocks = [bytes(control), data]
    packed = [bz2.compress(b) for b in blocks]
    first = 26
    second = first + 13 + len(packed[0])
    chunk = bytes([3]) + struct.pack("<III", 0, 0, first) + bytes([3]) + struct.pack("<III", 0, 0, second)
    for raw, p in zip(blocks, packed):
        chunk += bytes([4]) + struct.pack("<III", len(p), len(raw), 0) + p
    header = b"RZIP\x02\x01" + struct.pack(">II", len(data) & 0xFFFFFFFF, len(data) >> 32) + bytes(10)
    return header + chunk


def newc_bytes(items, prefix: str = "") -> bytes:
    """A newc cpio archive (also an RPM's payload)."""
    out = bytearray()

    def member(name: str, mode: int, data: bytes, ino: int):
        nonlocal out
        fields = [ino, mode, 0, 0, 1, MTIME, len(data), 0, 0, 0, 0, len(name.encode()) + 1, 0]
        out += b"070701" + "".join("%08X" % f for f in fields).encode() + name.encode() + b"\0"
        out += bytes((4 - len(out) % 4) % 4)
        out += data
        out += bytes((4 - len(out) % 4) % 4)

    for n, i in enumerate(items, start=1):
        if i.kind == "directory":
            member(prefix + i.path, 0o040000 | i.mode, b"", n)
        elif i.kind == "symlink":
            member(prefix + i.path, 0o120777, i.link.encode(), n)
        else:
            member(prefix + i.path, 0o100000 | i.mode, i.data, n)
    member("TRAILER!!!", 0, b"", 0)
    return bytes(out)


def ar_bytes(members) -> bytes:
    out = b"!<arch>\n"
    for name, data in members:
        out += ("%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, MTIME, 0, 0, "100644", len(data))).encode() + data
        if len(data) % 2:
            out += b"\n"
    return out


def rpm_bytes(items) -> bytes:
    """RPM: a 96-byte lead, an empty signature header (padded to 8 bytes), an empty main header, a gzip'd cpio payload."""
    lead = b"\xed\xab\xee\xdb" + bytes([3, 0]) + struct.pack(">HH", 0, 1) + b"fixture-1.0-1".ljust(66, b"\0") + struct.pack(">HH", 1, 5) + bytes(16)
    empty_header = b"\x8e\xad\xe8\x01" + bytes(4) + struct.pack(">II", 0, 0)
    return lead + empty_header + empty_header + gzip_bytes(newc_bytes(items, "./"))


def cab_bytes(items) -> bytes:
    """A cabinet with one MSZIP folder: each CFDATA block is "CK" and a raw deflate stream of up to 32 KiB."""
    files = files_of(items)
    entries, body, offset = b"", b"", 0
    date = (2023 - 1980) << 9 | 11 << 5 | 14
    time_ = 22 << 11 | 13 << 5 | 10
    for i in files:
        entries += struct.pack("<IIHHHH", len(i.data), offset, 0, date, time_, 0x20) + i.path.replace("/", "\\").encode() + b"\0"
        body += i.data
        offset += len(i.data)
    blocks = b""
    count = 0
    for start in range(0, len(body), 32768):
        piece = body[start:start + 32768]
        packer = zlib.compressobj(9, zlib.DEFLATED, -15)
        packed = b"CK" + packer.compress(piece) + packer.flush()
        blocks += struct.pack("<IHH", 0, len(packed), len(piece)) + packed
        count += 1
    files_at = 36 + 8
    data_at = files_at + len(entries)
    total = data_at + len(blocks)
    header = b"MSCF" + struct.pack("<IIIII", 0, total, 0, files_at, 0) + bytes([3, 1]) + struct.pack("<HHHHH", 1, len(files), 0, 1, 0)
    return header + struct.pack("<IHH", data_at, count, 1) + entries + blocks


def lha_bytes(items) -> bytes:
    """LHA level 0 headers with stored (-lh0-) data; folders are part of the names."""
    def crc16(data: bytes) -> int:
        crc = 0
        for b in data:
            crc ^= b
            for _ in range(8):
                crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
        return crc

    out = b""
    stamp = ((2023 - 1980) << 25) | (11 << 21) | (14 << 16) | (22 << 11) | (13 << 5) | 10
    for i in files_of(items):
        name = i.path.replace("/", "\\").encode()
        body = b"-lh0-" + struct.pack("<III", len(i.data), len(i.data), stamp) + bytes([0x20, 0, len(name)]) + name + struct.pack("<H", crc16(i.data))
        out += bytes([len(body), sum(body) & 0xFF]) + body + i.data
    return out + b"\0"


def alz_bytes(items) -> bytes:
    """ALZip: stored entries and folders, names in CP949 with backslashes."""
    out = b"ALZ\x01" + struct.pack("<I", 10)
    stamp = ((2023 - 1980) << 25) | (11 << 21) | (14 << 16) | (22 << 11) | (13 << 5) | 10
    for i in items:
        name = i.path.replace("/", "\\").encode("cp949")
        out += b"BLZ\x01" + struct.pack("<H", len(name))
        if i.kind == "directory":
            out += bytes([0x10]) + struct.pack("<I", stamp) + bytes([0, 0]) + name
        else:
            out += bytes([0x20]) + struct.pack("<I", stamp) + bytes([0x20, 0, 0, 0]) + struct.pack("<IHH", zlib.crc32(i.data), len(i.data), len(i.data)) + name + i.data
    return out


def arc_bytes(items) -> bytes:
    """SEA ARC: a stored entry (method 2) and run-length packed entries (method 3), CRC-16 over the original bytes."""
    def crc16(data: bytes) -> int:
        crc = 0
        for b in data:
            crc ^= b
            for _ in range(8):
                crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
        return crc

    def pack(data: bytes) -> bytes:
        out, n = bytearray(), 0
        while n < len(data):
            b = data[n]
            run_ = 1
            while n + run_ < len(data) and data[n + run_] == b and run_ < 255:
                run_ += 1
            if b == 0x90:
                out += b"\x90\x00"
                n += 1
            elif run_ >= 3:
                out += bytes([b, 0x90, run_])
                n += run_
            else:
                out.append(b)
                n += 1
        return bytes(out)

    date = (2023 - 1980) << 9 | 11 << 5 | 14
    time_ = 22 << 11 | 13 << 5 | 10
    out = b""
    for n, i in enumerate(files_of(items)):
        method, packed = (2, i.data) if n == 0 else (3, pack(i.data))
        out += bytes([0x1A, method]) + i.path.encode().ljust(13, b"\0") + struct.pack("<IHHHI", len(packed), date, time_, crc16(i.data), len(i.data)) + packed
    return out + b"\x1a\x00"


def ace_bytes(items) -> bytes:
    """ACE 2.0 layout with stored entries: header CRC-16 is the low half of the ACE CRC-32 (no final inversion)."""
    def ace_crc(data: bytes) -> int:
        return (~zlib.crc32(data)) & 0xFFFFFFFF

    def header(body: bytes) -> bytes:
        return struct.pack("<HH", ace_crc(body) & 0xFFFF, len(body)) + body

    stamp = ((2023 - 1980) << 25) | (11 << 21) | (14 << 16) | (22 << 11) | (13 << 5) | 10
    main = bytes([0]) + struct.pack("<H", 0) + b"**ACE**" + bytes([20, 20, 2, 0]) + struct.pack("<I", stamp) + bytes(8) + bytes([0])
    out = header(main)
    for i in items:
        if i.kind == "symlink":
            continue
        name = i.path.replace("/", "\\").encode()
        attributes = 0x10 if i.kind == "directory" else 0x20
        body = (bytes([1]) + struct.pack("<H", 1) + struct.pack("<IIIII", len(i.data), len(i.data), stamp, attributes, ace_crc(i.data))
                + bytes([0, 0]) + struct.pack("<HH", 0x000A, 0) + struct.pack("<H", len(name)) + name)
        out += header(body) + i.data
    return out


def eml_bytes() -> bytes:
    import base64
    one, two = FULL[5].data, FULL[2].data
    return ("From: Fixture <fixture@example.com>\r\nTo: Bench <bench@example.com>\r\nSubject: Two attachments\r\n"
            "Date: Tue, 14 Nov 2023 22:13:20 +0000\r\nMIME-Version: 1.0\r\n"
            "Content-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n--b1\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
            "The attachments are noise.bin and readme.md.\r\n--b1\r\n"
            "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"noise.bin\"\r\n"
            "Content-Transfer-Encoding: base64\r\n\r\n" + base64.encodebytes(one).decode().replace("\n", "\r\n") +
            "--b1\r\nContent-Type: text/markdown\r\nContent-Disposition: attachment; filename=\"readme.md\"\r\n"
            "Content-Transfer-Encoding: base64\r\n\r\n" + base64.encodebytes(two).decode().replace("\n", "\r\n") +
            "--b1--\r\n").encode()


def raw_zip(names_and_data) -> bytes:
    """A ZIP with stored entries whose names are the given raw bytes, UTF-8 flag clear (as old tools wrote them)."""
    out, central = b"", b""
    for name, data in names_and_data:
        crc = zlib.crc32(data)
        offset = len(out)
        common = struct.pack("<HHHHHIII", 10, 0, 0, 0x5D6E, 0x576F, crc, len(data), len(data))
        out += b"PK\x03\x04" + common + struct.pack("<HH", len(name), 0) + name + data
        central += (b"PK\x01\x02" + struct.pack("<H", 20) + common + struct.pack("<HHHHHII", len(name), 0, 0, 0, 0, 0, offset) + name)
    return out + central + b"PK\x05\x06" + struct.pack("<HHHHIIH", 0, 0, len(names_and_data), len(names_and_data), len(central), len(out), 0)


# MARK: The corpus

def check_with(tool: str, fixture: Path, expected: dict, scratch: Path, password: str = ""):
    """Extracts `fixture` with an independent reader and compares names, sizes and hashes with the manifest."""
    out = scratch / ("check-" + fixture.name)
    out.mkdir()
    if tool == "bsdtar":
        run("/usr/bin/tar", "-xf", fixture, "-C", out)
    else:
        run(SEVENZIP, "x", "-y", "-snl", "-p" + password, "-o" + str(out), fixture)
    got = {}
    for dirpath, dirnames, filenames in os.walk(out):
        for name in dirnames + filenames:
            p = Path(dirpath) / name
            rel = unicodedata.normalize("NFC", str(p.relative_to(out)))
            got[rel] = p
    want = {e["path"] for e in expected["entries"]}
    if set(got) != want:
        raise SystemExit(f"{fixture.name}: {tool} lists {sorted(set(got) ^ want)}")
    for e in expected["entries"]:
        p = got[e["path"]]
        if e["kind"] == "file" and hashlib.sha256(p.read_bytes()).hexdigest() != e["sha256"]:
            raise SystemExit(f"{fixture.name}: {e['path']} differs")
    shutil.rmtree(out)


def corpus(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    (out / "expected").mkdir(exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="archive-corpus-"))
    full_tree = materialise(FULL, scratch / "full")
    dos_tree = materialise(DOS, scratch / "dos")
    tar = tar_bytes(FULL)
    written = {}

    def put(name: str, data: bytes, items, modes=False, times=False, check=None, password=""):
        path = out / name
        path.write_bytes(data)
        expected = manifest(items, modes, times)
        (out / "expected" / (name + ".json")).write_text(json.dumps(expected, indent=1, ensure_ascii=False) + "\n")
        if check:
            check_with(check, path, expected, scratch, password)
        written[name] = len(data)

    def made(name: str, items, modes=False, times=False, check=None, password=""):
        put(name, (out / name).read_bytes(), items, modes, times, check, password)

    put("tree.zip", zip_bytes(FULL), FULL, True, True, "bsdtar")
    put("tree.jar", zip_bytes([i for i in FULL if i.kind != "symlink"], [("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\r\n\r\n")]),
        [Item("META-INF", "directory"), Item("META-INF/MANIFEST.MF", data=b"Manifest-Version: 1.0\r\n\r\n")] + [i for i in FULL if i.kind != "symlink"],
        True, True, "bsdtar")
    put("tree.tar", tar, FULL, True, True, "bsdtar")
    for name in ["tree.tar.gz", "tree.tgz"]:
        put(name, gzip_bytes(tar), FULL, True, True, "bsdtar")
    for name in ["tree.tar.bz2", "tree.tbz2", "tree.tbz", "tree.tar.bz"]:
        put(name, bz2.compress(tar), FULL, True, True, "bsdtar")
    put("tree.tar.xz", lzma.compress(tar), FULL, True, True, "bsdtar")
    for name in ["tree.tar.z", "tree.tz"]:
        put(name, compress_z(tar, scratch), FULL, True, True, "bsdtar")
    for name in ["tree.tar.lzo", "tree.tzo"]:
        put(name, lzop_bytes(tar, "tree.tar"), FULL, True, True)
    put("tree.cpio", newc_bytes(FULL), FULL, True, True, "bsdtar")
    put("tool.deb", ar_bytes([("debian-binary", b"2.0\n"), ("control.tar.gz", gzip_bytes(tar_bytes([Item("control", data=b"Package: fixture\nVersion: 1.0\n")], "./"))),
                              ("data.tar.xz", lzma.compress(tar_bytes(FULL, "./")))]), FULL, True, True)
    put("tool.rpm", rpm_bytes(FULL), FULL, True, True, "bsdtar")
    put("tree.cab", cab_bytes(DOS), DOS, check="bsdtar")
    put("tree.lha", lha_bytes(DOS), DOS, check="bsdtar")
    put("tree.alz", alz_bytes(DOS), DOS)
    put("tree.arc", arc_bytes(FLAT), FLAT)
    put("tree.ace", ace_bytes(DOS), DOS)
    put("stored.rar", rar5(), SINGLE, check="bsdtar")
    put("stored.arj", arj(), SINGLE, check="7zz")
    put("floppy.img", fat12(), [Item("HELLO.TXT", data=PAYLOAD)], check="7zz")
    put("message.eml", eml_bytes(), [Item("noise.bin", data=FULL[5].data), Item("readme.md", data=FULL[2].data)])

    # Single compressed files: the one file inside is named after the fixture.
    put("hello.txt.gz", gzip_bytes(PAYLOAD, "hello.txt"), SINGLE)
    put("hello.txt.bz2", bz2.compress(PAYLOAD), SINGLE)
    put("hello.txt.bz", bz2.compress(PAYLOAD), SINGLE)
    put("hello.txt.xz", lzma.compress(PAYLOAD), SINGLE)
    put("hello.txt.lzma", lzma.compress(PAYLOAD, format=lzma.FORMAT_ALONE), SINGLE)
    put("hello.txt.lz", lzip_bytes(PAYLOAD), SINGLE)
    put("hello.txt.z", compress_z(PAYLOAD, scratch), SINGLE)
    put("hello.txt.lzo", lzop_bytes(PAYLOAD, "hello.txt"), SINGLE)
    put("hello.txt.rz", rzip_bytes(PAYLOAD), SINGLE)

    # Legacy file names (formats §5 "File-name encoding"): CP437 and Shift-JIS, UTF-8 flag clear.
    put("cp437.zip", raw_zip([("café/naïve.txt".encode("cp437"), b"cp437\n")]), [Item("café/naïve.txt", data=b"cp437\n")])
    put("shift-jis.zip", raw_zip([("日本語/ファイル.txt".encode("shift_jis"), b"sjis\n")]), [Item("日本語/ファイル.txt", data=b"sjis\n")])

    # Hostile archives (quality §8 "Safety"): names that climb out are dropped, an absolute name lands inside (as bsdtar
    # does), links that point outside are dropped.
    put("zip-slip.zip", raw_zip([(b"../evil.txt", b"evil"), (b"/tmp/absolute.txt", b"abs\n"), (b"a/../../evil2.txt", b"evil"),
                                 (b"ok/fine.txt", b"fine\n")]), [Item("tmp/absolute.txt", data=b"abs\n"), Item("ok/fine.txt", data=b"fine\n")])
    escape = io.BytesIO()
    with tarfile.open(fileobj=escape, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, target in [("outside", "../../etc"), ("absolute", "/etc/passwd")]:
            info = tarfile.TarInfo(name)
            info.type, info.linkname, info.mtime = tarfile.SYMTYPE, target, MTIME
            t.addfile(info)
        info = tarfile.TarInfo("outside/passwd")
        info.size, info.mtime = 4, MTIME
        t.addfile(info, io.BytesIO(b"evil"))
        info = tarfile.TarInfo("safe.txt")
        info.size, info.mtime = 5, MTIME
        t.addfile(info, io.BytesIO(b"safe\n"))
    put("link-escape.tar", escape.getvalue(), [Item("outside", "directory"), Item("outside/passwd", data=b"evil"), Item("safe.txt", data=b"safe\n")])

    # Made by the bundled 7zz: 7Z, TAR in 7Z, AES-256 ZIP, ZipCrypto ZIP, 7Z with encrypted names.
    if SEVENZIP.exists():
        run(SEVENZIP, "a", "-t7z", "-snl", "-mx=5", out / "tree.7z", str(full_tree) + "/*")
        made("tree.7z", FULL, True, True, "bsdtar")
        (scratch / "tree.tar").write_bytes(tar)
        os.utime(scratch / "tree.tar", (MTIME, MTIME))
        run(SEVENZIP, "a", "-t7z", "-mx=5", out / "tree.tar.7z", scratch / "tree.tar")
        made("tree.tar.7z", FULL, True, True)
        run(SEVENZIP, "a", "-tzip", "-mem=AES256", "-p" + PASSWORD, out / "aes.zip", str(dos_tree) + "/*")
        made("aes.zip", DOS, check="7zz", password=PASSWORD)
        run(SEVENZIP, "a", "-tzip", "-mem=ZipCrypto", "-p" + PASSWORD, out / "zipcrypto.zip", str(dos_tree) + "/*")
        made("zipcrypto.zip", DOS, check="7zz", password=PASSWORD)
        run(SEVENZIP, "a", "-t7z", "-mhe=on", "-p" + PASSWORD, out / "secret.7z", str(dos_tree) + "/*")
        made("secret.7z", DOS, check="7zz", password=PASSWORD)

    # Made by macOS: an ISO 9660 + Joliet image, a UDF image and a compressed HFS+ disk image.
    if Path("/usr/bin/hdiutil").exists():
        for name, kind in [("tree.iso", "-iso"), ("udf.iso", "-udf")]:
            (out / name).unlink(missing_ok=True)
            run("/usr/bin/hdiutil", "makehybrid", "-quiet", kind, *(["-joliet"] if kind == "-iso" else []), "-default-volume-name", "FIXTURE",
                "-o", out / name, dos_tree)
            made(name, DOS, check="7zz")
        (out / "tree.dmg").unlink(missing_ok=True)
        run("/usr/bin/hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "UDZO", "-volname", "Fixture", "-srcfolder", full_tree, out / "tree.dmg")
        made("tree.dmg", FULL, True, True)

    shutil.rmtree(scratch)
    print(f"{len(written)} archive fixtures, {sum(written.values()) // 1024} KB")


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--corpus":
        corpus(Path(sys.argv[2]))
        return
    out = Path(sys.argv[1])
    (out / "payload").mkdir(parents=True, exist_ok=True)
    (out / "payload" / "hello.txt").write_bytes(PAYLOAD)
    (out / "stored.rar").write_bytes(rar5())
    (out / "stored.arj").write_bytes(arj())
    (out / "floppy.img").write_bytes(fat12())


main()
