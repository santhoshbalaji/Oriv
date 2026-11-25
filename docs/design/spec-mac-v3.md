# Oriv Mac Design v3 Specification

Phase 0 specification lock for the Oriv macOS Liquid Glass redesign (target: macOS 26, built with Xcode 27.2 SDK).

> **Mock canvas scale:** Every reference HTML mock in `docs/design/mocks/` renders at `1470 × 919` CSS px (MacBook Air 13" logical resolution). **1 CSS px = 1 macOS point (pt).** The committed JPEG previews are `2000 × 1250` rasterized renders; read authoritative numbers from the HTML CSS, not the JPEG pixel grid. Where a mock and an earlier review report disagree, the mock wins.

---

## 1. Scope, Design Decision, and Reconciliation Rules

### 1.1 Fixed design split

| Area | Authoritative Mock | Summary |
| --- | --- | --- |
| Overall Mac chrome (window frame, sidebar, rail, toolbar, address capsule, suggestions, external-private handoff) | `docs/design/mocks/neon-01-main-window-light.html`, `neon-02-main-window-dark.html`, `neon-03-address-bar-focused.html`, `neon-05-private-mode.html` | Floating 8 pt-inset Liquid Glass sidebar (14 pt continuous corners); toolbar + web viewport inside one inset rounded page card (12 pt corners, 0.5 pt hairline rim, soft shadow) on a softly tinted window backdrop; grouped glass toolbar capsules; centered glass address capsule; Neon sidebar; focused address halo + grouped glass suggestions popover; full-window "Amethyst Dusk" private chrome. |
| Mac start page (regular and private) | `docs/design/mocks/fable-04-start-page.html`, `fable-05-private-window.html` | Profile chip + date, large `"Where to?"` title, large in-page search field (`724 × 52 pt` capsule with engine chip), one row of up to 8 app-icon-style `52 × 52 pt` bookmark tiles, 2-column Frequently Visited card, shortcut hints footer, real empty state. Private start page: `"Private Browsing"` heading, private big field, two-column `"Not kept after you close these tabs"` / `"Still visible or kept"` card, shortcut hints. |

### 1.2 Reconciliation rules

1. **Neon frame everywhere.** Window padding (`8 pt`), sidebar-to-card gap (`8 pt`), floating sidebar (`14 pt` corners), and rounded page card (`12 pt` corners) apply on every regular and private browser window.
2. **Start-page card transparency.** On start pages (regular and private), the page card keeps its `12 pt` hairline rim and layout bounds, but its fill becomes transparent so the window backdrop gradient shows through continuously across the window—matching Fable's full-window gradient feel. **Black** appearance, **Reduce Transparency**, and **Increase Contrast** replace gradients and glass with solid colors.
3. **Start-page toolbar.** On start pages, the toolbar address capsule is hidden; the toolbar displays only the leading Back/Forward glass group and the trailing Site Privacy / Browser Actions glass group (matching `fable-04-start-page.html:212–216` and `fable-05-private-window.html:223–227`).
4. **Single `AddressField` instance.** The in-page start search field and the toolbar address field MUST be **one** `AddressField` instance (`Apps/macOS/Views/AddressField.swift:28` wraps a single AppKit `FocusAwareAddressField: NSTextField` with `PrivacyAddressCell`). Never instantiate two `AddressField` views or re-parent the `NSTextField` across conditional branches. Mount it once in a persistent overlay over the page card whose frame animates between the start-page slot (`724 × 52 pt`) and the toolbar slot (`520 × 34 pt` rest / `576 × 36 pt` focused).
5. **Neon sidebar always wins.** Ignore the sidebar drawn in `fable-04-start-page.html` and `fable-05-private-window.html`. Use Neon's sidebar everywhere: `14 pt` corners, no redundant tab count next to the profile name, recessed search pill, 4-column pinned tiles, `"Tabs N"` section header, `34 pt` rows with close/audio shown only when needed (no permanently reserved empty audio slot), inline `+ New Tab ⌘T` directly under the last tab row, profile switcher dots above the footer, and 5 footer icons with active-download dot.
6. **Token ownership.** Neon's typography, radius, and color tokens are the Mac base. The Mac start page preserves Fable's measured dimensions (`724 pt` column, `52 pt` big field, `52 × 52 pt` app icons, `12.5 pt` icon radius, `16 pt` big-field text, `30 pt` bold title) so the start page looks identical to the Fable mock.
7. **iPhone untouched.** `Apps/Shared/Theme.swift` and `Apps/Shared/StartPageSites.swift` compile into both Mac and iPhone. Keep the iPhone start page and all existing shared/iOS token values unchanged. Implement Mac v3 start page as a Mac-only view (`Apps/macOS/Views/StartPage.swift` + Mac-only helper views) and place all new Mac v3 tokens under `#if os(macOS)` inside `enum OrivMacV3` in `Apps/Shared/Theme.swift`.

### 1.3 Verified Liquid Glass API allowlist (macOS 26 target / Xcode 27.2 SDK)

Use **only** these verified public SwiftUI glass APIs when implementing v3:

| API | Primary Use in v3 |
| --- | --- |
| `GlassEffectContainer(spacing:)` | Toolbar leading and trailing capsule groups, unified glass transitions |
| `.glassEffect(.regular.interactive().tint(_:), in:)` | Interactive toolbar pills, address capsule, start-page big field, sidebar surface |
| `.glassEffect(.clear, in:)` | Subtle glass chrome (e.g., sidebar collapse button, recessed pills where clear glass is desired) |
| `.glassEffectID(_:in:)` | Identity binding for morphing address field / toolbar controls |
| `.glassEffectUnion(id:namespace:)` | Merging adjacent controls into a single toolbar capsule group |
| `.glassEffectTransition(.matchedGeometry)` | Address capsule morph between start-page slot and toolbar slot (disabled under Reduce Motion) |
| `ConcentricRectangle(corners: .concentric, isUniform:)` | Concentric inner radii inside rounded cards, popovers, and sidebar containers |
| `.scrollEdgeEffectStyle(.soft, for: .top)` | Soft blur/fade scroll edge beneath the floating toolbar on loaded web pages |
| `.backgroundExtensionEffect()` | Extending page/backdrop color cleanly under translucent chrome where applicable |
| `.buttonStyle(.glass)` | Native glass button treatment where appropriate inside glass containers |

---

## 2. Token Tables (`OrivMacV3`)

All new Mac v3 tokens live under `#if os(macOS) enum OrivMacV3` in `Apps/Shared/Theme.swift`. Existing `Theme`, `OrivSpacing`, `OrivRadius`, `OrivType`, `OrivLayout`, `OrivMotion`, `OrivElevation`, and `OrivMaterial` symbols remain intact so iPhone and unmodified Mac screens (Settings, Library) continue compiling unchanged.

Legend for the **Status** column:
- **New** — added in `OrivMacV3` (no prior Mac token).
- **Replaces `file:line`** — supersedes the listed Mac-only behavior/token in v3 views while leaving the old symbol intact if shared with iPhone or Settings until phased out.
- **Proposed** — value not literally specified in an HTML mock (e.g., Black appearance, hover states, Reduce Transparency / Increase Contrast fallbacks, or contrast-gate adjustment).

### 2.1 Window Backdrop (`OrivMacV3.Backdrop`)

| Swift Token | Appearance / Mode | Value | Source | Status |
| --- | --- | --- | --- | --- |
| `OrivMacV3.Backdrop.lightBase` | Light (loaded page) | Linear gradient `155°`: `#DDE6F5` (0%) → `#E7EBF3` (48%) → `#E1E7F0` (100%) | `neon-01-main-window-light.html:47` | Replaces `Theme.graphite.chrome` (`Theme.swift:473`) for browser window backdrop |
| `OrivMacV3.Backdrop.lightAmbient` | Light (loaded page) | 3 radial glows over base: `#A8CEFF` @ 92% (14%, 12%), `#D4C6FA` @ 85% (6%, 86%), `#FFDEC4` @ 72% (24%, 48%) | `neon-01-main-window-light.html:44–46` | New |
| `OrivMacV3.Backdrop.startLightBase` | Light (start page) | Base `#F4F5FA` + 4 soft radial glows: `#96BAFF` @ 60% (22%, 12%), `#FFC8AA` @ 50% (86%, 20%), `#C4AAFF` @ 42% (62%, 96%), `#96E2D6` @ 40% (6%, 92%), softly shifted toward active `ProfileColor` (12% tint mix, **proposed**) | `fable-04-start-page.html:145–149` + proposed profile tint | New |
| `OrivMacV3.Backdrop.darkBase` | Dark (loaded page) | Linear gradient `155°`: `#111521` (0%) → `#151822` (50%) → `#0F121B` (100%) | `neon-02-main-window-dark.html:44` | Replaces `Theme.graphite.chrome` (`Theme.swift:473`) |
| `OrivMacV3.Backdrop.darkAmbient` | Dark (loaded page) | 3 radial glows over base: `#3E6CC6` @ 52% (10%, 16%), `#6E44B6` @ 44% (16%, 84%), `#2C8092` @ 34% (24%, 48%) | `neon-02-main-window-dark.html:41–43` | New |
| `OrivMacV3.Backdrop.startDarkBase` | Dark (start page, regular) | Base `#111521` + 3 soft cool glows: `#3E6CC6` @ 38% (20%, 10%), `#2C8092` @ 30% (86%, 22%), active `ProfileColor` bloom @ 22% (60%, 96%) — keeps regular Dark distinct from Private purple | **Proposed** (reconciles `neon-02` dark palette with `fable-04` start wall without colliding with Private purple) | New |
| `OrivMacV3.Backdrop.black` | Black (all pages) | Solid `#000000` (outer window canvas) | **Proposed** (`Theme.t3Code.canvas`, `Theme.swift:460`) | New |
| `OrivMacV3.Backdrop.privateBase` | Private ("Amethyst Dusk") | Linear gradient `155°`: `#160F24` (0%) → `#120D1D` (52%) → `#0E0A16` (100%) | `neon-05-private-mode.html:40` | New |
| `OrivMacV3.Backdrop.privateAmbient` | Private ("Amethyst Dusk") | 3 radial glows: `#8B5CF6` @ 44% (12%, 14%), `#C084FC` @ 28% (18%, 88%), `#5B21B6` @ 24% (62%, 20%) | `neon-05-private-mode.html:37–39` | New |
| `OrivMacV3.Backdrop.reducedLight` | Light + RT / IC | Solid `#E7EBF3` | **Proposed** (midpoint of `neon-01` base) | New |
| `OrivMacV3.Backdrop.reducedDark` | Dark + RT / IC | Solid `#151822` | **Proposed** (midpoint of `neon-02` base) | New |
| `OrivMacV3.Backdrop.reducedPrivate` | Private + RT / IC | Solid `#120D1D` | **Proposed** (midpoint of `neon-05` base) | New |

### 2.2 Inset Page Card (`OrivMacV3.Card`)

| Swift Token | Appearance / State | Value | Source | Status |
| --- | --- | --- | --- | --- |
| `OrivMacV3.Card.fillLight` | Light (loaded page) | `#FBFBF9` (behind `WKWebView` / empty canvas) | `neon-01-main-window-light.html:356` | Replaces `Theme.graphite.canvas` (`Theme.swift:469`) inside Mac browser card |
| `OrivMacV3.Card.fillDark` | Dark (loaded page) | `#17181C` | `neon-02-main-window-dark.html:245` | Replaces `Theme.graphite.canvas` (`Theme.swift:469`) inside Mac browser card |
| `OrivMacV3.Card.fillBlack` | Black (loaded & start) | `#0A0A0A` (or `#000000` web backing) | **Proposed** (`Theme.t3Code.chrome` / `canvas`, `Theme.swift:460–461`) | New |
| `OrivMacV3.Card.fillPrivate` | Private (loaded page) | `#120D1A` (linear `#161020` → `#120D1A` behind private web/empty) | `neon-05-private-mode.html:129` | New |
| `OrivMacV3.Card.fillStartPage` | Regular & Private start page (standard transparency, non-Black) | `.clear` (transparent; window backdrop gradient shows through; rim remains) | Reconciliation rule §1.2 | New |
| `OrivMacV3.Card.fillStartPageSolid` | Start page under Black / RT / IC | Light: `#F4F5FA`; Dark: `#151822`; Black: `#000000`; Private: `#15101A` | `fable-04-start-page.html:149,153` + **proposed** Dark/Black | New |
| `OrivMacV3.Card.rimLight` | Light | `rgba(15, 23, 42, 0.085)` (`0.5 pt`) | `neon-01-main-window-light.html:359` | New |
| `OrivMacV3.Card.rimDark` | Dark | `rgba(255, 255, 255, 0.085)` (`0.5 pt`) | `neon-02-main-window-dark.html:248` | New |
| `OrivMacV3.Card.rimBlack` | Black | `rgba(255, 255, 255, 0.12)` (`0.5 pt`) | **Proposed** | New |
| `OrivMacV3.Card.rimPrivate` | Private | `rgba(216, 180, 254, 0.14)` (`0.5 pt`) | `neon-05-private-mode.html:124` | New |
| `OrivMacV3.Card.rimIncreasedContrast` | Increase Contrast (all) | `theme.separatorStrong` (`1.5 pt` — `#646469` Light, `#A3A3A9` Dark, `#818181` Black; Private `#D8B4FE`) | `Theme.swift:409,494` + **proposed** Private | New |
| `OrivMacV3.Card.shadowLight` | Light | Dual drop shadow: `rgba(15, 23, 42, 0.06)` blur `12` y `2` + `rgba(15, 23, 42, 0.04)` blur `2` y `0.5` | `neon-01-main-window-light.html:360–362` | New |
| `OrivMacV3.Card.shadowDark` | Dark | `rgba(0, 0, 0, 0.42)` blur `24` y `6` | `neon-02-main-window-dark.html:249` | New |
| `OrivMacV3.Card.shadowBlack` | Black | None (`0`) | **Proposed** | New |
| `OrivMacV3.Card.shadowPrivate` | Private | `rgba(0, 0, 0, 0.48)` blur `26` y `6` | `neon-05-private-mode.html:125` | New |

### 2.3 Sidebar Glass Tint, Contrast Guard, and Controls (`OrivMacV3.Sidebar`)

The floating sidebar uses `.glassEffect(.regular.tint(...), in: RoundedRectangle(cornerRadius: 14, style: .continuous))` layered with the user's selected `SidebarColor` (`Graphite`, `Profile color`, or the 7 pastels in `Theme.SidebarChromaticTokens`, `Theme.swift:277–366`) and the Mac-wide `SidebarGlassOpacity` contrast guard (`Balanced`, `High`, `Solid`).

#### Surface glass & contrast guard by mode

| Swift Token | Appearance | Balanced | High | Solid / RT | Increase Contrast | Source | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `OrivMacV3.Sidebar.graphiteLightTint` | Light (Graphite) | Top `#F7F9FE` @ 62% → Bottom `#EEF2FA` @ 54%; guard `#FFFFFF` @ 65% | Top/Bottom @ 86%; guard `#FFFFFF` @ 65% | Opaque `#F2F4FA` → `#E6EAF3` (100%) | Opaque `#F2F4FA` → `#E6EAF3` + `1.5 pt` `#646469` border | `neon-01-main-window-light.html:56`; guard from `Theme.swift:533–535` | Replaces `SidebarChromaticTokens.graphiteLight` (`Theme.swift:312`) backing opacity/stops |
| `OrivMacV3.Sidebar.graphiteDarkTint` | Dark (Graphite) | Top `#242A3A` @ 56% → Bottom `#191E2A` @ 62%; guard `#0E1118` @ 65% | Top/Bottom @ 86%; guard `#0E1118` @ 65% | Opaque `#242A3A` → `#191E2A` (100%) | Opaque `#242A3A` → `#191E2A` + `1.5 pt` `#A3A3A9` border | `neon-02-main-window-dark.html:53`; guard from `Theme.swift:533–535` | Replaces `SidebarChromaticTokens.graphiteDark` (`Theme.swift:314`) |
| `OrivMacV3.Sidebar.blackTint` | Black | Solid `#0A0A0A` @ 86% over guard `#000000` @ 36% | `#0A0A0A` @ 94% over guard `#000000` @ 36% | Opaque `#0A0A0A` (100%) | Opaque `#0A0A0A` + `1.5 pt` `#818181` border | `Theme.swift:364,536–537` | Retains existing Black guard |
| `OrivMacV3.Sidebar.privateTint` | Private (Amethyst Dusk) | Top `#301C4E` @ 56% → Bottom `#1E1232` @ 66%; guard `#120C1C` @ 65% (**proposed**) | Top/Bottom @ 86%; guard `#120C1C` @ 65% | Opaque `#301C4E` → `#1E1232` (100%) | Opaque `#301C4E` → `#1E1232` + `1.5 pt` `#D8B4FE` border | `neon-05-private-mode.html:49` + proposed guard | New |
| `OrivMacV3.Sidebar.chromaticSwatches` | 12 non-Graphite `SidebarColor` tints | Retains `Theme.SidebarChromaticTokens` (`Theme.swift:316–363`) at `65%` backing / `65%` guard | `86%` backing / `65%` guard | `100%` opaque gradient | `100%` opaque + `1.5 pt` `separatorStrong` border | `Theme.swift:316–363,533–535` | Retains existing 12 swatch palettes |

#### Sidebar border, shadow, and internal controls

| Swift Token | Light | Dark | Black | Private | RT / IC Fallback | Source | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `OrivMacV3.Sidebar.border` | `rgba(255, 255, 255, 0.72)` (`0.5 pt`) | `rgba(255, 255, 255, 0.14)` (`0.5 pt`) | `rgba(255, 255, 255, 0.12)` (**proposed**) | `rgba(216, 180, 254, 0.22)` (`0.5 pt`) | RT: `theme.separator`; IC: `theme.separatorStrong` (`1.5 pt`) | `neon-01:59`, `neon-02:56`, `neon-05:52` | New |
| `OrivMacV3.Sidebar.specularTop` | `rgba(255, 255, 255, 0.85)` (`1 pt` inset top) | `rgba(255, 255, 255, 0.18)` (`1 pt` inset top) | None | `rgba(233, 213, 255, 0.24)` (`1 pt` inset top) | None | `neon-01:61`, `neon-02:58`, `neon-05:54` | New |
| `OrivMacV3.Sidebar.shadow` | `rgba(15, 23, 42, 0.07)` r `26` y `8` + `0.05` r `3` y `1` | `rgba(0, 0, 0, 0.35)` r `30` y `10` | None | `rgba(0, 0, 0, 0.42)` r `32` y `10` | Same subtle drop shadow (`0` in IC) | `neon-01:63–64`, `neon-02:60`, `neon-05:55` | New |
| `OrivMacV3.Sidebar.toggleFill` | `rgba(255, 255, 255, 0.36)` (`.glassEffect(.clear)` / subtle pill) | `rgba(255, 255, 255, 0.06)` | `rgba(255, 255, 255, 0.08)` (**proposed**) | `rgba(216, 180, 254, 0.08)` | Solid `theme.sidebar.hover` | `neon-01:106`, `neon-02:89`, `neon-05:71` | New |
| `OrivMacV3.Sidebar.searchFill` | `rgba(20, 26, 40, 0.055)` + top inner shadow `rgba(15, 23, 42, 0.07)` | `rgba(255, 255, 255, 0.065)` + top inner highlight `rgba(255, 255, 255, 0.09)` | `#1E1E1E` (`Theme.t3Code.sidebar.field`) | `rgba(216, 180, 254, 0.075)` | Solid `theme.sidebar.field` (`+ 1.5 pt` IC border) | `neon-01:144–145`, `neon-02:119–120`, `neon-05:87–88` | Replaces `Theme.SidebarTone.search` (`Theme.swift:374`) |
| `OrivMacV3.Sidebar.pinFill` | `rgba(255, 255, 255, 0.52)`, border `rgba(255, 255, 255, 0.78)` `0.5 pt`, shadow `rgba(15, 23, 42, 0.045)` r `3` y `1` | `rgba(255, 255, 255, 0.075)`, border `rgba(255, 255, 255, 0.13)` `0.5 pt`, shadow `rgba(0, 0, 0, 0.18)` r `6` y `2` | `#171717`, border `rgba(255, 255, 255, 0.10)` (**proposed**) | `rgba(216, 180, 254, 0.10)`, border `rgba(216, 180, 254, 0.18)` (**proposed**) | Solid `theme.surfaceRaised` (Light) / `theme.fill` (Dark/Black) + `1.5 pt` IC border | `neon-01:195–197`, `neon-02:152–154` | New (replaces `Tile.Kind.pinned` fill in Mac sidebar) |
| `OrivMacV3.Sidebar.rowHover` | `rgba(20, 26, 40, 0.05)` | `rgba(255, 255, 255, 0.06)` (**proposed**) | `#171717` (`Theme.t3Code.sidebar.hover`) | `rgba(216, 180, 254, 0.08)` (**proposed**) | Solid `theme.sidebar.hover` | `neon-01:232` + `Theme.swift:373,466` | Replaces `Theme.SidebarTone.hover` (`Theme.swift:373`) |
| `OrivMacV3.Sidebar.activeFill` | Linear `rgba(255, 255, 255, 0.86)` → `rgba(224, 238, 255, 0.78)` | Linear `rgba(78, 134, 224, 0.40)` → `rgba(54, 102, 178, 0.34)` | `#292E37` (`Theme.swift:365`) | Linear `rgba(168, 85, 247, 0.36)` → `rgba(126, 34, 206, 0.28)` | Solid `tokens.opaqueActive` (Light `#C9E0FC`, Dark `#2E5A8F`, Black `#252A32`, Private `#5A2C8A` **proposed**) | `neon-01:221`, `neon-02:172`, `neon-05:102` | Replaces `SidebarChromaticStyle.fill` (`Theme.swift:561`) for Graphite & Private |
| `OrivMacV3.Sidebar.activeBorder` | `rgba(29, 111, 209, 0.22)` `0.5 pt` + top highlight `rgba(255, 255, 255, 0.95)` | `rgba(153, 199, 255, 0.34)` `0.5 pt` + top highlight `rgba(190, 220, 255, 0.32)` | `#A3AFC0` @ 30% (`Theme.swift:365`) | `rgba(216, 180, 254, 0.40)` `0.5 pt` + top highlight `rgba(243, 232, 255, 0.34)` | RT: `0.5 pt` `rimBottom`; IC: `2 pt` `activeInk` | `neon-01:225–227`, `neon-02:175–177`, `neon-05:104–105` | Replaces `SidebarChromaticStyle.rimTop/rimBottom` (`Theme.swift:562–563`) |
| `OrivMacV3.Sidebar.activeShadow` | `rgba(29, 111, 209, 0.10)` r `8` y `2` + `rgba(15, 23, 42, 0.06)` r `2` y `0.5` | `rgba(59, 130, 246, 0.22)` r `12` y `3` | None | `rgba(139, 92, 246, 0.28)` r `14` y `3` | None in RT / IC | `neon-01:228–229`, `neon-02:178`, `neon-05:105` | Replaces `SidebarChromaticStyle.glow` (`Theme.swift:564`) |
| `OrivMacV3.Sidebar.activeInk` | `#0B3D78` (Graphite Cobalt) / `tokens.ink` for custom tints | `#FFFFFF` | `#F5F5F5` | `#FFFFFF` | Same (verified ≥ 4.5:1 on opaque active) | `neon-01:18,222`, `neon-02:173`, `neon-05:103` | Replaces `graphiteLight.ink` (`#0C3566`, `Theme.swift:313`) |
| `OrivMacV3.Sidebar.audioInk` | `#007AFF` (or system accent) @ 92% | `#7CC0FF` | `#7CC0FF` (**proposed**) | `#D8B4FE` (**proposed**) | High-contrast accent (`theme.markerAccent`) | `neon-01:263–264`, `neon-02:200` | New |
| `OrivMacV3.Sidebar.profileAvatarBg` | Profile color gradient (e.g., Mulberry `rgba(139, 92, 246, 0.20)` → `0.30`), ink `#6B21A8` | Profile color gradient (`0.30` → `0.20`), ink `#E5B8FF` | Dark profile badge (**proposed**) | `rgba(192, 132, 252, 0.24)`, ink `#D8B4FE` | Solid tinted badge + `profile.sidebarInk` | `neon-01:124–125`, `neon-02:106–107`, `neon-05:78–79` | New |
| `OrivMacV3.Sidebar.footerSeparator` | `rgba(20, 22, 26, 0.085)` (`0.5 pt`) | `rgba(255, 255, 255, 0.09)` (`0.5 pt`) | `#191919` (`Theme.t3Code.separator`) | `rgba(216, 180, 254, 0.13)` (`0.5 pt`) | IC: `1.5 pt` `theme.separatorStrong` | `neon-01:22,323`, `neon-02:19,223`, `neon-05:15,114` | Replaces `theme.separator` (`BrowserSidebar.swift:343`) |
| `OrivMacV3.Sidebar.downloadDotRing` | `rgba(244, 247, 253, 0.95)` (`1.5 pt` ring around `6 pt` accent dot) | `rgba(25, 30, 42, 0.95)` (**proposed**) | `#0A0A0A` (**proposed**) | `#1E1232` (**proposed**) | Matches opaque sidebar bottom color | `neon-01:348` | New |

### 2.4 Toolbar Glass and Scroll Edge (`OrivMacV3.Toolbar`)

Toolbar pill groups use `GlassEffectContainer(spacing: 2)` with `.glassEffect(.regular.interactive().tint(...), in: Capsule())` (or `.glassEffectUnion(id:namespace:)` for buttons inside one pill). Under Black, Reduce Transparency, or Increase Contrast, they fall back to opaque capsules.

| Swift Token | Light | Dark | Black | Private | RT / IC Fallback | Source | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `OrivMacV3.Toolbar.groupTint` | `rgba(255, 255, 255, 0.68)` over `.regular.interactive()` glass | `rgba(40, 44, 54, 0.62)` over `.regular.interactive()` glass | Solid `#161618` (**proposed**) | `rgba(52, 34, 80, 0.62)` over `.regular.interactive()` glass | RT: Solid Light `#F4F5F8`, Dark `#282C36`, Black `#161618`, Private `#342250`; IC: `theme.fill` + `1.5 pt` `separatorStrong` | `neon-01:407`, `neon-02:291`, `neon-05:141` | Replaces solid `mainTopBar` background (`BrowserWindow.swift:440–443`) |
| `OrivMacV3.Toolbar.groupBorder` | `rgba(15, 23, 42, 0.085)` (`0.5 pt`) + top highlight `rgba(255, 255, 255, 0.92)` | `rgba(255, 255, 255, 0.14)` (`0.5 pt`) + top highlight `rgba(255, 255, 255, 0.18)` | `rgba(255, 255, 255, 0.14)` (**proposed**) | `rgba(216, 180, 254, 0.20)` (`0.5 pt`) + top highlight `rgba(233, 213, 255, 0.20)` | RT: `0.5 pt` `theme.separator`; IC: `1.5 pt` `theme.separatorStrong` | `neon-01:410–412`, `neon-02:294–296`, `neon-05:144–145` | New |
| `OrivMacV3.Toolbar.groupShadow` | `rgba(15, 23, 42, 0.065)` r `10` y `2` + `0.04` r `2` y `0.5` | `rgba(0, 0, 0, 0.32)` r `14` y `4` | None | `rgba(0, 0, 0, 0.34)` r `14` y `4` | None in IC | `neon-01:413–414`, `neon-02:297`, `neon-05:145` | New |
| `OrivMacV3.Toolbar.divider` | `rgba(15, 23, 42, 0.12)` (`0.5 × 14 pt`) | `rgba(255, 255, 255, 0.12)` (`0.5 × 14 pt`) | `rgba(255, 255, 255, 0.14)` (**proposed**) | `rgba(216, 180, 254, 0.16)` (`0.5 × 14 pt`) | IC: `theme.separatorStrong` | `neon-01:438–440`, `neon-02:321–323`, `neon-05:149` | New |
| `OrivMacV3.Toolbar.disabledOpacity` | `0.30` | `0.30` | `0.35` (**proposed**) | `0.30` | IC: `0.50` (`ToolbarButton.swift:48`) | `neon-01:426`, `neon-02:309`, `neon-05:148` | Replaces `0.5` (`ToolbarButton.swift:48`) |
| `OrivMacV3.Toolbar.shieldDot` | `#16A34A` + `1.5 pt` ring `rgba(255, 255, 255, 0.92)` | `#4ADE80` + `1.5 pt` ring `rgba(34, 38, 48, 0.95)` | `#4ADE80` + `#161618` ring (**proposed**) | `#4ADE80` + `#342250` ring (**proposed**) | Same high-contrast green | `neon-01:434–435`, `neon-02:317–318` | New |
| `OrivMacV3.Toolbar.scrollEdge` | `.scrollEdgeEffectStyle(.soft, for: .top)` (visual target: linear `#FBFBF9` @ 88% → 66% → 0% over `60 + 18 pt` fade) | `.scrollEdgeEffectStyle(.soft, for: .top)` (visual target: `#17181C` @ 80% → 48% → 0% over `60 + 22 pt`) | Solid `#0A0A0A` top band (no blur) | `.scrollEdgeEffectStyle(.soft, for: .top)` (`#161020` @ 80% → 0%) | RT / IC: solid `pageChrome.color` (or `theme.chrome`) top bar band | `neon-01:379–387`, `neon-02:264–272` | Replaces `.scrollEdgeEffectStyle(.automatic, for: .top)` (`BrowserWindow.swift:778`) |

### 2.5 Address Capsule (`OrivMacV3.Address`)

| Swift Token | Light | Dark | Black | Private | RT / IC Fallback | Source | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `OrivMacV3.Address.restFill` | `rgba(255, 255, 255, 0.72)` over `.regular.interactive()` glass | `rgba(42, 46, 56, 0.64)` over `.regular.interactive()` glass | Solid `#18181B` (**proposed**) | `rgba(54, 35, 84, 0.68)` over `.regular.interactive()` glass | RT: Solid Light `#F6F7FA`, Dark `#2A2E38`, Black `#18181B`, Private `#362354`; IC: `theme.fill` | `neon-01:456`, `neon-02:339`, `neon-05:155` | Replaces `MacAddressPalette.fill` (`BrowserWindow.swift:817–847`) |
| `OrivMacV3.Address.hoverFill` | `rgba(255, 255, 255, 0.82)` (**proposed**) | `rgba(50, 55, 67, 0.74)` (**proposed**) | `#222226` (**proposed**) | `rgba(66, 43, 102, 0.78)` (**proposed**) | Solid `theme.sidebar.hover` / elevated fill | **Proposed** | New |
| `OrivMacV3.Address.restBorder` | `rgba(15, 23, 42, 0.09)` (`0.5 pt`) + top highlight `rgba(255, 255, 255, 0.96)` | `rgba(255, 255, 255, 0.15)` (`0.5 pt`) + top highlight `rgba(255, 255, 255, 0.19)` | `rgba(255, 255, 255, 0.16)` (**proposed**) | `rgba(216, 180, 254, 0.26)` (`0.5 pt`) + top highlight `rgba(243, 232, 255, 0.22)` | RT: `0.5 pt` `theme.separator`; IC: `1.5 pt` `theme.separatorStrong` | `neon-01:459–461`, `neon-02:342–344`, `neon-05:158–159` | New |
| `OrivMacV3.Address.restShadow` | `rgba(15, 23, 42, 0.06)` r `10` y `2` + `0.04` r `2` y `0.5` | `rgba(0, 0, 0, 0.34)` r `16` y `4` | None | `rgba(0, 0, 0, 0.36)` r `16` y `4` | None in IC | `neon-01:462–463`, `neon-02:345`, `neon-05:159` | New |
| `OrivMacV3.Address.focusFill` | `rgba(255, 255, 255, 0.94)` over glass | `rgba(34, 38, 48, 0.94)` (**proposed**) | `#1E1E22` (**proposed**) | `rgba(48, 30, 74, 0.94)` (**proposed**) | Solid `#FFFFFF` (Light), `#222630` (Dark), `#1E1E22` (Black), `#301E4A` (Private) | `neon-03-address-bar-focused.html:178` + proposed dark/black/private | Replaces `MacAddressPalette` focused mix (`BrowserWindow.swift:820,832`) |
| `OrivMacV3.Address.focusBorder` | `theme.accent` @ 88% (`#007AFF` @ 88%), `1.5 pt` | `theme.accent` @ 90% (`#3B82F6` @ 90%), `1.5 pt` (**proposed**) | `theme.accent` @ 92%, `1.5 pt` (**proposed**) | `#C084FC` @ 90%, `1.5 pt` (**proposed**) | IC: `2 pt` opaque `theme.accent` (Private: `#D8B4FE`) | `neon-03:181` + proposed | Replaces `BrowserWindow.swift:506–507` |
| `OrivMacV3.Address.focusHalo` | `theme.accent` @ 18%, `3.5 pt` outer spread + drop shadow `rgba(15, 23, 42, 0.12)` r `20` y `6` | `theme.accent` @ 24%, `3.5 pt` spread (**proposed**) | `theme.accent` @ 24%, `3.5 pt` spread (**proposed**) | `#C084FC` @ 24%, `3.5 pt` spread (**proposed**) | IC: no soft halo; crisp `2 pt` focus ring | `neon-03:183–184` | New |
| `OrivMacV3.Address.inlineCompletionBg` | `rgba(0, 122, 255, 0.16)`, ink `#0B3D78` | `rgba(59, 130, 246, 0.28)`, ink `#E0EEFF` (**proposed**) | `rgba(59, 130, 246, 0.30)`, ink `#FFFFFF` (**proposed**) | `rgba(192, 132, 252, 0.28)`, ink `#F7F2FD` (**proposed**) | Native `NSTextView` selectedTextAttributes | `neon-03:203–204` | New |
| `OrivMacV3.Address.tabHint` | Fill `rgba(15, 23, 42, 0.06)`, border `0.5 pt` `rgba(15, 23, 42, 0.10)`, ink `textSecondary` | Fill `rgba(255, 255, 255, 0.09)`, border `rgba(255, 255, 255, 0.14)`, ink `textSecondary` (**proposed**) | Fill `#2A2A2E`, border `#3F3F46` (**proposed**) | Fill `rgba(216, 180, 254, 0.12)`, border `rgba(216, 180, 254, 0.22)` (**proposed**) | Solid `theme.fill` + `theme.separator` | `neon-03:215–218` | New |
| `OrivMacV3.Address.privatePill` | Fill `rgba(192, 132, 252, 0.24)`, border `0.5 pt` `rgba(216, 180, 254, 0.34)`, ink `#EAD2FF` | Same (Amethyst Dusk) | Same (Amethyst Dusk) | Same (`neon-05:161–167`) | Solid `#33263D` + `#D5AAF8` ink (`Theme.swift:413,457`) | `neon-05-private-mode.html:165–167` | Replaces `BrowserWindow.swift:526–527` |
| `OrivMacV3.Address.progressBar` | Linear `rgba(0, 122, 255, 0.18)` → `#007AFF` (70%) → `#60A5FA` (100%) + subtle glow (**proposed** Light mirror) | Linear `rgba(96, 165, 250, 0.15)` → `#60A5FA` (70%) → `#93C5FD` (100%) + glow `rgba(96, 165, 250, 0.65)` r `8` | `#60A5FA` solid (**proposed**) | Linear `rgba(192, 132, 252, 0.20)` → `#C084FC` → `#E9D5FF` (**proposed**) | Solid `theme.accent` (no glow in RT / IC) | `neon-02-main-window-dark.html:348–357` | Replaces full-width page-top bar (`BrowserWindow.swift:722–730`) |
| `ConnectionCue.color(_:)` (in address capsule) | `.recording` → `theme.danger` (`#B3261E`); `.notSecure` → `theme.warning` (`#794900`); others → `textSecondary` | `.recording` → `theme.danger` (`#FF9A8F`); `.notSecure` → `theme.warning` (`#E0AA55`); others → `textSecondary` | `.recording` → `#FF9A8F`; `.notSecure` → `#D9A04A`; others → `textSecondary` | Same dark semantic tokens | Same (verified ≥ 4.5:1) | `Apps/Shared/ConnectionCue.swift:42–48` + `Theme.swift:410,464,479` | Wires existing `ConnectionCue.color(_:)` into Mac address capsule (currently unused in `BrowserWindow.swift:535–537`) |

### 2.6 Popover, Suggestions Dropdown, and Handoff Bar Glass (`OrivMacV3.Popover`, `OrivMacV3.Suggestions`, `OrivMacV3.Handoff`)

| Swift Token | Light | Dark | Black | Private | RT / IC Fallback | Source | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `OrivMacV3.Popover.glassFill` | `rgba(252, 253, 255, 0.94)` over `.regular` glass | `rgba(34, 37, 46, 0.92)` (**proposed**) | `#141416` (**proposed**) | `rgba(42, 26, 66, 0.94)` (**proposed**) | Solid `theme.surface` (`#F5F5F7` / `#242426` / `#111111` / `#2A1A42`) | `neon-03-address-bar-focused.html:243` | Replaces `OrivMaterial.overlay` (`Theme.swift:192–204`) for Mac suggestions |
| `OrivMacV3.Popover.border` | Inner `0.5 pt` `rgba(255, 255, 255, 0.95)`, outer `0.5 pt` `rgba(15, 23, 42, 0.09)` | `0.5 pt` `rgba(255, 255, 255, 0.14)` (**proposed**) | `0.5 pt` `rgba(255, 255, 255, 0.14)` (**proposed**) | `0.5 pt` `rgba(216, 180, 254, 0.24)` (**proposed**) | RT: `theme.separator`; IC: `1.5 pt` `theme.separatorStrong` | `neon-03:246–251` | New |
| `OrivMacV3.Popover.shadow` | `rgba(15, 23, 42, 0.22)` r `54` y `22` + `0.08` r `14` y `4` | `rgba(0, 0, 0, 0.55)` r `54` y `22` (**proposed**) | `rgba(0, 0, 0, 0.70)` r `36` y `14` (**proposed**) | `rgba(0, 0, 0, 0.58)` r `54` y `22` (**proposed**) | `OrivElevation.overlay` (`Theme.swift:155`) | `neon-03:249–250` | Replaces `OrivElevation.overlay` for Mac suggestions |
| `OrivMacV3.Suggestions.scrim` | `rgba(15, 20, 32, 0.08)` over page content | `rgba(0, 0, 0, 0.24)` (**proposed**) | `rgba(0, 0, 0, 0.40)` (**proposed**) | `rgba(8, 4, 16, 0.28)` (**proposed**) | RT: same solid tint; IC: none | `neon-03:134` | New |
| `OrivMacV3.Suggestions.selectedFill` | Linear `rgba(0, 122, 255, 0.15)` → `0.11`, inner border `0.5 pt` `rgba(0, 122, 255, 0.24)`, title `#08346B`, url `#1E5494` | Linear `rgba(59, 130, 246, 0.28)` → `0.22`, border `rgba(147, 197, 253, 0.30)`, title `#FFFFFF`, url `#C7DCFF` (**proposed**) | `#252A36`, border `rgba(147, 197, 253, 0.32)`, title `#FFFFFF`, url `#C7DCFF` (**proposed**) | Linear `rgba(168, 85, 247, 0.32)` → `0.24`, border `rgba(216, 180, 254, 0.36)`, title `#FFFFFF`, url `#EAD2FF` (**proposed**) | Solid `theme.fillSelected` + `2 pt` IC border | `neon-03:270–273,299,308` | Replaces `ListSelection` 3 pt leading bar in Mac suggestions (`BrowserWindow.swift:870`) |
| `OrivMacV3.Suggestions.alreadyOpenPill` | Fill `rgba(0, 122, 255, 0.12)`, border `rgba(0, 122, 255, 0.20)`, ink `#0B3D78` | Fill `rgba(59, 130, 246, 0.22)`, border `rgba(147, 197, 253, 0.30)`, ink `#CFE4FF` (**proposed**) | Same as Dark | Fill `rgba(192, 132, 252, 0.22)`, border `rgba(216, 180, 254, 0.34)`, ink `#EAD2FF` (**proposed**) | Solid `theme.fill` + `theme.text` | `neon-03:310–322` | New (replaces neutral `Badge` in Mac suggestions) |
| `OrivMacV3.Suggestions.returnKeyChip` | Fill `rgba(255, 255, 255, 0.78)`, border `rgba(0, 122, 255, 0.25)`, ink `#0B3D78` | Fill `rgba(255, 255, 255, 0.14)`, border `rgba(147, 197, 253, 0.32)`, ink `#FFFFFF` (**proposed**) | Same as Dark | Fill `rgba(216, 180, 254, 0.18)`, border `rgba(216, 180, 254, 0.36)`, ink `#FFFFFF` (**proposed**) | Solid `theme.surfaceRaised` + `theme.text` | `neon-03:323–333` | New |
| `OrivMacV3.Suggestions.enginePill` | Fill `rgba(15, 23, 42, 0.05)`, ink `textTertiary` | Fill `rgba(255, 255, 255, 0.08)`, ink `textSecondary` (**proposed**) | Fill `#222226`, ink `textSecondary` (**proposed**) | Fill `rgba(216, 180, 254, 0.10)`, ink `textSecondary` (**proposed**) | Solid `theme.fill` | `neon-03:351–357` | New |
| `OrivMacV3.Suggestions.divider` | `rgba(15, 23, 42, 0.09)` (`0.5 pt`) | `rgba(255, 255, 255, 0.10)` (**proposed**) | `#222226` (**proposed**) | `rgba(216, 180, 254, 0.14)` (**proposed**) | `theme.separator` / `separatorStrong` | `neon-03:335–339` | New |
| `OrivMacV3.Handoff.bar` | N/A (private windows only) | N/A | N/A | Fill `rgba(60, 38, 94, 0.54)` over glass, border `0.5 pt` `rgba(216, 180, 254, 0.24)`, top highlight `rgba(243, 232, 255, 0.16)`, shadow `rgba(0, 0, 0, 0.26)` r `20` y `6`, msg `#EAD8FF`, picker `rgba(255, 255, 255, 0.08)`, Move button `#A855F7` → `#9333EA` white ink | RT / IC: Solid `#33263D`, `1.5 pt` `#D8B4FE` border, solid `#7E22CE` Move button | `neon-05-private-mode.html:178–210` | Replaces Mac branch of `ExternalPrivateBar` (`Apps/Shared/ExternalPrivateBar.swift:25,49–55`) |

### 2.7 Start Page Surface Tokens (`OrivMacV3.StartPage`)

| Swift Token | Light | Dark | Black | Private | RT / IC Fallback | Source | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `OrivMacV3.StartPage.bigFieldFill` | `rgba(255, 255, 255, 0.60)` over `.regular.interactive()` glass (elevates to `0.94` when focused) | `rgba(74, 77, 86, 0.50)` over `.regular.interactive()` glass | Solid `#18181B` (**proposed**) | `rgba(96, 70, 118, 0.46)` over `.regular.interactive()` glass | Solid `theme.surfaceRaised` (Light `#FFFFFF`, Dark `#2E2E30`, Black `#18181B`, Private `#2B1D3B`) | `fable-04-start-page.html:21,32,39,46,157–159` | New |
| `OrivMacV3.StartPage.bigFieldShadow` | `0 18 40 -16 rgba(20, 28, 60, 0.35)` + `0 2 6 rgba(20, 28, 60, 0.08)` + focused halo `3.5 pt` `accent` @ 14% & `1 pt` `accent` | Same dark shadow `rgba(0, 0, 0, 0.55)` + focused halo `3.5 pt` `accent` @ 20% | No drop shadow; crisp `1.5 pt` `accent` ring | Same dark shadow + focused halo `3.5 pt` `#C792F5` @ 22% & `1 pt` `#C792F5` | IC: `2 pt` solid focus border, no soft halo | `fable-04:17,28,39,158–159` | New |
| `OrivMacV3.StartPage.engineChipFill` | `rgba(0, 0, 0, 0.055)` | `rgba(255, 255, 255, 0.08)` | `#242428` (**proposed**) | `rgba(255, 255, 255, 0.08)` | Solid `theme.fill` | `fable-04:23,34,161` | New |
| `OrivMacV3.StartPage.tileHoverFill` | `rgba(255, 255, 255, 0.86)`, shadow `0 1 2.5 rgba(20, 28, 45, 0.13)` + `0.5 pt` `rgba(20, 28, 45, 0.07)` | `rgba(255, 255, 255, 0.16)`, top inset `rgba(255, 255, 255, 0.22)` | `#1C1C1C` (**proposed**) | N/A (no bookmarks in Private) | Solid `theme.surfaceRaised` + `theme.separator` | `fable-04:24,35,167` | New (replaces `Tile.Kind.site` on Mac) |
| `OrivMacV3.StartPage.appIconShadow` | `rgba(20, 28, 60, 0.35)` r `14` y `6` + `0.5 pt` inner `rgba(0, 0, 0, 0.08)` | `rgba(0, 0, 0, 0.45)` r `14` y `6` + `0.5 pt` inner `rgba(255, 255, 255, 0.12)` (**proposed**) | None | N/A | None in IC | `fable-04:168` | New |
| `OrivMacV3.StartPage.frequentCardFill` | `rgba(255, 255, 255, 0.86)` + `0.5 pt` `rgba(20, 28, 45, 0.07)` + shadow `0 1 2.5 rgba(20, 28, 45, 0.13)` | `rgba(255, 255, 255, 0.07)` + `0.5 pt` `rgba(255, 255, 255, 0.10)` | `#111111` + `0.5 pt` `#262626` (**proposed**) | N/A | Solid `theme.surfaceRaised` + `theme.separator` (`1.5 pt` IC) | `fable-04:24,169–171` | New |
| `OrivMacV3.StartPage.privateCardFill` | N/A | N/A | N/A | `rgba(213, 170, 248, 0.09)` + `0.5 pt` inner rim `rgba(213, 170, 248, 0.25)` | RT: Solid `#23192E` + `0.5 pt` `#6E4B8E`; IC: `#23192E` + `1.5 pt` `#D8B4FE` | `fable-05-private-window.html:178–179` | Replaces `StartPage.privateExplanation` (`StartPage.swift:29–41`) |
| `OrivMacV3.StartPage.keycapFill` | `rgba(0, 0, 0, 0.055)` | `rgba(255, 255, 255, 0.08)` | `#1C1C1E` (**proposed**) | `rgba(255, 255, 255, 0.08)` | Solid `theme.fill` | `fable-04:23,34,176` | New |

### 2.8 Text, Separator, Semantic Colours, and Focus Rings (`OrivMacV3.Ink`, `OrivMacV3.Semantic`, `OrivMacV3.Focus`)

| Swift Token | Light | Dark | Black | Private | Increase Contrast | Source | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `OrivMacV3.Ink.primary` | `#14161A` | `#F5F6FA` | `#F5F5F5` | `#F7F2FD` | Same (≥ 13:1 on all backings) | `neon-01:19`, `neon-02:16`, `neon-05:12`, `Theme.swift:462` | Replaces Mac chrome `theme.text` (`Theme.swift:475`) |
| `OrivMacV3.Ink.secondary` | `#4A4E59` | `#B4BAC7` | `#A3A3A3` | `#C8B7DE` | Light `#36363B`; Dark `#D9D9DD`; Black `#B8B8B8`; Private `#E8D8FC` (**proposed**) | `neon-01:20`, `neon-02:17`, `neon-05:13`, `Theme.swift:462,490,495` | Replaces Mac chrome `theme.textSecondary` (`Theme.swift:476`) |
| `OrivMacV3.Ink.tertiary` | `#6E7380` on card (`4.74:1` on `#FFF`); **`#5C616E` proposed** on tinted sidebar (`≥ 5.1:1`) | `#7E8594` on card (`4.79:1` on `#17181C`); **`#9BA2B0` proposed** on sidebar (`≥ 5.2:1`) | `#8A8A8A` (`Theme.swift:463`) | `#9683B0` on card (`5.46:1`); **`#AA98C4` proposed** on sidebar (`≥ 5.1:1`) | Promotes to `Ink.secondary` IC | `neon-01:21`, `neon-02:18`, `neon-05:14` + contrast-gate note | Replaces Mac chrome `theme.textTertiary` (`Theme.swift:478`) |
| `OrivMacV3.Semantic.accent` | System `NSColor.controlAccentColor` (mock ref `#007AFF`; link text `#0A6CF5` / `#0066D6` for ≥ 4.5:1 on white) | System `NSColor.controlAccentColor` (mock ref `#3B82F6` / `#60A5FA`) | System `NSColor.controlAccentColor` | `#D8B4FE` (highlight `#C084FC`) | System accent + `theme.markerAccent` | `neon-01:17`, `neon-02:15`, `neon-05:10–11`, `fable-04:17` | Uses existing `theme.accent` (`Theme.swift:261`) + Private override |
| `OrivMacV3.Semantic.danger` | `#B3261E` | `#FF9A8F` | `#FF9A8F` | `#FF9A8F` | Same | `Theme.swift:410` | Retains existing `theme.danger` |
| `OrivMacV3.Semantic.warning` | `#794900` | `#E0AA55` | `#D9A04A` | `#E0AA55` | Same | `Theme.swift:464,479` | Retains existing `theme.warning` |
| `OrivMacV3.Semantic.success` | `#1D6B3A` (shield dot `#16A34A`) | `#7FD99A` (shield dot `#4ADE80`) | `#7FD99A` | `#7FD99A` | Same | `Theme.swift:411`, `neon-01:434`, `neon-02:317` | Retains existing `theme.success` |
| `OrivMacV3.Semantic.privateAccent` | `#713692` | `#D8B4FE` (`#D5AAF8` in `Theme.swift:457`) | `#D8B4FE` | `#D8B4FE` (`#C084FC` strong) | Light `#521E70`; Dark/Private `#F0DBFF` (**proposed**) | `neon-05:10–11`, `Theme.swift:456–458` | Extends `theme.private` |
| `OrivMacV3.Focus.sidebarRing` | `#0F172A`, `2 pt` inset (`4 pt` inset from row edge) | `#FFFFFF`, `2 pt` inset | `#FFFFFF`, `2 pt` inset | `#F7F2FD`, `2 pt` inset (**proposed**) | Same (`≥ 3:1` verified) | `Theme.swift:121–122,275` | Retains `Theme.sidebarKeyboardFocus` |
| `OrivMacV3.Focus.addressRing` | `1.5 pt` `accent` @ 88% + `3.5 pt` `accent` @ 18% halo | `1.5 pt` `accent` @ 90% + `3.5 pt` `accent` @ 24% halo (**proposed**) | `1.5 pt` `accent` @ 92% + `3.5 pt` halo (**proposed**) | `1.5 pt` `#C084FC` @ 90% + `3.5 pt` `#C084FC` @ 24% halo (**proposed**) | `2 pt` opaque `accent` / `#D8B4FE` (no halo) | `neon-03:181–183` | Replaces `BrowserWindow.swift:506–507` |

---

## 3. Geometry

All dimensions are in macOS points (`1 CSS px = 1 pt`). Continuous corners (`.continuous` / `ConcentricRectangle`) are used everywhere.

### 3.1 Radius Ladder (`OrivMacV3.Radius`)

| Swift Token | v3 Target (pt) | Source | Current Value (pt) | Current `file:line` | Notes |
| --- | ---: | --- | ---: | --- | --- |
| `OrivMacV3.Radius.sidebarFavicon` | `5` | `neon-01:237` | `size * 0.22` (`~4.2`) | `Theme.swift:786` | `18 pt` row favicon |
| `OrivMacV3.Radius.tabHint` | `5` | `neon-03:218` | — | — | `Tab` hint chip & start footer keycaps (`fable-04:176`) |
| `OrivMacV3.Radius.accessory` | `6` | `neon-01:254` | `8` (`OrivRadius.control`) | `BrowserSidebar.swift:491` | Close/audio button & return-key chip (`neon-03:329`) |
| `OrivMacV3.Radius.profileAvatar` | `7` | `neon-01:123` | `none` (bare symbol) | `ProfileViews.swift:75–77` | `22 × 22` profile badge & `24 × 24` suggestion icon (`neon-03:277`) |
| `OrivMacV3.Radius.control` | `8` | `neon-01:98,333` | `8` (`OrivRadius.control`) | `Theme.swift:18` | Sidebar toggle & footer buttons |
| `OrivMacV3.Radius.sidebarSearch` | `9` | `neon-01:143` | `8` (`OrivRadius.control`) | `OrivSearchField.swift:18` | Recessed sidebar search pill & suggestion search row (`neon-03:343`) |
| `OrivMacV3.Radius.row` | `10` | `neon-01:14,114,211` | `8` inactive / `13` active | `Theme.swift:86`, `BrowserSidebar.swift:707` | Unified `10 pt` for profile row, active/hover tab rows, pin tiles, suggestion rows (`neon-03:264`), frequent rows (`fable-04:172`) |
| `OrivMacV3.Radius.pageCard` | `12` | `neon-01:13,355` | `0` (flush viewport) | `BrowserWindow.swift:219,689` | Inset rounded web card & external-private handoff bar (`neon-05:184`) |
| `OrivMacV3.Radius.startAppIcon` | `12.5` | `fable-04:188` | `9.7` (`36 * 0.27`) | `Theme.swift:819` | `52 × 52 pt` start-page bookmark app icon (macOS squircle ratio) |
| `OrivMacV3.Radius.sidebar` | `14` | `neon-01:12,55` | `0` (flush `MacSidebarGlass`) | `BrowserSidebar.swift:893` | Floating glass sidebar & rail card; also suggestions popover (`neon-03:241`) |
| `OrivMacV3.Radius.startCard` | `16` | `fable-04:165,169` | `10` (`OrivRadius.tile`) | `Tile.swift:21` | Bookmark tile hover card & Frequently Visited card |
| `OrivMacV3.Radius.privateCard` | `20` | `fable-05:178` | `12` (`OrivRadius.panel`) | `StartPage.swift:39` | Private start page two-column info card |
| `OrivMacV3.Radius.bigField` | `26` (capsule) | `fable-04:157` | — | — | `52 pt` tall start-page search capsule (`Capsule()`) |
| `OrivMacV3.Radius.capsule` | `Capsule()` | `neon-01:402,451` | `Capsule()` | `Theme.swift:23` | Toolbar pill groups, address capsule, badges, engine chip |

Use `ConcentricRectangle(corners: .concentric, isUniform: true)` when nesting inner surfaces inside the `14 pt` sidebar, `14 pt` suggestions popover, or `12 pt` page card where automatic concentricity matches the ladder above (`14 - 4 = 10` for sidebar/popover rows).

### 3.2 Window Frame, Insets, and Fullscreen (`OrivMacV3.Frame`)

| Swift Token | v3 Target (pt) | Source | Current Value (pt) | Current `file:line` |
| --- | ---: | --- | ---: | --- |
| `OrivMacV3.Frame.windowInset` | `8` (all 4 edges) | `neon-01:41` (`padding: 8px`) | `0` | `BrowserWindow.swift:213–231` |
| `OrivMacV3.Frame.sidebarCardGap` | `8` | `neon-01:42` (`gap: 8px`) | `0` | `BrowserWindow.swift:221` |
| `OrivMacV3.Frame.expandedReservation` | `sidebarWidth + 16` (`272` default) | `neon-01:41–42,52` & `fable-04:54` (`left: 272px`) | `sidebarWidth` (`256`) | `SidebarPresentation.swift:31–33` |
| `OrivMacV3.Frame.railReservation` | `railWidth + 16` (`88`) | **Proposed** (`8 + 72 + 8`) | `railWidth` (`72`) | `SidebarPresentation.swift:31–33` |
| `OrivMacV3.Frame.fullscreenInset` | `8` (native fullscreen keeps floating card; webpage video fullscreen = `0`, chrome hidden) | **Proposed** | `0` (`reservation = 0` in webpage fullscreen) | `SidebarPresentation.swift:32`, `BrowserWindow.swift:216,228` |

### 3.3 Sidebar, Rail, and Traffic Lights (`OrivMacV3.SidebarLayout`)

| Swift Token | v3 Target (pt) | Source | Current Value (pt) | Current `file:line` |
| --- | ---: | --- | ---: | --- |
| `OrivMacV3.SidebarLayout.width` | `256` (range `220...360`) | `neon-01:52` | `256` (`220...360`) | `Theme.swift:70`, `BrowserWindowChrome.swift:6–7` |
| `OrivMacV3.SidebarLayout.railWidth` | `72` | Current (`OrivLayout.railWidth`) | `72` | `Theme.swift:71`, `BrowserWindowChrome.swift:8` |
| `OrivMacV3.SidebarLayout.innerPadding` | `8` horizontal, `8` bottom, `0` top | `neon-01:67` | `8` (`MacBrowserLayout.sidebarInset`) | `BrowserWindowChrome.swift:12`, `BrowserSidebar.swift:190–191` |
| `OrivMacV3.SidebarLayout.titlebarHeight` | `40` | `neon-01:72` | `46` (`headerHeight - 4`) | `BrowserWindowChrome.swift:14` |
| `OrivMacV3.SidebarLayout.lightsLeading` | `22` expanded (`8` window + `8` sidebar + `6` titlebar); `17` rail (`8 + (72-54)/2`) | `neon-01:41,67,76` + **proposed** rail math | `12` expanded; `9` rail | `BrowserWindowChrome.swift:23–25,235` |
| `OrivMacV3.SidebarLayout.lightsCenterY` | `28` from window top (`8` window inset + `20` half of `40 pt` titlebar) | `neon-01:41,72` (see Risk §6.2 Q1) | `25` (`headerHeight / 2`) | `BrowserWindowChrome.swift:239` |
| `OrivMacV3.SidebarLayout.lightsSpacing` | `20` (`12 pt` button + `8 pt` gap) | `neon-01:82,86` | `20` | `BrowserWindowChrome.swift:25` |
| `OrivMacV3.SidebarLayout.toggleSize` | `28 × 28` | `neon-01:96–97` | `30 × 30` | `BrowserWindowChrome.swift:15` |
| `OrivMacV3.SidebarLayout.profileHeight` | `34` (`margin-bottom: 6`) | `neon-01:112,118` | `32` (`padding(.vertical, 4)`) | `Theme.swift:75`, `BrowserSidebar.swift:237` |
| `OrivMacV3.SidebarLayout.profileAvatarSize` | `22 × 22` | `neon-01:121–122` | `22 × 22` | `Theme.swift:76` |
| `OrivMacV3.SidebarLayout.searchHeight` | `30` (`margin-bottom: 14`, `padding-h: 9`) | `neon-01:142,149–150` | `28` (`padding-h: 8`, `padding-b: 8`) | `Theme.swift:77`, `BrowserSidebar.swift:280` |
| `OrivMacV3.SidebarLayout.sectionHeight` | `22` (`margin-bottom: 5`, `padding-h: 8`) | `neon-01:165,169–170` | `24` (`padding-top: 4`) | `Theme.swift:78`, `BrowserSidebar.swift:480–481` |
| `OrivMacV3.SidebarLayout.pinColumns` | `4` equal flexible columns (`repeat(4, 1fr)` → `55.5 pt` @ `256 pt` sidebar) | `neon-01:188` (see Open Q3) | `4...6` fixed `44 pt` | `Theme.swift:79`, `BrowserSidebar.swift:64–65` |
| `OrivMacV3.SidebarLayout.pinHeight` | `40` (`gap: 6`, `margin-bottom: 16`) | `neon-01:189–193` | `36` (`gap: 6`) | `Theme.swift:80–81` |
| `OrivMacV3.SidebarLayout.pinIconSize` | `18` (`20` max for monochrome marks) | `neon-01:614,630` | `20` | `Theme.swift:82` |
| `OrivMacV3.SidebarLayout.tabRowHeight` | `34` (`gap: 2`, `padding-h: 8`, inner `gap: 9`) | `neon-01:207,210,212,215` | `32` (`gap: 2`, `padding-h: 8`, inner `gap: 8`) | `Theme.swift:74`, `BrowserSidebar.swift:644,681` |
| `OrivMacV3.SidebarLayout.tabFaviconSize` | `18` | `neon-01:235–236` | `19` | `Theme.swift:91` |
| `OrivMacV3.SidebarLayout.accessoryVisual` | `20 × 20` visual (`24 × 24` hit target retained for a11y, **proposed**) | `neon-01:252–253` + `Theme.swift:142` | `24 × 24` (`2` permanently reserved slots) | `Theme.swift:89,142`, `BrowserSidebar.swift:671–678` |
| `OrivMacV3.SidebarLayout.newTabHeight` | `34` (`margin-top: 6`, directly below last tab row) | `neon-01:279–280` | `36` (pinned above footer) | `BrowserSidebar.swift:173,298` |
| `OrivMacV3.SidebarLayout.profileDotSize` | `7 × 7` (`gap: 10`, vertical padding `6` top / `8` bottom; `24 × 24` hit target) | `neon-01:307–312` | `8 × 8` (`OrivSpacing.small`), `24 × 24` target | `BrowserSidebar.swift:319,326` |
| `OrivMacV3.SidebarLayout.footerHeight` | `40` (`padding-top: 6`, `gap: 4`, buttons `32 × 32`, download dot `6 × 6`) | `neon-01:324–332,344–345` | `36` (`buttons: 32 × 32`, download dot `6 × 6`) | `Theme.swift:87–88`, `BrowserSidebar.swift:351,384–389` |
| `OrivMacV3.SidebarLayout.railItemSize` | `42 × 36` (`railFaviconSize: 22`) | Current (`OrivTarget.macRail`) | `42 × 36` (`22`) | `Theme.swift:92,144`, `BrowserWindowChrome.swift:19–20` |

### 3.4 Toolbar, Address Capsule, Suggestions, and Handoff Bar (`OrivMacV3.ToolbarLayout`)

| Swift Token | v3 Target (pt) | Source | Current Value (pt) | Current `file:line` |
| --- | ---: | --- | ---: | --- |
| `OrivMacV3.ToolbarLayout.overlayHeight` | `60` (`innerHeight: 36`, `padding-h: 14`) | `neon-01:371,375,392` | `50` (`padding-h: 12`) | `Theme.swift:72`, `BrowserWindow.swift:439` |
| `OrivMacV3.ToolbarLayout.groupHeight` | `34` (`padding: 3`, `gap: 2`) | `neon-01:401,403,406` | `32` (ungrouped `HStack`) | `BrowserWindow.swift:458,626` |
| `OrivMacV3.ToolbarLayout.buttonSize` | `28 × 28` (circle inside capsule; Browser Actions also `28 × 28` inside trailing pill) | `neon-01:417–419` | `28 × 28` (Browser Actions `36 × 32`) | `Theme.swift:143`, `BrowserWindowChrome.swift:10` |
| `OrivMacV3.ToolbarLayout.dividerSize` | `0.5 × 14` (`margin-h: 1`) | `neon-01:438–441` | — | — |
| `OrivMacV3.ToolbarLayout.shieldDotSize` | `5 × 5` (`top: 5, right: 5`) | `neon-01:429–432` | — | — |
| `OrivMacV3.ToolbarLayout.addressRestWidth` | `520` ideal (`min: 230`, clamped to available viewport width) | `neon-01:449` + `BrowserWindow.swift:61` | `640` max (`min: 230`) | `Theme.swift:97`, `BrowserWindow.swift:59–62,500` |
| `OrivMacV3.ToolbarLayout.addressRestHeight` | `34` (`padding-h: 5`, inline icon `24 × 24`, side slot `48`) | `neon-01:450,452,466,472–473` | `32` (`padding-h: 4`, inline icon `24 × 24`) | `Theme.swift:73,142`, `BrowserWindow.swift:498–499` |
| `OrivMacV3.ToolbarLayout.addressFocusWidth` | `576` ideal (clamped to viewport minus groups) | `neon-03:171` | unchanged on focus (`640` max) | `BrowserWindow.swift:500` |
| `OrivMacV3.ToolbarLayout.addressFocusHeight` | `36` (`padding: 0 6 0 10`, `gap: 8`) | `neon-03:172,174,177` | `32` | `BrowserWindow.swift:499` |
| `OrivMacV3.ToolbarLayout.privatePillHeight` | `24` (`padding-h: 9`, `gap: 5`) | `neon-05:162,164,172` | `24` (`padding-h: 8`) | `BrowserWindow.swift:524–525` |
| `OrivMacV3.ToolbarLayout.progressHeight` | `2` (inset `16 pt` from capsule ends, bottom edge inside capsule clip) | `neon-02:350–353` | `2` (full page width above web content) | `BrowserWindow.swift:725–727` |
| `OrivMacV3.ToolbarLayout.suggestionsWidth` | Matches focused capsule (`576` ideal) | `neon-03:239` | Matches capsule width | `BrowserWindow.swift:306` |
| `OrivMacV3.ToolbarLayout.suggestionsTopGap` | `7` below focused capsule (`top: 56` from card top; focused capsule bottom `= 49`) | `neon-03:141,172,235` | `2` (`OrivSpacing.xxs`) | `BrowserWindow.swift:310` |
| `OrivMacV3.ToolbarLayout.suggestionsPadding` | `8` (`groupLabel padding: 6 10 4`) | `neon-03:242,259` | `8` (`OrivSpacing.small`) | `BrowserWindow.swift:881` |
| `OrivMacV3.ToolbarLayout.suggestionRowHeight` | `46` (`padding-h: 10`, `gap: 11`, icon `24 × 24`); search row `38` | `neon-03:263,265,268,275,342` | `38` (search row `32`, icon `20`) | `Theme.swift:95`, `AddressSuggestions.swift:61`, `BrowserWindow.swift:869,878` |
| `OrivMacV3.ToolbarLayout.handoffHeight` | `44` (`top: 66` from card top, `inset-h: 24`, `padding: 0 10 0 14`, `gap: 12`; controls height `26`) | `neon-05:180–188,197,202` | variable (~52–88, multi-line wrap) | `ExternalPrivateBar.swift:24–27,133` |

### 3.5 Start Page Geometry — Mac-Only (`OrivMacV3.StartLayout`)

| Swift Token | v3 Target (pt) | Source | Current Value (pt) | Current `file:line` |
| --- | ---: | --- | ---: | --- |
| `OrivMacV3.StartLayout.columnWidth` | `724` (responsive clamp to viewport width − `48 pt`) | `fable-04:157,162,164,169` | `640` (`OrivLayout.contentMaxWidth`) | `Theme.swift:97`, `StartPage.swift:22` |
| `OrivMacV3.StartLayout.headerTopMargin` | `150` (scales down proportionally on short windows `< 760 pt` height, **proposed**) | `fable-04:155` | `56` (`xxl + xl`) | `StartPage.swift:23` |
| `OrivMacV3.StartLayout.profileChipAvatar` | `18 × 18` circle (`gap: 8`) | `fable-04:155,183` | — | — |
| `OrivMacV3.StartLayout.titleTopGap` | `8` below profile/date line | `fable-04:156` | — | — |
| `OrivMacV3.StartLayout.bigFieldSize` | `724 × 52` (`margin-top: 26`, `padding: 0 10 0 18`, `gap: 12`) | `fable-04:157` | — (toolbar only) | `StartPage.swift:3` |
| `OrivMacV3.StartLayout.engineChipHeight` | `32` (`padding-h: 12`, `gap: 6`, icon `12`) | `fable-04:161,186` | — | — |
| `OrivMacV3.StartLayout.sectionTopGap` | `44` (`contentTopGap: 10`) | `fable-04:162,164,169` | `24` (`OrivSpacing.xl`) | `StartPageSites.swift:46` |
| `OrivMacV3.StartLayout.bookmarkColumns` | `8` (`gap: 8`, up to 8 bookmarks in one row; responsive `4 × 2` when card width `< 772 pt`, **proposed**) | `fable-04:164` + proposed responsive rule | `4` columns (`4 × 2`, `gap: 8`) | `StartPageSites.swift:29,38` |
| `OrivMacV3.StartLayout.bookmarkIconSize` | `52 × 52` (`tile padding: 12 4 10`, `gap: 8`) | `fable-04:165,188` | `36 × 36` (`minHeight: 84`) | `StartPageSites.swift:74,84` |
| `OrivMacV3.StartLayout.frequentCardPadding` | `6` (`2` columns; `1` column below `600 pt`, **proposed**) | `fable-04:169` | `4`-column tile grid | `StartPageSites.swift:29,54` |
| `OrivMacV3.StartLayout.frequentRowHeight` | `40` (`padding-h: 10`, `gap: 10`, favicon `20 × 20` r `4.8`) | `fable-04:172,190` | `84` min tile height | `StartPageSites.swift:84` |
| `OrivMacV3.StartLayout.privateCardTopGap` | `40` (`width: 724`, `padding: 22 26`, `2` columns, `rowGap: 10`, `colGap: 34`, item `margin-top: 8`, icon `16`) | `fable-05:178,181,196` | `56` top padding, single-column banner | `StartPage.swift:23,29–41` |
| `OrivMacV3.StartLayout.footerBottomInset` | `22` (`gap: 22`, keycap `padding: 1 5`, `margin-right: 5`) | `fable-04:175–176` | — | — |

---

## 4. Typography and Motion

### 4.1 Typography (`OrivMacV3.Type`)

System sans-serif (`SF Pro Text` / `SF Pro Display`) throughout chrome and start page.

| Swift Token | Size (pt) | Weight | Line Height / Tracking / Digits | Source | Current Token (`Theme.swift`) |
| --- | ---: | --- | --- | --- | --- |
| `OrivMacV3.Type.startHeroTitle` | `30` | Bold (`700`) | `36 pt` line height, tracking `-0.5` | `fable-04:156` | New |
| `OrivMacV3.Type.startBigField` | `16` | Regular (`400`) | single line | `fable-04:157` | New |
| `OrivMacV3.Type.addressFocused` | `13.5` | Regular / Medium (`500` typed) | tracking `-0.005 em` | `neon-03:190–194` | `OrivLayout.macAddressFontSize` (`13`, `Theme.swift:69`) |
| `OrivMacV3.Type.addressRest` | `13` | Medium (`500`) | tracking `-0.005 em` | `neon-01:481–484` | `OrivType.bodyEmphasized` (`Theme.swift:45`) |
| `OrivMacV3.Type.sidebarProfile` | `13` | Semibold (`600`) | tracking `-0.01 em` | `neon-01:132–134` | `OrivType.headline` (`Theme.swift:44`) |
| `OrivMacV3.Type.sidebarRowActive` | `13` | Semibold (`600`) | tracking `-0.005 em` | `neon-01:216,223–224` | `OrivType.headline` (`Theme.swift:44`) |
| `OrivMacV3.Type.sidebarRow` | `13` | Regular (`400`) | — | `neon-01:216` | `OrivType.body` (`Theme.swift:39`) |
| `OrivMacV3.Type.sidebarNewTab` | `13` | Medium (`500`) | — | `neon-01:286–287` | `OrivType.bodyEmphasized` (`Theme.swift:45`) |
| `OrivMacV3.Type.startSectionHeader` | `13` | Semibold (`600`) | — | `fable-04:162` | `OrivType.headline` (`Theme.swift:44`) |
| `OrivMacV3.Type.startBody` | `13` | Regular (`400`) | `18 pt` line height (Private card items) | `fable-05:181` | `OrivType.body` (`Theme.swift:39`) |
| `OrivMacV3.Type.handoffMessage` | `12.5` | Regular (`400`) / Semibold (`600` app name) | — | `neon-05:195,348` | `OrivType.detail` (`12`, `Theme.swift:40`) |
| `OrivMacV3.Type.detail` | `12` | Regular (`400`) | Sidebar search, engine chip, handoff controls, start Show All, private card subtext | `neon-01:152`, `neon-05:199,205`, `fable-04:161,163`, `fable-05:183` | `OrivType.detail` (`Theme.swift:40`) |
| `OrivMacV3.Type.suggestionURL` | `11.5` | Regular (`400`) / Bold match | Also bookmark tile label (`11.5 / 14`) & frequent host (`11.5`) | `neon-03:302`, `fable-04:165,174` | `OrivType.caption` (`11`, `Theme.swift:41`) |
| `OrivMacV3.Type.sectionLabel` | `11` | Semibold (`600`) | tracking `+0.02 em`; also private pill, private card column heading, suggestion group label | `neon-01:173–176`, `neon-03:255`, `neon-05:168`, `fable-05:180` | `OrivType.sectionLabel` (`Theme.swift:46`) |
| `OrivMacV3.Type.sectionCount` | `11` | Medium (`500`) | `monospacedDigit()` (`tabular-nums`) | `neon-01:179–182` | `OrivType.caption` (`Theme.swift:41`) |
| `OrivMacV3.Type.shortcutHint` | `10.5` | Medium (`500`) | `monospacedDigit()`, tracking `+0.02 em` (sidebar `⇧⌘A`/`⌘T`, Tab chip, Already open pill; start footer `11 pt`) | `neon-01:156–160`, `neon-03:213,311`, `fable-04:175` | `OrivType.badge` (`10`, `Theme.swift:47`) |

### 4.2 Motion (`OrivMacV3.Motion`)

All animations check `environment.browserReduceMotion` (`Apps/macOS/Views/BrowserSidebar.swift:780–786`), which mirrors `accessibilityReduceMotion` and supports snapshot overrides. `BrowserAppearanceModifier` (`Theme.swift:705–707`) already disables SwiftUI transactions globally when `reduceMotion == true`.

| Swift Token | Standard Animation | Reduce Motion Fallback | Use | Source |
| --- | --- | --- | --- | --- |
| `OrivMacV3.Motion.quick` | `.easeOut(duration: 0.10)` | `nil` (instant) | Hover fills, button press, close/audio reveal, peek label fade | `neon-01:103`, `Theme.swift:110` |
| `OrivMacV3.Motion.standard` | `.easeInOut(duration: 0.20)` | `.easeInOut(duration: 0.15)` opacity crossfade (or `nil` for geometry) | Sidebar expand/collapse (`⌥⌘S`), scroll-edge settle, dimming scrim | `Theme.swift:111,113` |
| `OrivMacV3.Motion.addressFocus` | `.spring(response: 0.24, dampingFraction: 0.88)` (**proposed**) | `nil` (instant frame & border swap) | Address capsule expand (`520 × 34` → `576 × 36`) + focus halo + suggestions popover appear | **Proposed** |
| `OrivMacV3.Motion.addressMorph` | `.spring(response: 0.34, dampingFraction: 0.90)` with `.glassEffectTransition(.matchedGeometry)` (**proposed**) | `.easeInOut(duration: 0.15)` fade without translation | Single `AddressField` overlay moving between start-page slot (`724 × 52`) and toolbar slot (`520 × 34`) on navigation / new tab | **Proposed** (reconciliation rule §1.2) |
| `OrivMacV3.Motion.popover` | `.spring(response: 0.22, dampingFraction: 0.92)` + opacity (**proposed**) | `.easeInOut(duration: 0.12)` opacity only | Suggestions dropdown & external-private handoff bar appear/dismiss | **Proposed** |
| `OrivMacV3.Motion.progressShimmer` | Linear progress width interpolation `0.18 s` easeOut + subtle leading shimmer (**proposed**) | Width update only (no shimmer) | Loading progress bar tucked along bottom of address capsule | `neon-02:348–357` + proposed |
| `OrivMacV3.Motion.tabLoading` | Continuous `0.9 s` linear rotation of `270°` `16 pt` ring (**proposed**) | Static `270°` arc (no spin) | Loading tab indicator replacing favicon in sidebar | `neon-01:268–275,669–672` + proposed |

---

## 5. Per-Phase Acceptance Criteria

### Phase 1 — Tokens, Materials, and Static Gates

**Scope:** Add `#if os(macOS) enum OrivMacV3` to `Apps/Shared/Theme.swift`; update `scripts/check-contrast.py` to verify all new v3 Light, Dark, Black, Private, RT, and IC token pairs; keep `scripts/check-design-tokens.py` passing without increasing raw-literal baselines; zero iPhone changes.

**Acceptance criteria:**
1. **iPhone invariance:** `git diff` touches no iOS-compiled values in `Apps/Shared/Theme.swift`, `Apps/Shared/StartPageSites.swift`, or `Apps/iOS/`; `scripts/check-iphone.sh` (or iOS build/tests) passes unchanged.
2. **Token completeness:** Every Swift token in §2, §3, and §4 exists under `#if os(macOS) enum OrivMacV3` in `Apps/Shared/Theme.swift`, with no raw color/shadow/motion literals leaked into views.
3. **Contrast gate (`scripts/check-contrast.py`):**
   - Primary text ≥ `4.5:1` (≥ `7.0:1` on Settings cards), secondary text ≥ `4.5:1`, tertiary text on card and sidebar ≥ `4.5:1`, active tab ink ≥ `4.5:1` across all 13 `SidebarColor` tints + Private Amethyst Dusk + Black in `Balanced`, `High`, `Solid`, Reduce Transparency, and Increase Contrast.
   - Focus rings (`sidebarRing`, `addressRing`), Increase Contrast borders (`1.5–2 pt`), and favicon cushions ≥ `3.0:1`.
   - All existing negative tests (`--negative-test`, `--negative-sidebar-test`, `--negative-sidebar-tint-test`, `--negative-sidebar-focus-test`, `--negative-sidebar-active-test`, `--negative-sidebar-plate-test`, `--negative-settings-test`) still fail on injected regressions.
4. **Token & policy gates:** `scripts/check-design-tokens.py` and `scripts/check-background-ui.py` exit `0`.

### Phase 2 — Window Frame (Backdrop, Floating Sidebar & Rail, Page Card, Traffic Lights, Fullscreen)

**Scope:** Replace flush split chrome in `BrowserWindow.swift`, `BrowserWindowChrome.swift`, `BrowserSidebar.swift`, and `SidebarPresentation.swift` with the Neon floating frame.

**Visually checkable criteria against mocks:**

| Check | Reference Mock | Capture Scene (`capture-mac-visuals.sh`) | Expected Visual Result |
| --- | --- | --- | --- |
| Window backdrop | `neon-01-main-window-light.jpg`, `neon-02-main-window-dark.jpg` | `mac-glass-light`, `mac-glass-dark`, `mac-glass-reduced` | Soft tinted ambient backdrop visible in the `8 pt` outer margin and the `8 pt` vertical gap between sidebar and page card; solid `#E7EBF3` / `#151822` / `#000000` in RT/IC/Black. |
| Floating sidebar & rail | `neon-01-main-window-light.jpg` | `mac-glass-light`, `mac-04-compact-sidebar`, `ORIV_GLASS_SCENE=sidebar` | Sidebar and `72 pt` rail are inset `8 pt` from top/leading/bottom with `14 pt` continuous corners, `0.5 pt` rim, and soft elevation shadow; no edge-to-edge flush strip. |
| Inset page card | `neon-01-main-window-light.jpg`, `neon-02-main-window-dark.jpg` | `mac-glass-light`, `mac-glass-dark`, `mac-06-loaded-https` | Web content and toolbar sit inside one rounded card (`12 pt` corners, `8 pt` inset from top/trailing/bottom, `8 pt` gap from sidebar), clipped cleanly to `12 pt` corners with `0.5 pt` hairline rim (`1.5 pt` strong rim in IC). |
| Traffic lights & toggle | `neon-01-main-window-light.jpg` | `mac-glass-light`, `mac-04-compact-sidebar`, `ORIV_GLASS_SCENE=sidebar` (`fullscreen`, `fullscreen-collapsed`) | Traffic lights sit inside the floating sidebar's `40 pt` top bar (`22 pt` from window leading edge expanded; centered inside the `72 pt` floating rail collapsed), never overlapping the rounded sidebar corner or the collapse toggle; RTL mirrors cleanly (`ORIV_GLASS_SCENE=p3-rtl`). |
| Fullscreen & webpage fullscreen | — | `ORIV_GLASS_SCENE=sidebar` (`fullscreen`, `fullscreen-collapsed`) | Native fullscreen hides traffic lights without relayout jitter on menu reveal; HTML5 video fullscreen hides sidebar and toolbar (`reservation = 0`) and expands video edge-to-edge (`0 pt` inset). |
| Resize & narrow overlay | — | `ORIV_GLASS_SCENE=sidebar` (`minimum`, `covered`) | Sidebar drag grip (`220...360 pt`, double-click resets to `256 pt`) tracks smoothly in the `8 pt` gap; narrow window (`< 796 pt`) auto-collapses to floating rail; explicit expand overlays the page card with floating shadow. |

### Phase 3 — Glass Toolbar (Scroll Edge, `GlassEffectContainer` Groups, Glass Address Capsule, Semantic Cues, Progress)

**Scope:** Replace opaque `mainTopBar` in `BrowserWindow.swift` and `ToolbarButton.swift` with floating Liquid Glass capsules over `.scrollEdgeEffectStyle(.soft, for: .top)`, wire `ConnectionCue.color(_:)`, and move loading progress inside the address capsule.

**Visually checkable criteria against mocks:**

| Check | Reference Mock | Capture Scene (`capture-mac-visuals.sh`) | Expected Visual Result |
| --- | --- | --- | --- |
| Transparent scroll-edge toolbar | `neon-01-main-window-light.jpg`, `neon-02-main-window-dark.jpg` | `mac-glass-light`, `mac-glass-light-scrolled`, `mac-glass-dark`, `mac-glass-dark-scrolled` | No solid colored header strip cuts across the top of the page card; scrolled article artwork and headings pass visibly beneath the `60 pt` toolbar zone with a soft top blur/fade (`.scrollEdgeEffectStyle(.soft, for: .top)`). `webView.obscuredContentInsets.top` matches the floating toolbar inset so page top headers at `scrollY = 0` are not clipped. |
| Grouped glass capsules | `neon-01-main-window-light.jpg`, `neon-02-main-window-dark.jpg` | `mac-glass-light`, `mac-glass-dark`, `mac-glass-menu` | Leading Back/Forward (`34 pt` tall pill, `28 × 28` targets, `0.5 × 14 pt` divider, `30%` disabled opacity) and trailing Site Privacy (with `5 pt` active green dot) / Share / Browser Actions sit in two `GlassEffectContainer` pills (`14 pt` from card edges). |
| Glass address capsule | `neon-01-main-window-light.jpg`, `neon-02-main-window-dark.jpg` | `mac-glass-light`, `mac-glass-dark`, `mac-06-loaded-https` | Centered `520 × 34 pt` (`min: 230 pt`) glass capsule with `24 × 24` leading connection icon, centered `13 pt` medium host, and `24 × 24` trailing reload/stop (plus zoom pill when `!= 100%`). |
| Semantic connection cues | — (code contract `ConnectionCue.swift:42–48`) | `mac-glass-insecure`, `mac-07-loaded-http` | HTTP pages render `"Not secure"` shield + label in `theme.warning` (`#794900` Light / `#E0AA55` Dark); camera/microphone capture renders `record.circle.fill` in `theme.danger` (`#B3261E` / `#FF9A8F`). |
| Integrated progress bar | `neon-02-main-window-dark.jpg` | `mac-glass-dark` (loading state) / unit test | `2 pt` rounded accent gradient bar renders tucked along the inside bottom edge of the address capsule (`16 pt` horizontal inset); the old full-width page-top progress bar (`BrowserWindow.swift:722–730`) is removed. |
| Accessibility & Black fallbacks | — | `mac-glass-reduced`, `ORIV_GLASS_SCENE=design-system` | Reduce Transparency, Increase Contrast, and Black render opaque toolbar pills, opaque address capsule, `1.5 pt` IC borders, and solid top scroll-edge backing with zero legibility loss. |

### Phases 4–9 — Summary Acceptance Criteria

- **Phase 4 (Sidebar Refinement):** Matches `neon-01` / `neon-02` sidebar: profile row (`34 pt`, `22 × 22 r7` tinted avatar, no redundant tab count), `30 pt` recessed search pill (`r9`), `4`-column `40 pt` pinned glass tiles (`r10`), `"Tabs N"` section header, `34 pt` rows (`r10`, `18 pt` favicons, contrast-guarded monochrome marks with no white disc on dark), conditional close/audio accessories (zero wasted trailing slot on quiet rows), inline `+ New Tab ⌘T` directly under the last tab, `7 pt` profile dots with active halo above `40 pt` footer with `6 pt` download dot. Verified in `mac-glass-light`, `mac-glass-dark`, `ORIV_GLASS_SCENE=sidebar-v3`, `sidebar-pins`, `sidebar-chromatic`.
- **Phase 5 (Address Focus & Grouped Glass Suggestions):** Matches `neon-03-address-bar-focused.jpg`: focused capsule expands to `576 × 36 pt` with elevated `94%` backing, `1.5 pt` accent border + `3.5 pt` concentric halo, leading accent search icon, inline completion highlight + `Tab` chip + clear button; page dims with subtle scrim (`8%` Light / `24%` Dark); `576 pt` floating glass popover (`r14`) `7 pt` below capsule with `Switch to Tab` / `Bookmarks` / `History` groups, `46 pt` rows, tinted full-row selection pill + `↵` chip (no 3 pt leading bar), `"Already open"` blue pill, `38 pt` explicit Search row with engine chip. Verified in `mac-glass-focused`, `mac-08-suggestions-keyboard`, `mac-09-suggestions-similar`.
- **Phase 6 (Mac Start Page — Fable Layout + Single `AddressField` Overlay):** Matches `fable-04-start-page.jpg` inside the Neon frame: transparent rim-only page card showing soft profile-tinted backdrop gradient; toolbar hides address capsule and shows only Back/Forward + Shield/Actions pills; single persistent `AddressField` overlay renders in the `724 × 52 pt` in-page capsule (`16 pt` font, search icon, engine chip) and never re-creates `NSTextField`; profile chip + formatted date + `"Where to?"` (`30 pt` bold); up to 8 bookmarks in one `8`-column row of `52 × 52 pt` (`r12.5`) app icons; `2`-column Frequently Visited card (`r16`, `40 pt` rows); bottom shortcut hints footer; real empty state (`mac-02-start-empty`); `homeBookmarks` and `homeFrequent` geometry markers preserved; iPhone start page untouched. Verified in `mac-01-start`, `mac-02-start-empty`.
- **Phase 7 (Private Browsing — Amethyst Dusk + Fable Private Start Page):** Matches `neon-05-private-mode.jpg` chrome + `fable-05-private-window.jpg` start content: full-window Amethyst Dusk backdrop, purple glass sidebar (`"Private"` header, `"Private N"` section, purple active pill), purple toolbar groups & address capsule (`Private` glasses pill), single-line `44 pt` glass external-private handoff bar (`Opened privately from <App>`, profile picker, purple `Move to <Profile>`, `Keep Private ×`), and Fable's `724 pt` private start page (`Private window`, `"Private Browsing"`, `724 × 52 pt` private field, two-column `"Not kept after you close these tabs"` / `"Still visible or kept"` card, shortcut hints). Verified in `mac-03-private-start`, `mac-12-external-private`, `mac-13-external-moved-to-personal`, `mac-glass-private`.
- **Phase 8 (Motion & Reduce Motion):** Smooth `.glassEffectTransition(.matchedGeometry)` between start-page big field and toolbar capsule, spring address focus expansion, sidebar expand/collapse, smooth tab loading ring & progress shimmer; under `accessibilityReduceMotion` / `browserReduceMotion`, all springs/shimmers/spins drop cleanly to instant state changes or short opacity fades (`≤ 0.15 s`).
- **Phase 9 (Remaining Screens & Live Verification):** Audit Settings (`mac-11-settings-*`), Library (`mac-10-library-*`), popovers (Site Info, Site Privacy, Passwords), Find Bar, HTTP warning, and `PageErrorState` for visual harmony; verify RTL (`p3-rtl`), VoiceOver, Full Keyboard Access, Reduce Transparency, Increase Contrast, and foreground/device live WindowServer Liquid Glass compositing (since `ORIV_BACKGROUND_UI=1` captures opaque fallbacks only).

---

## 6. Risks and Open Questions

### 6.1 Codebase Risks Discovered During Audit

1. **Strict source-text assertions in `scripts/check-contrast.py`:**
   - Lines `66–90` assert exact Swift substrings across `BrowserSidebar.swift`, `NativeSidebarTabs.swift`, `SidebarSearchPanel.swift`, `OrivSearchField.swift`, and `BrowserChrome.swift`.
   - Lines `100–127` regex-parse `Theme.SidebarChromaticTokens` and `SidebarChromaticStyle` constants (requiring `balancedBacking.light == balancedBacking.dark` and exact 13 tint names × Light/Dark + `black`).
   - Lines `292–305` assert `"pageChrome.color\n" in mac`, `"Rectangle().fill(.clear).glassEffect(.regular, in: .rect)" in sidebar_source`, and parse `MacAddressPalette`'s `lift`, `lightShade`, `focusedMix`, `placeholderOpacity`, and `focusOpacity` from `BrowserWindow.swift`.
   - **Mitigation:** Update `check-contrast.py` in lockstep during Phases 1, 2, and 3—keeping equal or stricter WCAG coverage for the new `OrivMacV3` tokens rather than relaxing assertions.

2. **Per-file raw-token baseline in `scripts/check-design-tokens.py` (`scripts/design-token-baseline.json`):**
   - Only `Theme.swift` (and 5 test/bench files) are exempt (`check-design-tokens.py:12–13`). All view files (`BrowserWindow.swift`, `BrowserSidebar.swift`, `StartPage.swift`, `NativeSidebarTabs.swift`, `ToolbarButton.swift`, etc.) fail CI if they exceed their per-file counts for `raw color`, `shadow`, `motion`, `focus state`, `font size`, `radius`, `padding`, or `spacing`.
   - Note that `// oriv:raw-metric <reason>` only exempts layout metrics (`font size`, `font style`, `radius`, `padding`, `spacing`)—it does **not** exempt `raw color`, `shadow`, or `motion` (`check-design-tokens.py:46`). Also note `"colour"`/`"colours"` in string literals trips `retired copy`.
   - **Mitigation:** Define every v3 color, gradient, shadow, and animation inside `Theme.swift` (`OrivMacV3`).

3. **Existing Mac unit tests assert flush-sidebar & v2 geometry (`Tests/BrowserMacTests/`):**
   - `SidebarLayoutTests.swift:107–119, 241–250`: asserts `sidebarSurfaceGeometry.minX == 0`, `minY == 0`, `height == content.bounds.height`, `browserTopBarGeometry.minX == sidebar.reservation`, `maxX == content.maxX`, `maxY == content.maxY`, `sidebar.maxX == toolbar.minX`.
   - `SidebarLayoutTests.swift:264–267, 295, 312–315`: asserts `sidebarNewTabGeometry` sits `sidebarFooterGap` above footer, `sidebarTitlebarGeometry.height == 46`, `sidebarToggleGeometry.midY == 25`.
   - `SidebarLayoutTests.swift:346, 351–353`: asserts `sidebarProfileCountGeometry` exists inside `sidebarProfileGeometry` (Neon removes the redundant profile tab count).
   - `SidebarLayoutTests.swift:136–142` & `SidebarBehaviorTests.swift:286–318`: asserts `PinGrid` tile width == `44 pt`, height == `36 pt`, 4–6 columns.
   - `SidebarGlassTests.swift:240` & `SidebarLayoutTests.swift:172–189`: asserts `sidebarClose-<id>` marker count and hit-test geometry.
   - `ChromeFocusTests.swift:1257–1280`: asserts `browserAddressGeometry.height == 32`, `2 pt` gap to suggestions, and **unchanged** `browserAddressGeometry` frame before vs. after focus (v3 expands on focus).
   - `ChromeFocusTests.swift:1322–1338` & `SidebarLayoutTests.swift:547–591, 619–677`: asserts traffic-light `minX`/`midY` and `webView.obscuredContentInsets.top == headerHeight`.
   - `SidebarLayoutTests.swift:437–445`: asserts `homeBookmarks` and `homeFrequent` markers exist on regular start page and vanish on private start page / after `clearHistory()`.
   - **Mitigation:** Preserve all marker names (`browserSidebarGeometry`, `sidebarSurfaceGeometry`, `browserTopBarGeometry`, `browserAddressGeometry`, `browserAddressSuggestionsGeometry`, `homeBookmarks`, `homeFrequent`, `sidebarItem-<id>`, `sidebarSelection-<id>`, etc.) and update each phase's corresponding test assertions in the same PR.

4. **`WebViewHost.layout()` obscured-inset check (`Apps/macOS/Views/WebPageView.swift:127–143`):**
   - Currently checks `abs(rect.maxY - (window.frame.height - headerInset)) < 1` to decide whether to extend the `WKWebView` frame upward under a flush top bar.
   - In v3, the page card is inset `8 pt` from the window top and the toolbar floats **inside** the top of the clipped `12 pt` rounded card. `WebViewHost` will already fill the full card height (`rect.maxY == window.frame.height - 8`), so `WebViewHost` should set `webView.obscuredContentInsets.top = headerInset` directly without extending `webView.frame` above the card's `12 pt` rounded clip.

5. **Single `AddressField` overlay + dynamic font size + popover anchoring (`AddressField.swift`, `BrowserWindow.swift:301–313`):**
   - `AddressField.font` (`AddressField.swift:29`) is currently a static `13 pt` constant. Supporting Fable's `16 pt` big start-page field and `13/13.5 pt` toolbar field requires a dynamic `fontSize` input updated inside `updateNSView` (updating `field.font` and any active `currentEditor()?.font` without recreating the `NSTextField`).
   - `MacAddressBounds` must report the overlay's actual rendered capsule frame so `AddressSuggestionList` anchors cleanly below both the `724 × 52` start-page field and the `576 × 36` toolbar field.
   - Because `BrowserWindow.swift:474–477` handles Return-to-choose-suggestion and `BrowserPopover` (`BrowserWindow.swift:887–1025`) saves/restores `window.firstResponder`, moving `AddressField` into the overlay must keep `SiteInformationView` anchored to the leading icon inside the toolbar capsule.

6. **8 pt floating inset math in sidebar drag, resize, hover-peek, and profile swipe:**
   - `MacBrowserWindowContext.sidebarContainsFocus` (`BrowserWindowChrome.swift:66–67`) checks `leading + rect.width <= sidebarWidth + 1` — must add `windowInset` (`8 pt`).
   - `SidebarWindowEvents` outside-click dismissal (`SidebarPresentation.swift:232`: `if leading > controller.sidebar.width`) must add `windowInset` (`8 pt`).
   - `SidebarResizeGrip` (`BrowserWindowChrome.swift:322–377`) must straddle the `8 pt` gap on the trailing edge of the floating sidebar card.
   - `NativeSidebarTabs.accessory(at:includesClose:)` (`NativeSidebarTabs.swift:1888–1904`) hard-codes two permanently reserved `24 pt` slots (`insetTrailing < slot` for close, `insetTrailing < 2 * slot` for audio). Removing the unused empty audio slot in Phase 4 requires matching hit-test logic to the actually visible trailing accessories (`close` only, `audio` only, or `audio + close`).
   - `ProfileSidebarAnchor` / `ProfileSidebarSwitch` (`ProfileSidebarSwitch.swift:20–80`) snapshots the sidebar body for swipe gestures; verify its clipping matches the `14 pt` floating card.

7. **Background UI policy (`scripts/check-background-ui.py` & `Apps/macOS/BackgroundUIMode.swift`):**
   - No new `NSWindow`/`NSPanel` allocations or window-raising calls may be introduced for v3 popovers, backdrops, or suggestion sheets; keep everything inside the existing browser window (and `BrowserPopover` on `NSPopover`).
   - Off-screen snapshot captures (`ORIV_BACKGROUND_UI=1`) render the opaque fallback rather than live WindowServer `.glassEffect(...)`, so every visual phase requires a final live foreground/device sanity pass.

### 6.2 Open Questions Requiring Orchestrator Decision

1. **Q1 — Traffic lights vs. toolbar centerline:** In `neon-01-main-window-light.html`, `.sidebar-titlebar` is `40 pt` (`traffic-light midY = 28 pt` from window top) while `.toolbar-overlay` is `60 pt` (`toolbar pill midY = 38 pt` from window top)—a `10 pt` vertical offset. Current Oriv aligns both on the exact same centerline (`25 pt`). Keep Neon's exact `40 pt` / `60 pt` heights (`28 pt` vs `38 pt`), or tighten `.toolbar-overlay` to `50–52 pt` and `.sidebar-titlebar` to `44–48 pt` so the traffic lights and toolbar pills share one horizontal axis?
2. **Q2 — Rail width with 8 pt floating inset:** Confirm `railWidth` stays `72 pt` (giving `8 + 72 + 8 = 88 pt` leading reservation for the page card and `17 pt` traffic-light leading inset), or narrow `railWidth` to `64 pt` to keep total rail reservation near the current `72 pt`.
3. **Q3 — Pinned tile grid at wider sidebar widths (`220...360 pt`):** Lock pinned tiles to `4` equal flexible columns across `220...360 pt` (matching Neon's `repeat(4, 1fr)`), or keep adaptive `4...6` columns (`BrowserSidebar.swift:64`) while raising tile height from `36 pt` to `40 pt`?
4. **Q4 — `New Tab` behavior when the tab list overflows:** When open tabs exceed the sidebar's visible height, should `+ New Tab ⌘T` scroll with the bottom of the tab list, or stick just above the profile dots / footer once the list overflows so it stays always reachable?
5. **Q5 — Private tab inside a regular profile window:** When a user opens a private tab inside a regular profile window (mixed session), should the whole window switch to Amethyst Dusk while that private tab is selected, or reserve full Amethyst Dusk for standalone/external Private windows while mixed-session private tabs keep the profile sidebar tint + purple pill + Fable private start page?
6. **Q6 — Scrolled-page toolbar ink polarity:** On live Liquid Glass over a scrolled web page, should toolbar controls rely on system Liquid Glass automatic legibility (using `PageChrome` only for Reduce Transparency / Increase Contrast / Black fallbacks), or should `PageChrome` continue driving explicit light/dark foreground overrides?
7. **Q7 — Regular Dark start-page backdrop:** `fable-04-start-page.html:150–153` shares a purple `#15101A` gradient for both `.dark` and `.private`. Confirm using the proposed cool slate-blue + profile-tinted Dark gradient (`OrivMacV3.Backdrop.startDarkBase`) on regular Dark start pages so purple remains exclusive to Private Browsing.
8. **Q8 — Narrow-window responsive start page:** Confirm wrapping the 8-column bookmark row into `4 × 2` when the page card is `< 772 pt` wide, and collapsing Frequently Visited (and Private info card) from 2 columns to 1 column when the page card is `< 600 pt` wide.
