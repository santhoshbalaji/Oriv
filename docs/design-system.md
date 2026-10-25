# Oriv: a place for connected thoughts

## Direction before implementation

Oriv connects browsing to a remembered source, a thought and a next action. Its subtle kolam mark suggests continuity; the UI should echo that through a fine woven line and an activity thread, without turning the interface into a decorative pattern.

Palette (light / dark):
- Mulberry, primary action: `#713C52` / `#E3ADC4`.
- Paper, reading surface: `#FCFAFD` / `#252228`.
- Mist, canvas: `#F3F0F5` / `#1D1B20`.
- Graphite, reference ink: `#28232D` / `#F1ECF3`; actual text uses adaptive system primary/secondary colors.
- Fern, completed-work accent: `#35685D` / `#A6CDBF`.
- Thread, decorative line: `#C8B8CD` / `#6C5B73`.

Native selection uses a separate dark-mode accent, `#9B6681`, because macOS draws white text on selected rows. The lighter Mulberry tint remains for foreground icons and custom controls. Selected site monograms inherit the native foreground rather than the brand tint.

Typography: native San Francisco for controls, metadata, forms and reading. System serif for the new-tab greeting and saved-item title, bringing a literary tone to the content without replacing familiar Mac controls. Body content stays selectable and comfortably spaced. No external fonts.

Layout:
```
Browser:   [Oriv / Workspace / tabs] [native toolbar + address]
                                   [greeting, subtle thread]
                                   [search]
                                   [compact quick links]
                                   [continue work | recent pages]
Workspace: [scope navigation] [saved items] [source/title/purpose]
                                          [actions / notes / content / timeline]
```

Principles: hierarchy before decoration; one primary task per panel; preserve native selection, keyboard focus, resizing and menus; glass only for controls/navigation; opaque readable content; distinguish private browsing with both text and symbol; adapt to dark mode, Increase Contrast and Reduce Transparency. No invented activity, sync status or AI features.

Critique before building: merely tinting the existing blue interface would leave a generic browser template. The meaningful changes are the prominent Workspace doorway, a new-tab continuation area backed by real items, the editorial detail layout, a connected activity timeline, and consistent editor headings. Avoid a grid of indistinguishable rounded cards or large branding on websites.

## References

- [Apple Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials): system materials and content hierarchy.
- [Apple Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility): contrast, recognizable controls and system accessibility preferences.
- [Things](https://culturedcode.com/things/): task hierarchy and restrained list presentation.
- [Craft](https://www.craft.do/): readable document layouts and keeping tasks near context.

These are design references, not copied layouts or assets. Native SwiftUI/AppKit supplies the platform behavior. This is implementation guidance, not a claim of Apple certification or an exhaustive accessibility audit.
