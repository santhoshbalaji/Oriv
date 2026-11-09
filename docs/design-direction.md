# Oriv browser direction

The current direction is a privacy-first, performance-conscious native browser on Mac and iPhone. The browser is the product: reaching a page, understanding its origin, keeping tabs organized, finding saved links and controlling local website data should be direct and predictable.

The authoritative interaction rules are in [the browser design system](design-system.md). [Appearance](appearance.md) defines the shared T3 Code palette. The Mac uses a sidebar and native toolbar; the iPhone uses one browser screen with focused sheets. They share session behavior and theme roles while retaining platform-specific layouts.

The earlier Workspace design is retired from the active product. Browser profiles isolate local tabs, bookmarks, history, website logins and preferences. Optional Mac and iPhone continuity is implemented as opt-in, metadata-only sync through iCloud in a configured Continuity build: profile identity, regular tabs, bookmarks, history and allowlisted profile preferences. Website logins, cookies and passwords stay on the device inside their profile and are not synced. Tasks, AI, dashboards and source-monitoring status remain outside the active product. See [browser continuity](browser-continuity.md).

The current UX implementation addresses the observed privacy indicators, edited-form closing, large-text appearance picker, address suggestions, mobile navigation, Library grouping, data controls and feedback. Bottom-address placement and collapsing chrome remain design experiments requiring real-phone testing. They are not implied by the shared dark palette.

The current evidence and remaining acceptance work are in [the UX implementation report](ux-implementation.md). Historical release reports describe their own versions and are not current product specifications.
