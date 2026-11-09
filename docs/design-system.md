# Oriv browser design system

Oriv is a privacy-first native browser for Mac and iPhone. The active interface covers browsing, tabs, bookmarks, history, downloads, profiles and browser settings. Workspace, tasks, trackers, AI and source monitoring are outside the current product scope.

## Appearance and typography

The shared palette and components live in `Apps/macOS/Views/Theme.swift` and are compiled into both apps. **T3 Code** is the default for new profiles. System, Light and Dark remain available. The choice belongs to the current profile on the current device; it is not an account-wide or synced preference. See [Appearance](appearance.md) for the exact palette and website-color behavior.

Use semantic theme roles instead of hardcoded colors. Main text belongs in address fields; secondary text belongs on the canvas or surface. Increased Contrast brightens foreground accents, secondary text and boundaries. Filled primary buttons retain a darker fill so white labels remain readable. Selection also has a checkmark or a leading indicator. Private browsing uses text and glasses, independently of the connection-security icon.

Use system text styles for iPhone controls and content so Dynamic Type can reflow. Toolbar glyphs retain compact, labeled targets while text grows. At accessibility text sizes the appearance picker becomes one column and hides decorative previews. Mac controls use native text fields, menu commands and familiar keyboard shortcuts. The new-tab heading uses system serif; controls use the system sans-serif. No downloaded fonts or remote theme assets.

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
