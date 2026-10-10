#!/usr/bin/env python3
"""Fetch the real HD60 Pro EDID from the Wolffyx hd60pro-linux-driver and
convert it to a Vivado $readmemh init file (src/mz0380_edid.mem, 256 lines).

Caches the download in tools/.cache/ and works offline from the cache.
Hard-fails unless exactly 256 bytes are parsed - never fabricates EDID data.
"""

from __future__ import annotations

import re
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent      # pcileech-hd60pro/
URL = ("https://raw.githubusercontent.com/Wolffyx/hd60pro-linux-driver/"
       "master/src/mz0380-edid-hd60pro.txt")
CACHE = Path(__file__).resolve().parent / ".cache" / "mz0380-edid-hd60pro.txt"
OUT = REPO / "src" / "mz0380_edid.mem"
EXPECTED_BYTES = 256


def fetch() -> str:
    if CACHE.exists():
        return CACHE.read_text(encoding="utf-8", errors="replace")
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(URL, timeout=30) as r:
        data = r.read()
    CACHE.write_bytes(data)
    return data.decode("utf-8", errors="replace")


def parse_edid(text: str) -> bytes:
    # EDID here is a comment-headed hex dump: bare 2-digit hex token pairs.
    # Strip comment lines (#), then take bare 2-hex-digit tokens only.
    body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    toks = re.findall(r"(?<![0-9a-fA-Fx])([0-9a-fA-F]{2})(?![0-9a-fA-F])", body)
    if len(toks) != EXPECTED_BYTES:
        raise SystemExit(
            f"fetch_edid: parsed {len(toks)} bytes, need exactly {EXPECTED_BYTES}"
        )
    return bytes(int(t, 16) for t in toks)


def main() -> int:
    text = fetch()
    edid = parse_edid(text)
    lines = [f"{b:02x}" for b in edid]
    OUT.write_text("\n".join(lines) + "\n")
    print(f"OK: {len(edid)} bytes -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
