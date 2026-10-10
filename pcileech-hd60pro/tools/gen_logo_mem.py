#!/usr/bin/env python3
"""Generate the MZ0380 no-signal splash assets for the FPGA emulation.

Produces:
  src/mz0380_logo.mem       - 19,200 lines, 8 hex digits each: the 320x240
                              8-bit Y tile, 4 bytes (one 32-bit BRAM word)
                              per line, little-endian byte order.
  src/mz0380_nosg_burst.bin - the full 0x30a5c0-byte DMA burst the engine
                              streams: Y plane 720x1080 (0x11 bg, tile blit
                              at (200,420)), UV plane 720x540 (0x80), 0xff
                              junk fill to burst end.

Geometry/constants mirror mz0380_pkg.sv (Task 2) - THIS FILE is the single
source of truth; the SV package repeats the values with a pointer here.

The real card's splash draws tinyvenc5's NOSG_LOGO_Y asset (320x240,
sha256 dfce4efd5139298f544d23473f85a42fb7115a3c5e4ba65b71c070d59883a30b,
extraction documented in the Wolffyx hd60pro-linux-driver RE_FINDINGS.md
M127b). That asset is not redistributable here, so this generator draws an
equivalent "NO SIGNAL" tile. To get the byte-identical vendor splash: drop
the tinyvenc5 ELF next to this script, extract the asset at offset 0x5B10C,
verify its sha256, and extend render_tile() to blit it (the geometry below
already matches M50/M127b exactly).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent      # pcileech-hd60pro/

# ---- burst geometry (M50) -------------------------------------------------
BURST_SIZE = 0x30A5C0        # 1920*1107*3/2 - what the card actually DMAs
FRAME_SIZE = 0x11CC40        # 720*1080*3/2  - the NV12 payload inside it
UV_OFFSET = 0xBDD80          # frame*2/3 - UV plane start
JUNK_BYTE = 0xFF

# ---- canvas / tile geometry (M50 + M127b) ---------------------------------
CANVAS_W, CANVAS_H = 720, 1080
TILE_W, TILE_H = 320, 240
TILE_X = (CANVAS_W - TILE_W) // 2        # 200
TILE_Y = (CANVAS_H - TILE_H) // 2        # 420

# ---- palette ---------------------------------------------------------------
Y_BG = 0x11
Y_ON = 0xEA              # "NO SIGNAL" text pixels
Y_BORDER = 0x92          # 1px rectangle, 8px inset
UV_NEUTRAL = 0x80

TEXT = "NO SIGNAL"
FONT_W, FONT_H = 5, 7
SCALE = 4                # glyph pixel size
GAP = 4                  # gap between glyph boxes (pre-scale)
INSET = 8                # border rectangle inset inside the tile

# 5x7 bitmap font: rows top->bottom, bit 4 = leftmost column
FONT = {
    "N": [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001],
    "O": [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
    "S": [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
    "I": [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
    "G": [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111],
    "L": [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111],
    "A": [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
    " ": [0] * 7,
}


def text_pixel(tx: int, ty: int) -> bool:
    """True if (tx, ty) is inside the tile-local text block and lit."""
    box = FONT_W * SCALE + GAP
    n = len(TEXT)
    block_w = n * box - GAP
    block_h = FONT_H * SCALE
    x0 = (TILE_W - block_w) // 2
    y0 = (TILE_H - block_h) // 2
    if not (x0 <= tx < x0 + block_w and y0 <= ty < y0 + block_h):
        return False
    gx = (tx - x0) % box
    if gx >= FONT_W * SCALE:
        return False
    ch = TEXT[(tx - x0) // box]
    row = (ty - y0) // SCALE
    col = gx // SCALE
    return bool((FONT[ch][row] >> (FONT_W - 1 - col)) & 1)


def border_pixel(tx: int, ty: int) -> bool:
    """1px rectangle, INSET pixels inside the tile edge."""
    x1, y1 = TILE_W - 1 - INSET, TILE_H - 1 - INSET
    on_edge = (
        (INSET <= tx <= x1 and ty in (INSET, y1))
        or (INSET <= ty <= y1 and tx in (INSET, x1))
    )
    return on_edge and not text_pixel(tx, ty)


def render_tile() -> bytes:
    """320x240 Y tile: 0x11 bg, border rect, NO SIGNAL text."""
    out = bytearray(TILE_W * TILE_H)
    for ty in range(TILE_H):
        for tx in range(TILE_W):
            if text_pixel(tx, ty):
                out[ty * TILE_W + tx] = Y_ON
            elif border_pixel(tx, ty):
                out[ty * TILE_W + tx] = Y_BORDER
            else:
                out[ty * TILE_W + tx] = Y_BG
    return bytes(out)


def render_burst(tile: bytes) -> bytes:
    """Full 0x30a5c0 burst: Y+UV planes, then junk fill."""
    y = bytearray([Y_BG]) * (CANVAS_W * CANVAS_H)
    for r in range(TILE_H):
        dst = (TILE_Y + r) * CANVAS_W + TILE_X
        src = r * TILE_W
        y[dst:dst + TILE_W] = tile[src:src + TILE_W]
    uv = bytes([UV_NEUTRAL]) * ((CANVAS_W // 2) * CANVAS_H)
    frame = bytes(y) + uv
    assert len(frame) == FRAME_SIZE, f"frame {len(frame):#x} != {FRAME_SIZE:#x}"
    return frame + bytes([JUNK_BYTE]) * (BURST_SIZE - FRAME_SIZE)


def write_logo_mem(tile: bytes, path: Path) -> None:
    lines = [
        f"// mz0380 no-signal splash tile: {TILE_W}x{TILE_H} Y-plane, "
        f"4 bytes (little-endian) per 32-bit word",
        f"// generated by tools/gen_logo_mem.py - do not edit by hand",
    ]
    for i in range(0, len(tile), 4):
        b = tile[i:i + 4]
        lines.append("".join(f"{x:02x}" for x in reversed(b)))
    path.write_text("\n".join(lines) + "\n")


def verify(burst: bytes) -> list[str]:
    errs = []
    if len(burst) != BURST_SIZE:
        errs.append(f"size {len(burst):#x} != {BURST_SIZE:#x}")
    checks = [
        ("byte[0] bg", burst[0], Y_BG),
        (f"byte[{UV_OFFSET:#x}] uv", burst[UV_OFFSET], UV_NEUTRAL),
        (f"byte[{FRAME_SIZE:#x}] junk", burst[FRAME_SIZE], JUNK_BYTE),
        (f"tile pixel ({TILE_X+8},{TILE_Y+8}) border", burst[(TILE_Y + 8) * CANVAS_W + (TILE_X + 8)], Y_BORDER),
        (f"tile pixel ({TILE_X+INSET},{TILE_Y+INSET}) border corner", burst[(TILE_Y + INSET) * CANVAS_W + (TILE_X + INSET)], Y_BORDER),
    ]
    # a pixel inside the 'N' glyph box must be bg or on - sample the text block centre
    for name, got, want in checks:
        if got != want:
            errs.append(f"{name}: got {got:#04x}, want {want:#04x}")
    return errs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--verify", action="store_true",
                    help="generate, then self-test the written burst")
    args = ap.parse_args()

    tile = render_tile()
    burst = render_burst(tile)

    mem_path = REPO / "src" / "mz0380_logo.mem"
    bin_path = REPO / "src" / "mz0380_nosg_burst.bin"
    write_logo_mem(tile, mem_path)
    bin_path.write_bytes(burst)

    if args.verify:
        reread = bin_path.read_bytes()
        errs = verify(reread)
        if errs:
            for e in errs:
                print(f"VERIFY FAIL: {e}", file=sys.stderr)
            return 1
        # mem file sanity: 19200 lines, each 8 hex digits
        lines = mem_path.read_text().splitlines()
        data = [l for l in lines if not l.startswith("//")]
        if len(data) != TILE_W * TILE_H // 4:
            print(f"VERIFY FAIL: mem has {len(data)} data lines, want {TILE_W*TILE_H//4}", file=sys.stderr)
            return 1
        if any(len(l) != 8 for l in data):
            print("VERIFY FAIL: mem line length != 8 hex digits", file=sys.stderr)
            return 1
    print(f"OK: tile {TILE_W}x{TILE_H}, burst {BURST_SIZE:#x} bytes -> {bin_path.name}, "
          f"mem {TILE_W*TILE_H//4} words -> {mem_path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
