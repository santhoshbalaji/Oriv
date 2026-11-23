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
| Chrome and sidebar backing | `#F0F0F3` | `#252528` | `#0A0A0A` |
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

| Backing | Light | Dark |
| --- | --- | --- |
| Graphite | `#F0F0F3` | `#252528` |
| Profile color · Mulberry | `#F1DBEE` | `#45243F` |
| Profile color · Ocean | `#CFEAF8` | `#1C344D` |
| Profile color · Fern | `#D7EED5` | `#233A25` |
| Profile color · Amber | `#FAE7CC` | `#493223` |
| Profile color · Slate | `#DFE7F2` | `#2A3544` |
| Rose | `#F6DCE5` | `#492736` |
| Peach | `#F8E1D4` | `#4C2E27` |
| Butter | `#F7EDC5` | `#42351D` |
| Mint | `#D8EFE3` | `#173B30` |
| Sage | `#DDE8CD` | `#303A24` |
| Sky | `#D6E9F8` | `#21364A` |
| Lavender | `#E6DDF7` | `#39284D` |

The backing follows the active profile in the expanded sidebar and 72 pt rail.
**Glass opacity** under **All profiles** offers **Balanced** (43%, default),
**High** (74%), and **Solid** (100%). Balanced uses a neutral contrast layer
under the sidebar backing. The layer is white at 42% for Graphite Light and 45%
for light tints. It is black at 54% for Graphite Dark, 60% for dark tints, and
36% for Black. High also uses a 38% black guard in Dark. Selected rows, hover,
search and selected pins add translucent tonal fills over the backing. Black uses solid
control fills.
Reduce Transparency and Increase Contrast use the opaque backing. Increase
Contrast also strengthens secondary text, the panel edge and the selected row’s
outline. The active tab uses the 3 pt system-accent marker in both rows and tiles. Websites and the
page-derived toolbar keep their own colors.

Black uses the near-black `#0A0A0A` backing and disables the swatches. Settings
shows “Sidebar color is available in System, Light and Dark.” The saved choice
applies again when the profile returns to one of those appearances.

The contrast gate checks primary, secondary and private ink over every backing,
opacity and sidebar state. It composites the glass input, tinted backing and
control fill for each sample. The Mac appearance
preference can sync through Sync. The separate sidebar color preference is
device-local. Drag the panel edge to adjust its width. New windows use the
last width saved on this Mac. A private tab displays a purple **Private** pill
in the Mac address capsule. See [design system](design-system.md).


iPhone controls use interactive system glass. Reduce Transparency and Increase
Contrast replace it with an opaque field and border. The private address capsule
shows glasses beside the address, and private pages use a purple top band in Light
appearance. The page menu uses an ellipsis in both modes.
