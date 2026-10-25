# Built-in ad blocking

Oriv 0.3.0 uses public WebKit content rules in both normal and private tabs. The shield beside the address field opens the controls; Settings also exposes the global mode and saved regular-site exceptions.

| Mode | Behavior |
| --- | --- |
| Off | Removes Oriv's content rules. |
| Balanced (default) | Blocks third-party requests to the bundled advertising and tracking domains. Keeps cosmetic filtering off for compatibility. |
| Strict | Also filters first-party matches and additional analytics domains, and hides a short list of common ad-slot selectors. |

The mode is global, including private tabs. “Block on this site” applies to the exact hostname, across schemes and ports; it does not implicitly exempt sibling domains or subdomains. Regular exceptions are saved locally. Private exceptions are separate, stay in memory and are erased when the last private tab closes. No private hostname is written into a compiled rule list or saved preferences.

Changing a setting updates existing WebKit controllers and subsequent loads. Use **Reload page** to remove already loaded ads or restore hidden elements. Tabs are not automatically reloaded, preserving unsaved form contents. The interface does not invent a blocked-request count: the public rule-list API does not supply one.

## Implementation

`AdBlocker` is in the shared BrowserEngine package and compiles for macOS and iOS. `BrowserTab` waits for rules before allowing a main-frame navigation, so the first load is protected. Compilation failure stops that load and shows a recoverable error; it does not silently browse unfiltered. The user can explicitly choose Off. Compiled rules are cached under a digest of their contents.

Each tab owns its user-content controller, including WebKit-created popups. The original popup request, website data store, opener semantics and supplied user scripts are preserved. Filters update on redirects before the destination's subresources load. Private tabs retain the ephemeral website data store and remain excluded from history/session persistence.

The original, bundled rules live in `AdBlockingRules` in `Packages/BrowserKit/Sources/BrowserEngine/AdBlocker.swift`, version `2026.10.25`. They use a bounded set of common advertising domains, additional analytics domains in Strict, and narrowly named cosmetic selectors. There are no downloaded filter lists, third-party extension binaries, runtime script injection, provider accounts or outbound telemetry. Rules update with Oriv releases; this is not an EasyList or uBlock Origin implementation.

The network filters deliberately exclude top-level navigation, media resources, styles and fonts. They can still block a script that a player needs; use the per-site switch when a page breaks. Blocking does not guarantee removal of first-party or server-inserted video ads, including YouTube ads, and it is not a malware or complete tracking protection service.

## Verification

`AdBlockingTests` uses local resources with deterministic compiled rules to verify actual request blocking in normal/private tabs, first-load behavior, all three modes, reloads, exceptions, redirect scoping, popup isolation, private-session cleanup and failure recovery. A separate test compiles the shipping rules and checks Strict cosmetic filtering. Network test domains are not added to the shipping list.

Apple references: [WKContentRuleList](https://developer.apple.com/documentation/webkit/wkcontentrulelist), [WKContentRuleListStore](https://developer.apple.com/documentation/webkit/wkcontentruleliststore), and [content-blocker rule syntax](https://developer.apple.com/documentation/safariservices/creating-a-content-blocker).
