#!/usr/bin/env python3
"""Render a real cursor-theme preview strip from actual XCursor files.

Pure standard library (struct + zlib only) — no Pillow, no numpy, no
external image tool. Parses the XCursor binary format directly, picks the
nominal size closest to a target preview size (downsampling with a simple
box filter if the theme only ships larger bitmaps), always uses the first
frame of an animated cursor, and composites the requested roles into one
transparent-background PNG strip so the surrounding QML card can paint its
own themed background/border around it.

Usage:
  xcursor_preview.py <roles.json> <output.png> [--cell 40] [--target-size 32]

<roles.json> is a JSON object: {"pointer": "/path/to/cursors/left_ptr", ...}.
Only the roles present are rendered, in the order given by the JSON object
(Python dicts preserve insertion order, and the caller controls that order).
A role whose file fails to parse is skipped rather than aborting the whole
render, so one corrupt cursor file cannot blank out the entire preview.
"""
import json
import struct
import sys
import zlib

XCURSOR_MAGIC = b"Xcur"
CHUNK_IMAGE = 0xFFFD0002
IMAGE_CHUNK_HEADER_SIZE = 36  # 9 CARD32 fields before pixel data


def parse_xcursor_images(path):
    """Return a list of {size, width, height, pixels(RGBA straight-alpha bytes)}
    for every image chunk in the file, in on-disk (TOC) order."""
    with open(path, "rb") as f:
        data = f.read()

    if len(data) < 16 or data[:4] != XCURSOR_MAGIC:
        raise ValueError("not an Xcursor file")

    header_size, _version, ntoc = struct.unpack_from("<III", data, 4)

    images = []
    off = header_size
    for _ in range(ntoc):
        if off + 12 > len(data):
            break
        typ, subtype, position = struct.unpack_from("<III", data, off)
        off += 12
        if typ != CHUNK_IMAGE:
            continue
        if position + IMAGE_CHUNK_HEADER_SIZE > len(data):
            continue
        (_chdr, _ctype, csubtype, _cver, width, height, _xhot, _yhot, _delay) = (
            struct.unpack_from("<IIIIIIIII", data, position)
        )
        if width <= 0 or height <= 0 or width > 4096 or height > 4096:
            continue
        pixel_off = position + IMAGE_CHUNK_HEADER_SIZE
        nbytes = width * height * 4
        if pixel_off + nbytes > len(data):
            continue
        raw = data[pixel_off : pixel_off + nbytes]
        images.append(
            {"size": csubtype, "width": width, "height": height, "pixels": _unpremultiply(raw)}
        )
    return images


def _unpremultiply(raw):
    """Xcursor stores premultiplied ARGB32 as little-endian words, i.e. bytes
    on disk are (B, G, R, A) per pixel. Convert to straight-alpha RGBA bytes
    for PNG, since PNG colortype 6 expects unassociated alpha."""
    out = bytearray(len(raw))
    for i in range(0, len(raw), 4):
        b, g, r, a = raw[i], raw[i + 1], raw[i + 2], raw[i + 3]
        if a == 0:
            out[i : i + 4] = (0, 0, 0, 0)
        elif a == 255:
            out[i : i + 4] = (r, g, b, 255)
        else:
            out[i] = min(255, (r * 255) // a)
            out[i + 1] = min(255, (g * 255) // a)
            out[i + 2] = min(255, (b * 255) // a)
            out[i + 3] = a
    return bytes(out)


def pick_frame0(images, target_size):
    """Pick the nominal size closest to target_size, then the first image at
    that size (TOC order == animation frame order, so this is frame 0)."""
    if not images:
        return None
    sizes = sorted({img["size"] for img in images})
    chosen_size = min(sizes, key=lambda s: abs(s - target_size))
    for img in images:
        if img["size"] == chosen_size:
            return img
    return images[0]


def box_downsample(width, height, rgba, max_dim):
    """Integer box-filter downsample so a theme that only ships larger
    bitmaps (e.g. 48px) still fits the preview cell without blurring via
    interpolation. No-op if already within max_dim."""
    if width <= max_dim and height <= max_dim:
        return width, height, rgba

    factor = max(1, -(-max(width, height) // max_dim))  # ceil division
    new_w = max(1, width // factor)
    new_h = max(1, height // factor)
    out = bytearray(new_w * new_h * 4)

    for ny in range(new_h):
        for nx in range(new_w):
            r = g = b = a = count = 0
            for sy in range(ny * factor, min((ny + 1) * factor, height)):
                row_off = sy * width * 4
                for sx in range(nx * factor, min((nx + 1) * factor, width)):
                    off = row_off + sx * 4
                    r += rgba[off]
                    g += rgba[off + 1]
                    b += rgba[off + 2]
                    a += rgba[off + 3]
                    count += 1
            if count == 0:
                continue
            o = (ny * new_w + nx) * 4
            out[o] = r // count
            out[o + 1] = g // count
            out[o + 2] = b // count
            out[o + 3] = a // count

    return new_w, new_h, bytes(out)


def blit_centered(canvas, canvas_w, cell_x, cell_y, cell_size, width, height, rgba):
    """Copy an RGBA image centered inside a cell_size x cell_size region of
    canvas (a flat bytearray, canvas_w pixels wide). Destination starts fully
    transparent, so a straight copy (no blending math) is correct."""
    off_x = cell_x + max(0, (cell_size - width) // 2)
    off_y = cell_y + max(0, (cell_size - height) // 2)
    for y in range(height):
        dy = off_y + y
        src_off = y * width * 4
        dst_off = (dy * canvas_w + off_x) * 4
        canvas[dst_off : dst_off + width * 4] = rgba[src_off : src_off + width * 4]


def write_png(path, width, height, rgba_bytes):
    def chunk(tag, payload):
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: None
        raw.extend(rgba_bytes[y * stride : (y + 1) * stride])
    idat = zlib.compress(bytes(raw), 9)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


DEFAULT_ROLE_ORDER = [
    "pointer",
    "text",
    "link",
    "wait",
    "resize-horizontal",
    "grab",
]


def render(role_files, output_path, cell_size=40, target_size=32, gap=6):
    roles = [r for r in DEFAULT_ROLE_ORDER if r in role_files] or list(role_files.keys())
    n = len(roles)
    if n == 0:
        raise ValueError("no roles to render")

    width = n * cell_size + (n - 1) * gap
    height = cell_size
    canvas = bytearray(width * height * 4)

    for i, role in enumerate(roles):
        path = role_files[role]
        try:
            images = parse_xcursor_images(path)
            frame = pick_frame0(images, target_size)
        except (ValueError, OSError):
            frame = None
        if frame is None:
            continue
        w, h, rgba = box_downsample(frame["width"], frame["height"], frame["pixels"], cell_size)
        cell_x = i * (cell_size + gap)
        blit_centered(canvas, width, cell_x, 0, cell_size, w, h, rgba)

    write_png(output_path, width, height, bytes(canvas))


def main(argv):
    if len(argv) < 3:
        print("Usage: xcursor_preview.py <roles.json> <output.png> [--cell N] [--target-size N]", file=sys.stderr)
        return 1

    roles_arg, output_path = argv[1], argv[2]
    cell_size = 40
    target_size = 32
    rest = argv[3:]
    i = 0
    while i < len(rest):
        if rest[i] == "--cell" and i + 1 < len(rest):
            cell_size = int(rest[i + 1])
            i += 2
        elif rest[i] == "--target-size" and i + 1 < len(rest):
            target_size = int(rest[i + 1])
            i += 2
        else:
            i += 1

    if roles_arg == "-":
        role_files = json.load(sys.stdin)
    else:
        role_files = json.loads(roles_arg)

    render(role_files, output_path, cell_size=cell_size, target_size=target_size)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
