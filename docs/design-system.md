# Oriv browser design system

Oriv is a privacy-first native browser for Mac and iPhone. The active interface covers browsing, tabs, bookmarks, history, downloads, profiles and browser settings. Workspace, tasks, trackers, AI and source monitoring are outside the current product scope.

## Appearance and typography

The shared palette and components live in `Apps/Shared/Theme.swift` and are compiled into both apps. **T3 Code** is the default for new profiles. System, Light and Dark remain available. The choice belongs to the current profile. When the user enables continuity on their devices in a configured Continuity build, appearance syncs for that same profile across Mac and iPhone. The continuity allowlist includes `appearance`, keyed as `preference.<profile UUID>.appearance`; different profiles retain independent choices. With continuity off, the choice stays local. Website logins, cookies and passwords remain on the device inside the profile and are never synced. See [Appearance](appearance.md) for the exact palette and website-color behavior.

Use semantic theme roles instead of hardcoded colors. Main text belongs in address fields; secondary text belongs on the canvas or surface. Increased Contrast brightens foreground accents, secondary text and boundaries. Filled primary buttons retain a darker fill so white labels remain readable. Selection also has a checkmark or a leading indicator. Private browsing uses text and glasses, independently of the connection-security icon.

Use system text styles for iPhone controls and content so Dynamic Type can reflow. Toolbar glyphs retain compact, labeled targets while text grows. At accessibility text sizes the appearance picker becomes one column and hides decorative previews. Mac controls use native text fields, menu commands and familiar keyboard shortcuts. The new-tab heading uses system serif; controls use the system sans-serif. No downloaded fonts or remote theme assets.

## Shared metrics and content

Use the selective tokens in `Theme.swift`; retain intentional platform geometry rather than rounding every value to a token.

| Token | Values / mapping |
| --- | --- |
| `OrivSpacing` | `xs` 4, `small` 8, `medium` 12, `large` 16, `xl` 24, `xxl` 32 pt |
| `OrivRadius` | `compact` 6, `small` 8, `medium` 10, `large` 14 pt; use `Capsule()` for capsules |
| `OrivType` on Mac | `body` 13, `detail` 12, `caption` 11, `title` 17 pt (semibold) |
| `OrivType` on iPhone | `body` → body, `detail` → footnote, `caption` → caption, `title` → headline |

`PageRowContent` shares the site favicon (with local monogram fallback), title, disambiguated address and optional “Already open” badge or selection checkmark. Mac keeps compact inline rows (title only in its tab sidebar); iPhone stacks the address and moves the accessory underneath at accessibility text sizes. Titles may use two lines at accessibility sizes; addresses always use one line with middle truncation so host, port and path tokens never split across lines. Pass each visible list’s `URLDisplay.Context`. Full URLs remain available as accessibility custom content named “Address”; Mac callers keep hover help. Buttons, List/Form selection, close targets, swipe actions and context menus belong to the platform container. Keep the existing 24 pt Mac and 44 pt iPhone minimum control targets.

`BrowserEmptyState` shows one explanatory message and an optional native action. Use it for empty home, saved-page lists, downloads, website data, other-device states and searches with no matches. The message wraps at accessibility sizes; do not add a decorative icon, separate heading or second explanatory paragraph. Page-load failures retain their diagnostic and recovery presentation.

The appearance modifier disables SwiftUI transaction animations under Reduce Motion and forces a solid theme toolbar background under Reduce Transparency. App-owned content already uses solid theme surfaces; native sheets, menus and system transitions also follow OS accessibility preferences. Site monograms use BrowserCore’s small `SiteMonogram` suffix hint, never for security, storage or sync decisions.

## Navigation

Mac: a native toolbar with one address/search field, a vertical tab sidebar, and a browser content area. The start-page search affordance focuses that same field. Suggestions are available from any page. Bookmarks, history and downloads open from the sidebar; Settings is labeled explicitly.

The Mac header’s **Browser Actions** ellipsis opens a native SwiftUI pull-down `Menu`. Its 36 × 32 pt rectangular label includes all glass padding in the target. Use the header’s `MacAddressGlass` treatment; let the system render menu material, selection, dismissal, keyboard navigation and accessibility. Group Bookmark (with its current state), Copy Link / Copy Original Link and Find first, followed by a zoom section (Zoom In, Zoom Out, Actual Size with the current percentage; a palette hid the reset label in practice), tab actions (including active downloads), and Continuity / reading / privacy / Password AutoFill Help. Keep page-dependent and private-tab disabled states. Password help opens a popover from its menu action. Do not reintroduce a full-window tap-catcher or a custom menu panel. The native menu inherits the platform’s accessibility material preferences. Off-screen captures verify toolbar layout only; a menu tracking window must not be opened under the background-only policy.

iPhone: one browser screen with an address control above the page and a single bottom row for Back, Forward, Library, tab count and Page options. Tabs, Library, Site settings and Settings open as sheets. Library groups bookmarks, history and downloads. The page menu names the active profile in its Settings action. Profile names are also visible on the start page and tab list.

The resting iPhone address shows the host; editing exposes the complete URL with native selection and a clear button. Private mode remains visible during address editing. Site settings shows the exact origin, connection state and per-site controls. HTTPS is described as connection encryption, not a guarantee that a site is trustworthy.

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
fallback and the separate glasses/text cue for private browsing. The Mac sidebar draws site artwork full bleed at 19 pt in rows, 24 pt in pins
and 22 pt in the rail. Decode-time alpha and dominant glyph luminance analysis
adds a contrasting light or dark plate only when a transparent mark would vanish
against its panel or selection. Other lists and iPhone retain their existing
icon presentation and shared cache.

Address results use shared `AddressSuggestionRow` content and native field
editors. Group up to seven local matches under Switch to Tab, Bookmarks and
History, followed by one explicit Search row. Highlight query text in title and
address; keep selection visible with the existing marker. iPhone uses the existing
Liquid Glass treatment, adapting to Reduce Transparency and Increased Contrast.
Inline completion selects only the host suffix; accepting it is distinct from
choosing a result. Local ranking uses prefix strength, bookmarks, visit frequency
and recency; an actor maintains normalized prefix and trigram indexes off-main.

## Mac sidebar: Safari-like glass (B)

The Mac sidebar is a single inset system Liquid Glass panel with 20 pt corners
and a 10 pt window inset. The expanded panel is 276 pt wide (296 pt including
insets); the icon rail is 64 pt (84 pt including insets). The existing toggle and
⌥⌘S animate between them, respecting Reduce Motion. The address editor and page
host retain their identity. The iPhone interface is unchanged.

Use `GlassEffectContainer` and `.glassEffect(.regular)` for the panel on the
macOS 26 deployment target. Rows and the footer use quiet fills, without extra
per-row glass effects. Reduce Transparency and Increase Contrast replace the
panel material with the semantic light/dark surface; increased contrast adds a
strong boundary and selected/focused row outlines. The observed page colour
continues behind the panel and transparent titlebar. Do not mirror page text
into the titlebar or force a dark sidebar in a light window.

The profile picker uses a primary-colour stacked-tabs glyph, bold name, tab count
and chevron, followed by persistent Search tabs. Empty Pinned is hidden; a compact
pin target appears during a local tab drag. Section counts omit zero. Pinned favicons occupy at most two rows of four; additional pins
appear as a labelled lazy list. Tabs and Private have independent headings and
counts. New Tab and the Library/Settings footer stay fixed while the tab
collection scrolls. The rail uses centred 42 × 36 pt icon targets, a 15 pt selection marker and no
close button. Search and New Tab form its top group; Library and Settings form
its bottom group. It retains full accessibility labels, context-menu closing and
a search button that expands the title-bearing results.

Search filters only active-profile tab metadata by title or hostname, including
pins and private tabs in a separate section. It never instantiates a webview.
⇧⌘A expands the sidebar and focuses search; Escape clears it and returns focus
to the selected tab. Matching pins become titled rows during search. A selection
outside the current filter clears it. Arrow keys navigate the grid/list, Return
activates, and Tab/Shift-Tab reach controls and close buttons. Down Arrow from
the toggle enters the selected tab; focus waits for a lazy target to mount.
Focus ownership stays with the containing window during collapse. Down Arrow from
the sidebar toggle enters the selected tab, including in the rail. Titles, hosts,
selected/pinned/private/loading/audio states are spoken; favicons are decorative.
Close remains an accessibility action and a keyboard/VoiceOver control when its
glyph is hidden. Pins close through their context menu or ⌘W.

Pin/unpin commands use the existing `TabRecord.isPinned` model and version-3
session snapshot; no migration is needed. Dragging onto Pinned pins a regular
tab, and dropping onto Tabs unpins it, appending to the destination group. Row
and tile drops reorder within the current pin/privacy section. Drags are scoped
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

Rows reuse `SiteIdentity`/`SiteIconStore`'s bounded shared cache. The normal,
overflow-pin and private collections use a lazy stack with stable tab IDs. Audio
indication is event-driven for HTML audio/video, including child frames; there
are no per-row timers or playback polling loops. Web Audio-only pages require a
separate future public-API strategy; pause/block still applies through WebKit.

At narrow expanded widths, Share, New Tab and Overview remain in Browser Actions
and the fixed sidebar controls, leaving the 230 pt address minimum and privacy
button reachable. Active downloads also have a sidebar badge.

The Mac sidebar uses direction B's slate/lilac semantic palette, including the
lifted selection, mulberry marker, 32 pt search field and 42 pt footer pill.
Its light secondary foreground is darker than the mock to preserve 4.5:1 on the
selection. The 60 pt page header has plain navigation/action glyphs and a filled,
borderless address capsule; Browser Actions retains its 36 × 32 pt target.
Restored pages receive initial native web-content focus, while empty tabs focus
the address editor. Keyboard navigation retains the system focus ring.
