# Oriv browser design system

Oriv is a privacy-first native browser for Mac and iPhone. The active interface covers browsing, tabs, bookmarks, history, downloads, profiles and browser settings. Workspace, tasks, trackers, AI and source monitoring are outside the current product scope.

## Appearance and typography

The shared palette and tokens live in `Apps/Shared/Theme.swift` and are compiled into both apps. **System** is the default and uses the Graphite palette. Light and Dark set Graphite explicitly. Black keeps its dark canvas. The choice belongs to the current profile. When the user turns on Sync on their devices, appearance syncs for that same profile across Mac and iPhone. The continuity allowlist includes `appearance`, keyed as `preference.<profile UUID>.appearance`; different profiles retain independent choices. With Sync off, the choice stays local. Website logins, cookies and passwords remain on the device inside the profile and are never synced. See [Appearance](appearance.md) for the exact palette and website-color behavior.

Use semantic theme roles for colors. Main text belongs in address fields and secondary text is used for hints and supporting text. Increase Contrast strengthens secondary text and boundaries. Native controls inherit the platform accent. Selection includes a checkmark or a 3 pt leading marker whose system-accent hue is preserved when lightness needs adjustment for contrast. Purple glasses and explicit labels identify private browsing independently of the connection-security icon.

Use system text styles for iPhone controls and content so Dynamic Type can reflow. Toolbar glyphs retain compact, labeled targets while text grows. At accessibility text sizes the appearance picker becomes one column and hides decorative previews. Mac controls use native text fields, menu commands and familiar keyboard shortcuts. Use system sans-serif throughout. The Mac profile switcher uses 13 pt semibold and sheet titles use 15 pt semibold. Sidebar section headings use 11 pt semibold secondary ink, and counts use 11 pt regular. The active sidebar row uses 13 pt medium.

## Shared metrics and content

Use the shared tokens in `Theme.swift` for new UI. Document local platform geometry with `// oriv:raw-metric <reason>`.

| Family | Values and mapping |
| --- | --- |
| `OrivSpacing` | `xxs` 2, `xs` 4, `small` 8, `medium` 12, `large` 16, `larger` 20, `xl` 24, `xxl` 32 pt |
| `OrivRadius` | `badge` 6, `control` 8, `tile` 10, `panel` 12, `card` 14, `thumbnail` 18 pt, and `capsule` |
| `OrivType` on Mac | `windowTitle` 17 semibold, `title` 15 semibold, `headline` 13 semibold, `body` 13, `bodyEmphasized` 13 medium, `detail` 12, `caption` 11, `sectionLabel` 11 semibold, `badge` 10 medium |
| `OrivType` on iPhone | System Dynamic Type styles from title 3 through caption 2 |
| Layout and targets | `OrivLayout` supplies row, control and content dimensions. `OrivTarget` defines Mac minimum, toolbar and rail targets and iPhone touch and bar targets |
| Icons and motion | `OrivIcon` sizes SF Symbols. `OrivMotion` supplies quick and standard fades, a navigation spring and a reduced-motion cross-fade |
| Elevation | `OrivElevation` supplies flat, overlay and drawer recipes |

Use `textTertiary` on `canvas`, `surface`, or `surfaceRaised`. Use `danger` for
errors, recording and destructive buttons, `success` for confirmations, and
`private` on `privateWash` for private status. `onAccent(for:)` calculates ink
for an app-owned accent fill. Existing renamed roles forward to the v2 tokens.

`PageRowContent` shares the site favicon (with local monogram fallback), title, disambiguated address and optional “Already open” badge or selection checkmark. Mac keeps compact inline rows (title only in its tab sidebar); iPhone stacks the address and moves the accessory underneath at accessibility text sizes. Titles may use two lines at accessibility sizes; addresses always use one line with middle truncation so host, port and path tokens never split across lines. Pass each visible list’s `URLDisplay.Context`. Full URLs remain available as accessibility custom content named “Address”; Mac callers keep hover help. Buttons, List/Form selection, close targets, swipe actions and context menus belong to the platform container. Keep the existing 24 pt Mac and 44 pt iPhone minimum control targets.

`BrowserEmptyState` shows one explanatory message and an optional native action. Use it for empty home, saved-page lists, downloads, website data, other-device states and searches with no matches. The message wraps at accessibility sizes; do not add a decorative icon, separate heading or second explanatory paragraph. Both platforms use `PageErrorState` with the attempted host, a diagnostic, and **Try Again**.

The four `OrivMaterial` roles are `navigation` for the Mac sidebar, `control` for
interactive system glass, `overlay` for a solid floating surface with a border and
shadow, and `sheet` for native presentation. Page content and libraries use solid
or native grouped surfaces.

Liquid Glass belongs to the navigation layer, the Mac sidebar, iPhone bars and floating controls. Use system foreground styles where controls sit on glass. Keep start pages and libraries on solid or native grouped surfaces. The appearance modifier disables SwiftUI transaction animations under Reduce Motion. Glass controls use solid accessibility backings under Reduce Transparency or Increase Contrast. Native sheets and menus inherit the system material preferences. Site monograms use BrowserCore’s small `SiteMonogram` suffix hint, never for security, storage or sync decisions.

## Navigation

Mac: a native toolbar with one address/search field, a vertical tab sidebar, and a browser content area. The start-page search affordance focuses that same field. Suggestions are available from any page. The sidebar footer opens Bookmarks, History, Downloads, Other devices and Settings.

The Mac header’s **Browser Actions** ellipsis opens a native SwiftUI pull-down `Menu`. Its 36 × 32 pt target uses the shared toolbar button style. The menu inherits system material, selection, dismissal, keyboard navigation and accessibility. Group Bookmark (with its current state), Copy Link / Copy Original Link and Find first, followed by a zoom section (Zoom In, Zoom Out, Actual Size with the current percentage; a palette hid the reset label in practice), tab actions (including active downloads), and Sync / reading / privacy / Password AutoFill Help. Keep page-dependent and private-tab disabled states. Password help opens a popover from its menu action. Do not reintroduce a full-window tap-catcher or a custom menu panel. The native menu inherits the platform’s accessibility material preferences. Off-screen captures verify toolbar layout only; a menu tracking window must not be opened under the background-only policy.

On iPhone, the bottom browser controls contain Back, Forward when available,
the address capsule, and Show All Tabs. The capsule keeps Page Menu and Reload
alongside the address in regular and private browsing. Page Menu groups link
actions, page tools, site actions and Settings. Open Library from Tab actions
in the grid. Library links to Bookmarks, History, Other devices and Downloads.

The iPhone tab grid uses a native **Tabs / Private** segmented control and a
separate profile chip. The chip shows the active profile name and symbol in
its profile tint. At accessibility text sizes it moves into the top toolbar.
New Tab follows the selected segment. Done returns to a tab in that mode or
opens a blank tab when the mode is empty. The grid retains swipe-to-close and
the browser address capsule retains swipe-up to open the grid.

The resting address shows the host, or **Search** on a blank tab. The editor
exposes the full URL with native selection and a clear button. Its keyboard
layout guide anchors the editor and sets the available height for suggestions.
Suggestions grow upward from the field as a solid panel. The highest-ranked
result is closest to the field. VoiceOver traversal follows rank within each
group, and Up Arrow selects from nearest to farthest. Results scroll when they
reach the top safe area. Private tabs keep a glasses cue and a private-wash
top band.

Site settings shows the exact origin, connection state, protections and
permissions. Reload Page applies changes. Reset This Site restores default
protections and permissions after confirmation. Forget This Site separately
removes browsing data. Appearance uses a border and checkmark to indicate the
selected choice, with one column at accessibility text sizes.

## Shared behavior

- Local address suggestions use the active profile only. Regular tabs can suggest regular tabs, bookmarks and history; private tabs suggest only open private tabs. Results deduplicate by URL and prefer an already open tab. Nothing is sent to a search provider until submission.
- A saved link reuses an empty regular tab. Otherwise it opens a new regular tab, preserving a loaded page or private tab. An explicit Open in new tab always adds a tab.
- Both apps confirm closing a page after trusted form input. This is an edited-field signal, not a promise that the website's data is unsaved or saved.
- Removing a bookmark offers one-level Undo, restoring its metadata and position without creating duplicates. Other destructive actions state their scope and use confirmation where recovery is unavailable.
- Download feedback reports actual activity, bytes, completion or failure. Mobile downloads are temporary until saved or shared; their list is not restored across launches.
- Empty libraries and searches with no matches have distinct messages. Success messages do not use error titles.

## Native behavior and acceptance

Preserve existing WebKit instances during address editing and sheet navigation. Native scrolling, focus, sheets, menus, system permission prompts and selection behavior take precedence over decoration. Keep large content readable, avoid nested global navigation, and use explicit scope language for profile data and privacy controls.

Release acceptance still includes real-device reachability, VoiceOver and Full Keyboard Access, Increase Contrast and Reduce Transparency, landscape/narrow layouts, localization and media/camera permission flows. Local build and simulator evidence does not establish complete accessibility, HIG or web-standards conformance. Current evidence is recorded in [the UX implementation report](ux-implementation.md).

## Site identities and address results

`SiteIdentity` uses the profile/session icon environment. Keep the monogram as a
fallback and the separate glasses/text cue for private browsing. The Mac sidebar draws site artwork at 19 pt in rows and pins and 22 pt in the rail.
Uncached regular sites use a local monogram. Private tabs use a glasses glyph
when a favicon is unavailable. The rail places one glasses badge inside a
private tab’s cached favicon. Decode-time alpha and dominant glyph luminance analysis
adds a contrasting light or dark plate only when a transparent mark would vanish
against its panel or selection. Other lists and iPhone retain their existing
icon presentation and shared cache.

Address results use shared `AddressSuggestionRow` content and native field
editors. Group up to seven local matches under Switch to Tab, Bookmarks and
History, followed by one explicit Search row. Highlight query text in title and
address; keep selection visible with the existing marker. Both platforms place suggestions on solid overlays.
The group heading says “Switch to Tab” and the row badge says “Already open.”
Inline completion selects only the host suffix; accepting it is distinct from
choosing a result. Local ranking uses prefix strength, bookmarks, visit frequency
and recency; an actor maintains normalized prefix and trigram indexes off-main.

## Mac sidebar and rail

The Mac sidebar is a single Liquid Glass panel set 8 pt in from the window
edges with 14 pt continuous corners. The expanded panel defaults to 256 pt.
Drag its trailing edge between 220 and 360 pt or double-click the edge to
return to 256 pt. Each open browser window keeps its width across profile
switches. New windows use the last saved width on this Mac. The 72 pt icon rail
retains an independent width. The 50 pt browser toolbar aligns with the native
traffic lights. ⌥⌘S toggles the rail. At narrow window sizes explicit expansion
overlays the page.

The sidebar and rail share one full-height `MacSidebarGlass` surface. The
traffic lights and expanded toggle align at the toolbar midpoint. The
8 pt gutter shows the window’s sidebar material, with a theme chrome fill in
Black, accessibility fallbacks and fullscreen. Page tinting starts at the
toolbar’s leading edge. Per-profile
**Sidebar color** offers Graphite, Profile color and seven pastels. Black keeps
its near-black backing while retaining the saved color choice. The Mac-wide
**Glass opacity** applies a contrast guard below the selected backing. White
or black tonal fills above the backing let its tint show through selected rows,
hover, search and pins. Reduce Transparency and Increase Contrast use an opaque
backing and solid control fills. Increase Contrast strengthens outlines.
[Sidebar backing tokens](appearance.md#mac-sidebar-color)

The profile picker shows the current profile’s symbol and color in both
layouts. Expanded mode also shows the profile name, a plain secondary tab count and colored
profile dots for direct switching. Keyboard focus receives a visible outline.
Expanded rows are 32 pt high at standard text sizes. They reserve two trailing
targets for audio and close. The close glyph appears on hover and selection.
Clicking a speaker toggles mute. The context menu retains the separate media
pause action. VoiceOver announces the title, host, and applicable selected,
pinned, private, loading and audio states. Its row actions include Close and
Mute or Unmute. Keyboard users can use ⌘W and ⌃⌘M.

Pins show the site icon and a short site label. A single pin uses the full
width. Below 250 pt the grid uses two columns and up to four tiles. At 250 pt
and above it uses rows of two or three and up to six tiles. Additional pins
continue as title-bearing rows in the same section. The rail uses 42 × 36 pt icon
targets and context menus. New Tab stays reachable outside the scrolling list.
The footer has a hairline and five icon buttons. Downloads shows a dot while
a download is active.

| Mac sidebar token | Points |
| --- | ---: |
| Toolbar height and expanded titlebar spacer | 50 and 38 |
| Panel, content and row horizontal inset | 8 |
| Expanded toggle and profile picker height | 30 and 32 |
| Profile symbol frame | 22 |
| Search height and horizontal padding | 28 and 8 |
| Section height and extra spacing before Tabs and Private | 24 and 4 |
| Standard row height and between-row gap | 32 and 2 |
| Close and audio hit target | 24 × 24 each |
| Pin tile height, icon and gap | 46, 17 and 4 |
| Expanded footer button band and button size | 36 and 32 × 32 |
| Rail footer button target | 42 × 36 |

Search uses one active-profile finder for both widths and ⇧⌘A. It begins in the
selected tab’s privacy scope. Mixed sessions show a **Tabs / Private** control.
The finder matches normalized titles and hosts in memory and revalidates the
tab ID, profile, privacy scope and query when opening a result. The expanded
sidebar shows matching rows, and the rail opens a title-bearing panel. Escape
clears search and returns focus. Arrows, Home, End, Page Up and Page Down
highlight tabs. Return, Space or a click opens a tab. Down Arrow from the
sidebar toggle enters the tab list.

Pin/unpin commands use the existing `TabRecord.isPinned` model and version-3
session snapshot; no migration is needed. Dragging onto Pinned pins a regular
tab, and dropping onto Tabs unpins it, appending to the destination group. Between-row and between-tile insertion markers show where a tab will land
within its current pin and privacy section. Drags are scoped
to the controller, so another window/profile cannot move its tabs. Move Up/Down
provide keyboard alternatives. Private tabs reject pinning in both the UI and
model. Bulk close preserves pins and the other privacy group. Pinned tabs keep
the existing idle-discard exclusion alongside selected, private, edited, media,
capture, download and request-safety rules.

Optional continuity already allows `TabRecord.isPinned` in regular-tab metadata,
with profile/device ownership and pinned-first ordering. Pins therefore use that
existing path; no new payload, preference or allowlist is added. Receiving remote
tabs does not replace local tabs. Private tabs never enter session persistence
or continuity. The search query and rail focus remain local transient state.

Rows reuse `SiteIdentity`/`SiteIconStore`'s bounded shared cache. The native collection view virtualizes normal, pinned and private rows keyed
by stable tab IDs. Audio
indication is event-driven for HTML audio/video, including child frames; there
are no per-row timers or playback polling loops. Web Audio-only pages require a
separate future public-API strategy; pause/block still applies through WebKit.

At narrow expanded widths, Share remains available in Browser Actions and New Tab
remains in the sidebar. The address capsule keeps a 230 pt minimum and centers
on the page viewport. Active downloads also have a sidebar badge.

Sidebar controls use the shared tonal surface and focus-outline tokens. The
3 pt selection marker sits inside the outline. The address capsule keeps a
230 pt minimum and shows a compact **Private** pill with purple glasses when
the selected tab is private. The page-derived color band keeps its monochrome
navigation controls. Browser Actions retains its 36 × 32 pt target. Suggestions
float in a solid 12 pt panel. Restored pages receive initial native web-content
focus, and empty tabs focus the address editor.

The Mac start page aligns its 640 pt content column with the address capsule
and uses a four-column tile grid at standard text sizes with up to eight bookmarks. The private start page
uses the shared private banner and a short explanation on the private surface.
iPhone uses three flexible columns at standard text sizes and one column at
accessibility text sizes. Both use
solid tiles and secondary section labels. Library counts appear beside their
section names on the surface, with list content on the canvas. Find in Page
uses the shared search field and toolbar controls. Glass opacity applies to all
profiles.


## Mac Settings

Settings keeps the native seven-item preference toolbar. In System, Light and
Dark, AppKit supplies behind-window material at 76% opacity in the gutters.
Each scrolling pane uses a soft scroll edge under the toolbar. Each group contains its heading, controls, scope and
supporting text on opaque `surfaceRaised`, with a half-point inset hairline.
The backdrop follows window activity and is independent of website colors
and sidebar tints. System follows the Mac appearance, while explicit appearance
comes from the active profile.

Reduce Transparency, Increase Contrast and Black use the opaque canvas.
Increase Contrast also strengthens secondary ink, group boundaries and the
titlebar separator. Preferred window heights follow the selected pane and
fit the available display. Scroll views keep all controls reachable as content
grows. The Settings scene keeps its selected pane when the active profile
changes. An open browsing-data sheet retains the session it was opened for.

Use **This profile** with the profile name for profile-scoped controls and
**All profiles on this Mac** for Mac-wide browser defaults. Show **Synced**
on profile preference groups in the continuity allowlist while sync is enabled.
Copy for local data and for deletion explains their scope separately. Scope
labels use 11 pt secondary ink and align to the trailing edge. Section headings
use 13 pt semibold.

| Mac Settings token | Points |
| --- | ---: |
| Form horizontal and vertical inset | 24 and 16 |
| Gap between groups | 20 |
| Group horizontal and vertical padding | 16 and 12 |
| Gap between heading, controls and detail | 8 |
| Gap between controls | 4 |

## Copy and verification

Use US English and sentence case for labels, headings and settings. Use title case
for commands. Keep shared labels in `OrivStrings.swift`, including **Sync**,
**Other devices**, **Search or enter address**, **Site Privacy**, and **Try Again**.
Protection list versions appear in About.

`scripts/check-browser.sh` checks the per-file SwiftUI and AppKit raw-token and focus-state baseline and contrast.
Lower the baseline when a migration removes literals. The contrast gate includes
status and private roles, solid controls, every sidebar tint and glass level,
and the Settings card composite over synthetic extreme inputs. Settings requires
7:1 primary ink, 4.5:1 secondary ink, and 3:1 Increase Contrast boundaries.

For Mac gallery snapshots, set `ORIV_BACKGROUND_UI=1` and
`ORIV_GLASS_SCENE=design-system` and run `scripts/capture-mac-visuals.sh --glass`.
For the iPhone gallery and browser inventory, select an isolated simulator and
derived data folder with `ORIV_IOS_SIMULATOR_ID` and `ORIV_IOS_DERIVED_DATA`,
then run `scripts/capture-iphone-design.sh <output-directory>`. Both use synthetic
fixtures. Live glass compositing and VoiceOver require a foreground or device check.

## Component catalogue

Shared SwiftUI components live in `Apps/Shared/Components`. Platform controls live in `Apps/macOS/Views/Components` and `Apps/iOS/Components`.

| Component | Use |
| --- | --- |
| `orivButton` | Primary, secondary, quiet, destructive and link roles. Native bordered styles supply keyboard and accessibility behavior. Quiet actions use hover and press fills. Busy actions expose an in-progress value and are disabled. The external-private handoff uses the contrast-resolved accent fill on iPhone. |
| `ToolbarButton` | Page-adaptive ink and a shared Mac toolbar hit area. Inline address controls use the same style at the smaller target. Hover, press and active states use 7%, 12% and 16% capsule fills. The system tracks the Browser Actions menu and ShareLink. |
| `BarButton` | iPhone control glass and 48 pt bar targets, with a 44 pt variant for Forward. Glyphs grow with Dynamic Type up to the icon cap. Native history and tab menus own their primary actions and long-press behavior. |
| `PageRowContent` | Inline, stacked and title-only site rows with highlighted suggestion text, private and loading icons, and optional selected and already-open accessories. |
| `ListSelection` | List fill and leading marker, card border, and a stronger Increase Contrast outline. Appearance choices add a checkmark. Platform containers set the selected accessibility trait and own keyboard navigation and focus. |
| `SettingRow` | Native toggle, picker or action followed by optional inline helper text. This keeps each control and its explanation in one form row. Native controls retain disabled and focus behavior. |
| `SectionHeader` | Sidebar title and count, content title with optional Show All, and suggestion group label. Forms use native section headings. |
| `OrivPopover` | Native Mac popover content with a title, optional symbol and scrollable overflow at the height cap. BrowserPopover still routes Escape, Tab and responder restoration. |
| `OrivSheet` | Native presentations with a shared title, optional subtitle, content and trailing actions. Mac widths are 420, 560 and 760 pt. Busy and error lines sit above or beside the actions. Cancel is the default for destructive confirmations. Library uses the same title style in its split layout. |
| `OrivSearchField` | Mac sidebar and content fields with 32 pt chrome, magnifier, clear action and optional shortcut hint. Callers own focus and key commands. The sidebar fill becomes opaque with focus or accessibility settings. iPhone content searches use native searchable navigation. |
| `OrivBanner` | Info, success, warning and private notices with optional action and dismiss. Minimum height is 32 pt on Mac and 44 pt on iPhone. At accessibility sizes the text wraps above the actions. The external-private destination picker shares the banner label and colors. |
| `Badge` | Neutral Already open, private and count labels. Counts may use an unfilled variant. |
| `BrowserEmptyState`, `PageErrorState` | Shared empty and retry presentation. Retain the caller’s container, full attempted host and optional recovery action. |
| `Tile` | Start-page and pinned surfaces, appearance choices and sidebar swatches. Tiles share their radius and card selection treatment while the platform retains input handling. |

The debug design-system scene captures foundations, controls, rows, notices and presentations in Light, Dark and Black with standard, reduced-transparency and increased-contrast settings. The iPhone inventory includes accessibility-sized text. Offscreen captures show the fallback material on Mac. Check live menu tracking, glass compositing, keyboard traversal and VoiceOver on an authorized foreground or physical-device pass.
