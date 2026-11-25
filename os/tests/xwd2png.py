#!/usr/bin/env python3
"""Converts the screen file of Xvfb (-fbdir: an XWD image) into a PNG. usage: xwd2png.py IN.xwd OUT.png"""
import struct, sys, zlib
d = open(sys.argv[1], "rb").read()
hs, ver, fmt, depth, w, h, xoff, bo, bu, bbo, bp, bpp, bpl, vc, rm, gm, bm, bpr, cs, ncol, ww = struct.unpack(">21I", d[:84])
if w == 0 or h == 0:
    sys.exit("no image in the file (header is empty)")
off = hs + ncol * 12
rows, nz = [], 0
for y in range(h):
    row = d[off + y * bpl: off + y * bpl + w * 4]
    out = bytearray()
    for x in range(w):
        b, g, r = row[4 * x], row[4 * x + 1], row[4 * x + 2]
        out += bytes((r, g, b))
        nz += 1 if (r or g or b) else 0
    rows.append(b"\0" + bytes(out))
def chunk(t, c): return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
print("%dx%d, %d of %d pixels not black" % (w, h, nz, w * h))
