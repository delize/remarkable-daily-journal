#!/usr/bin/env python3
"""Regenerate tests/fixtures/two-page.pdf.

A minimal, content-free 2-page PDF (~400 bytes, plain text, no streams) used
by tests/generate-native-journal.bats to exercise TEMPLATE_PDF/TEMPLATE_DOC.
Offsets are computed while writing, so the xref table is byte-exact — no
guessed offsets to keep in sync by hand.
"""
import os

objects = []


def add(body):
    objects.append(body)
    return len(objects)


cat = add("<< /Type /Catalog /Pages 2 0 R >>")
add("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>")
add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>")

out = bytearray(b"%PDF-1.4\n")
offsets = [0]
for i, body in enumerate(objects, 1):
    offsets.append(len(out))
    out += f"{i} 0 obj\n{body}\nendobj\n".encode()

xref_off = len(out)
n = len(objects) + 1
out += f"xref\n0 {n}\n0000000000 65535 f \n".encode()
for off in offsets[1:]:
    out += f"{off:010d} 00000 n \n".encode()
out += f"trailer\n<< /Size {n} /Root {cat} 0 R >>\nstartxref\n{xref_off}\n%%EOF\n".encode()

out_path = os.path.join(os.path.dirname(__file__), "..", "tests", "fixtures", "two-page.pdf")
with open(out_path, "wb") as f:
    f.write(out)
print(f"Wrote {out_path} ({len(out)} bytes)")
