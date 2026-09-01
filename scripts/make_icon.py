#!/usr/bin/env python3
"""Build logo/hashedbuild.ico (and the VS Code extension's icon) from the logo.

Windows wants a .ico for a file-type icon, and the logo is a PNG of a different
shape - so this crops it to the glyph, squares it, resamples it to the sizes an
icon carries, and writes the container. Stdlib only: PNG is zlib plus a filter
per scanline, ICO is a table plus either PNGs or bitmaps, and neither is worth
a dependency.

  python3 scripts/make_icon.py                 # logo/hashedbuild.png -> .ico
  python3 scripts/make_icon.py --sharp         # no rounded corners

The icon keeps the logo's own white background rather than making it
transparent. A black glyph on transparency vanishes against a dark file list,
which is where a lot of people would be looking at it; a white tile is legible
either way.
"""

import os
import struct
import sys
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(REPO, "logo", "hashedbuild.png")
ICO_OUT = os.path.join(REPO, "logo", "hashedbuild.ico")
EXT_ICON = os.path.join(REPO, "editors", "vscode", "hashedbuild-debug", "icon.png")

# 256 and 128 ride as PNG (every Windows since Vista reads those); the smaller
# ones as bitmaps, which is what the shell has always understood and what some
# icon caches still prefer.
SIZES_PNG = (256, 128)
SIZES_BMP = (64, 48, 32, 16)

MARGIN = 0.14   # of the glyph's longer side, so it does not touch the edges
RADIUS = 0.12   # corner rounding, as a fraction of the icon's side


# ---- PNG in ------------------------------------------------------------------

def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def read_png(path):
    """-> (width, height, rows of RGBA bytes). 8-bit RGB or RGBA, no interlace."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path} is not a PNG")

    pos, idat, ihdr = 8, bytearray(), None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            ihdr = body
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length

    w, h, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", ihdr)
    if depth != 8 or colour not in (2, 6) or interlace:
        sys.exit(f"{path}: need an 8-bit RGB or RGBA PNG without interlacing "
                 f"(got depth {depth}, colour type {colour}, interlace {interlace})")

    src_bpp = 4 if colour == 6 else 3
    raw = zlib.decompress(bytes(idat))
    stride = w * src_bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        if f:
            for x in range(stride):
                a = line[x - src_bpp] if x >= src_bpp else 0
                b = prev[x]
                c = prev[x - src_bpp] if x >= src_bpp else 0
                if f == 1:
                    line[x] = (line[x] + a) & 255
                elif f == 2:
                    line[x] = (line[x] + b) & 255
                elif f == 3:
                    line[x] = (line[x] + ((a + b) >> 1)) & 255
                elif f == 4:
                    line[x] = (line[x] + paeth(a, b, c)) & 255
                else:
                    sys.exit(f"{path}: unknown scanline filter {f}")
        prev = line
        if src_bpp == 4:
            rows.append(bytes(line))
        else:
            out = bytearray(w * 4)
            for x in range(w):
                out[x * 4:x * 4 + 3] = line[x * 3:x * 3 + 3]
                out[x * 4 + 3] = 255
            rows.append(bytes(out))
    return w, h, rows


# ---- shaping ------------------------------------------------------------------

def ink_bounds(w, h, rows):
    """The glyph's own extent: anything neither transparent nor near-white."""
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        r = rows[y]
        for x in range(w):
            alpha = r[x * 4 + 3]
            lum = (r[x * 4] + r[x * 4 + 1] + r[x * 4 + 2]) // 3
            if alpha > 8 and lum < 200:
                minx, maxx = min(minx, x), max(maxx, x)
                miny, maxy = min(miny, y), max(maxy, y)
    if maxx < 0:
        sys.exit("the logo appears to be blank")
    return minx, miny, maxx, maxy


def square_canvas(w, h, rows):
    """Crop to the glyph, centre it on a square of the logo's own background."""
    minx, miny, maxx, maxy = ink_bounds(w, h, rows)
    gw, gh = maxx - minx + 1, maxy - miny + 1
    margin = int(max(gw, gh) * MARGIN)
    side = max(gw, gh) + margin * 2

    background = rows[0][0:4]  # the logo's corner: its own background colour
    out = [bytearray(background * side) for _ in range(side)]
    ox, oy = (side - gw) // 2, (side - gh) // 2
    for y in range(gh):
        src = rows[miny + y]
        out[oy + y][ox * 4:(ox + gw) * 4] = src[minx * 4:(maxx + 1) * 4]
    return side, [bytes(r) for r in out]


def resample(side, rows, target):
    """Box filter over premultiplied alpha - averaging raw RGB would darken
    edges wherever a transparent pixel contributed its colour as well as its
    transparency."""
    out = []
    for ty in range(target):
        y0, y1 = ty * side // target, max(ty * side // target + 1, (ty + 1) * side // target)
        line = bytearray(target * 4)
        for tx in range(target):
            x0, x1 = tx * side // target, max(tx * side // target + 1, (tx + 1) * side // target)
            r = g = b = a = n = 0
            for sy in range(y0, y1):
                row = rows[sy]
                for sx in range(x0, x1):
                    pa = row[sx * 4 + 3]
                    r += row[sx * 4] * pa
                    g += row[sx * 4 + 1] * pa
                    b += row[sx * 4 + 2] * pa
                    a += pa
                    n += 1
            if a:
                line[tx * 4] = min(255, r // a)
                line[tx * 4 + 1] = min(255, g // a)
                line[tx * 4 + 2] = min(255, b // a)
            line[tx * 4 + 3] = a // n if n else 0
        out.append(bytes(line))
    return out


def round_corners(size, rows, radius_fraction=RADIUS):
    """Anti-aliased rounded corners, by clearing alpha outside the shape."""
    radius = size * radius_fraction
    if radius < 1:
        return rows
    out = [bytearray(r) for r in rows]
    for y in range(size):
        for x in range(size):
            # Distance outside the rounded rectangle, at pixel centres.
            px, py = x + 0.5, y + 0.5
            cx = min(max(px, radius), size - radius)
            cy = min(max(py, radius), size - radius)
            dx, dy = px - cx, py - cy
            d = (dx * dx + dy * dy) ** 0.5
            if d <= radius - 0.5:
                continue
            coverage = 0.0 if d >= radius + 0.5 else radius + 0.5 - d
            i = x * 4 + 3
            out[y][i] = int(out[y][i] * coverage)
    return [bytes(r) for r in out]


# ---- PNG out / ICO out ---------------------------------------------------------

def write_png(size, rows):
    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    raw = bytearray()
    for r in rows:
        raw.append(0)  # filter: none. The images are tiny; compression is not the point.
        raw += r
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def write_bmp(size, rows):
    """A 32-bit DIB as ICO carries one: doubled height in the header, rows
    bottom-up, BGRA, and an AND mask that 32-bit icons no longer use but every
    reader still expects to find."""
    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, size * size * 4, 0, 0, 0, 0)
    pixels = bytearray()
    for y in range(size - 1, -1, -1):
        r = rows[y]
        for x in range(size):
            pixels += bytes((r[x * 4 + 2], r[x * 4 + 1], r[x * 4], r[x * 4 + 3]))
    mask_stride = ((size + 31) // 32) * 4
    return header + bytes(pixels) + bytes(mask_stride * size)


def write_ico(path, images):
    """images: [(size, payload)], already encoded."""
    count = len(images)
    out = bytearray(struct.pack("<HHH", 0, 1, count))
    offset = 6 + 16 * count
    for size, payload in images:
        dim = 0 if size >= 256 else size  # 0 means 256 in an ICO entry
        out += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(payload), offset)
        offset += len(payload)
    for _, payload in images:
        out += payload
    open(path, "wb").write(bytes(out))


def main():
    sharp = "--sharp" in sys.argv
    w, h, rows = read_png(SOURCE)
    side, square = square_canvas(w, h, rows)
    print(f"{SOURCE}: {w}x{h} -> {side}x{side} square")

    images = []
    for size in SIZES_PNG + SIZES_BMP:
        scaled = resample(side, square, size)
        if not sharp:
            scaled = round_corners(size, scaled)
        payload = write_png(size, scaled) if size in SIZES_PNG else write_bmp(size, scaled)
        images.append((size, payload))
        print(f"  {size:>3}px  {len(payload):>6} bytes  {'png' if size in SIZES_PNG else 'bmp'}")
        if size == 128:
            open(EXT_ICON, "wb").write(write_png(size, scaled))

    write_ico(ICO_OUT, images)
    print(f"wrote {ICO_OUT} ({os.path.getsize(ICO_OUT)} bytes)")
    print(f"wrote {EXT_ICON}")


if __name__ == "__main__":
    main()
