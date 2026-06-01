#!/usr/bin/env python3
"""Rewrite assets/blank-page.rm with SceneInfo.extra_data stripped.

The v6 stencil that ships in this repo was originally captured from a
Paper Pro (rmpp), whose firmware writes trailing scene-render-time bytes
inside the SceneInfo block (custom-zoom params, tool state, etc.). Those
bytes are presentational state for the rmpp itself and are not needed to
re-render the page; older v6 readers (rmscene < 0.7) emit a
"Some data has not been read..." warning when they encounter them.

This script reads the stencil, clears `SceneInfo.extra_data`, and writes
the result back. Re-parsing the output yields zero rmscene warnings, the
file shrinks (~409 → ~300 bytes), and the generator pipeline + on-device
rendering are unaffected.

Run after capturing a new stencil from a device:
    pipx install rmscene
    python3 scripts/clean-stencil.py assets/blank-page.rm
"""
from __future__ import annotations

import io
import pathlib
import sys

from rmscene import read_blocks, write_blocks
from rmscene.scene_stream import SceneInfo


def main(path: str) -> int:
    p = pathlib.Path(path)
    src = p.read_bytes()
    blocks = list(read_blocks(io.BytesIO(src)))
    stripped = 0
    for b in blocks:
        if isinstance(b, SceneInfo) and b.extra_data:
            stripped += len(b.extra_data)
            b.extra_data = b""
    if not stripped:
        print(f"{p}: already clean ({len(src)} bytes)")
        return 0
    buf = io.BytesIO()
    write_blocks(buf, blocks)
    out = buf.getvalue()
    p.write_bytes(out)
    print(f"{p}: stripped {stripped} bytes of SceneInfo.extra_data "
          f"({len(src)} -> {len(out)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1] if len(sys.argv) > 1
                          else "assets/blank-page.rm"))
