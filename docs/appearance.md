# Appearance

Mac and iPhone offer **System**, **Light**, **Dark** and **T3 Code**. Choose one in **Settings → Appearance**. System is the default and follows the device’s light or dark appearance. Light and Dark use the same Graphite palette with an explicit color scheme. T3 Code is dark-only with a black canvas.

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

Mac Settings uses native grouped forms. On Mac the sidebar has **Balanced (83%)**, **High (92%)** and **Solid** opacity under **All profiles**. Reduce Transparency and Increase Contrast switch the sidebar to its solid backing. Increase Contrast strengthens separator, text and selection boundaries. Private browsing uses neutral surfaces with purple glasses and explicit private labels. Website colors and page-derived toolbar tint remain controlled by the page.

The shared implementation is in `Apps/Shared/Theme.swift`. The contrast gate covers app-owned text and opaque and composited backings, including black and white inputs at each opacity. macOS’s live Liquid Glass compositor and OS-defined control rendering remain part of visual acceptance. See [design system](design-system.md).
