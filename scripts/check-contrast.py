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
assert "OrivMacV3.Sidebar.chromaticSwatches(" in sidebar_source
assert "orivV3Glass(recipe, in: shape, forceSolid: effectiveOpacity == .solid)" in sidebar_source
assert "OrivMacV3.Radius.sidebar" in sidebar_source
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

# Mac Design v3 glass toolbar & solid fallback source and contrast checks.
# Live glass relies on system Liquid Glass legibility (Q6); solid paths
# (Reduce Transparency, Increase Contrast, Black, off-screen fallback) use
# OrivMacV3 toolbar/address tokens and PageChrome polarity on solid page bands.
mac = (ROOT / "Apps/macOS/Views/BrowserWindow.swift").read_text()
assert "foregroundThreshold = sqrt(1.05 * 0.05) - 0.05" in chrome
assert "GlassEffectContainer(" in mac
assert "OrivMacV3.Toolbar.groupTint(" in mac
assert "OrivMacV3.Toolbar.scrollEdge(" in mac
assert "OrivMacV3.Address.restFill(" in mac
assert "OrivMacV3.Address.focusFill(" in mac
assert "ConnectionCue(" in mac and "cue.color(theme)" in mac
assert ".scrollEdgeEffectStyle(.soft, for: .top)" in mac
assert "MacAddressPalette" not in mac
assert "pageChrome.color\n" not in mac
assert ".glassEffect(.regular.tint(recipe.tintColor.opacity(recipe.tintOpacity)), in: shape)" in text
assert "shape.fill(guardColor.opacity(recipe.guardOpacity))" in text
assert "OrivMacV3.usesOpaqueSurface(" in text

page_colours = {f"{r:02X}{g:02X}{b:02X}" for r in range(0, 256, 17) for g in range(0, 256, 17) for b in range(0, 256, 17)}
page_colours.update(f"{c:02X}{c:02X}{c:02X}" for c in range(256))
page_colours.update(("1F6F5C", "FBFBF9", "111111"))

for page in sorted(page_colours):
    dark = luminance(page) < (1.05 * 0.05) ** 0.5 - 0.05
    foreground = "FFFFFF" if dark else "000000"
    checks.append(("PageChrome solid band", "foreground", foreground, "page", page, 4.5))

# A system accent can be any luminance. Check both ends and the crossover.
assert "luminance(resolvedAccent) < sqrt(1.05 * 0.05) - 0.05" in text
for accent in sorted(page_colours):
    ink = "FFFFFF" if luminance(accent) < (1.05 * 0.05) ** 0.5 - 0.05 else "000000"
    checks.append(("System accent", "onAccent", accent if role_negative == "onAccent" else ink, "accent", accent, 4.5))

# Oriv Mac Design v3 token & glass-layering contrast checks (§2–§4, §6.3).
v3_block = block("enum OrivMacV3 {", "\nextension View {", text)

def v3_hex(name):
    match = re.search(rf"static let {name}: UInt32 = 0x([0-9A-Fa-f]{{6}})", v3_block)
    assert match, f"Missing OrivMacV3 hex token: {name}"
    return match.group(1).upper()

def v3_float(name):
    match = re.search(rf"static let {name}(?:: Double)? = ([0-9.]+)", v3_block)
    assert match, f"Missing OrivMacV3 float token: {name}"
    return float(match.group(1))

def v3_hex_list(name):
    match = re.search(rf"static let {name}: \[UInt32\] = \[([^\]]+)\]", v3_block)
    assert match, f"Missing OrivMacV3 hex array: {name}"
    return [h.upper() for h in re.findall(r"0x([0-9A-Fa-f]{6})", match.group(1))]

def v3_glows(name):
    match = re.search(rf"static let {name}: \[RadialGlow\] = \[([\s\S]+?)\n        \]", v3_block)
    assert match, f"Missing OrivMacV3 glows: {name}"
    return [(h.upper(), float(op)) for h, op in re.findall(r"RadialGlow\(hex: 0x([0-9A-Fa-f]{6}), opacity: ([0-9.]+)", match.group(1))]

v3_tint_pair = tuple(map(float, re.search(
    r"static let v3TintOpacity = \(balanced: ([0-9.]+), high: ([0-9.]+)\)", v3_block).groups()))
v3_high_guard = v3_float("v3HighGuardOpacity")
v3_solid_mix = v3_float("v3ChromaticSolidMix")
v3_guards_block = re.search(r"static let v3BalancedGuardByTint: \[String: Double\] = \[([\s\S]+?)\n        \]", v3_block).group(1)
v3_guards = {k: float(v) for k, v in re.findall(r'"(\w+)": ([0-9.]+)', v3_guards_block)}
assert set(v3_guards) == ({name + mode for name in tint_names for mode in ("Light", "Dark")} | {"private", "black"})
assert all(0 < t <= 0.35 for t in v3_tint_pair), f"v3 tint opacity exceeds 0.35 cap: {v3_tint_pair}"
assert 0 <= v3_high_guard <= 0.20, f"v3 high guard exceeds 0.20 cap: {v3_high_guard}"
assert all(0 <= g <= 0.20 for g in v3_guards.values()), f"v3 balanced guard exceeds 0.20 cap: {v3_guards}"

v3_negative = "--negative-v3-test" in sys.argv

# Window backdrop gradient stops + radial glows (sidebar floats over the backdrop, not over web content).
v3_light_stops = v3_hex_list("lightStops")
v3_dark_stops = v3_hex_list("darkStops")
v3_priv_stops = v3_hex_list("privateStops")
v3_light_backdrops = list(v3_light_stops) + [
    composite(gh, v3_light_stops[i % len(v3_light_stops)], gop)
    for i, (gh, gop) in enumerate(v3_glows("lightAmbient"))
] + [v3_hex("startLightBaseHex")] + [
    composite(gh, v3_hex("startLightBaseHex"), gop)
    for gh, gop in v3_glows("startLightAmbient")
]
v3_dark_backdrops = list(v3_dark_stops) + [
    composite(gh, v3_dark_stops[i % len(v3_dark_stops)], gop)
    for i, (gh, gop) in enumerate(v3_glows("darkAmbient"))
] + [
    composite("3E6CC6", v3_hex("startDarkBaseHex"), 0.38),
    composite("2C8092", v3_hex("startDarkBaseHex"), 0.30),
]
v3_priv_backdrops = list(v3_priv_stops) + [
    composite(gh, v3_priv_stops[i % len(v3_priv_stops)], gop)
    for i, (gh, gop) in enumerate(v3_glows("privateAmbient"))
]

v3_inks = {
    "light": (v3_hex("primaryLightHex"), v3_hex("secondaryLightHex"), v3_hex("tertiarySidebarLightHex"),
              v3_hex("secondaryICLightHex"), v3_hex("tertiaryCardLightHex")),
    "dark": (v3_hex("primaryDarkHex"), v3_hex("secondaryDarkHex"), v3_hex("tertiarySidebarDarkHex"),
             v3_hex("secondaryICDarkHex"), v3_hex("tertiaryCardDarkHex")),
    "black": (v3_hex("primaryBlackHex"), v3_hex("secondaryBlackHex"), v3_hex("tertiarySidebarBlackHex"),
              v3_hex("secondaryICBlackHex"), v3_hex("tertiaryCardBlackHex")),
    "private": (v3_hex("primaryPrivateHex"), v3_hex("secondaryPrivateHex"), v3_hex("tertiarySidebarPrivateHex"),
                v3_hex("secondaryICPrivateHex"), v3_hex("tertiaryCardPrivateHex")),
}
v3_focus_rings = {
    "light": v3_hex("sidebarRingLightHex"),
    "dark": v3_hex("sidebarRingDarkHex"),
    "black": v3_hex("sidebarRingDarkHex"),
    "private": v3_hex("sidebarRingPrivateHex"),
}
v3_ic_borders = {
    "light": v3_hex("rimICLightHex"),
    "dark": v3_hex("rimICDarkHex"),
    "black": v3_hex("rimICBlackHex"),
    "private": v3_hex("rimICPrivateHex"),
}

v3_checks = []
v3_sidebar_minima = {}

def v3_record(level, label, role, fg, surface, bg, minimum):
    v3_checks.append((label, role, fg, surface, bg, minimum))
    if level is not None:
        bucket = v3_sidebar_minima.setdefault(level, {})
        bucket[role] = min(bucket.get(role, float("inf")), ratio(fg, bg))

v3_sidebar_entries = []
for key, tok in sorted(tints.items()):
    if key == "black":
        v3_sidebar_entries.append(("black", "black", "0A0A0A", "0A0A0A", "000000", "0A0A0A", "0A0A0A",
                                   "292E37", "292E37", 1.0, "252A32", v3_hex("activeInkBlackHex"), ["000000"]))
        continue
    mode = "dark" if key.endswith("Dark") else "light"
    bgs = v3_dark_backdrops if mode == "dark" else v3_light_backdrops
    if key == "graphiteLight":
        v3_sidebar_entries.append((key, mode, "F7F9FE", "EEF2FA", "FFFFFF", "F2F4FA", "E6EAF3",
                                   "FFFFFF", "E0EEFF", 0.82, "E5F0FE", v3_hex("activeInkLightHex"), bgs))
    elif key == "graphiteDark":
        v3_sidebar_entries.append((key, mode, "242A3A", "191E2A", "0E1118", "242A3A", "191E2A",
                                   "4E86E0", "3666B2", 0.37, "2E5A8F", v3_hex("activeInkDarkHex"), bgs))
    else:
        base_bg = v3_hex("reducedDarkHex") if mode == "dark" else v3_hex("reducedLightHex")
        v3_sidebar_entries.append((key, mode, tok["top"], tok["bottom"], tok["guardColor"],
                                   composite(tok["top"], base_bg, v3_solid_mix),
                                   composite(tok["bottom"], base_bg, v3_solid_mix),
                                   tok["active"], tok["active"], active_alpha[mode == "dark"],
                                   tok["opaqueActive"], tok["ink"], bgs))

v3_sidebar_entries.append(("private", "private", "301C4E", "1E1232", "120C1C", "301C4E", "1E1232",
                           "A855F7", "7E22CE", 0.36, "5A2C8A", v3_hex("activeInkPrivateHex"), v3_priv_backdrops))

for (key, mode, tint_top, tint_bot, guard_col, solid_top, solid_bot,
     act_top, act_bot, act_alpha, act_solid, act_ink, backdrops) in v3_sidebar_entries:
    primary, secondary, tertiary, sec_ic, _ = v3_inks[mode]
    focus_ring = v3_focus_rings[mode]
    ic_border = v3_ic_borders[mode]
    hover_col = "D8B4FE" if mode == "private" else ("FFFFFF" if mode != "light" else "141A28")
    hover_a = 0.08 if mode == "private" else (0.06 if mode != "light" else 0.05)
    search_col = hover_col
    search_a = 0.075 if mode == "private" else (0.065 if mode != "light" else 0.055)
    for step in ("balanced", "high", "solid", "reduce transparency", "increase contrast"):
        opaque = step in ("solid", "reduce transparency", "increase contrast") or mode == "black"
        tint_a = v3_tint_pair[1] if step == "high" else v3_tint_pair[0]
        guard_a = v3_high_guard if step == "high" else v3_guards[key]
        if v3_negative and key == "skyDark" and step == "balanced":
            guard_a = 0.0
        label = f"v3 {key} sidebar, {step}"
        surfaces = ([solid_top, solid_bot] if opaque else [
            composite(guard_col, composite(stop, bg, tint_a), guard_a)
            for bg in backdrops for stop in (tint_top, tint_bot)
        ])
        sec_ink = sec_ic if step == "increase contrast" else secondary
        ter_ink = sec_ic if step == "increase contrast" else tertiary
        for panel in surfaces:
            hover = composite(hover_col, panel, hover_a)
            search = composite(search_col, panel, search_a)
            for state, bg in (("panel", panel), ("hover", hover), ("search", search)):
                v3_record(step, label, "primary", primary, state, bg, 4.5)
                v3_record(step, label, "secondary", sec_ink, state, bg, 4.5)
                v3_record(step, label, "tertiary", ter_ink, state, bg, 4.5)
            act_surfaces = [act_solid] if opaque else [composite(act_top, panel, act_alpha), composite(act_bot, panel, act_alpha)]
            for act_bg in act_surfaces:
                v3_record(step, label, "active", act_ink, "active row", act_bg, 4.5)
                v3_record(step, label, "focus ring", focus_ring, "active row", act_bg, 3.0)
            v3_record(step, label, "focus ring", focus_ring, "panel", panel, 3.0)
            if step == "increase contrast":
                v3_record(step, label, "ic border", ic_border, "panel", panel, 3.0)

for step, minima in v3_sidebar_minima.items():
    roles = ("primary", "secondary", "tertiary", "active", "focus ring")
    numbers = " / ".join(f"{minima[r]:.2f}" for r in roles)
    print(f"v3 {step.capitalize()} (primary / secondary / tertiary / active / focus ring): {numbers}")

# Toolbar, Address, Popover, Suggestions, Handoff, Start Page solid fallbacks, focus rings, and IC borders.
v3_surface_pairs = [
    # Toolbar solid fallbacks
    ("v3 Toolbar Light solid", "primary", v3_hex("primaryLightHex"), v3_hex("solidLightHex"), 4.5),
    ("v3 Toolbar Light solid", "secondary", v3_hex("secondaryLightHex"), v3_hex("solidLightHex"), 4.5),
    ("v3 Toolbar Dark solid", "primary", v3_hex("primaryDarkHex"), v3_hex("solidDarkHex"), 4.5),
    ("v3 Toolbar Dark solid", "secondary", v3_hex("secondaryDarkHex"), v3_hex("solidDarkHex"), 4.5),
    ("v3 Toolbar Black solid", "primary", v3_hex("primaryBlackHex"), v3_hex("solidBlackHex"), 4.5),
    ("v3 Toolbar Black solid", "secondary", v3_hex("secondaryBlackHex"), v3_hex("solidBlackHex"), 4.5),
    ("v3 Toolbar Private solid", "primary", v3_hex("primaryPrivateHex"), v3_hex("solidPrivateHex"), 4.5),
    ("v3 Toolbar Private solid", "secondary", v3_hex("secondaryPrivateHex"), v3_hex("solidPrivateHex"), 4.5),
    # Address rest & focused solid fallbacks
    ("v3 Address Light rest", "primary", v3_hex("primaryLightHex"), v3_hex("restSolidLightHex"), 4.5),
    ("v3 Address Light rest", "secondary", v3_hex("secondaryLightHex"), v3_hex("restSolidLightHex"), 4.5),
    ("v3 Address Dark rest", "primary", v3_hex("primaryDarkHex"), v3_hex("restSolidDarkHex"), 4.5),
    ("v3 Address Dark rest", "secondary", v3_hex("secondaryDarkHex"), v3_hex("restSolidDarkHex"), 4.5),
    ("v3 Address Black rest", "primary", v3_hex("primaryBlackHex"), v3_hex("restSolidBlackHex"), 4.5),
    ("v3 Address Black rest", "secondary", v3_hex("secondaryBlackHex"), v3_hex("restSolidBlackHex"), 4.5),
    ("v3 Address Private rest", "primary", v3_hex("primaryPrivateHex"), v3_hex("restSolidPrivateHex"), 4.5),
    ("v3 Address Private rest", "secondary", v3_hex("secondaryPrivateHex"), v3_hex("restSolidPrivateHex"), 4.5),
    ("v3 Address Light focus", "primary", v3_hex("primaryLightHex"), v3_hex("focusSolidLightHex"), 4.5),
    ("v3 Address Light focus", "secondary", v3_hex("secondaryLightHex"), v3_hex("focusSolidLightHex"), 4.5),
    ("v3 Address Light focus", "tertiary", v3_hex("tertiaryCardLightHex"), v3_hex("focusSolidLightHex"), 4.5),
    ("v3 Address Dark focus", "primary", v3_hex("primaryDarkHex"), v3_hex("focusSolidDarkHex"), 4.5),
    ("v3 Address Dark focus", "secondary", v3_hex("secondaryDarkHex"), v3_hex("focusSolidDarkHex"), 4.5),
    ("v3 Address Black focus", "primary", v3_hex("primaryBlackHex"), v3_hex("focusSolidBlackHex"), 4.5),
    ("v3 Address Black focus", "secondary", v3_hex("secondaryBlackHex"), v3_hex("focusSolidBlackHex"), 4.5),
    ("v3 Address Private focus", "primary", v3_hex("primaryPrivateHex"), v3_hex("focusSolidPrivateHex"), 4.5),
    ("v3 Address Private focus", "secondary", v3_hex("secondaryPrivateHex"), v3_hex("focusSolidPrivateHex"), 4.5),
    ("v3 Address Private pill", "ink", v3_hex("privatePillInkHex"), composite("C084FC", v3_hex("restSolidPrivateHex"), 0.24), 4.5),
    ("v3 Address Private pill solid", "ink", v3_hex("privatePillSolidInkHex"), v3_hex("privatePillSolidFillHex"), 4.5),
    # Semantic ConnectionCue (warning & danger) and IC secondary ink on v3 solid address pills
    ("v3 Address Light rest", "warning cue", palettes[0][2]["warning"], v3_hex("restSolidLightHex"), 4.5),
    ("v3 Address Light rest", "danger cue", adaptive_constant("danger", 0), v3_hex("restSolidLightHex"), 4.5),
    ("v3 Address Light rest", "secondary IC", v3_hex("secondaryICLightHex"), v3_hex("restSolidLightHex"), 4.5),
    ("v3 Address Dark rest", "warning cue", palettes[1][2]["warning"], v3_hex("restSolidDarkHex"), 4.5),
    ("v3 Address Dark rest", "danger cue", adaptive_constant("danger", 1), v3_hex("restSolidDarkHex"), 4.5),
    ("v3 Address Dark rest", "secondary IC", v3_hex("secondaryICDarkHex"), v3_hex("restSolidDarkHex"), 4.5),
    ("v3 Address Black rest", "warning cue", palettes[2][2]["warning"], v3_hex("restSolidBlackHex"), 4.5),
    ("v3 Address Black rest", "danger cue", adaptive_constant("danger", 1), v3_hex("restSolidBlackHex"), 4.5),
    ("v3 Address Black rest", "secondary IC", v3_hex("secondaryICBlackHex"), v3_hex("restSolidBlackHex"), 4.5),
    ("v3 Address Private rest", "warning cue", palettes[1][2]["warning"], v3_hex("restSolidPrivateHex"), 4.5),
    ("v3 Address Private rest", "danger cue", adaptive_constant("danger", 1), v3_hex("restSolidPrivateHex"), 4.5),
    ("v3 Address Private rest", "secondary IC", v3_hex("secondaryICPrivateHex"), v3_hex("restSolidPrivateHex"), 4.5),
    ("v3 Address Light focus", "warning cue", palettes[0][2]["warning"], v3_hex("focusSolidLightHex"), 4.5),
    ("v3 Address Light focus", "danger cue", adaptive_constant("danger", 0), v3_hex("focusSolidLightHex"), 4.5),
    ("v3 Address Dark focus", "warning cue", palettes[1][2]["warning"], v3_hex("focusSolidDarkHex"), 4.5),
    ("v3 Address Dark focus", "danger cue", adaptive_constant("danger", 1), v3_hex("focusSolidDarkHex"), 4.5),
    ("v3 Address Black focus", "warning cue", palettes[2][2]["warning"], v3_hex("focusSolidBlackHex"), 4.5),
    ("v3 Address Black focus", "danger cue", adaptive_constant("danger", 1), v3_hex("focusSolidBlackHex"), 4.5),
    ("v3 Address Private focus", "warning cue", palettes[1][2]["warning"], v3_hex("focusSolidPrivateHex"), 4.5),
    ("v3 Address Private focus", "danger cue", adaptive_constant("danger", 1), v3_hex("focusSolidPrivateHex"), 4.5),
    # Toolbar IC secondary ink on v3 solid toolbar groups
    ("v3 Toolbar Light solid", "secondary IC", v3_hex("secondaryICLightHex"), v3_hex("solidLightHex"), 4.5),
    ("v3 Toolbar Dark solid", "secondary IC", v3_hex("secondaryICDarkHex"), v3_hex("solidDarkHex"), 4.5),
    ("v3 Toolbar Black solid", "secondary IC", v3_hex("secondaryICBlackHex"), v3_hex("solidBlackHex"), 4.5),
    ("v3 Toolbar Private solid", "secondary IC", v3_hex("secondaryICPrivateHex"), v3_hex("solidPrivateHex"), 4.5),
    # Popover & Suggestions solid fallbacks
    ("v3 Popover Light", "primary", v3_hex("primaryLightHex"), v3_hex("popoverSolidLightHex"), 4.5),
    ("v3 Popover Light", "secondary", v3_hex("secondaryLightHex"), v3_hex("popoverSolidLightHex"), 4.5),
    ("v3 Popover Light", "tertiary", v3_hex("tertiaryCardLightHex"), v3_hex("popoverSolidLightHex"), 4.5),
    ("v3 Popover Dark", "primary", v3_hex("primaryDarkHex"), v3_hex("popoverSolidDarkHex"), 4.5),
    ("v3 Popover Dark", "secondary", v3_hex("secondaryDarkHex"), v3_hex("popoverSolidDarkHex"), 4.5),
    ("v3 Popover Black", "primary", v3_hex("primaryBlackHex"), v3_hex("popoverSolidBlackHex"), 4.5),
    ("v3 Popover Private", "primary", v3_hex("primaryPrivateHex"), v3_hex("popoverSolidPrivateHex"), 4.5),
    ("v3 Popover Light selected", "title", v3_hex("selectedTitleLightHex"), composite("007AFF", v3_hex("popoverSolidLightHex"), 0.15), 4.5),
    ("v3 Popover Light selected", "url", v3_hex("selectedURLLightHex"), composite("007AFF", v3_hex("popoverSolidLightHex"), 0.15), 4.5),
    ("v3 Popover Dark selected", "title", "FFFFFF", composite("3B82F6", v3_hex("popoverSolidDarkHex"), 0.28), 4.5),
    ("v3 Popover Dark selected", "url", v3_hex("selectedURLDarkHex"), composite("3B82F6", v3_hex("popoverSolidDarkHex"), 0.28), 4.5),
    ("v3 Popover Private selected", "title", "FFFFFF", composite("A855F7", v3_hex("popoverSolidPrivateHex"), 0.32), 4.5),
    ("v3 Popover Private selected", "url", v3_hex("selectedURLPrivateHex"), composite("A855F7", v3_hex("popoverSolidPrivateHex"), 0.32), 4.5),
    # Handoff bar & Move button
    ("v3 Handoff Private", "message", v3_hex("messageInkHex"), v3_hex("solidBgHex"), 4.5),
    ("v3 Handoff Move button top", "ink", "FFFFFF", v3_hex("moveButtonTopHex"), 4.5),
    ("v3 Handoff Move button bottom", "ink", "FFFFFF", v3_hex("moveButtonBottomHex"), 4.5),
    ("v3 Handoff Move button solid", "ink", "FFFFFF", v3_hex("moveButtonSolidHex"), 4.5),
    # Start Page big field & private card solid fallbacks
    ("v3 StartPage Light bigField", "primary", v3_hex("primaryLightHex"), v3_hex("bigFieldSolidLightHex"), 4.5),
    ("v3 StartPage Light bigField", "tertiary", v3_hex("tertiaryCardLightHex"), v3_hex("bigFieldSolidLightHex"), 4.5),
    ("v3 StartPage Dark bigField", "primary", v3_hex("primaryDarkHex"), v3_hex("bigFieldSolidDarkHex"), 4.5),
    ("v3 StartPage Dark bigField", "secondary", v3_hex("secondaryDarkHex"), v3_hex("bigFieldSolidDarkHex"), 4.5),
    ("v3 StartPage Black bigField", "primary", v3_hex("primaryBlackHex"), v3_hex("bigFieldSolidBlackHex"), 4.5),
    ("v3 StartPage Private bigField", "primary", v3_hex("primaryPrivateHex"), v3_hex("bigFieldSolidPrivateHex"), 4.5),
    ("v3 StartPage Private card", "primary", v3_hex("primaryPrivateHex"), v3_hex("privateCardSolidFillHex"), 4.5),
    ("v3 StartPage Private card", "secondary", v3_hex("secondaryPrivateHex"), v3_hex("privateCardSolidFillHex"), 4.5),
    # Focus rings & IC borders (>= 3.0:1)
    ("v3 Focus address Light", "focus ring", v3_hex("accentLightHex"), v3_hex("focusSolidLightHex"), 3.0),
    ("v3 Focus address Light card", "focus ring", v3_hex("accentLightHex"), v3_hex("fillLightHex"), 3.0),
    ("v3 Focus address Dark", "focus ring", v3_hex("accentDarkHex"), v3_hex("focusSolidDarkHex"), 3.0),
    ("v3 Focus address Dark card", "focus ring", v3_hex("accentDarkHex"), v3_hex("fillDarkHex"), 3.0),
    ("v3 Focus address Black", "focus ring", v3_hex("accentDarkHex"), v3_hex("focusSolidBlackHex"), 3.0),
    ("v3 Focus address Private", "focus ring", v3_hex("privateAccentStrongHex"), v3_hex("focusSolidPrivateHex"), 3.0),
    ("v3 Focus address Private IC", "focus ring", v3_hex("privateAccentDarkHex"), v3_hex("focusSolidPrivateHex"), 3.0),
    ("v3 IC border Light toolbar", "ic border", v3_hex("rimICLightHex"), v3_hex("solidLightHex"), 3.0),
    ("v3 IC border Light card", "ic border", v3_hex("rimICLightHex"), v3_hex("fillLightHex"), 3.0),
    ("v3 IC border Light backdrop", "ic border", v3_hex("rimICLightHex"), v3_hex("reducedLightHex"), 3.0),
    ("v3 IC border Dark toolbar", "ic border", v3_hex("rimICDarkHex"), v3_hex("solidDarkHex"), 3.0),
    ("v3 IC border Dark card", "ic border", v3_hex("rimICDarkHex"), v3_hex("fillDarkHex"), 3.0),
    ("v3 IC border Dark backdrop", "ic border", v3_hex("rimICDarkHex"), v3_hex("reducedDarkHex"), 3.0),
    ("v3 IC border Black address", "ic border", v3_hex("rimICBlackHex"), v3_hex("restSolidBlackHex"), 3.0),
    ("v3 IC border Black card", "ic border", v3_hex("rimICBlackHex"), v3_hex("fillBlackHex"), 3.0),
    ("v3 IC border Private address", "ic border", v3_hex("rimICPrivateHex"), v3_hex("restSolidPrivateHex"), 3.0),
    ("v3 IC border Private backdrop", "ic border", v3_hex("rimICPrivateHex"), v3_hex("reducedPrivateHex"), 3.0),
]
for label, role, fg, bg, minimum in v3_surface_pairs:
    v3_checks.append((label, role, fg, "solid", bg, minimum))

checks.extend(v3_checks)

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
elif negative_test or sidebar_negative or v3_negative:
    if not failures:
        print("FAIL negative test: low-contrast foreground was not caught")
        sys.exit(1)
    print(f"Negative test passed: caught {failures} low-contrast foreground uses")
else:
    print(f"{len(checks) - failures}/{len(checks)} contrast checks pass")
    sys.exit(1 if failures else 0)
