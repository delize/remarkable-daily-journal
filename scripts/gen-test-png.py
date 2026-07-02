#!/usr/bin/env python3
"""Regenerate tests/fixtures/test-template.png.

A minimal, uncompressed 2x2 white PNG (no external deps) used by
tests/generate-native-journal.bats to exercise TEMPLATE_PDF's PNG auto-wrap
(via img2pdf) path.
"""
import os
import struct
import zlib


def chunk(tag, data):
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


width, height = 16, 16
ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB
raw = b"".join(b"\x00" + b"\xff\xff\xff" * width for _ in range(height))
idat = zlib.compress(raw)

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")

out_path = os.path.join(os.path.dirname(__file__), "..", "tests", "fixtures", "test-template.png")
with open(out_path, "wb") as f:
    f.write(png)
print(f"Wrote {out_path} ({len(png)} bytes)")
