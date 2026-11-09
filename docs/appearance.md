# Appearance

Mac and iPhone offer **System**, **Light**, **Dark** and **T3 Code**. Choose one under **Settings → Appearance** on Mac or **Page options → Settings → Theme** on iPhone. The choice is saved for the current browser profile and syncs for that same profile across the user’s devices when continuity is enabled in a configured Continuity build. With continuity off, it remains local. New profiles default to T3 Code; an existing explicit appearance preference is preserved.

T3 Code is a dark-only theme based on the installed T3 Code Nightly `0.1.7-nightly.20261103.4119` built-in dark palette. The shared implementation is `Apps/macOS/Views/Theme.swift`, compiled into both application targets.

| Role | sRGB color |
| --- | --- |
| Canvas and sidebar | `#000000` |
| Toolbar | `#0A0A0A` |
| Surface and selected row | `#111111` |
| Input field | `#1E1E1E` |
| Main text | `#F5F5F5` |
| Secondary text | `#818181` |
| Border | `#191919` |
| Accent and focus | `#346BF1` |

The shared palette reaches home pages, browser controls, libraries, sheets and settings through a SwiftUI environment value. Changing it updates the existing view tree and does not reconstruct browser sessions. Increased Contrast brightens secondary text, foreground accents and borders. Filled primary buttons keep a darker blue for readable white labels; address placeholders use the main text role. The iPhone appearance picker uses one column at accessibility text sizes. Native control rendering and disabled states remain under the platform's control. Oriv retains its logo and typography.

Theme selection changes the app's color scheme, including the preference exposed to websites that support it. It does not inject styles into website content or force a light-only site to become dark. No network requests, theme downloads or account services are added.

## Local verification

Both final application builds passed on 4 November 2026: Mac Debug and iPhone Simulator Debug. Mac strict signature validation, the browser-scope guard and whitespace checks passed. Visual checks covered T3 Code home and appearance screens, the Mac bookmarks sheet, Light ↔ T3 Code switching, native disabled controls and tab continuity on Mac. The iPhone choice was checked in its saved preferences and retained across app update/relaunch. Captures are under `build/screenshots/t3-code/`.

The installed Mac apps and the original checkout were not modified. Physical-iPhone and full accessibility acceptance remain separate from these local visual checks.

The later browser UX changes and their verification are recorded in [the UX implementation report](ux-implementation.md).
