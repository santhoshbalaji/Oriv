#!/usr/bin/env python3
"""Pair background sidebar captures with approved B images at the same point scale.

Requires Pillow. Inputs and outputs are explicit local directories; no app launch.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

from PIL import Image, ImageDraw, ImageFont


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--captures", type=Path, required=True)
    parser.add_argument("--mock", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((args.captures / "manifest.json").read_text())
    if manifest["failures"]:
        raise SystemExit("Capture manifest contains failures")
    audit = manifest.get("backgroundUI", {})
    if any(audit.get(key, 1) for key in ("frontmostViolations", "activationViolations", "onscreenWindowViolations")):
        raise SystemExit("Capture background audit failed")
    font = ImageFont.load_default(size=23)
    small = ImageFont.load_default(size=18)
    inputs = []
    groups = {12: [], 50: [], 100: []}
    expression = re.compile(r"mac-glass-sidebar-b-(12|50|100)-(light|dark)-(760|820|1280)-(expanded|rail)(.*)-opaque-fallback.png")
    for record in manifest["evidence"]:
        match = expression.fullmatch(record["file"])
        if not match:
            continue
        count, mode, width, state, suffix = match.groups()
        production = args.captures / record["file"]
        mock = args.mock / f"{mode}-{'wide' if int(width) > 1000 else 'narrow'}-{'collapsed' if state == 'rail' else state}.png"
        inputs.append({"capture": production.name, "sha256": record["sha256"], "mock": mock.name,
                       "mockSHA256": hashlib.sha256(mock.read_bytes()).hexdigest()})
        images = [Image.open(path).convert("RGB") for path in (mock, production)]
        title = f"{mode} / {count} tabs / {width} pt / {state}{suffix}"
        detail = Image.new("RGB", (1184, 1870), "#18171b")
        draw = ImageDraw.Draw(detail)
        draw.text((12, 6), title, font=font, fill="white")
        for index, image in enumerate(images):
            draw.text((index * 592 + 12, 37), "Approved B" if index == 0 else "Production (opaque)", font=small, fill="white")
            detail.paste(image.crop((0, 0, 592, 1800)), (index * 592, 70))
        groups[int(count)].append(detail)
        if count == "12" and width == "820" and not suffix:
            full = Image.new("RGB", (3280, 1870), "#18171b")
            for index, image in enumerate(images):
                full.paste(image.crop((0, 0, 1640, 1800)), (1640 * index, 70))
                ImageDraw.Draw(full).text((1640 * index + 14, 15), "Approved B" if index == 0 else "Production (opaque)", font=font, fill="white")
            full.save(args.output / f"{mode}-{state}.png")
            detail.save(args.output / f"{mode}-{state}-sidebar.png")
    sheets = []
    for count, tiles in groups.items():
        for offset in range(0, len(tiles), 6):
            group = tiles[offset:offset + 6]
            sheet = Image.new("RGB", (1184 * 3, 1870 * ((len(group) + 2) // 3)), "#18171b")
            for index, tile in enumerate(group):
                sheet.paste(tile, ((index % 3) * 1184, (index // 3) * 1870))
            name = f"benchmark-{count}-{offset // 6 + 1:02}.png"
            sheet.save(args.output / name)
            sheets.append(name)
    (args.output / "benchmark-manifest.json").write_text(json.dumps({
        "captureRunID": manifest["runID"], "inputs": inputs, "sheets": sheets,
        "limitations": manifest["limitations"], "backgroundUI": audit,
    }, indent=2) + "\n")
    (args.output / "index.html").write_text("<!doctype html><meta charset=utf-8><title>Sidebar B comparison</title>"
        "<h1>Sidebar B background comparison</h1><p>Same point scale; opaque layout evidence. "
        "Hover/focus and loading/audio artwork use labelled Debug inputs. Live materials, pointer and VoiceOver require foreground acceptance.</p>"
        + "".join(f'<p><a href="{name}">{name}</a></p>' for name in sheets))
    print(f"Compared {len(inputs)} captures in {len(sheets)} sheets; background audit passed")


if __name__ == "__main__":
    main()
