#!/usr/bin/env python3
"""Fails when a text or indicator colour in Theme.swift falls below WCAG contrast on a surface it appears on.

Text needs 4.5:1. Non-text indicators (selection marker, focus ring) need 3:1.
Colours are read from Apps/macOS/Views/Theme.swift so the check cannot drift from the app.
Classic text colours are explicit adaptive tokens. The recording indicator stays system red; every Theme text token is explicit.
--negative-test simulates using the brand accent as the global text tint and must detect it.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Apps/macOS/Views/Theme.swift"
text = SOURCE.read_text()
negative_test = "--negative-test" in sys.argv
if negative_test:
    text = text.replace(".tint(theme.accentText).accentColor(theme.accentText)", ".tint(theme.accent).accentColor(theme.accent)")
# Both platforms inherit this tint for text controls (macOS 27 Form values included).
text_tint = re.search(r"\.tint\(theme\.(\w+)\)\.accentColor\(theme\.\1\)", text).group(1)

def luminance(hex_value):
    channels = [int(hex_value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)

def block(start, end):
    i = text.index(start)
    return text[i:text.index(end, i)]

def hex_tokens(source):
    return {name: value.upper() for name, value in re.findall(r"(\w+): (?:Self\.)?hex\(0x([0-9A-Fa-f]{6})\)", source)}

def adaptive_tokens(source):
    return {name: (light.upper(), dark.upper()) for name, _, light, dark in
            re.findall(r"(\w+): adaptive\(\"(\w+)\", light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)", source)}

t3 = hex_tokens(block("static let t3Code = Theme(", "static let classic"))
t3["warning"] = re.search(r"var warning: Color \{ isT3Code \? Self\.hex\(0x([0-9A-Fa-f]{6})\)", text).group(1).upper()
private_light, private_dark = re.search(r'privateAccent = adaptive\("Private", light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)', text).groups()
t3["privateAccent"] = private_dark.upper()
increased = {**t3, **hex_tokens(block("func respecting(", "#if os(macOS)"))}
classic_adaptive = adaptive_tokens(block("static let classic = Theme(", "func respecting("))
warning_light, warning_dark = re.search(r"classicWarning = adaptive\(\"Warning\", light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)", text).groups()
NATIVE_LIGHT = {"field (white)": "FFFFFF", "chrome (macOS light)": "ECECEC"}
NATIVE_DARK = {"field (macOS dark)": "1E1E1E", "field (iOS dark)": "1C1C1E", "chrome (macOS dark)": "282828", "chrome (iOS dark)": "000000"}

def classic(mode):
    index = 0 if mode == "light" else 1
    surfaces = {name: classic_adaptive[name][index] for name in ("canvas", "surface", "selection")}
    surfaces.update(NATIVE_LIGHT if mode == "light" else NATIVE_DARK)
    return {**{token: classic_adaptive[token][index] for token in ({"text", "secondaryText", "accentText", text_tint} | (text_foregrounds - {"privateAccent", "fieldText", "warning"}))},
            "fieldText": classic_adaptive["secondaryText"][index],
            "privateAccent": private_light.upper() if mode == "light" else private_dark.upper(),
            "warning": warning_light.upper() if mode == "light" else warning_dark.upper()}, surfaces

# Catch a text foreground accidentally using an indicator token, not just changes to the palette.
# Include line-wrapped modifier chains, stopping at the next view constructor.
text_foregrounds = set()
for source in (ROOT / "Apps").rglob("*.swift"):
    text_foregrounds.update(re.findall(r"\bText\([^;{}]*?\.foregroundStyle\(theme\.(\w+)\)", source.read_text()))
text_tokens = {"text", "secondaryText", "fieldText", "accentText", "warning", "privateAccent", text_tint} | text_foregrounds
checks = []  # (theme, token, colour, surface, background, minimum)
for label, palette in (("T3 Code", t3), ("T3 Code, Increased Contrast", increased)):
    surfaces = {name: palette[name] for name in ("canvas", "chrome", "surface", "field", "selection")}
    palette["fieldText"] = palette["secondaryText"]
    for token in sorted(text_tokens):
        for surface, background in surfaces.items():
            checks.append((label, token, palette[token], surface, background, 4.5))
    for surface in ("canvas", "chrome", "surface", "selection"):  # selection marker
        checks.append((label, "accent (selection marker)", palette["accent"], surface, surfaces[surface], 3.0))
    checks.append((label, "accent (focus ring)", palette["accent"], "field", surfaces["field"], 3.0))
for mode in ("light", "dark"):
    tokens, surfaces = classic(mode)
    for token, colour in tokens.items():
        for surface, background in surfaces.items():
            checks.append((f"Classic {mode}", token, colour, surface, background, 4.5))

failures = 0
for theme, token, colour, surface, background, minimum in checks:
    value = ratio(colour, background)
    if value < minimum:
        failures += 1
        print(f"FAIL {theme}: {token} #{colour} on {surface} #{background} = {value:.2f}:1 (needs {minimum}:1)")
if negative_test:
    if not failures:
        print("FAIL negative test: brand accent as text was not caught")
        sys.exit(1)
    print(f"Negative test passed: caught {failures} low-contrast brand-accent text uses")
else:
    print(f"{len(checks) - failures}/{len(checks)} contrast checks pass")
    sys.exit(1 if failures else 0)
