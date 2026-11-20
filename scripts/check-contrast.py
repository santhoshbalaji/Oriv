#!/usr/bin/env python3
"""Check app-owned text, borders and composited backings against WCAG thresholds."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Apps/Shared/Theme.swift"
text = SOURCE.read_text()
negative_test = "--negative-test" in sys.argv

def luminance(hex_value):
    channels = [int(hex_value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)

def block(start, end, source=None):
    source = text if source is None else source
    i = source.index(start)
    return source[i:source.index(end, i)]

def hex_tokens(source):
    return {name: value.upper() for name, value in re.findall(r"(\w+): (?:Self\.)?hex\(0x([0-9A-Fa-f]{6})\)", source)}

def adaptive_tokens(source):
    return {name: (light.upper(), dark.upper()) for name, _, light, dark in
            re.findall(r"(\w+)\s*[:=] adaptive\(\"(\w+)\", light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)", source)}

def split_palette(source, read, mode=0):
    content, sidebar = source.split("sidebar: SidebarPalette(", 1)
    return read(content, mode), read(sidebar, mode)

def light_or_dark(source, mode):
    return {name: values[mode] for name, values in adaptive_tokens(source).items()}

def composite(front, back, opacity):
    return "".join(f"{round(int(front[i:i+2], 16) * opacity + int(back[i:i+2], 16) * (1-opacity)):02X}" for i in (0, 2, 4))

def adaptive_constant(name, mode):
    return light_or_dark(block(f"let {name} =", "\n"), mode)[name]

palettes = [
    ("Graphite Light", 0, *split_palette(block("static let graphite =", "func respecting"), light_or_dark, 0)),
    ("Graphite Dark", 1, *split_palette(block("static let graphite =", "func respecting"), light_or_dark, 1)),
    ("T3 Code", 1, *split_palette(block("static let t3Code =", "static let graphite"), lambda source, _: hex_tokens(source))),
]
# Explicit text roles. Native controls inherit the OS accent, which can vary at runtime.
text_tokens = {"text", "secondaryText", "fieldText", "warning", "privateAccent"}
for source in (ROOT / "Apps").rglob("*.swift"):
    text_tokens.update(re.findall(r"\bText\([^;{}]*?\.foregroundStyle\(theme\.(\w+)\)", source.read_text()))

checks = []  # (theme, token, colour, surface, background, minimum)
sidebar_source = (ROOT / "Apps/macOS/Views/BrowserSidebar.swift").read_text()
assert "content.background(theme.sidebar.backing)" in sidebar_source
assert "reduceTransparency || captureReduceTransparency || contrast == .increased" in sidebar_source
assert "content.background(theme.sidebar.backing.opacity(effectiveOpacity.backingOpacity)" in sidebar_source
assert "selected ? theme.sidebar.selection" in sidebar_source
sidebar_opacities = {name: float(value) for name, value in re.findall(
    r"case \.(\w+): ([0-9.]+)", sidebar_source.split("enum SidebarGlassOpacity:", 1)[1].split("struct MacSidebarGlass:", 1)[0])}
assert sidebar_opacities == {"balanced": 0.83, "high": 0.92, "solid": 1.0}
focused_field, idle_field = map(float, re.search(
    r"background\(theme.sidebar.field.opacity\(searchFocused \? ([0-9.]+) : ([0-9.]+)\)", sidebar_source).groups())
tile_opacity = float(re.search(r"tile && !rail \? theme.sidebar.field.opacity\(([0-9.]+)\)", sidebar_source).group(1))
chrome = (ROOT / "Apps/Shared/BrowserChrome.swift").read_text()
opacity = float(re.search(r"theme.field.opacity\((0\.\d+)\)", chrome).group(1))
sidebar_negative = "--negative-sidebar-test" in sys.argv
sidebar_checks = []
for appearance, mode, palette, sidebar in palettes:
    palette["privateAccent"] = adaptive_constant("privateAccent", mode)
    if negative_test:
        palette["secondaryText"] = "888888"
    for accessibility in ("standard", "increase contrast"):
        colors = dict(palette)
        if accessibility == "increase contrast":
            if appearance == "T3 Code":
                colors["secondaryText"] = re.search(r"palette.secondaryText = isT3Code \? Self.hex\(0x(\w+)\)", text)[1]
                colors["separator"] = re.search(r"palette.separator = isT3Code \? Self.hex\(0x(\w+)\)", text)[1]
            else:
                colors["secondaryText"] = adaptive_constant("highContrastSecondary", mode)
                colors["separator"] = adaptive_constant("highContrastSeparator", mode)
        colors["fieldText"] = colors["secondaryText"]
        surfaces = {role: colors[role] for role in ("canvas", "surface", "row", "chrome", "field", "selection")}
        for token in sorted(text_tokens):
            for surface, background in surfaces.items():
                checks.append((appearance + " " + accessibility, token, colors[token], surface, background, 4.5))
        if accessibility == "increase contrast":
            for surface, background in surfaces.items():
                checks.append((appearance, "strong separator", colors["separator"], surface, background, 3))
        for page in ("FFFFFF", "000000"):
            backing = composite(colors["field"], page, opacity)
            for token in sorted(text_tokens):
                checks.append((appearance + " chrome glass", token, colors[token], "backing over #" + page, backing, 4.5))

        steps = {"increase contrast": 1.0} if accessibility == "increase contrast" else {
            **sidebar_opacities, "reduce transparency": 1.0}
        for step, backing_opacity in steps.items():
            for page in ("FFFFFF", "000000", "6000D9", "888888", "00D4C8", "FF8C24"):
                panel = composite(sidebar["backing"], page, 0 if sidebar_negative else backing_opacity)
                field = sidebar["field"]
                states = {"panel": panel, "selection / rail": sidebar["selection"], "hover": sidebar["hover"],
                          "pin": composite(field, panel, tile_opacity), "search": composite(field, panel, idle_field),
                          "focused search": composite(field, panel, focused_field), "footer": colors["surface"],
                          "pressed": sidebar["selection"]}
                label = f"{appearance} sidebar, page #{page}, {step}"
                for state, background in states.items():
                    for token in ("text", "secondaryText", "privateAccent"):
                        sidebar_checks.append((label, token, colors[token], state, background, 4.5))
                    if accessibility == "increase contrast":
                        sidebar_checks.append((label, "strong boundary", colors["text"], state, background, 3))

checks.extend(sidebar_checks)
worst = min((check for check in sidebar_checks if check[-1] == 4.5), key=lambda check: ratio(check[2], check[4]))
print(f"Sidebar minimum text contrast: {ratio(worst[2], worst[4]):.2f}:1 ({worst[0]}, {worst[1]} on {worst[3]})")
print("App-owned colors checked. Native system accent and compositor output depend on runtime settings.")

# Mac page chrome chooses black/white from the band's WCAG luminance. Read the
# actual lift constant and check RGB cube samples, every neutral and the theme
# colour. The capsule is opaque, so underlying page extremes cannot affect it.
mac = (ROOT / "Apps/macOS/Views/BrowserWindow.swift").read_text()
assert "foregroundThreshold = sqrt(1.05 * 0.05) - 0.05" in chrome
assert "private var chromeForeground: Color { pageChrome.foreground }" in mac
assert ".background(pageChrome.color)" in mac
lift = float(re.search(r"static let lift = ([0-9.]+)", mac).group(1))
shade = float(re.search(r"static let lightShade = ([0-9.]+)", mac).group(1))
page_colours = {f"{r:02X}{g:02X}{b:02X}" for r in range(0, 256, 17) for g in range(0, 256, 17) for b in range(0, 256, 17)}
page_colours.update(f"{c:02X}{c:02X}{c:02X}" for c in range(256))
page_colours.update(("1F6F5C", "FBFBF9", "111111"))
for page in sorted(page_colours):
    dark = luminance(page) < (1.05 * 0.05) ** 0.5 - 0.05
    foreground = "FFFFFF" if dark else "000000"
    checks.append(("Mac page band / reduced chrome", "foreground", foreground, "page", page, 4.5))
    source = [int(page[i:i+2], 16) / 255 for i in (0, 2, 4)]
    lifted = [c * (1 - lift) + lift if dark else c * (1 - shade) for c in source]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in lifted]
    lum = sum(a*b for a, b in zip(linear, (0.2126, 0.7152, 0.0722)))
    safe = 1.05 / (lum + 0.05) >= 4.55 if dark else (lum + 0.05) / 0.05 >= 4.55
    values = lifted if safe else [c * 0.88 if dark else c * 0.88 + 0.12 for c in source]
    backing = "".join(f"{round(c * 255):02X}" for c in values)
    checks.append(("Mac filled address capsule", "foreground", foreground, "page #" + page, backing, 4.5))

failures = 0
for theme, token, colour, surface, background, minimum in checks:
    value = ratio(colour, background)
    if value < minimum:
        failures += 1
        print(f"FAIL {theme}: {token} #{colour} on {surface} #{background} = {value:.2f}:1 (needs {minimum}:1)")
if negative_test or sidebar_negative:
    if not failures:
        print("FAIL negative test: low-contrast foreground was not caught")
        sys.exit(1)
    print(f"Negative test passed: caught {failures} low-contrast foreground uses")
else:
    print(f"{len(checks) - failures}/{len(checks)} contrast checks pass")
    sys.exit(1 if failures else 0)
