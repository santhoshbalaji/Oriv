#!/usr/bin/env python3
"""Guard the isolated password focus script and its revalidation call."""
from pathlib import Path
import re

source = (Path(__file__).resolve().parent.parent /
          "Packages/BrowserKit/Sources/BrowserEngine/PasswordFieldFocus.swift").read_text()
forbidden = {
    "field contents": r"\b(?:value(?:AsDate|AsNumber)?|defaultValue|FormData|setRangeText|textContent|innerText|innerHTML|outerHTML)\b",
    "clipboard": r"(?i:clipboard|pasteboard|execCommand|\bpaste\b)",
    "network": (r"\b(?:fetch|XMLHttpRequest|WebSocket(?:Stream)?|EventSource|WebTransport|RTCPeerConnection|"
                r"sendBeacon|Request|open|submit|requestSubmit|importScripts|Worker|SharedWorker|Image|"
                r"createElement(?:NS)?|src|srcset|href|assign|replace|reload)\b"),
}
for purpose, pattern in forbidden.items():
    if match := re.search(pattern, source):
        raise SystemExit(f"Password field classifier touches {purpose}: {match.group()}")
posts = re.findall(r"\.postMessage\s*\((.*)\)", source)
if posts != ["{kind, frame}"]:
    raise SystemExit("Password field classifier must only post kind and frame")
print("Password field classifier scope passed")
