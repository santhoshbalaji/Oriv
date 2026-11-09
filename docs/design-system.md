# Oriv browser design system

Oriv is a privacy-first native browser for Mac and iPhone. The active interface covers browsing, tabs, bookmarks, history, downloads, profiles and browser settings. Workspace, tasks, trackers, AI and source monitoring are outside the current product scope.

## Appearance and typography

The shared palette and components live in `Apps/macOS/Views/Theme.swift` and are compiled into both apps. **T3 Code** is the default for new profiles. System, Light and Dark remain available. The choice belongs to the current profile. When the user enables continuity on their devices in a configured Continuity build, appearance syncs for that same profile across Mac and iPhone. The continuity allowlist includes `appearance`, keyed as `preference.<profile UUID>.appearance`; different profiles retain independent choices. With continuity off, the choice stays local. Website logins, cookies and passwords remain on the device inside the profile and are never synced. See [Appearance](appearance.md) for the exact palette and website-color behavior.

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

`PageRowContent` shares the local site monogram, title, disambiguated address and optional “Already open” badge or selection checkmark. Mac keeps compact inline rows (title only in its tab sidebar); iPhone stacks the address and moves the accessory underneath at accessibility text sizes. Titles may use two lines at accessibility sizes; addresses always use one line with middle truncation so host, port and path tokens never split across lines. Pass each visible list’s `URLDisplay.Context`. Full URLs remain available as accessibility custom content named “Address”; Mac callers keep hover help. Buttons, List/Form selection, close targets, swipe actions and context menus belong to the platform container. Keep the existing 24 pt Mac and 44 pt iPhone minimum control targets.

`BrowserEmptyState` shows one explanatory message and an optional native action. Use it for empty home, saved-page lists, downloads, website data, other-device states and searches with no matches. The message wraps at accessibility sizes; do not add a decorative icon, separate heading or second explanatory paragraph. Page-load failures retain their diagnostic and recovery presentation.

The appearance modifier disables SwiftUI transaction animations under Reduce Motion and forces a solid theme toolbar background under Reduce Transparency. App-owned content already uses solid theme surfaces; native sheets, menus and system transitions also follow OS accessibility preferences. Site monograms use BrowserCore’s small `SiteMonogram` suffix hint, never for security, storage or sync decisions.

## Navigation

Mac: a native toolbar with one address/search field, a vertical tab sidebar, and a browser content area. The start-page search affordance focuses that same field. Suggestions are available from any page. Bookmarks, history and downloads open from the sidebar; Settings is labeled explicitly.

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
