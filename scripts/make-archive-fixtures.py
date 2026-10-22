"""Writes the 7zz smoke-test fixtures into the directory given as argv[1] (run with `python3 -I`).

No archiver for these formats exists on a stock Mac, so the files are built here from their published layouts, with
the data stored uncompressed: a RAR 5 archive, an ARJ archive and a FAT12 floppy image. Each holds `hello.txt`
(FAT: HELLO.TXT) with the same bytes as `payload/hello.txt`. 7zz must extract them byte for byte.
"""
import struct
import sys
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
            + vint(file_flags) + vint(len(PAYLOAD)) + vint(0x20)    # file flags, unpacked size, attributes
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


def main() -> None:
    out = Path(sys.argv[1])
    (out / "payload").mkdir(parents=True, exist_ok=True)
    (out / "payload" / "hello.txt").write_bytes(PAYLOAD)
    (out / "stored.rar").write_bytes(rar5())
    (out / "stored.arj").write_bytes(arj())
    (out / "floppy.img").write_bytes(fat12())


main()
