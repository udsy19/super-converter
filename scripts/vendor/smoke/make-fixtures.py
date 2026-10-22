#!/usr/bin/env python3
"""Writes the byte-exact fixtures the vendor smoke tests read: `sample.alz` (one stored and one deflated entry,
the layout CUnAlz parses) and `sample.dng` (a 16-bit 32x32 RGGB Bayer DNG). Standard library only.

    make-fixtures.py <output-directory>
"""
import os
import struct
import sys
import zlib

ALZ_FILES = [
    ("hello.txt", b"hello from the ALZ fixture\n", 0),                    # stored
    ("deep/data.bin", bytes(range(256)) * 8, 2),                          # deflate
]


def alz(path):
    out = bytearray(b"ALZ\x01" + struct.pack("<I", 10))
    for name, data, method in ALZ_FILES:
        raw = name.encode()
        body = data
        if method == 2:
            comp = zlib.compressobj(9, zlib.DEFLATED, -15)
            body = comp.compress(data) + comp.flush()
        out += b"BLZ\x01"
        out += struct.pack("<hBIBB", len(raw), 0x20, 0x5A8F0000, 0x40, 0)   # head: 4-byte size fields
        out += struct.pack("<BBI", method, 0, zlib.crc32(data) & 0xFFFFFFFF)
        out += struct.pack("<II", len(body), len(data))
        out += raw + body
    out += b"CLZ\x01" + b"\0" * 8 + struct.pack("<I", 0x035A4C43) + b"CLZ\x02"
    with open(path, "wb") as f:
        f.write(out)


def dng(path, width=32, height=32):
    def ifd_entry(tag, typ, count, value):
        return struct.pack("<HHI", tag, typ, count) + value

    pixels = b"".join(struct.pack("<H", 1000 + 4000 * ((x + y) % 8)) for y in range(height) for x in range(width))
    blobs = {}
    entries = []

    def add(tag, typ, count, payload):
        entries.append((tag, typ, count, payload))

    ASCII, SHORT, LONG, RATIONAL, BYTE, SRATIONAL = 2, 3, 4, 5, 1, 10
    add(254, LONG, 1, struct.pack("<I", 0))
    add(256, LONG, 1, struct.pack("<I", width))
    add(257, LONG, 1, struct.pack("<I", height))
    add(258, SHORT, 1, struct.pack("<H", 16))
    add(259, SHORT, 1, struct.pack("<H", 1))
    add(262, SHORT, 1, struct.pack("<H", 32803))
    add(271, ASCII, 5, b"Test\0")
    add(272, ASCII, 10, b"Synthetic\0")
    add(273, LONG, 1, None)                                  # strip offset, patched below
    add(277, SHORT, 1, struct.pack("<H", 1))
    add(278, LONG, 1, struct.pack("<I", height))
    add(279, LONG, 1, struct.pack("<I", len(pixels)))
    add(33421, SHORT, 2, struct.pack("<HH", 2, 2))
    add(33422, BYTE, 4, bytes([0, 1, 1, 2]))
    add(50706, BYTE, 4, bytes([1, 4, 0, 0]))
    add(50708, ASCII, 15, b"Test Synthetic\0")
    add(50717, LONG, 1, struct.pack("<I", 65535))
    add(50721, SRATIONAL, 9, b"".join(struct.pack("<ii", n, 10000) for n in (6000, 0, 0, 0, 10000, 0, 0, 0, 6000)))
    add(50728, RATIONAL, 3, b"".join(struct.pack("<II", 1, 1) for _ in range(3)))
    add(50778, SHORT, 1, struct.pack("<H", 21))
    entries.sort(key=lambda e: e[0])

    header = b"II*\0" + struct.pack("<I", 8)
    ifd_size = 2 + 12 * len(entries) + 4
    cursor = 8 + ifd_size
    extra = bytearray()
    table = bytearray()
    strip_offset = None
    for tag, typ, count, payload in entries:
        if tag == 273:
            strip_offset = len(table)                        # fix up after layout
            table += struct.pack("<HHI", tag, typ, count) + b"\0\0\0\0"
            continue
        if len(payload) <= 4:
            table += struct.pack("<HHI", tag, typ, count) + payload.ljust(4, b"\0")
        else:
            table += struct.pack("<HHI", tag, typ, count) + struct.pack("<I", cursor + len(extra))
            extra += payload + (b"\0" if len(payload) % 2 else b"")
    data_offset = cursor + len(extra)
    table[strip_offset + 8:strip_offset + 12] = struct.pack("<I", data_offset)
    blob = header + struct.pack("<H", len(entries)) + bytes(table) + struct.pack("<I", 0) + bytes(extra) + pixels
    with open(path, "wb") as f:
        f.write(blob)


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    alz(os.path.join(out, "sample.alz"))
    dng(os.path.join(out, "sample.dng"))
