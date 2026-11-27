# Oriv changelog

Oriv's public beta starts after 0.29.0. Every version listed below was a private development build, made while Oriv was being built and tested by its developer, and none of them was distributed publicly. They are recorded here so the history is complete. For 0.5.0 onward, each date is the date of the commit that set that version. Versions 0.2.0 to 0.4.0 predate this repository's git history (0.5.0 is its first commit), so their dates come from their release notes.

## 0.30.0 — first public beta (unreleased)

- **A new Mac design.** A floating window frame, a Liquid Glass toolbar and a refined sidebar. The address bar opens grouped glass suggestions, and there's a new "Where to?" start page.
- **Private windows** have their own Amethyst Dusk appearance, and links opened privately from other apps get a bar for moving the page to a profile.
- **Motion:** the address bar moves between the start page and the toolbar in one frame, pages show a loading ring, and Reduce Motion is respected throughout.
- **Automatic updates** for the Mac public beta through Sparkle. Oriv asks before it first checks.
- **Fixes:**
  - The Settings window no longer freezes on heavy panes.
  - Switching tabs or profiles no longer jumps.
  - The selected tab keeps the right colour after a profile swipe.
  - Address suggestions no longer flicker while you type.
  - Two-tone site icons show as drawn.
  - Closing a tab stops its audio and video.
  - YouTube's seek keys no longer trigger the alert sound.

## 0.29.0 (2026-11-24)

- Drag and drop in the Mac sidebar is smooth across tab rows, pinned tabs and the collapsed rail, and dropped tabs animate into place.
- The Mac sidebar gains Chromatic Glass styling with adaptive favicons.
- Positional pinning is back in the Mac sidebar, and the keyboard highlight stays put while search results update.
- Address bar polish on Mac: clicking the capsule's padding focuses the field, and the placeholder stays readable in every appearance.
- Fixes: the Browser Actions menu keeps its full click area, rail search results follow the selected glass level, and pressed sidebar controls stay readable over bright glass.

## 0.28.0 (2026-11-24)

- The Mac sidebar is now a resizable, floating glass panel with its own window backdrop.
- Pinned Mac tabs appear as compact favicon tiles, and the active-tab marker is back.
- Selected sidebar tabs use a clear glass selection pill.
- The Mac Settings window uses a Liquid Glass material with more open grouping and spacing.
- Mac tab search is unified and scoped, glass controls are refined, and keyboard handling is fixed.

## 0.27.0 (2026-11-23)

- Design system v2 now covers Mac browsing and Settings screens and the iPhone browser. Buttons, popovers, sheets, notices, badges, search fields and tiles share one look.
- The Mac Tab Overview is gone. Sidebar tab search remains.
- iPhone: native search in the tab grid, a tab search button in the toolbar, address suggestions anchored to the keyboard bar, and separate controls for tab modes.
- Site Privacy fits its content and keeps keyboard focus, and loading button labels no longer overlap the spinner.
- Fixed tab grid cards showing the wrong content after switching between normal and private browsing.

## 0.26.0 (2026-11-23)

- Foundations for design system v2, plus clearer sidebar glass.
- Interface text is now in US English, and status messages and wording are clearer.
- When a navigation is refused, Oriv keeps its address so you can retry it.

## 0.25.0 (2026-11-23)

- Mac suspends idle background tabs and reclaims their memory.
- Closing or unloading a tab releases its memory, including web views and password-field handlers.
- One-click Apple Passwords on Mac: focused login fields open the Apple Passwords menu through WebKit's field menu.

## 0.24.0 (2026-11-23)

- Clearer sidebar glass, with text that keeps its contrast.
- Each profile can have its own Mac sidebar colour.
- Browser popovers keep keyboard focus within themselves.
- Accessibility fixes in the browser and Settings.

## 0.23.0 (2026-11-22)

- Switching profiles is smooth because the window is no longer rebuilt. Oriv now swaps the browser contents in place and saves the switch in the background.

## 0.22.0 (2026-11-21)

- Forget This Site removes a site's website data, cookies, history, suggestions and cached icons and snapshots from the current profile. Bookmarks are kept. See [privacy](../privacy.md#forget-this-site).
- Strict mode blocks trackers that hide behind CNAME records.

## 0.21.3 (2026-11-21)

- Switching profiles no longer moves focus into the address bar.

## 0.21.2 (2026-11-21)

- Profile swiping works with real Mac trackpads.

## 0.21.1 (2026-11-20)

- Profile swipes are more reliable and follow natural gestures.
- Fixed a crash during window setup.
- The native Settings toolbar is restored, and the selection in Library is easier to read.

## 0.21.0 (2026-11-20)

- Profile dots in the sidebar, and keyboard shortcuts for switching profiles on Mac.
- Swipe with two fingers to switch profiles, with an animated transition.

## 0.20.0 (2026-11-20)

- New Graphite theme for browser chrome, start pages, Settings and iPhone controls. It follows the system accent colour.
- YouTube ad blocking, using a bundled filter that runs only on YouTube.
- Oriv rejects known cookie banners automatically, and link cleaning unwraps known tracking redirects and strips more parameters.
- Additional profiles can be permanently deleted, and inactive iPhone profiles no longer trigger downloads or app prompts.
- The expanded Mac sidebar is narrower, and the Mac shortcuts for a private tab and a private window have swapped.

## 0.19.0 (2026-11-20)

- Dedicated private windows on Mac.
- Each newly opened private tab gets its own isolated website data.
- Muting a Mac tab now also silences Web Audio.
- A setting for the Mac sidebar's glass opacity.
- The iPhone page menu is grouped by how often each action is used.

## 0.18.0 (2026-11-20)

- Start pages on Mac and iPhone show bookmarks and frequently visited sites, with one tile per site.
- Tab list polish: duplicate titles show the site's host, and the native tab menu gains page and audio actions.
- The Mac sidebar and native controls mirror correctly in right-to-left languages.
- Smoother iPhone tab grid transitions.
- The redundant New Tab toolbar button is gone, the window buttons sit inside the collapsed rail, and GitHub favicons load more reliably.

## 0.17.1 (2026-11-19)

- `data:` addresses typed into the address bar or opened from bookmarks load on Mac and iPhone. Pages can no longer open them as blank pop-up tabs.

## 0.17.0 (2026-11-19)

- The Mac sidebar's tab list is rebuilt on a native AppKit collection.
- Sidebar rows keep their layout when the window resizes, and keyboard focus and section reveals work again.
- Fixed the iPhone tab grid when tabs are deleted on iOS 27.

## 0.16.0 (2026-11-19)

- Browsing history is stored per profile and can be searched.
- Site icons are fetched with WebKit's identity over an anonymous connection.
- Files served as attachments now download on Mac and iPhone instead of opening.
- Empty tabs match the window's current appearance. Mac history paging buttons work independently.

## 0.15.5 (2026-11-19)

- No user-facing changes. The Mac and iPhone apps now share their app resources.

## 0.15.4 (2026-11-19)

- Focus rings on Mac appear only during keyboard navigation.

## 0.15.3 (2026-11-19)

- Fixes for the Mac sidebar and the tab snapshot shown when switching tabs.
- The selected tab keeps keyboard focus when the sidebar rail updates, and focus is no longer clipped with legacy scroll bars.

## 0.15.2 (2026-11-18)

- The glass sidebar sits flush with the window edges, and the window buttons sit in the rail header.
- Only one focus cue appears, and only during keyboard navigation.

## 0.15.1 (2026-11-18)

- The Mac sidebar and toolbar match the approved design: sidebar material, favicons, profile header, tab rows and rail.

## 0.15.0 (2026-11-18)

- A Safari-like Liquid Glass sidebar on Mac, with a grid of pinned tabs, a favicon rail and separate Tabs and Private sections.
- Search Tabs (Shift-Command-A).
- Private tabs can't be pinned.

## 0.14.0 (2026-11-18)

- Switching tabs is smoother.
- Keyboard shortcuts to cycle through tabs, plus a hard reload.
- Site favicons, and address completion from local history and bookmarks.

## 0.13.1 (2026-11-17)

- The Browser Actions menu on Mac is a native pull-down that responds reliably to clicks.

## 0.13.0 (2026-11-17)

- Continuity between devices updates faster and more reliably.
- Better tab recovery, and Mac reclaims memory from eligible background tabs.
- Private windows opened from other apps appear reliably.

## 0.12.5 (2026-11-16)

- On iPhone, the All Tabs button uses the same transition as swiping up on the address bar.

## 0.12.4 (2026-11-15)

- Swipe-to-close in iPhone All Tabs is smooth and visible, and the remaining cards animate into place.

## 0.12.3 (2026-11-15)

- The top bar's colour changes smoothly when you swipe between tabs and when pages change.

## 0.12.2 (2026-11-15)

- Tab-swipe fixes on iPhone.
- The prompt for upgrading a site to HTTPS appears once per exact host.
- Tab snapshots use less memory.

## 0.12.1 (2026-11-13)

- iPhone gestures are polished, and live pages stay stable during tab overview transitions.

## 0.12.0 (2026-11-11)

- The Mac sidebar is now a full-height window column.
- Privacy features: link cleaning, EasyList and EasyPrivacy filtering, a per-site shield, HTTPS upgrades, cookie-banner hiding and Global Privacy Control.

## 0.11.0 (2026-11-11)

- In full screen, the toolbar matches the window.
- Safari-style tab transitions on iPhone.
- Closing a normal tab no longer asks for confirmation.
- Page colour applies instantly.

## 0.10.1 (2026-11-10)

- Scrolling on Mac no longer starts editing the address.
- The top bar's colour stays steady while you scroll.

## 0.10.0 (2026-11-10)

- An iOS 27-style address bar on iPhone, with tab gestures, refresh and contextual actions.
- Native Find in page.

## 0.9.0 (2026-11-10)

- Like Safari 26, the toolbar takes its colour from the page's pinned header or background.
- On iPhone, the glass bar adapts to the page, and content scrolls beneath the glass.

## 0.8.0 (2026-11-10)

- Liquid Glass toolbar and bottom bar that blend with the page.

## 0.7.0 (2026-11-09)

- Links from other apps can be opened privately.
- Open on iPhone and Open on Mac.
- Fewer session saves, history titles that update when a page's title arrives late, ranked address suggestions, and recovery after a web content crash.
- Shared design tokens, consistent rows and empty states, and support for Reduce Motion and Reduce Transparency.

## 0.6.0 (2026-11-09)

- The first iPhone app, alongside visual polish for the Mac browser.
- Profiles, and opt-in continuity between devices.
- Oriv is now browser-only: the contextual workspace from 0.4.0 has been removed.

## 0.5.0 (2026-10-25)

- A new design system, shared across the browser, start page, Workspace, Library and Settings.
- The new-tab page continues from saved items and next actions, and private new tabs show no normal suggestions.
- Guidance for Apple Passwords AutoFill, without Oriv handling credentials itself.

Full notes: [0.5.0](0.5.0.md).

## 0.4.0 (2026-10-25)

- A contextual workspace: save a page with a purpose note, then add notes, actions, due dates and reminders.
- A Workspace window with search, Today, Upcoming and Waiting lists, Archive and recoverable Trash.
- Existing bookmarks were migrated, and Apple Passwords can be opened from Library and Settings.

Full notes: [0.4.0](0.4.0.md).

## 0.3.0 (2026-10-25)

- Ad blocking with Off, Balanced and Strict modes, plus per-site exceptions.
- Full screen from a normal window, including YouTube, was verified to work without code changes.

Full notes: [0.3.0](0.3.0.md).

## 0.2.0 (2026-10-25)

- YouTube live chat works.
- Video and chat fill the screen correctly in full screen.
- The app is named Oriv, with its kolam-inspired icon.

Full notes: [0.2.0](0.2.0.md).
