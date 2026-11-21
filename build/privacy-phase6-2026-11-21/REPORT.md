# Oriv Phase 6 privacy report

Implemented from the task brief at base `531061a` (0.21.3). The referenced plan was absent from this worktree.

## Forget This Site

| Area | Behavior |
| --- | --- |
| Scope | Current regular profile. A bundled Mozilla Public Suffix List (ICANN and PRIVATE sections, including wildcards and exceptions) determines the registrable domain. IP addresses are canonicalized and single-label names such as localhost match exactly. |
| WebKit | Removes the matching records for all types returned by `WKWebsiteDataStore.allWebsiteDataTypes()` and deletes matching cookies through `WKHTTPCookieStore`. WebKit exposes records grouped by registrable domain. [WKWebsiteDataRecord](https://developer.apple.com/documentation/webkit/wkwebsitedatarecord) |
| History and suggestions | Deletes matching local and previously synced SQLite rows, invalidates history-derived suggestions and frequently visited tiles, and removes matching recently closed entries. Retained bookmarks and open tabs may still appear as suggestions. |
| Site icons and snapshots | Removes in-memory and disk site icons associated with the site and invalidates matching tab snapshots. The first purge also removes any legacy regular-profile PNG cache files because their flat hashed filenames cannot be mapped back to a domain. |
| Tabs | Retains tab IDs, URLs, ordering, and pins. Live tabs reload in fresh WebKit contexts, dropping session storage and their WebKit back/forward stacks. Dormant tabs load fresh on selection. The automatic reload skips visit recording. Sites can create fresh state on reload. |
| Entry points | Mac Browser Actions and Library history row context menu. iPhone Page Menu. Each confirmation names the domain and describes cookie, website data, and history deletion. Private page menus omit the command. |
| Continuity | Persists a site cutoff with the local SQLite deletion and publishes it through the existing encrypted `BrowserRecordV1.body` field. Updated devices remove matching visits at or before the cutoff, including offline history arriving later. Known redacted visits become ordinary history tombstones. Later visits, bookmarks and other profiles remain intact. Website data is device-local. No CloudKit schema deployment is required. |

## CNAME-cloaked trackers

The pinned AdGuard MIT-licensed disguised tracker list covers **306,627 unique hosts**. The **13,476** listed parent hosts already cover **140,647** listed descendants. The converter emits two fixed URL endings per retained host to cover ordinary and trailing-dot hostnames while letting WebKit share the host trie. There are **331,960** rules in four chunks of **85,000**, **85,000**, **85,000**, and **76,960**. The packed resources total **2.89 MiB**. Standard (Balanced) and Strict attach both chunks through the existing shared compiler. Off and per-site ad-blocking exceptions leave them detached. URL filters match the destination host regardless of first- or third-party classification. Main documents are excluded from the resource types, so direct navigation remains available. Updates ship with Oriv releases. Instructions and attribution are in the converter, privacy documentation, bundled manifest, and acknowledgements. [AdGuard CNAME trackers](https://github.com/AdguardTeam/cname-trackers/tree/dd5bd59eda209a97efeee1ee7898e119c582a13b)

## Verification

The converter tests passed 8 of 8. A rebuild from the pinned source cache reproduced the bundled manifest and rules byte for byte. Shared tests cover label boundaries, public and private suffixes, wildcard/exception rules, IDNs, IPv4, IPv6, localhost, SQLite deletion, suggestion and frequent-site invalidation, and unseen visits arriving through Continuity.

The native test uses a nonpersistent WebKit store to verify cookie, local storage, and session storage deletion, history removal, tab and bookmark preservation, and profile isolation. A loopback-only synthetic proxy serves a listed hostname to WebKit. Direct navigation works, while the same-origin script is blocked in Balanced and Strict and loads with an ad-block exception or Off. The Mac off-screen Page Menu tests exercise the existing presentation path. Menu-item selection and confirmation UI are owner checks.

Cold compile measurements use a fresh WebKit rule-cache namespace. The existing components and the added CNAME components are measured separately in the same runs. Warm results are cached lookups. The initial wildcard and per-host optional suffix designs missed the first-navigation test’s 40-second deadline. The fixed URL endings resolved that failure. [WebKit compiler implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/CombinedURLFilters.cpp)

| Platform | Existing components, cold | CNAME components, cold | CNAME cache lookup |
| --- | ---: | ---: | ---: |
| macOS 27.0.1 | 8.51 s | 13.14 s | <1 ms |
| iOS 26.5 simulator | 9.10 s | 13.77 s | 1.22 ms |

### Gates

- `ORIV_BACKGROUND_UI=1 ./scripts/check-browser.sh` passed, including the generic iPhone build, 169 BrowserKit tests, 281 passing native Mac tests, 11 foreground or opt-in skips, and signing, entitlement, scope, background-UI, contrast and diff checks.
- The Mac test host ran the worktree’s debug app in background mode. Privacy tests audited zero frontmost, activation or on-screen window violations. A focused Mac rerun passed after disabling favicon discovery in the synthetic CNAME fixture.
- `ORIV_IOS_SIMULATOR_ID=<id> ./scripts/check-iphone.sh` passed on a dedicated iPhone 17 simulator running iOS 26.5. Of 106 selected tests, 103 passed and 3 skipped for opt-in live sites, OS 26 GPC availability, and service-worker entitlement availability. The dedicated simulator was deleted and its absence verified.
- Both gates passed the Forget This Site and same-origin CNAME integration tests. Cold CNAME compilation is a first-use cost for new bundled content. WebKit reused the compiled lists by digest in the warm run.

- Publication check uses `python3 scripts/check-public-safety.py --range origin/main..HEAD`.

## Owner checks

- On Mac, confirm the menu item in Browser Actions and a Library history row. On iPhone, confirm the Page Menu entry. Cancel once and verify the site still has its data, then confirm deletion. Check that the action is absent in a private page menu.
- In two regular profiles, sign into the same test site. Forget it in one profile and confirm the other profile retains its login, history, and icons.
- With Continuity enabled on updated devices, leave one device offline with a visit to a sibling subdomain. Forget the site and reconnect. Confirm the old visit disappears and a new visit can still sync. Production-account CloudKit and physical-device UI were not exercised in this worktree.
