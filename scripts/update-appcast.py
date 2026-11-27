#!/usr/bin/env python3
"""Maintain oriv.dev's Sparkle appcast, and read release notes from the changelog.

Add or replace a release (newest first):
  update-appcast.py --appcast site/appcast.xml --version 0.30.0 --build 51 \
      --url <dmg url> --notes <release page url> --signature 'sparkle:edSignature="…" length="…"'
Print one version's changelog section, for GitHub release notes:
  update-appcast.py --changelog docs/releases/CHANGELOG.md --version 0.30.0
"""
import argparse
import email.utils
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
MINIMUM_SYSTEM = "26.0"


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE}}}{tag}"


def empty_feed() -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Oriv"
    ET.SubElement(channel, "link").text = "https://oriv.dev/"
    ET.SubElement(channel, "description").text = "Updates for Oriv for Mac."
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def update(args) -> None:
    match = re.fullmatch(r'\s*sparkle:edSignature="([^"]+)"\s+length="(\d+)"\s*', args.signature)
    if not match:
        sys.exit('--signature must be sign_update output: sparkle:edSignature="…" length="…"')
    signature, length = match.groups()
    if not re.fullmatch(r"\d+(\.\d+){1,2}", args.version) or not args.build.isdigit():
        sys.exit("--version must look like 0.30.0 and --build must be a number")
    path = Path(args.appcast)
    tree = ET.parse(path) if path.exists() else empty_feed()
    channel = tree.getroot().find("channel")
    for item in channel.findall("item"):
        if item.findtext(sparkle("version")) == args.build:
            channel.remove(item)
        elif int(item.findtext(sparkle("version")) or 0) > int(args.build):
            sys.exit(f"The appcast already has a newer build than {args.build}")
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Oriv {args.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = MINIMUM_SYSTEM
    ET.SubElement(item, sparkle("releaseNotesLink")).text = args.notes
    ET.SubElement(item, "enclosure", {
        "url": args.url, "length": length, "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    })
    first = next((index for index, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first, item)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)
    with path.open("a") as handle:
        handle.write("\n")


def changelog(args) -> None:
    text = Path(args.changelog).read_text()
    pattern = rf"^## {re.escape(args.version)}\b.*?\n(.*?)(?=^## |\Z)"
    match = re.search(pattern, text, re.S | re.M)
    if not match:
        sys.exit(f"No changelog section for {args.version}")
    print(match.group(1).strip())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--appcast")
    parser.add_argument("--changelog")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build")
    parser.add_argument("--url")
    parser.add_argument("--notes")
    parser.add_argument("--signature")
    args = parser.parse_args()
    if args.changelog:
        changelog(args)
    elif args.appcast and args.build and args.url and args.notes and args.signature:
        update(args)
    else:
        parser.error("use --changelog, or --appcast with --build, --url, --notes and --signature")


if __name__ == "__main__":
    main()
