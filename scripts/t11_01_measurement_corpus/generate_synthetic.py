#!/usr/bin/env python3
"""Deterministic, source-free PNG generator for the T11-01 corpus."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT.parents[1] / "Fixtures/MeasurementCorpus/corpus-manifest.json"
SIZE = 800


def rect(pixels, x0, y0, x1, y1, color):
    for y in range(max(0, y0), min(SIZE, y1)):
        row = pixels[y]
        for x in range(max(0, x0), min(SIZE, x1)):
            row[x] = color


def garment(pixels, mode="complete"):
    # A deliberately generic, non-personal T-shirt silhouette and mask source.
    x0, y0, x1, y1 = (110, 130, 550, 560) if mode != "out_of_frame" else (-20, 130, 710, 820)
    color = (232, 231, 226) if mode == "low_contrast" else (50, 103, 157)
    rect(pixels, x0 + 110, y0, x1 - 110, y1, color)
    rect(pixels, x0, y0 + 85, x0 + 150, y0 + 280, color)
    rect(pixels, x1 - 150, y0 + 85, x1, y0 + 280, color)
    rect(pixels, x0 + 230, y0, x1 - 230, y0 + 35, (225, 224, 220) if mode == "low_contrast" else (34, 75, 116))


def marker(pixels, x, y, side, occluded=False, height=None):
    height = side if height is None else height
    rect(pixels, x, y, x + side, y + height, (0, 0, 0))
    inset = round(min(side, height) * 0.1)
    rect(pixels, x + inset, y + inset, x + side - inset, y + height - inset, (255, 255, 255))
    if occluded:
        rect(pixels, x + side // 2, y, x + side, y + height // 2, (50, 103, 157))


def polygon(pixels, points, color):
    for y in range(max(0, min(y for _, y in points)), min(SIZE, max(y for _, y in points) + 1)):
        intersections = []
        for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1]):
            if (y1 <= y < y2) or (y2 <= y < y1):
                intersections.append(x1 + (y - y1) * (x2 - x1) / (y2 - y1))
        intersections.sort()
        for left, right in zip(intersections[::2], intersections[1::2]):
            rect(pixels, round(left), y, round(right) + 1, y + 1, color)


def marker_polygon(pixels, corners, occluded=False):
    polygon(pixels, corners, (0, 0, 0))
    center_x = sum(x for x, _ in corners) / 4
    center_y = sum(y for _, y in corners) / 4
    inner = [(round(x + (center_x - x) * 0.1), round(y + (center_y - y) * 0.1)) for x, y in corners]
    polygon(pixels, inner, (255, 255, 255))
    if occluded:
        a, b, c, d = corners
        polygon(pixels, [((a[0] + b[0]) // 2, (a[1] + b[1]) // 2), b, c, ((c[0] + d[0]) // 2, (c[1] + d[1]) // 2)], (50, 103, 157))


def box_blur(pixels):
    block = 8
    reduced = []
    for y in range(0, SIZE, block):
        row = []
        for x in range(0, SIZE, block):
            values = [pixels[yy][xx] for yy in range(y, y + block) for xx in range(x, x + block)]
            row.append(tuple(sum(value[index] for value in values) // len(values) for index in range(3)))
        reduced.append(row)
    for y in range(SIZE):
        for x in range(SIZE):
            pixels[y][x] = reduced[y // block][x // block]


def encode_png(pixels):
    raw = b"".join(b"\x00" + bytes(component for pixel in row for component in pixel) for row in pixels)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def image_for(case):
    bg = (234, 232, 224)
    pixels = [[bg for _ in range(SIZE)] for _ in range(SIZE)]
    garment(pixels, case.get("garment", "complete"))
    geometry = case.get("markerGeometry")
    if geometry:
        if case.get("markerCorners"):
            marker_polygon(pixels, [tuple(point) for point in case["markerCorners"]], case.get("marker") == "occluded")
        else:
            x, y, side = geometry["x"], geometry["y"], geometry["side"]
            marker(pixels, x, y, side, case.get("marker") == "occluded", geometry.get("height"))
        if case.get("marker") == "multiple":
            marker(pixels, 90, 70, 100)
    if case.get("qualityFlag") == "blur":
        box_blur(pixels)
    if case.get("qualityFlag") == "dark":
        for row in pixels:
            for index, (red, green, blue) in enumerate(row):
                row[index] = (red // 6, green // 6, blue // 6)
    return encode_png(pixels)


def generate(output):
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    output.mkdir(parents=True, exist_ok=True)
    for case in manifest["cases"]:
        data = image_for(case)
        target = output / case["file"]
        target.write_bytes(data)
        observed = hashlib.sha256(data).hexdigest()
        if observed != case["sha256"]:
            raise ValueError(f"{case['id']}: manifest hash is {case['sha256']}, generated {observed}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    generate(args.output)
