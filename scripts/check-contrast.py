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
    return luminance_ratio(luminance(a), luminance(b))

def luminance_ratio(a, b):
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)

def block(start, end, source=None):
    source = text if source is None else source
    i = source.index(start)
    return source[i:source.index(end, i)]

def hex_tokens(source):
    return {name: value.upper() for name, value in re.findall(r"(\w+): (?:Self\.)?hex\(0x([0-9A-Fa-f]{6})\)", source)}

def adaptive_tokens(source):
    return {name: (light.upper(), dark.upper()) for name, _, light, dark in
            re.findall(r"`?(\w+)`?\s*[:=] (?:Theme\.)?adaptive\(\"(\w+)\", light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)", source)}

def split_palette(source, read, mode=0):
    content, sidebar = source.split("sidebar: SidebarPalette(", 1)
    return read(content, mode), read(sidebar, mode)

def light_or_dark(source, mode):
    return {name: values[mode] for name, values in adaptive_tokens(source).items()}

def composite(front, back, opacity):
    return "".join(f"{round(int(front[i:i+2], 16) * opacity + int(back[i:i+2], 16) * (1-opacity)):02X}" for i in (0, 2, 4))

def adaptive_constant(name, mode):
    return light_or_dark(block(f"let {name if name != 'private' else '`private`'} =", "\n"), mode)[name]

palettes = [
    ("Graphite Light", 0, *split_palette(block("static let graphite =", "func respecting"), light_or_dark, 0)),
    ("Graphite Dark", 1, *split_palette(block("static let graphite =", "func respecting"), light_or_dark, 1)),
    ("Black", 1, *split_palette(block("static let t3Code =", "static let graphite"), lambda source, _: hex_tokens(source))),
]
# Text roles and their intended surfaces. Native controls inherit the OS accent.
text_tokens = ("text", "textSecondary", "warning", "private", "danger", "success")
base_surfaces = ("canvas", "surface", "surfaceRaised")
role_surfaces = {
    **{role: (*base_surfaces, "chrome", "fill", "fillSelected") for role in text_tokens},
    "textTertiary": base_surfaces,
    "private": (*base_surfaces, "chrome", "fill", "fillSelected", "privateWash"),
    "text": (*base_surfaces, "chrome", "fill", "fillSelected", "privateWash"),
}
negative_roles = ("danger", "success", "textTertiary", "privateWash", "onAccent")
role_negative = next((role for role in negative_roles if f"--negative-{role}-test" in sys.argv), None)
checks = []  # (theme, token, colour, surface, background, minimum)
sidebar_source = (ROOT / "Apps/macOS/Views/BrowserSidebar.swift").read_text()
assert "content.environment(\\.sidebarChromaticStyle, style)" in sidebar_source
assert ".opacity(style.opaque ? 1 : style.backingOpacity)" in sidebar_source
assert "Theme.hex(style.tokens.guardColor).opacity(style.guardOpacity)" in sidebar_source
assert "tone: !active && hovered ? .hover : nil" in sidebar_source
assert "shape.fill(style.fill)" in sidebar_source
assert "accessibilityReduceTransparency || chromeReduceTransparencyOverride || sidebarContrast == .increased" in sidebar_source
assert "tone.fill(in: theme, dark: dark, opaque: opaque)" in sidebar_source
native_sidebar = (ROOT / "Apps/macOS/Views/NativeSidebarTabs.swift").read_text()
assert "NSColor(Theme.sidebarKeyboardFocus).setStroke()" in native_sidebar
assert "ring.lineWidth = OrivOutline.focus" in native_sidebar
rail_search = (ROOT / "Apps/macOS/Views/SidebarSearchPanel.swift").read_text()
assert "SidebarSelectionSurface(active: active, radius: radius)" in rail_search
assert "strokeBorder(Theme.sidebarKeyboardFocus, lineWidth: OrivOutline.focus)" in rail_search
assert "icon.treatment(on: backing)" in text
tonal_opacities = {name: (float(light), float(dark)) for name, light, dark in re.findall(
    r"private static let (\w+)Tone = \(light: ([0-9.]+), dark: ([0-9.]+)\)", text)}
assert set(tonal_opacities) == {"selection", "hover", "search"}
search_field = (ROOT / "Apps/macOS/Views/Components/OrivSearchField.swift").read_text()
assert "SidebarToneSurface(tone: sidebar ? .search : nil)" in search_field
chrome = (ROOT / "Apps/Shared/BrowserChrome.swift").read_text()
control = block("struct BrowserGlass:", "private struct ChromeReduceTransparencyKey", chrome)
assert "accessibilityReduceTransparency" in control and "contrast == .increased" in control
assert "content.background(theme.fill, in: shape)" in control
assert "content.glassEffect(.regular.interactive(), in: shape)" in control
assert "theme.fill.opacity(" not in control
sidebar_negative = "--negative-sidebar-test" in sys.argv
tint_negative = "--negative-sidebar-tint-test" in sys.argv
focus_negative = "--negative-sidebar-focus-test" in sys.argv
active_negative = "--negative-sidebar-active-test" in sys.argv
plate_negative = "--negative-sidebar-plate-test" in sys.argv
sidebar_checks = []
selection_checks = []
levels = {}
tints = {}
for name, fields in re.findall(r"private static let (\w+) = Self\((top: 0x[\s\S]+?)\)", text):
    tints[name] = dict(re.findall(r"(\w+): 0x([0-9A-F]{6})", fields))
tint_names = {"graphite", "rose", "peach", "butter", "mint", "sage", "sky", "lavender",
          "mulberry", "ocean", "fern", "amber", "slate"}
assert set(tints) == {name + mode for name in tint_names for mode in ("Light", "Dark")} | {"black"}
assert all(set(tokens) == {"top", "bottom", "bloom", "guardColor", "active", "ink", "rim", "opaqueActive"}
           for tokens in tints.values())

def numeric_token(name):
    return float(re.search(rf"static let {name} = ([0-9.]+)", text)[1])

def pair_token(name):
    return tuple(map(float, re.search(rf"static let {name} = \(\w+: ([0-9.]+), \w+: ([0-9.]+)\)", text).groups()))

def hex_token(name):
    return re.search(rf"static let {name}: UInt32 = 0x([0-9A-F]{{6}})", text)[1]

balanced_backing = pair_token("balancedBacking")
balanced_guard = pair_token("balancedGuard")
black_backing = pair_token("blackBacking")
high_backing = numeric_token("highBacking")
sheen = pair_token("satinSheen")
bloom_alpha = pair_token("satinBloom")
active_alpha = pair_token("activeOpacity")
cushion_mix = pair_token("cushionHue")
assert all(0 < alpha < high_backing < 1 for alpha in balanced_backing)
assert balanced_backing[0] == balanced_backing[1] and balanced_guard[0] == balanced_guard[1]
assert 0 < black_backing[0] < black_backing[1] < 1

def record(level, label, role, ink, state, background, minimum, bucket):
    bucket.append((label, role, ink, state, background, minimum))
    minima = levels.setdefault(level, {})
    minima[role] = min(minima.get(role, float("inf")), ratio(ink, background))

def check_chromatic(label, level, mode, black, tokens, panel, palette, sidebar):
    opaque = level in ("solid", "reduce transparency", "increase contrast")
    tonal_ink = "FFFFFF" if mode else "000000"
    hover = sidebar["hover"] if opaque or black else composite(tonal_ink, panel, tonal_opacities["hover"][mode])
    active = tokens["opaqueActive"] if opaque else composite(tokens["active"], panel, active_alpha[mode])
    active_hover = sidebar["hover"] if opaque or black else composite(tonal_ink, active, tonal_opacities["hover"][mode])
    focus = adaptive_constant("sidebarKeyboardFocus", mode)
    primary = palette["text"] if black else adaptive_constant("primaryInk", mode)
    secondary = palette["textSecondary"] if opaque and level == "increase contrast" else adaptive_constant("secondaryInk", mode)
    private = adaptive_constant("glassPrivate", mode)
    pressed = sidebar["selection"] if opaque or black else composite("FFFFFF", panel, tonal_opacities["selection"][mode])
    for state, background in (("panel", panel), ("hover", hover), ("pressed", pressed),
                              ("search field", sidebar["field"] if opaque or black else
                               composite(tonal_ink, panel, tonal_opacities["search"][mode]))):
        for role, ink in (("primary", primary), ("secondary", secondary), ("private", private),
                          ("panel text", palette["text"]), ("panel secondary", adaptive_constant("glassSecondary", mode))):
            record(level, label, role, ink, state, background, 4.5, sidebar_checks)
    for state, background in (("active", active), ("active accessory hover", active_hover)):
        record(level, label, "selected text", background if active_negative else tokens["ink"],
               state, background, 4.5, selection_checks)
    for state, background in (("panel", panel), ("hover", hover), ("active", active)):
        record(level, label, "focus ring", composite(focus, background, 0.35) if focus_negative else focus,
               state, background, 3, selection_checks)
    if level == "increase contrast":
        for state, background in (("panel", panel), ("active", active)):
            record(level, label, "active outline", tokens["ink"], state, background, 3, selection_checks)
    record(level, label, "private glasses", palette["private"], "fallback icon", palette["fill"], 3, selection_checks)
    record(level, label, "private badge", private, "badge", palette["surface"], 3, selection_checks)

def check_plates(level, label, tokens):
    light = composite(tokens["bloom"], hex_token("lightFrost"), cushion_mix[0])
    dark = composite(tokens["bloom"], hex_token("darkFrost"), cushion_mix[1])
    if plate_negative:
        light = dark = "888888"
    # Every sRGB luminance from 0 to 1. The analytical crossover is the
    # minimum between light and dark plates. Peak luminance can only help.
    crossover = ((luminance(light) + 0.05) * (luminance(dark) + 0.05)) ** 0.5 - 0.05
    if not plate_negative and luminance_ratio(luminance(light), crossover) < 3:
        sys.exit(f"FAIL {label}: frosted plate crossover was below 3:1")
    for channel in range(256):
        ink = f"{channel:02X}" * 3
        plate = max((light, dark), key=lambda background: ratio(ink, background))
        record(level, label, "icon cushion", ink, "resolved frost", plate, 3, selection_checks)

for appearance, mode, palette, sidebar in palettes:
    for role in ("private", "privateWash", "danger", "success"):
        palette[role] = adaptive_constant(role, mode)
    if negative_test:
        palette["textSecondary"] = "888888"
    for accessibility in ("standard", "increase contrast"):
        colors = dict(palette)
        if accessibility == "increase contrast":
            if appearance == "Black":
                colors["textSecondary"] = re.search(r"palette.textSecondary = isT3Code \? Self.hex\(0x(\w+)\)", text)[1]
                colors["separator"] = re.search(r"separatorStrong: Color \{ isT3Code \? Self.hex\(0x(\w+)\)", text)[1]
            else:
                colors["textSecondary"] = adaptive_constant("highContrastSecondary", mode)
                colors["separator"] = adaptive_constant("highContrastSeparator", mode)
        for token, surfaces in role_surfaces.items():
            for surface in surfaces:
                foreground = colors[surface] if token == role_negative else colors[token]
                background = colors[token] if surface == role_negative else colors[surface]
                checks.append((appearance + " " + accessibility, token, foreground, surface, background, 4.5))
        if accessibility == "increase contrast":
            for surface in role_surfaces["text"]:
                checks.append((appearance, "strong separator", colors["separator"], surface, colors[surface], 3))
        # The accessible control uses opaque fill; live regular glass and
        # system ink are evaluated by the compositor on a device.
        for role in ("text", "textSecondary", "private"):
            checks.append((appearance + " solid control", role, colors[role], "fill", colors["fill"], 4.5))
        checks.append((appearance + " solid control", "controlPrivate",
                       adaptive_constant("controlPrivate", mode), "fill", colors["fill"], 4.5))

        steps = ("increase contrast",) if accessibility == "increase contrast" else (
            "balanced", "high", "solid", "reduce transparency")
        black = appearance == "Black"
        for key, recipe in tints.items():
            if (black and key != "black") or (not black and not key.endswith("Dark" if mode else "Light")):
                continue
            tokens = dict(recipe)
            if key == "roseLight" and tint_negative:
                tokens["top"] = tokens["bottom"] = "888888"
            for step in steps:
                opaque = step not in ("balanced", "high")
                opacity = 1 if opaque else (
                    black_backing[step == "high"] if black else high_backing if step == "high" else balanced_backing[mode])
                guard = numeric_token("blackGuard") if black else balanced_guard[mode]
                label = f"{key} sidebar, {step}"
                check_plates(step, label, tokens)
                for material in ("FFFFFF", "000000", "6000D9", "888888", "00D4C8", "FF8C24", "1C3354",
                                 "33919C", "FCC775", "D15959", "404585", "F7E6CC", "1C1C1E"):
                    glass = composite(tokens["guardColor"], material, guard)
                    top = composite(tokens["top"], glass, 0 if sidebar_negative else opacity)
                    bottom = composite(tokens["bottom"], glass, 0 if sidebar_negative else opacity)
                    surfaces = [top, bottom]
                    if not opaque and not black:
                        bloom = composite(tokens["bloom"], top, bloom_alpha[mode])
                        surfaces.extend((composite("FFFFFF", top, sheen[mode]),
                                         bloom, composite("FFFFFF", bloom, sheen[mode])))
                    for panel in surfaces:
                        check_chromatic(label, step, mode, black, tokens, panel, colors, sidebar)
                check_chromatic(f"{key} rail search, {step}", step, mode, black, tokens,
                                colors["surface"], colors, sidebar)
            if not black:
                sidebar_checks.append((f"{key} swatch", "checkmark", colors["text"], "swatch", tokens["top"], 3))

checks.extend(sidebar_checks)
checks.extend(selection_checks)
for step, minima in levels.items():
    roles = ("primary", "secondary", "private", "selected text", "focus ring", "icon cushion")
    numbers = " / ".join(f"{minima[role]:.2f}" for role in roles)
    print(f"{step.capitalize()} (primary / secondary / private / selected text / focus ring / icon cushion): {numbers}")

# Settings owns the foreground and the opaque card. The full-opacity AppKit
# material is the gutter input. Sample its possible output, including both
# luminance endpoints. The native toolbar uses system ink.
settings = (ROOT / "Apps/macOS/Views/AppearanceSettings.swift").read_text()
settings_group = block("private struct SettingsGroupSurface:", "/// A native pop-up", settings)
assert "WindowBackdropMaterial(material: .underWindowBackground)" in settings
assert "var opacity: CGFloat = 1\n" in (ROOT / "Apps/macOS/Views/BrowserWindowChrome.swift").read_text()
assert ".background(theme.surfaceRaised, in: shape)" in settings_group
assert ".strokeBorder(theme.separator, lineWidth: increased ? 1.5 : 0.5)" in settings_group
assert "appearance == .t3Code || reduceTransparency || contrast == .increased" in settings
assert "theme.canvas.ignoresSafeArea()" in settings
settings_negative = "--negative-settings-test" in sys.argv
settings_checks = []
for appearance, mode, palette, _ in palettes:
    for variant in ("standard", "reduce transparency", "increase contrast"):
        solid = appearance == "Black" or variant != "standard"
        secondary = palette["textSecondary"]
        if variant == "increase contrast":
            secondary = (re.search(r"palette.textSecondary = isT3Code \? Self.hex\(0x(\w+)\)", text)[1]
                         if appearance == "Black" else adaptive_constant("highContrastSecondary", mode))
        gutters = ((palette["canvas"],) if solid else
                   (palette["chrome"], "FFFFFF", "000000", "6000D9", "00D4C8", "FF8C24"))
        minima = [float("inf"), float("inf")]
        for gutter in gutters:
            card = composite(palette["surfaceRaised"], gutter, 0.5 if settings_negative else 1.0)
            label = f"{appearance} Settings / {variant} / gutter #{gutter}"
            for index, (role, ink, minimum) in enumerate((
                ("primary", palette["text"], 7.0),
                ("secondary", secondary, 4.5),
            )):
                settings_checks.append((label, role, ink, "card", card, minimum))
                minima[index] = min(minima[index], ratio(ink, card))
            if variant == "increase contrast":
                strong = (re.search(r"separatorStrong: Color \{ isT3Code \? Self.hex\(0x(\w+)\)", text)[1]
                          if appearance == "Black" else adaptive_constant("highContrastSeparator", mode))
                settings_checks.append((label, "strong boundary", strong, "card", card, 3.0))
                settings_checks.append((label, "strong boundary", strong, "canvas", gutter, 3.0))
        print(f"{appearance} Settings / {variant} (primary / secondary): {minima[0]:.2f} / {minima[1]:.2f}")
print("Settings material opacity: 100%")
checks.extend(settings_checks)
print("App-owned colors checked. Native system accent and compositor output depend on runtime settings.")

# Mac page chrome chooses black/white from the band's WCAG luminance. Read the
# actual lift constant and check RGB cube samples, every neutral and the theme
# colour. The capsule is opaque, so underlying page extremes cannot affect it.
mac = (ROOT / "Apps/macOS/Views/BrowserWindow.swift").read_text()
assert "foregroundThreshold = sqrt(1.05 * 0.05) - 0.05" in chrome
assert "private var chromeForeground: Color { pageChrome.foreground }" in mac
assert "pageChrome.color\n" in mac
assert "Rectangle().fill(.clear).glassEffect(.regular, in: .rect)" in sidebar_source
lift = float(re.search(r"static let lift = ([0-9.]+)", mac).group(1))
shade = float(re.search(r"static let lightShade = ([0-9.]+)", mac).group(1))
page_colours = {f"{r:02X}{g:02X}{b:02X}" for r in range(0, 256, 17) for g in range(0, 256, 17) for b in range(0, 256, 17)}
page_colours.update(f"{c:02X}{c:02X}{c:02X}" for c in range(256))
page_colours.update(("1F6F5C", "FBFBF9", "111111"))
focused_mix = float(re.search(r"static let focusedMix = ([0-9.]+)", mac)[1])
hint_opacity = float(re.search(r"static let placeholderOpacity = ([0-9.]+)", mac)[1])
focus_opacity = float(re.search(r"static let focusOpacity = ([0-9.]+)", mac)[1])

def rgb_hex(values):
    return "".join(f"{round(c * 255):02X}" for c in values)

for page in sorted(page_colours):
    dark = luminance(page) < (1.05 * 0.05) ** 0.5 - 0.05
    ink = int(dark)
    neutral = 1 - ink
    foreground = "FFFFFF" if dark else "000000"
    checks.append(("Mac page band / reduced chrome", "foreground", foreground, "page", page, 4.5))
    source = [int(page[i:i+2], 16) / 255 for i in range(0, 6, 2)]
    idle = [c * (1 - lift) + lift if dark else c * (1 - shade) for c in source]
    focused = [c * (1 - focused_mix) + neutral * focused_mix for c in source]
    def hint(values):
        return rgb_hex(c * (1 - hint_opacity) + ink * hint_opacity for c in values)
    for label, candidate in (("idle", idle), ("focused", focused)):
        values = candidate if ratio(hint(candidate), rgb_hex(candidate)) >= 4.55 else [
            c * 0.60 + neutral * 0.40 for c in source
        ]
        backing = rgb_hex(values)
        checks.append((f"Mac address capsule / {label}", "foreground", foreground, "page #" + page, backing, 4.5))
        checks.append((f"Mac address capsule / {label}", "placeholder", hint(values), "page #" + page, backing, 4.5))
        if label == "focused":
            ring = composite(foreground, backing, focus_opacity)
            checks.append(("Mac address capsule / focused", "focus ring", ring, "page #" + page, backing, 3))

# A system accent can be any luminance. Check both ends and the crossover.
assert "luminance(resolvedAccent) < sqrt(1.05 * 0.05) - 0.05" in text
for accent in sorted(page_colours):
    ink = "FFFFFF" if luminance(accent) < (1.05 * 0.05) ** 0.5 - 0.05 else "000000"
    checks.append(("System accent", "onAccent", accent if role_negative == "onAccent" else ink, "accent", accent, 4.5))

failures = 0
reported = set()
for theme, token, colour, surface, background, minimum in checks:
    value = ratio(colour, background)
    if value < minimum:
        failures += 1
        if (theme, token) in reported:
            continue
        reported.add((theme, token))
        print(f"FAIL {theme}: {token} #{colour} on {surface} #{background} = {value:.2f}:1 (needs {minimum}:1)")
if focus_negative or active_negative or plate_negative:
    role = "focus ring" if focus_negative else "selected text" if active_negative else "icon cushion"
    if not failures or any(token != role for _, token in reported):
        sys.exit(f"FAIL negative sidebar test: expected only {role} regressions")
    print(f"Negative sidebar {role} test passed: caught {failures} low-contrast uses")
elif settings_negative:
    if not any(ratio(ink, card) < minimum for _, _, ink, _, card, minimum in settings_checks):
        sys.exit("FAIL negative Settings test: translucent Settings card was not caught")
    print("Negative Settings test passed")
elif tint_negative:
    caught = any(label.startswith("roseLight sidebar,") and ratio(foreground, background) < minimum
                 for label, _, foreground, _, background, minimum in sidebar_checks)
    if not caught:
        sys.exit("FAIL negative tint test: low-contrast Rose backing was not caught")
    print(f"Negative tint test passed: caught {failures} low-contrast uses")
elif role_negative:
    if not any((role_negative in (token, surface)) and ratio(foreground, background) < minimum
               for _, token, foreground, surface, background, minimum in checks):
        sys.exit(f"FAIL negative test: {role_negative} regression was not caught")
    print(f"Negative {role_negative} test passed")
elif negative_test or sidebar_negative:
    if not failures:
        print("FAIL negative test: low-contrast foreground was not caught")
        sys.exit(1)
    print(f"Negative test passed: caught {failures} low-contrast foreground uses")
else:
    print(f"{len(checks) - failures}/{len(checks)} contrast checks pass")
    sys.exit(1 if failures else 0)
