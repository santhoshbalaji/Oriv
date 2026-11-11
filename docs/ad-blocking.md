# Built-in ad blocking

Oriv uses public WebKit content rules in both normal and private tabs. The shield beside the address field opens the controls; Settings also exposes the global mode and saved regular-site exceptions.

| Mode | Behavior |
| --- | --- |
| Off | Removes Oriv's content rules. |
| Balanced (default) | Uses the supported network subset of EasyList and EasyPrivacy, respecting each filter's party/resource scope. Adds light generic class/ID cosmetics. |
| Strict | Adds broader EasyList cosmetics and the original first-party analytics supplement. |

The mode applies per profile, including that profile's private tabs. “Block on this site” applies to the exact hostname, across schemes and ports; it does not implicitly exempt sibling domains or subdomains. Regular exceptions are saved locally. Private exceptions are separate, stay in memory and are erased when the last private tab closes. No private hostname is written into a compiled rule list or saved preferences.

Changing a setting updates existing WebKit controllers and subsequent loads. Use **Reload page** to remove already loaded ads or restore hidden elements. Tabs are not automatically reloaded, preserving unsaved form contents. The interface does not invent a blocked-request count: the public rule-list API does not supply one.

## Implementation

`AdBlocker` is in the shared BrowserEngine package and compiles for macOS and iOS. `BrowserTab` waits for rules before allowing a main-frame navigation, so the first load is protected. Compilation failure stops that load and shows a recoverable error; it does not silently browse unfiltered. The user can explicitly choose Off. Compiled rules are cached under a digest of their contents.

Each tab owns its user-content controller, including WebKit-created popups. The original popup request, website data store, opener semantics and supplied user scripts are preserved. Filters update on redirects before the destination's subresources load. Private tabs retain the ephemeral website data store and remain excluded from history/session persistence.

The maintained EasyList/EasyPrivacy/Cookie adaptations, version and conversion counts are bundled under `Packages/BrowserKit/Sources/BrowserEngine/Resources/Privacy/`, separately licensed CC BY-SA 3.0. The original first-party Strict supplement remains in `AdBlockingRules`. An original reproducible converter and compact, digest-checked resources keep unsupported syntax observable without a runtime updater. [Privacy controls](privacy.md) describes the conversion subset, licence route, cookie layer, navigation cleaning, HTTPS and GPC. Updates ship only with app releases.

The maintained network subset excludes top-level document blocking. Media, style and font filters follow supported upstream resource options. The original Strict supplement excludes media, styles and fonts. They can still block a script that a player needs; use the per-site switch when a page breaks. Blocking does not guarantee removal of first-party or server-inserted video ads, including YouTube ads, and it is not a malware or complete tracking protection service.

## Verification

`AdBlockingTests` uses local resources with deterministic compiled rules to verify actual request blocking in normal/private tabs, first-load behavior, all three modes, reloads, exceptions, redirect scoping, popup isolation, private-session cleanup and failure recovery. A separate test compiles the shipping rules and checks Strict cosmetic filtering. Network test domains are not added to the shipping list.

Apple references: [WKContentRuleList](https://developer.apple.com/documentation/webkit/wkcontentrulelist), [WKContentRuleListStore](https://developer.apple.com/documentation/webkit/wkcontentruleliststore), and [content-blocker rule syntax](https://developer.apple.com/documentation/safariservices/creating-a-content-blocker).
