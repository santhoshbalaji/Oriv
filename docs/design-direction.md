# Oriv — native workspace design

The current 0.5 direction is defined in [the Oriv design system](design-system.md). The notes below retain the earlier layout rationale.

The Mac browser should feel like a quiet, carefully composed Apple application. Its primary job is to make a page easy to reach and keep useful pages close. The iPhone interface will share the model, not copy desktop geometry.

## Contextual Workspace (0.4.0)

The productivity workspace uses a separate native three-column window: scope, saved items, and item detail. It preserves a full browser beside it and opens a saved item from a notification or Command-D. Overview, Content and Activity keep actions/notes, captured evidence and personal history distinct. The source title and purpose establish context before the controls.

System NavigationSplitView, toolbars and `.glass` / `.glassProminent` controls provide Liquid Glass. Long-form content stays on a readable semantic surface; no blur is layered behind saved text. SF Symbols, system text styles, native segmented controls, date pickers, keyboard shortcuts and contextual help keep interaction consistent with macOS. Search includes saved content; empty states explain what to do. Archive and Trash remain recoverable and visibly pause reminders. Note editing opens a dedicated sheet and preserves earlier revisions.

Actual app evidence and accessibility limits are recorded in the [0.4.0 release report](releases/0.4.0.md). This extends the prior browser design; the existing icon and web-page chrome are retained.

## References and decisions

- [Apple toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars): standard controls, logical action groups, restrained chrome and menu equivalents.
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass): use system navigation materials; avoid layering simulated glass on content. Respect transparency, contrast and motion settings.
- [Apple sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars): familiar sidebar selection and a clear hierarchy.
- [Apple accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): labeled controls, keyboard operation, semantic colors and multiple cues for state.
- [Safari start page](https://support.apple.com/guide/safari/customize-your-start-page-ibrw01514823/mac): useful favorites and recent browsing, generous but purposeful space.
- [Arc command bar](https://start.arc.net/command-bar-actions): fast keyboard access and compact vertical organization. This is a design reference, not a runtime dependency or recommendation to adopt Arc.

## Tokens and layout

Use adaptive AppKit/SwiftUI semantic colors. Light reference values: canvas #F5F5F7, content #FFFFFF, ink #1D1D1F, secondary ink #6E6E73, ocean accent #007AFF, private violet #AF52DE. Dark appearance uses system equivalents. Color is always paired with text, selection or an icon.

San Francisco is the sole UI type family. Use a 34-point rounded, medium greeting; 17-point section headings; 13-point body/controls; 11–12-point metadata. Prefer standard system text styles for controls and lists. Content is left aligned; favorite launchers are centered within their grid cells.

Spacing follows 4/8/12/16/24/32 points. Sidebar width is 240 points, adjustable from 210 to 300. Start-page content has a 740-point maximum measure and flexible outer margins. The signature is a broad, usable search surface above favorite launchers and compact recent pages. Rounded surfaces indicate interactive content; they are not a universal card wrapper.

```text
┌ traffic lights / sidebar ┬ back forward   [ address / search ]  actions ┐
│ Personal           +  ⋯  │                                             │
│ Search tabs              │ Good morning.                  Sun, Oct 25  │
│                          │ Search the web or enter a website            │
│ Tabs                     │ [ real editable search                     ]│
│  site / title      close │                                             │
│  selected page     close │ Favorites                                   │
│                          │  icon       icon       icon       icon       │
│ Private tabs             │  name       name       name       name       │
│  private page      close │                                             │
│                          │ Recently visited                  Show all  │
│                          │  page + domain         page + domain        │
│                          │                                             │
│ Library     bookmarks ↶ ↓│  Private tab       Reopen tab               │
└──────────────────────────┴─────────────────────────────────────────────┘
```

Review: oversized product branding adds little to a browser. Remove it, reduce toolbar duplication, and use the start page for actual search and local navigation. No invented AI, Spaces, sync or security counters. Keep browser content full size when a website opens.

## Interaction and accessibility

- Command-L focuses and selects the native address field. Return navigates; Escape restores the current URL. New tabs focus that field.
- Start-page search is editable and offers local matches from open regular tabs/bookmarks/history. Private tabs do not surface regular history in suggestions.
- Sidebar selection remains a native List with keyboard navigation. Tab search stays local.
- Close controls remain accessible; context menus expose duplicate and close actions.
- Library search has a meaningful no-results state. Bookmarks/history/downloads use consistent rows and native controls.
- Preserve WebKit views, private data stores and session recovery.
- No automatic animation. Use standard navigation materials, semantic colors and system focus rings. Respect reduced transparency in custom surfaces.
- Verify screenshots of the real app, keyboard navigation, narrow layout and appearance variants. Documentation alone is not complete HIG or accessibility verification.

## Verification — 25 October 2026

The implemented Mac app was inspected on macOS 27.0.1 with Xcode 27. Native system appearance was restored after testing the app's Light and Dark settings.

| Area | Result |
| --- | --- |
| Address and navigation | Command-L selects the current address; Return loads a real HTTPS page; Escape restores the address; Command-T focuses the new tab address. |
| Sidebar | Matching and empty filter results work; creating a tab clears an incompatible filter. |
| Library | History, search and no-results views render; Command-W dismisses the library without closing the selected tab. |
| Private browsing | Distinct text/icon treatment; suggestions exclude regular tabs, bookmarks and history. Automated privacy-boundary test passes. |
| Window adaptation | Toolbar address remains visible at 901 points wide; the start page scrolls at 561 points high. |
| Reopen tab | Closing a tab immediately enables Reopen; activating it restores the closed page. |
| Builds and tests | Mac build and code-signature verification pass. Eight core tests and seven integration tests pass. Shared modules build for the arm64 iPhone simulator, targeting iOS 26. |

Actual app captures: dark start page (`qa/redesign/start-dark.png`, local QA artifact), light start page (`qa/redesign/start-light.png`, local QA artifact), website (`qa/redesign/browsing-dark.png`, local QA artifact), library (`qa/redesign/library-light.png`, local QA artifact), private tab (`qa/redesign/private-light.png`, local QA artifact), and compact window (`qa/redesign/compact-light.png`, local QA artifact).

Full VoiceOver, Full Keyboard Access, Increase Contrast and Reduce Transparency audits remain release checks. iPhone interface and device validation are a later milestone. These checks establish a locally verified Mac implementation, not complete HIG/accessibility conformance or distribution readiness.

## Topbar and sidebar refinement

The standard unified toolbar gives the address control even vertical clearance. Its width adapts to the window and reserves additional room for window controls when the sidebar is hidden. The address field has a 28-point content height and a 24-point reload target; its focus outline clears on Escape or ending editing.

The sidebar uses a compact 13-point title, 28-point search field, 42-point minimum tab rows and 24-point site identities. The tab count sits next to its section label. New-tab creation is next to the sidebar title; bookmarks, history and downloads use a single compact footer with accessible labels and help text.

The refinement was rebuilt and checked in the running app at normal size and approximately 900 points wide, with the sidebar visible and hidden. The address field and all primary toolbar actions remain visible. Sidebar new-tab creation, Command-L/Escape focus handling, History access and Command-W sheet dismissal were verified. The original two tabs and window size were restored after checking. This UI-only pass used build/signature and interactive checks; the 15 automated test results above are from the preceding redesign pass.

Updated captures: normal window (`qa/redesign/chrome-after.png`, local QA artifact), browsing (`qa/redesign/chrome-browsing-after.png`, local QA artifact), compact window (`qa/redesign/chrome-compact.png`, local QA artifact) and sidebar hidden (`qa/redesign/chrome-sidebar-hidden.png`, local QA artifact).

Raw QA captures and build logs referenced here are retained locally and excluded from the public repository. Published synthetic-content screenshots are in `docs/images/`.
