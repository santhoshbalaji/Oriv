# Appearance

Mac and iPhone offer **System**, **Light**, **Dark** and **Black**. Choose one in **Settings → Appearance**. System is the default and follows the device’s light or dark appearance. Light and Dark use the Graphite base palette with an explicit color scheme. Black is dark-only with a black canvas.

The choice is saved for the current browser profile. Profiles without a saved choice use System on read, including profiles that previously inherited Black. Black still uses the stored and synced value `T3 Code`. All four existing preference values remain valid. The older pastel colors belonged to the palette behind System, Light and Dark, so there are no additional stored themes to translate.

An explicit choice syncs for the same profile when Sync is available and enabled. An unset local preference uses System without publishing a choice. Previously synced appearance records remain valid. Older clients also published their implicit default, so an existing synced T3 Code record is honored as a saved choice. Unknown incoming values are ignored for forward compatibility.

## Palette

| Semantic role | Graphite Light | Graphite Dark | Black |
| --- | --- | --- | --- |
| Page and canvas | `#FFFFFF` | `#1C1C1E` | `#000000` |
| Grouped surface and start-page tiles | `#F5F5F7` | `#242426` | `#111111` |
| Grouped row | `#FFFFFF` | `#2E2E30` | `#111111` |
| Window chrome | `#F0F0F3` | `#252528` | `#0A0A0A` |
| Field | `#E6E6EA` | `#323236` | `#1E1E1E` |
| Selection | `#DEDEE3` | `#3D3D42` | `#1C1C1C` |
| Sidebar hover | `#E7E7EB` | `#303034` | `#171717` |
| Separator | `#C9C9CF` | `#48484D` | `#191919` |
| Main text | `#1D1D1F` | `#F5F5F7` | `#F5F5F5` |
| Secondary text | `#4E4E54` | `#C2C2C8` | `#A3A3A3` |
| Tertiary text | `#6A6A70` | `#A1A1A8` | `#8A8A8A` |
| Danger | `#B3261E` | `#FF9A8F` | `#FF9A8F` |
| Success | `#1D6B3A` | `#7FD99A` | `#7FD99A` |
| Private wash | `#F3E9F9` | `#33263D` | `#33263D` |
| Private cue | `#713692` | `#D5AAF8` | `#D5AAF8` |
| Warning | `#794900` | `#E0AA55` | `#D9A04A` |

All appearances use the platform accent for interactive controls. macOS reads `NSColor.controlAccentColor` and iPhone uses SwiftUI’s system accent and tint. The active row marker uses that hue and adjusts its lightness when needed for contrast on the selection surface. Native controls manage their own focus, disabled state, and tint rendering.

## Mac sidebar color

In **Settings → Appearance → Sidebar color**, choose **Graphite**, **Profile color**,
or **Rose**, **Peach**, **Butter**, **Mint**, **Sage**, **Sky** or **Lavender**. The selected
swatch has a checkmark and a selected accessibility state. Profile color follows
changes to the profile’s own color. Oriv saves this preference for each profile on
this Mac. An unset or unrecognized value uses Graphite. Standalone private windows
and private windows opened by external links also use Graphite. A private tab
inside a profile uses that profile’s backing and keeps its glasses and private labels.

| Sidebar color | Light panel, top → bottom | Dark panel, top → bottom |
| --- | --- | --- |
| Graphite | `#F2F4FA` → `#E6EAF3` | `#2A2F3D` → `#1E222E` |
| Profile color · Mulberry | `#F6DFF3` → `#EBCBE9` | `#603259` → `#42213E` |
| Profile color · Ocean | `#D4EEFD` → `#BDDEF7` | `#284D74` → `#1A344E` |
| Profile color · Fern | `#DCF3DA` → `#C7E7C5` | `#315137` → `#223B26` |
| Profile color · Amber | `#FDEBD1` → `#F5DCB8` | `#634325` → `#47301E` |
| Profile color · Slate | `#E3EBF6` → `#CCD9EA` | `#3B4B61` → `#283647` |
| Rose | `#FFE3EF` → `#FCCBDD` | `#693150` → `#4D223B` |
| Peach | `#FFE7DA` → `#FAD4C0` | `#683B2D` → `#482B22` |
| Butter | `#FFF3CA` → `#F9E6AC` | `#59451F` → `#3D3118` |
| Mint | `#D8F5E8` → `#C1ECDA` | `#235345` → `#163C31` |
| Sage | `#E2EED2` → `#CFE2BA` | `#445333` → `#2C3A22` |
| Sky | `#DCF1FF` → `#C4E5FF` | `#28527D` → `#1B3857` |
| Lavender | `#ECE3FF` → `#DACBFF` | `#4F3878` → `#392759` |

Chromatic Glass uses a subtle leading tint over regular system Liquid Glass.
Graphite stays cool and uses a cobalt selection. Other colors use the same
translucent selection in Light and Dark, with deep matching ink in Light and
bright ink in Dark. Active pins have a soft rim and a small glow.

**Glass opacity** under **All profiles** offers **Balanced** (65% backing in
Light and Dark), **High** (86%), and **Solid** (100%). A hue-matched contrast
guard uses the same opacity in both Light and Dark. Solid, Reduce Transparency
and Increase Contrast use the opaque gradient and active fill. Increase
Contrast strengthens secondary ink, the panel edge and the active outline.
The separate inset focus ring follows keyboard navigation.

Black uses a near-black `#0A0A0A` panel and a restrained slate selection.
Its Balanced and High backing opacities are 86% and 94%. Settings shows
“Sidebar color is available in System, Light and Dark.” The saved swatch
applies again when the profile returns to one of those appearances.

The contrast gate checks text, focus rings and favicon cushions across all
13 sidebar colors in Light and Dark, all glass levels and the opaque
accessibility variants. The Mac appearance preference can sync through Sync.
The separate sidebar color preference is device-local. Drag the panel edge to
adjust its width. New windows use the last width saved on this Mac. A private
tab displays a purple **Private** pill in the Mac address capsule.
See [design system](design-system.md).

iPhone controls use interactive system glass. Reduce Transparency and Increase
Contrast replace it with an opaque field and border. The private address capsule
shows glasses beside the address, and private pages use a purple top band in Light
appearance. The page menu uses an ellipsis in both modes.
