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
assert ".background(backing.opacity(effectiveOpacity.backingOpacity))" in sidebar_source
assert ".background(Self.balancedTintGuard.opacity(guardOpacity))" in sidebar_source
assert ".background { glass }" in sidebar_source
assert "SidebarSelectionSurface(active: active, radius: radius)" in sidebar_source
assert "tone: !active && hovered ? .hover : nil" in sidebar_source
assert "shape.fill(Theme.SidebarSelection.fill(in: theme, dark: dark, opaque: opaque, environment: environment))" in sidebar_source
assert "if !opaque { shape.fill(Theme.SidebarSelection.backing(dark: dark)) }" in sidebar_source
assert "tone.fill(in: theme, dark: dark, opaque: opaque)" in sidebar_source
native_sidebar = (ROOT / "Apps/macOS/Views/NativeSidebarTabs.swift").read_text()
assert "NSColor(Theme.sidebarKeyboardFocus).setStroke()" in native_sidebar
assert "ring.lineWidth = OrivOutline.focus" in native_sidebar
rail_search = (ROOT / "Apps/macOS/Views/SidebarSearchPanel.swift").read_text()
assert "SidebarSelectionSurface(active: active, radius: radius)" in rail_search
assert "strokeBorder(Theme.sidebarKeyboardFocus, lineWidth: OrivOutline.focus)" in rail_search
selected_opacities = tuple(float(value) for value in re.search(
    r"selectedOpacity = \(light: ([0-9.]+), dark: ([0-9.]+)\)", text).groups())
selected_guards = tuple(float(value) for value in re.search(
    r"selectedGuardOpacity = \(light: ([0-9.]+), dark: ([0-9.]+)\)", text).groups())
selected_dark_limit = re.search(r"selectedDarkAccentLimit = hex\(0x(\w{6})\)", text)[1]
assert "if opaque { return selectedSolid }" in text
assert "accent.linearGreen / limit.linearGreen, accent.linearBlue / limit.linearBlue" in text
assert "dark ? Color.black.opacity(selectedGuardOpacity.dark) : Color.white.opacity(selectedGuardOpacity.light)" in text
assert "let adjustment = needsAdjustment ? (baseLuminance - accentLuminance) / (endpoint - accentLuminance) : 0" in text
assert "let needsAdjustment = dark ? accentLuminance < baseLuminance : accentLuminance > baseLuminance" in text
assert 0 <= float(re.search(r"selectedInkAccentMix: Float = ([0-9.]+)", text)[1]) <= 1
tonal_opacities = {name: (float(light), float(dark)) for name, light, dark in re.findall(
    r"private static let (\w+)Tone = \(light: ([0-9.]+), dark: ([0-9.]+)\)", text)}
assert set(tonal_opacities) == {"selection", "hover", "search"}
sidebar_opacities = {name: float(value) for name, value in re.findall(
    r"case \.(\w+): ([0-9.]+)", sidebar_source.split("enum SidebarGlassOpacity:", 1)[1].split("struct MacSidebarGlass:", 1)[0])}
assert 0 < sidebar_opacities["balanced"] < sidebar_opacities["high"] < sidebar_opacities["solid"] == 1
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
sidebar_checks = []
sidebar_levels = {}
selection_checks = []
selection_levels = {}


def check_selection(label, step, mode, panel, hover, palette, inks, opaque):
    selected_ink = adaptive_constant("selectedInk", mode)
    focus_ink = adaptive_constant("sidebarKeyboardFocus", mode)
    # Per-channel compositing is monotonic. Check the full range of the
    # bounded accent wash and the worst normalized ink luminance separately.
    guarded = composite("000000" if mode else "FFFFFF", panel, selected_guards[mode])
    fills = {adaptive_constant("selectedSolid", mode)} if opaque else {
        composite(accent, guarded, selected_opacities[mode])
        for accent in ("000000", selected_dark_limit if mode else "FFFFFF")
    }
    minima = selection_levels.setdefault(step, {"selected text": float("inf"), "focus ring": float("inf")})

    def check(role, ink, state, background, minimum):
        selection_checks.append((label, role, ink, state, background, minimum))
        if role in minima:
            minima[role] = min(minima[role], ratio(ink, background))

    for fill in sorted(fills):
        accessory = hover if opaque else composite("FFFFFF" if mode else "000000", fill, tonal_opacities["hover"][mode])
        for state, background in (("selected row / pin", fill), ("selected hover accessory", accessory),
                                  ("selected fallback icon plate", palette["fill"])):
            check("selected text", selected_ink, state, background, 4.5)
        check("private glasses", palette["private"], "icon plate", palette["fill"], 3)
        check("private badge", inks["private"], "badge", palette["surface"], 3)
        if step == "increase contrast":
            check("selected boundary", palette["text"], "selected fill", fill, 3)
            check("selected boundary", palette["text"], "panel", panel, 3)

    for state, background in [("idle row / pin", panel), ("hovered row / pin", hover),
                              *(("selected row / pin", fill) for fill in sorted(fills))]:
        ink = composite(focus_ink, background, 0.35) if focus_negative else focus_ink
        check("focus ring", ink, state, background, 3)


tints = {name.removesuffix("Backing"): (light.upper(), dark.upper())
         for name, light, dark in re.findall(
             r'(\w+Backing) = Theme.adaptive\("Sidebar\w+", light: 0x(\w{6}), dark: 0x(\w{6})\)', sidebar_source)}
guards = {name: float(value) for name, value in re.findall(
    r"private static let balanced(\w+)Guard = ([0-9.]+)", sidebar_source)}
high_dark_guard = float(re.search(r"highDarkGuard = ([0-9.]+)", sidebar_source)[1])
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
                for material in ("FFFFFF", "000000", "6000D9", "888888", "00D4C8", "FF8C24",
                             "1C3354", "33919C", "FCC775", "D15959", "404585", "F7E6CC", "1C1C1E"):
                    guard_key = "Black" if appearance == "Black" else ("Dark" if mode else "Light")
                    if name != appearance:
                        guard_key += "Tint"
                    guard_opacity = guards[guard_key] if step == "balanced" else 0
                    if step == "high" and mode and appearance != "Black":
                        guard_opacity = high_dark_guard
                    glass = composite(guard_colors[mode], material, guard_opacity)
                    panel = composite(backing, glass, 0 if sidebar_negative else backing_opacity)
                    opaque = appearance == "Black" or step in ("increase contrast", "reduce transparency")
                    solids = {"selection": sidebar["selection"], "hover": sidebar["hover"], "search": sidebar["field"]}
                    states = {"panel / rail footer": panel, "private badge": colors["surface"]}
                    for state, solid in solids.items():
                        tonal_ink = "FFFFFF" if mode or state == "selection" else "000000"
                        states[state] = solid if opaque else composite(tonal_ink, panel, tonal_opacities[state][mode])
                    states["hovered accessory"] = (sidebar["hover"] if opaque else
                        composite("FFFFFF" if mode else "000000", states["hover"], tonal_opacities["hover"][mode]))
                    label = f"{name} sidebar, glass input #{material}, {step}"
                    check_selection(label, step, mode, panel, states["hover"], colors, inks, opaque)
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
        for step in steps:
            surface = colors["surface"]
            opaque = appearance == "Black" or step in ("increase contrast", "reduce transparency")
            hover = sidebar["hover"] if opaque else composite("FFFFFF" if mode else "000000", surface, tonal_opacities["hover"][mode])
            check_selection(f"{appearance} rail search, {step}", step, mode, surface, hover, colors, inks, opaque)

checks.extend(sidebar_checks)
checks.extend(selection_checks)
worst = min((check for check in sidebar_checks if check[-1] == 4.5), key=lambda check: ratio(check[2], check[4]))
for name, minima in sidebar_levels.items():
    values = " / ".join(f"{minima[token]:.2f}" for token in ("text", "textSecondary", "private"))
    print(f"{name.capitalize()} sidebar (primary / secondary / private): {values}")
print(f"Sidebar minimum text contrast: {ratio(worst[2], worst[4]):.2f}:1 ({worst[0]}, {worst[1]} on {worst[3]})")
for step, minima in selection_levels.items():
    print(f"{step.capitalize()} S2 minimum (selected text / focus ring): "
          f"{minima['selected text']:.2f}:1 / {minima['focus ring']:.2f}:1")
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
assert "WindowBackdropMaterial(material: .sidebar)" in mac
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
if focus_negative:
    rejected = [check for check in selection_checks if check[1] == "focus ring" and ratio(check[2], check[4]) < check[-1]]
    if not rejected or len(rejected) != failures:
        sys.exit("FAIL negative focus test: expected failures from the weakened ring only")
    print(f"Negative sidebar focus test passed: caught {len(rejected)} rings below 3:1")
elif settings_negative:
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
