#!/usr/bin/env python3
"""
The OS/7 mark, rasterised without a renderer — docs/BRAND-PLAN.md BR8.

The boot splash needs the mark as PNG sprites, and Plymouth can draw nothing
else: its script plugin loads images and moves them, and there is no vector
path in it. So something has to turn brand/os7-wordmark.svg into pixels, and
the question is what.

NOT rsvg-convert at build time. It is not in os7-build:<arch> (adding it means
rebuilding both build images, the arm64 one under emulation), and the PNGs it
writes cannot be held to anything: a check that wants to know whether a
checked-in sprite is still the mark would need the same renderer at the same
version on every host that runs the check.

So this file IS the renderer, and it is small because the mark is: an ellipse
ring, a stroked cubic spine, and two polygons. Each is turned into closed
polygon loops, the loops are filled with a nonzero rule, and coverage is exact
across each scanline and supersampled down it.

DETERMINISM IS THE POINT, and it is why there is no `math.cos` in here.
Addition, subtraction, multiplication, division and sqrt are correctly rounded
by IEEE 754 on every platform Python runs on; sin and cos come from the C
library and may differ in the last place between glibc and the Windows CRT.
The ellipse is therefore walked with the rational parametrisation
((1-t^2)/(1+t^2), 2t/(1+t^2)), which needs neither. The result is that
`brand.py verify` can re-render a sprite on any host and require the PIXELS to
be identical — the decoded pixels, not the PNG bytes, because zlib and zlib-ng
compress the same data differently and both are correct.

No dependencies beyond the standard library, like palette.py and brand.py.
"""
import re
import struct
import zlib

SUB = 8          # sub-scanlines per pixel row; horizontal coverage is exact
BEZIER_STEPS = 48
ELLIPSE_STEPS = 96   # per quadrant


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------
def _norm(x, y):
    length = (x * x + y * y) ** 0.5
    return (x / length, y / length)


def parse_path(d):
    """
    An absolute M/L/C/Z path -> a list of subpaths, each (points, closed).

    The master uses absolute upper-case commands only, and this refuses
    anything else rather than guessing: a lower-case command read as an upper
    one draws a different mark in silence.
    """
    tokens = re.findall(r"[A-Za-z]|-?\d+(?:\.\d+)?", d)
    subpaths, points, closed = [], [], False
    i, cmd = 0, None
    while i < len(tokens):
        t = tokens[i]
        if t.isalpha():
            if t not in "MLCZ":
                raise ValueError(f"path command {t!r} is not one this renderer draws")
            cmd = t
            i += 1
            if cmd == "Z":
                closed = True
                subpaths.append((points, closed))
                points, closed = [], False
            continue
        if cmd == "M":
            if points:
                subpaths.append((points, False))
            points = [(float(tokens[i]), float(tokens[i + 1]))]
            i += 2
            cmd = "L"
        elif cmd == "L":
            points.append((float(tokens[i]), float(tokens[i + 1])))
            i += 2
        elif cmd == "C":
            x1, y1, x2, y2, x, y = (float(v) for v in tokens[i:i + 6])
            x0, y0 = points[-1]
            for k in range(1, BEZIER_STEPS + 1):
                s = k / BEZIER_STEPS
                u = 1.0 - s
                a, b, c, e = u * u * u, 3 * u * u * s, 3 * u * s * s, s * s * s
                points.append((a * x0 + b * x1 + c * x2 + e * x,
                               a * y0 + b * y1 + c * y2 + e * y))
            i += 6
        else:
            raise ValueError("path data before any command")
    if points:
        subpaths.append((points, closed))
    return subpaths


def stroke_outline(points, width):
    """
    The outline of an open polyline stroked at `width` with BUTT caps, as one
    closed loop: the left offset forward, the right offset back.

    Vertex normals are the normalised sum of the two adjacent segment normals,
    lengthened by the miter factor. The spine is flattened finely and its
    joins are tangent-continuous, so the factor stays within a hair of 1; it is
    computed anyway rather than assumed.
    """
    h = width / 2.0
    n = len(points)
    seg = []
    for i in range(n - 1):
        dx = points[i + 1][0] - points[i][0]
        dy = points[i + 1][1] - points[i][1]
        tx, ty = _norm(dx, dy)
        seg.append((-ty, tx))
    left, right = [], []
    for i in range(n):
        if i == 0:
            nx, ny = seg[0]
            k = 1.0
        elif i == n - 1:
            nx, ny = seg[-1]
            k = 1.0
        else:
            ax, ay = seg[i - 1]
            bx, by = seg[i]
            nx, ny = _norm(ax + bx, ay + by)
            k = 1.0 / (nx * ax + ny * ay)
        x, y = points[i]
        left.append((x + nx * h * k, y + ny * h * k))
        right.append((x - nx * h * k, y - ny * h * k))
    return left + right[::-1]


def ellipse_ring(cx, cy, rx, ry, width):
    """
    An ellipse stroked at `width`, as two loops of opposite orientation — the
    true offset curves, along the ellipse's own normal, not two ellipses with
    the radii grown (an offset ellipse is not an ellipse).
    """
    h = width / 2.0
    quadrant = []
    for k in range(ELLIPSE_STEPS):
        t = k / ELLIPSE_STEPS
        d = 1.0 + t * t
        quadrant.append(((1.0 - t * t) / d, 2.0 * t / d))
    unit = []
    for c, s in quadrant:
        unit.append((c, s))
    for c, s in quadrant:
        unit.append((-s, c))
    for c, s in quadrant:
        unit.append((-c, -s))
    for c, s in quadrant:
        unit.append((s, -c))
    outer, inner = [], []
    for c, s in unit:
        px, py = cx + rx * c, cy + ry * s
        nx, ny = _norm(c / rx, s / ry)
        outer.append((px + nx * h, py + ny * h))
        inner.append((px - nx * h, py - ny * h))
    return [outer, inner[::-1]]


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


# ---------------------------------------------------------------------------
# Filling
# ---------------------------------------------------------------------------
def fill(loops, width, height):
    """
    Coverage in [0, 1] per pixel, row-major, for closed `loops` under the
    nonzero winding rule. SUB sub-scanlines per row; along each one the span
    edges are exact, so a pixel half-covered horizontally gets exactly half.
    """
    edges = []
    for loop in loops:
        for i in range(len(loop)):
            (x0, y0), (x1, y1) = loop[i], loop[(i + 1) % len(loop)]
            if y0 == y1:
                continue
            w = 1 if y1 > y0 else -1
            if y0 > y1:
                x0, y0, x1, y1 = x1, y1, x0, y0
            edges.append((y0, y1, x0, (x1 - x0) / (y1 - y0), w))
    edges.sort()

    cov = [0.0] * (width * height)
    active, nxt = [], 0
    weight = 1.0 / SUB
    for row in range(height):
        for k in range(SUB):
            y = row + (k + 0.5) / SUB
            while nxt < len(edges) and edges[nxt][0] <= y:
                active.append(edges[nxt])
                nxt += 1
            active = [e for e in active if e[1] > y]
            xs = sorted((e[2] + (y - e[0]) * e[3], e[4]) for e in active if e[0] <= y)
            wind = 0
            for j in range(len(xs) - 1):
                wind += xs[j][1]
                if wind == 0:
                    continue
                xa, xb = max(xs[j][0], 0.0), min(xs[j + 1][0], float(width))
                if xb <= xa:
                    continue
                base = row * width
                ia, ib = int(xa), int(xb)
                if ia == ib:
                    cov[base + ia] += (xb - xa) * weight
                    continue
                cov[base + ia] += (ia + 1 - xa) * weight
                for x in range(ia + 1, ib):
                    cov[base + x] += weight
                if ib < width:
                    cov[base + ib] += (xb - ib) * weight
    return cov


def to_rgba(cov, width, height, colour):
    """Straight (not premultiplied) RGBA rows: the ink everywhere, coverage in alpha."""
    r, g, b = colour
    rows = []
    for row in range(height):
        out = bytearray()
        for x in range(width):
            a = cov[row * width + x]
            a = 0 if a <= 0 else 255 if a >= 1 else int(a * 255 + 0.5)
            out += bytes((r, g, b, a))
        rows.append(bytes(out))
    return rows


# ---------------------------------------------------------------------------
# PNG, both directions
# ---------------------------------------------------------------------------
def _chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def encode_png(width, height, rows):
    raw = b"".join(b"\x00" + r for r in rows)
    return (b"\x89PNG\r\n\x1a\n"
            + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(raw, 9))
            + _chunk(b"IEND", b""))


def decode_png(data):
    """
    (width, height, rows) for an 8-bit RGBA, non-interlaced PNG — which is what
    encode_png writes. Anything else is refused by name: this reads the files
    this module wrote, and a sprite replaced by one exported from an editor is
    exactly what the check exists to notice.
    """
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, ihdr = 8, b"", None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    if ihdr is None:
        raise ValueError("no IHDR")
    width, height, depth, ctype, _, _, interlace = ihdr
    if (depth, ctype, interlace) != (8, 6, 0):
        raise ValueError(f"depth {depth}, colour type {ctype}, interlace {interlace}: "
                         "not the 8-bit RGBA this module writes")
    raw = zlib.decompress(idat)
    stride = width * 4
    rows, prev = [], bytearray(stride)
    for r in range(height):
        f = raw[r * (stride + 1)]
        line = bytearray(raw[r * (stride + 1) + 1:(r + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - 4] if i >= 4 else 0
            b = prev[i]
            c = prev[i - 4] if i >= 4 else 0
            if f == 1:
                line[i] = (line[i] + a) & 0xFF
            elif f == 2:
                line[i] = (line[i] + b) & 0xFF
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else b if pb <= pc else c
                line[i] = (line[i] + pred) & 0xFF
            elif f != 0:
                raise ValueError(f"unknown PNG filter {f}")
        rows.append(bytes(line))
        prev = line
    return width, height, rows
