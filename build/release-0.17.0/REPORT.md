# Oriv 0.17.0 build 32

## Implementation

The Mac sidebar uses a transparent AppKit `NSCollectionView` in the SwiftUI Liquid Glass shell. The collection owns selection, arrow navigation, scrolling, and drag sessions. A collection item represents one tab in both the pinned grid and the single-column list, so each pinned tile has its own selection and accessibility row. The layout preserves the overflow list, regular and private sections, and single-column rail. Each tab exposes an accessibility row with its title, host, state, and available actions. The section headings expose heading semantics. The native scroll view uses the system scroller style in the expanded sidebar and an overlay scroller style in the rail and hover-peek to keep the 56 pt viewport. [Apple collection view documentation](https://developer.apple.com/documentation/appkit/collection-view)

Tab artwork retains the style B palette, favicon sizes, selection pill and leading accent, hover fill, close glyph, and media cues. The context menu and middle click use the existing tab commands. Dragging to a row reorders within the same pin and privacy group. The Pinned and Tabs headings pin and unpin regular tabs. Section changes use the session's existing order and persistence logic. Search still matches tab titles and hosts.

Hover-peek stays. The same collection changes its cell width when peek reveals titles, preserving the rail's favicon centers. The library and bookmarks are outside the tab collection. Both app targets are version 0.17.0, build 32.

## C4

An arrow moves the native selected item immediately. The browser keeps the current page and defers activation until input has been idle for 200 ms. Return activates the selected preview immediately. Leaving the list cancels the pending preview, and switching tabs elsewhere synchronizes the collection. This uses the review's short-settle option. It allows a pause to open one tab while a rapid sequence crosses sleeping tabs without instantiating their WebKit views. The test moves through five sleeping tabs in one sequence and checks that only the settled destination instantiates. A second test checks Return and cancellation.

## Removed code

Relative to `bddbdfb`, the diff removes 385 lines from `BrowserSidebar.swift`, including `SidebarTabFocus`, `SidebarFocusContext`, per-row SwiftUI focus bindings, scroll-to-materialize requests, and the SwiftUI drag path. All 75 lines of `ChromeFocus.swift` are deleted. The window, router, and button styles remove the remaining synthetic modality and ring consumers. The replacement tests assert native responder ownership, selection, scrolling, drag delegates, and accessibility row actions.

## Background parity

The baseline used `bddbdfb` with only the scroll capture fixture added. The candidate used the clean `4c0fab8` tree. The `sidebar-b` fixture captures 12, 50, and 100 tabs with pins, pin overflow, and private tabs. The 100-tab fixture also scrolls the sidebar 810 pt forward in both appearances and sidebar modes. Each matrix includes page snapshots, app-owned opaque sidebar bitmaps, and geometry JSON. The opaque bitmaps verify layout and artwork under the background policy. Live Liquid Glass, active focus decoration, and the spoken VoiceOver traversal require the screen checks below.

Both runs produced 116 verified evidence PNGs across 58 scenes, with zero activation, frontmost, or display-overlap violations. In the 1,280 pt fixture, the expanded shell measured 296 pt and regular rows measured 280 × 36 pt with 8 pt outer and inner insets. The pinned cells measured 56 × 48 pt in both runs. The rendered rail kept 42 × 36 pt cells with 7 pt side insets at the top and after scrolling. The four paired comparisons showed matching favicon centers, pill placement, and scroll order. Section heading text aligned within half a point. The expanded system legacy scroller can reserve its normal gutter. An AppKit overlay scroller can appear in the rail without changing its viewport width.

- [Light expanded](compare-light-expanded.png) and [dark expanded](compare-dark-expanded.png)
- [Light rail](compare-light-rail.png) and [dark rail](compare-dark-rail.png)
- [Baseline manifest](before/manifest.json) and [candidate manifest](after/manifest.json)

## Verification

An exploratory test run recorded an unexpected test-host activation under background mode, with zero display overlap. The arrow regression now exercises the list’s native responder directly inside the owned window. The focused regression run passed 12 tests with zero background UI violations. The first complete run of the revised layout passed all sidebar suites. XCTest aborted after the existing WebKit frame-sequence test in its observation callback, and the gate reported a failure. The serial retry passed the entire gate on macOS 27.0.1 with Xcode 27.0. XCTest ran 230 Mac tests, with 219 passed, 11 skipped, and zero failed. The background audit recorded 4,077 frontmost checks and 12,803 window-frame checks with zero activation, frontmost, or display-overlap violations. The shared suite, generic iPhone Simulator build, signature and entitlements checks, and all 9,717 contrast checks passed. The built Mac and iPhone property lists both reported 0.17.0 (32). [Local gate log](local-gate-retry.log) · [Mac test result](../browser-quality.tyKPT9/BrowserTests.xcresult)

| Mac suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| ChromeFocusTests | 6 | 0 | 0 |
| SidebarBehaviorTests | 22 | 0 | 0 |
| SidebarGlassTests | 18 | 1 | 0 |
| SidebarLayoutTests | 15 | 2 | 0 |
| Entire Mac suite | 219 | 11 | 0 |

Hosted CI passed at code commit `4c0fab8` on macOS 26.7.2. XCTest ran 230 Mac tests, with 217 passed, 13 skipped, and zero failed. The audit recorded zero activation, frontmost, and display-overlap violations. The workflow uploaded the `browser-quality` artifact. The temporary branch was deleted, and remote `main` was verified at `bddbdfb`. [Browser quality run](https://github.com/santhoshbalaji/Oriv/actions/runs/44511850741)

## Foreground checks for the orchestrator

1. In the isolated development app, open a synthetic profile with nine pinned tabs, at least 40 regular tabs, and one private tab. In Light and Dark, inspect the sidebar over a bright page and a dark page. Verify the glass shows between rows, header counts are readable, the pinned grid wraps 4+4, overflow has a title, and the selected pill and hovered row are distinct.
2. Click a tab and then the sidebar toggle. Check that a pointer click leaves no focus ring. Use Tab or Shift-Tab to reach the list, then arrows and Return. Verify the system ring tracks keyboard focus. Repeat with System Settings → Accessibility → Keyboard → Full Keyboard Access enabled. Exercise Option-Command-S, Shift-Command-A, Command-T, and Control-Tab after a pointer click, verify these shortcuts leave no ring, then navigate by keyboard again.
3. Restore a profile with sleeping tabs. Hold Down or press it rapidly from the focused list. Confirm the page stays put during rapid movement and only the paused-on tab loads. Move again and press Return to check immediate activation. Repeat from a filtered result and use Escape to clear the filter.
4. Set System Settings → Appearance → Show scroll bars to Always. Collapse with Option-Command-S. Scroll up and down with a trackpad or mouse, then navigate to the last row by keyboard. Verify icons remain centered and selection stays inside the 56 pt rail. Expand again and check the scrollbar scrolls the list independent of the page.
5. In the expanded sidebar, drag a regular tab across several peers, then onto Pinned. Drag it onto Tabs to unpin. Drag in the grid and rail to reorder. Try moving a private tab into the regular group and confirm the drop is rejected. Check pointer hover, the close glyph, middle click on a regular tab, and right-click menu actions. Enable hover-peek and verify icons stay in place as titles appear.
6. Turn on VoiceOver and navigate into Sidebar tabs from the search field. Check headings, row order, the selected state, pinned and private announcements, and the row's Close Tab action. Scroll to an off-screen row and check it enters the traversal.
