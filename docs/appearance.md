# Appearance

Mac and iPhone offer **System**, **Light**, **Dark** and **T3 Code**. Choose one in **Settings → Appearance**. System is the default and follows the device’s light or dark appearance. Light and Dark use the Graphite base palette with an explicit color scheme. T3 Code is dark-only with a black canvas.

The choice is saved for the current browser profile. Profiles without a saved choice use System on read, including profiles that previously inherited T3 Code. All four existing preference values remain valid. The older pastel colors belonged to the palette behind System, Light and Dark, so there are no additional stored themes to translate.

An explicit choice syncs for the same profile when continuity is enabled in a configured Continuity build. An unset local preference uses System without publishing a choice. Previously synced appearance records remain valid. Older clients also published their implicit default, so an existing synced T3 Code record is honored as a saved choice. Unknown incoming values are ignored for forward compatibility.

## Palette

| Semantic role | Graphite Light | Graphite Dark | T3 Code |
| --- | --- | --- | --- |
| Page and canvas | `#FFFFFF` | `#1C1C1E` | `#000000` |
| Grouped surface and start-page tiles | `#F5F5F7` | `#242426` | `#111111` |
| Grouped row | `#FFFFFF` | `#2E2E30` | `#111111` |
| Chrome and sidebar backing | `#F0F0F3` | `#252528` | `#0A0A0A` |
| Field | `#E6E6EA` | `#323236` | `#1E1E1E` |
| Selection | `#DEDEE3` | `#3D3D42` | `#1C1C1C` |
| Sidebar hover | `#E7E7EB` | `#303034` | `#171717` |
| Separator | `#C9C9CF` | `#48484D` | `#191919` |
| Main text | `#1D1D1F` | `#F5F5F7` | `#F5F5F5` |
| Secondary text | `#4E4E54` | `#C2C2C8` | `#A3A3A3` |
| Private cue | `#713692` | `#D5AAF8` | `#D5AAF8` |
| Warning | `#794900` | `#E0AA55` | `#D9A04A` |

All appearances use the platform accent for interactive controls. macOS reads `NSColor.controlAccentColor` and iPhone uses SwiftUI’s system accent and tint. The active row marker uses that hue and adjusts its lightness when needed for contrast on the selection surface. Native controls manage their own focus, disabled state, and tint rendering.

## Mac sidebar color

In **Settings → Appearance → Sidebar color**, choose **Graphite**, **Profile colour**,
or **Rose**, **Peach**, **Butter**, **Mint**, **Sage**, **Sky** or **Lavender**. The selected
swatch has a checkmark and a selected accessibility state. Profile colour follows
changes to the profile’s own color. Oriv saves this preference for each profile on
this Mac. An unset or unrecognized value uses Graphite. Standalone private windows
and private windows opened by external links also use Graphite. A private tab
inside a profile uses that profile’s backing and keeps its glasses and private labels.

| Backing | Light | Dark |
| --- | --- | --- |
| Graphite | `#F0F0F3` | `#252528` |
| Profile colour · Mulberry | `#F1DBEE` | `#45243F` |
| Profile colour · Ocean | `#CFEAF8` | `#1C344D` |
| Profile colour · Fern | `#D7EED5` | `#233A25` |
| Profile colour · Amber | `#FAE7CC` | `#493223` |
| Profile colour · Slate | `#DFE7F2` | `#2A3544` |
| Rose | `#F6DCE5` | `#492736` |
| Peach | `#F8E1D4` | `#4C2E27` |
| Butter | `#F7EDC5` | `#42351D` |
| Mint | `#D8EFE3` | `#173B30` |
| Sage | `#DDE8CD` | `#303A24` |
| Sky | `#D6E9F8` | `#21364A` |
| Lavender | `#E6DDF7` | `#39284D` |

The backing follows the active profile in the expanded sidebar and 72 pt rail.
**Glass opacity** under **All profiles** offers **Balanced** (70%, default),
**High** (92%), and **Solid** (100%). Colored backings in Balanced use a 16%
white layer in Light or black layer in Dark between the tint and the glass.
Reduce Transparency and Increase Contrast use the opaque backing. Increase
Contrast also strengthens secondary text, the panel edge and the selected row’s
outline. Selection still uses the 3 pt system-accent marker. Websites and the
page-derived toolbar keep their own colors.

T3 Code uses the near-black `#0A0A0A` backing and disables the swatches. Settings
shows “Sidebar color is available in System, Light and Dark.” The saved choice
applies again when the profile returns to one of those appearances.

The contrast gate checks primary, secondary and private ink over every backing,
opacity and sidebar state, including extreme glass inputs. The Mac appearance
preference can sync through Continuity. The separate sidebar color preference is
device-local. See [design system](design-system.md).
