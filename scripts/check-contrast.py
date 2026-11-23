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
            re.findall(r"`?(\w+)`?\s*[:=] adaptive\(\"(\w+)\", light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)", source)}

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
assert "content.background(backing)" in sidebar_source
assert "reduceTransparency || captureReduceTransparency || contrast == .increased" in sidebar_source
assert "content.background(backing.opacity(effectiveOpacity.backingOpacity)" in sidebar_source
assert "selected ? theme.sidebar.selection" in sidebar_source
sidebar_opacities = {name: float(value) for name, value in re.findall(
    r"case \.(\w+): ([0-9.]+)", sidebar_source.split("enum SidebarGlassOpacity:", 1)[1].split("struct MacSidebarGlass:", 1)[0])}
assert sidebar_opacities == {"balanced": 0.55, "high": 0.80, "solid": 1.0}
search_field = (ROOT / "Apps/macOS/Views/Components/OrivSearchField.swift").read_text()
assert "sidebar && !focused && !opaque && !increased ? idleSidebarOpacity : 1" in search_field
assert "(sidebar ? theme.sidebar.field : theme.fill).opacity(opacity)" in search_field
focused_field = 1.0
idle_field = float(re.search(r"idleSidebarOpacity = ([0-9.]+)", search_field).group(1))
tile_opacity = float(re.search(r"!hovered \? theme.sidebar.field.opacity\(([0-9.]+)\)", sidebar_source).group(1))
chrome = (ROOT / "Apps/Shared/BrowserChrome.swift").read_text()
control = block("struct BrowserGlass:", "private struct ChromeReduceTransparencyKey", chrome)
assert "accessibilityReduceTransparency" in control and "contrast == .increased" in control
assert "content.background(theme.fill, in: shape)" in control
assert "content.glassEffect(.regular.interactive(), in: shape)" in control
assert "theme.fill.opacity(" not in control
sidebar_negative = "--negative-sidebar-test" in sys.argv
tint_negative = "--negative-sidebar-tint-test" in sys.argv
sidebar_checks = []
sidebar_levels = {}
tints = {name.removesuffix("Backing"): (light.upper(), dark.upper())
         for name, light, dark in re.findall(
             r'(\w+Backing) = Theme.adaptive\("Sidebar\w+", light: 0x(\w{6}), dark: 0x(\w{6})\)', sidebar_source)}
guards = {name: float(value) for name, value in re.findall(
    r"private static let balanced(\w+)Guard = ([0-9.]+)", sidebar_source)}
assert set(guards) == {"Light", "LightTint", "Dark", "DarkTint", "Black"}
guard_colors = re.search(r'balancedTintGuard = Theme.adaptive\("SidebarTintGuard", light: 0x(\w{6}), dark: 0x(\w{6})\)', sidebar_source).groups()
assert set(tints) == {"rose", "peach", "butter", "mint", "sage", "sky", "lavender",
                      "mulberry", "ocean", "fern", "amber", "slate"}
for appearance, mode, palette, sidebar in palettes:
    for role in ("private", "privateWash", "danger", "success"):
        palette[role] = adaptive_constant(role, mode)
    sidebar_text = {
        "text": palette["text"],
        "textSecondary": adaptive_constant("glassSecondary", mode),
        "private": adaptive_constant("glassPrivate", mode),
    }
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

        steps = {"increase contrast": 1.0} if accessibility == "increase contrast" else {
            **sidebar_opacities, "reduce transparency": 1.0}
        backings = {appearance: sidebar["backing"]}
        if appearance != "Black":
            scheme = "Dark" if mode else "Light"
            backings.update({f"{name.capitalize()} {scheme}": values[mode] for name, values in tints.items()})
        inks = dict(sidebar_text)
        if accessibility == "increase contrast":
            inks["textSecondary"] = colors["textSecondary"]
        for name, backing in backings.items():
            if name == "Rose Light" and tint_negative:
                backing = "888888"
            for step, backing_opacity in steps.items():
                # Black and white bound the panel luminance. Also exercise saturated glass inputs.
                for page in ("FFFFFF", "000000", "6000D9", "888888", "00D4C8", "FF8C24",
                             "1C3354", "33919C", "FCC775", "D15959", "404585", "F7E6CC", "1C1C1E"):
                    guard_key = "Black" if appearance == "Black" else ("Dark" if mode else "Light")
                    if name != appearance:
                        guard_key += "Tint"
                    glass = composite(guard_colors[mode], page, guards[guard_key]) if step == "balanced" else page
                    panel = composite(backing, glass, 0 if sidebar_negative else backing_opacity)
                    field = sidebar["field"]
                    states = {"panel / rail footer": panel, "selection / rail": sidebar["selection"],
                              "hover": sidebar["hover"], "pressed": sidebar["selection"],
                              "pin": composite(field, panel, tile_opacity),
                              "search": composite(field, panel, focused_field if step in ("increase contrast", "reduce transparency") else idle_field),
                              "focused search": composite(field, panel, focused_field),
                              "expanded footer / private badge": colors["surface"]}
                    label = f"{name} sidebar, page #{page}, {step}"
                    for state, background in states.items():
                        for token, foreground in inks.items():
                            sidebar_checks.append((label, token, foreground, state, background, 4.5))
                            minima = sidebar_levels.setdefault(step, {})
                            minima[token] = min(minima.get(token, float("inf")), ratio(foreground, background))
                        if accessibility == "increase contrast":
                            sidebar_checks.append((label, "strong boundary", colors["text"], state, background, 3))
            if appearance != "Black":
                # The Settings swatch shows a primary-ink checkmark on the opaque backing.
                sidebar_checks.append((f"{name} sidebar swatch", "checkmark", colors["text"], "swatch", backing, 3))

checks.extend(sidebar_checks)
worst = min((check for check in sidebar_checks if check[-1] == 4.5), key=lambda check: ratio(check[2], check[4]))
for name, minima in sidebar_levels.items():
    values = " / ".join(f"{minima[token]:.2f}" for token in ("text", "textSecondary", "private"))
    print(f"{name.capitalize()} sidebar (primary / secondary / private): {values}")
print(f"Sidebar minimum text contrast: {ratio(worst[2], worst[4]):.2f}:1 ({worst[0]}, {worst[1]} on {worst[3]})")
# Settings owns the foreground and the complete card. AppKit owns the material
# and toolbar in the empty gutters. Model wallpaper as an arbitrary material
# output, including the RGB endpoints that bound luminance for alpha blends.
settings = (ROOT / "Apps/macOS/Views/AppearanceSettings.swift").read_text()
settings_group = block("private struct SettingsGroupSurface:", "private struct SettingsWindowMaterial:", settings)
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
        inputs = (palette["canvas"],) if solid else ("FFFFFF", "000000", "6000D9", "00D4C8", "FF8C24")
        minima = [float("inf"), float("inf")]
        for backdrop in inputs:
            card = composite(palette["surfaceRaised"], backdrop, 0.5 if settings_negative else 1.0)
            label = f"{appearance} Settings / {variant} / material #{backdrop}"
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
                settings_checks.append((label, "strong boundary", strong, "canvas", backdrop, 3.0))
        print(f"{appearance} Settings / {variant} (primary / secondary): {minima[0]:.2f} / {minima[1]:.2f}")
checks.extend(settings_checks)
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

# A system accent can be any luminance. Check both ends and the crossover.
assert "luminance(resolvedAccent) < sqrt(1.05 * 0.05) - 0.05" in text
for accent in sorted(page_colours):
    ink = "FFFFFF" if luminance(accent) < (1.05 * 0.05) ** 0.5 - 0.05 else "000000"
    checks.append(("System accent", "onAccent", accent if role_negative == "onAccent" else ink, "accent", accent, 4.5))

failures = 0
for theme, token, colour, surface, background, minimum in checks:
    value = ratio(colour, background)
    if value < minimum:
        failures += 1
        print(f"FAIL {theme}: {token} #{colour} on {surface} #{background} = {value:.2f}:1 (needs {minimum}:1)")
if settings_negative:
    if not any(ratio(ink, card) < minimum for _, _, ink, _, card, minimum in settings_checks):
        sys.exit("FAIL negative Settings test: translucent Settings card was not caught")
    print("Negative Settings test passed")
elif tint_negative:
    caught = any(label.startswith("Rose Light sidebar,") and ratio(foreground, background) < minimum
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
