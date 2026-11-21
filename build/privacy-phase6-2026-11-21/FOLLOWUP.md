# Phase 6 privacy follow-up

## Deferred CNAME protection

Profile activation starts core rule preparation. First navigation waits for the same core components as 0.21.3. Once core preparation succeeds, a separate background-priority task compiles the four CNAME components. Profiles share the bundled compilations. The app attaches the completed CNAME lists on the main actor to the weakly tracked live content controllers. It checks the current mode and the latest policy host against the appropriate regular or private exception set. The same installation diff serves navigation, preference changes and late attachment.

Late attachment covers new requests from documents that are already open. A request completed before attachment can still load. If CNAME preparation fails, the app logs a numeric error code, displays a status message in privacy settings and continues with core protection. The CNAME task can try again on the next app launch.

## Rule count and coverage

The pinned upstream input has 306,627 unique hosts. The converter already removes all 140,647 descendants of listed parents, leaving 165,980 retained hosts. Independent suffix enumeration and a rule-for-rule comparison against the four decompressed bundles verified these counts. Together the bundles contain 331,960 rules and occupy 3,031,988 bytes (2.89 MiB). Each retained host has separate endings for ordinary and trailing-dot host names.

Collapsing siblings under an unlisted parent changes the block set. For example, a rule for the unlisted `0.hb-api.tt.omtrdc.net` would block unlisted siblings of the listed `brcn-us2ssldel.0.hb-api.tt.omtrdc.net` and `ca-familyuatadmin1.0.hb-api.tt.omtrdc.net`. The shipped bundles retain the existing block set. [Pinned AdGuard source](https://raw.githubusercontent.com/AdguardTeam/cname-trackers/dd5bd59eda209a97efeee1ee7898e119c582a13b/data/combined_disguised_trackers_justdomains.txt)

A windowless Mac command-line control merged each host’s two endings into a single optional-dot expression with identical match semantics. It halved the count to 165,980 and reduced bundled input to 2,234,635 bytes (2.13 MiB). In fresh WebKit stores, all four shipped chunks compiled in 13.82 s. The optional-dot control had compiled three of four chunks at the 45 s cutoff. Those three files totaled 131,932,702 bytes, compared with 112,326,517 bytes for the corresponding shipped chunks. The implementation keeps the fixed endings.

## Cold navigation and WebContent measurements

Each configuration ran twice on macOS 27.0.1 with `ORIV_BACKGROUND_UI=1` and twice on an iPhone 17 simulator running iOS 26.5. A hosted native test mounted one tab in a nonpersistent WebKit store and activated its session and submitted the navigation together. The timer ended at WebKit’s `didCommit`. A fresh rule namespace per run forced cache misses and the test checked each component’s cache result. The 0.21.3 and all-gating builds came from the actual source revisions, `531061a` and `9b567a4`.

The page and script were served through a loopback-only proxy. The timing fixture’s host is covered by the core lists too. The deferred-attachment integration test isolates CNAME by giving the core test list an unrelated domain.

The reported cache sizes are the logical sizes of WebKit’s compiled files for all components in a fresh namespace. The WebContent RSS readings use the fixture view’s own PID and host `ps`, with five quarter-second readings per checkpoint. Each pair below shows the two runs’ checkpoint medians. The first checkpoint is just after the fixture’s initial script resolves. The final checkpoint follows a dynamic script request on the same view, after late attachment in the deferred configuration. The WebContent RSS reflects resident pages on this single fixture and varies with process age and paging.

### First committed navigation

Each cell gives the median in seconds, followed by the two samples.

| Platform | 0.21.3 core gate | Deferred CNAME | All lists gating |
| --- | ---: | ---: | ---: |
| macOS 27.0.1 | **8.80** (9.05, 8.56) | **8.82** (8.83, 8.82) | **22.23** (22.16, 22.30) |
| iOS 26.5 simulator | **9.02** (9.25, 8.79) | **8.99** (9.13, 8.85) | **23.33** (23.47, 23.19) |

Median CNAME compilation time per cold run was 15.12 s on Mac and 15.62 s on the simulator in the deferred build. The all-gating build spent 13.21 s and 13.98 s respectively compiling the same four chunks.

### Compiled cache files

| Platform | Core only | CNAME addition | Total |
| --- | ---: | ---: | ---: |
| macOS 27.0.1 | 97,948,672 bytes (93.41 MiB) | 145,781,734 bytes (139.03 MiB) | 243,730,406 bytes (232.44 MiB) |
| iOS 26.5 simulator | 97,947,864 bytes (93.41 MiB) | 145,781,734 bytes (139.03 MiB) | 243,729,598 bytes (232.44 MiB) |

The four CNAME files were 37,798,610, 37,582,929, 36,944,978, and 33,455,217 bytes on both platforms.

### WebContent RSS, MiB

| Platform | Build | After initial script | After final script |
| --- | --- | ---: | ---: |
| macOS 27.0.1 | 0.21.3 | 42.1, 42.0 | 35.5, 42.7 |
| macOS 27.0.1 | Deferred CNAME | 42.0, 42.0 | 28.6, 30.1 |
| macOS 27.0.1 | All lists gating | 31.8, 43.2 | 36.7, 43.8 |
| iOS 26.5 simulator | 0.21.3 | 135.9, 107.1 | 136.4, 87.9 |
| iOS 26.5 simulator | Deferred CNAME | 137.1, 138.4 | 130.0, 111.1 |
| iOS 26.5 simulator | All lists gating | 109.9, 133.5 | 109.2, 125.6 |

The deferred rows are paired measurements from the same WebContent PID before and after attachment. The all-gating rows have CNAME attached at both checkpoints. RSS varied across the runs, with no consistent increase attributable to CNAME on this fixture. The compiled cache addition was stable across runs.

## Continuity

0.21.2 (`74a1726`) and 0.21.3 (`531061a`) have identical record decoding and CloudKit transport. Their decoder recognizes the `clear.` ID prefix and returns nil for an unknown payload kind before decoding the closed Swift enum. Fetch records the unknown key, continues through the page, and advances the token after the complete fetch. The unknown record remains opaque in the transport's server cache. Push also refuses to overwrite an unknown record at the same key.

Executed the 0.21.3 decoder and replica merge with a synthetic mixed batch containing a visit, a Phase 6 cutoff body, and a bookmark. The visit and bookmark merged, existing history survived, and the cutoff produced no record or tombstone. Older clients still apply ordinary history tombstones emitted for known redacted visits. Enforcement of the cutoff against previously unseen or offline visits requires an updated client. The compatibility probe exercised decoding and merge locally.

## Verification

- The three new native regressions passed on Mac and iOS 26.5. They hold back CNAME during navigation, exercise new requests in already-open tabs, and check the private exception set, Off, duplicate installs, and compile failure. The existing bundled-list and cold/warm compile tests also passed on both platforms.
- The iPhone gate passed with 106 passing tests and three skips on the dedicated iPhone 17 simulator. A fresh DerivedData directory resolved a stale build cache that failed to find `BrowserSite` on the initial attempt. The temporary simulator was deleted and its absence verified.
- The full Mac gate remains red. The first run executed 295 native tests, with 283 passes, 11 skips, and one failure in `testNativeArrowNavigationInShortWindowsAtOnePointScale`. The isolated retry passed that test and all privacy cases. During the sidebar reorder and search budget test, the background audit recorded 13 frontmost samples, one activation, and zero display overlaps despite `ORIV_BACKGROUND_UI=1`. The test runner restarted after an XCTest assertion, and the retry was interrupted. The background-mode privacy and timing runs reported zero focus, activation, and display violations.
- The generic iPhone build and 169 shared tests passed in the Mac gate. Mac code signature and entitlements were verified separately after the interruption. All eight converter tests passed.
- The outgoing range scan uses `python3 scripts/check-public-safety.py --range origin/main..HEAD`.
