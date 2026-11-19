# Oriv 0.16.0 build 31 validation

## iOS 27 compatibility

**Build 31 at `cad5d82` passed the full iOS 27 suite with 178 passed, three skipped and zero failed out of 181.**

The build 30 control run at `950f094` completed all 181 tests on the dedicated iPhone 18 Pro simulator running iOS 27.0 (24A434). XCTest counted 176 passes, three skips and two failed tests. The redirect and download policy test passed with the attachment-policy fix already present in build 30.

The edited-field fixture drove an unattached WebKit view while iOS 27 was suspending its WebContent process. The test now attaches the view to the existing simulator window before navigation, polls for the bridge signal, and requires the second document to finish and reset the edit flag. The grid fixtures now navigate and capture each WebKit view while its tab is mounted. The grid color test starts recording at the action and samples through the observed end of the transition. Its earlier 900 ms capture ended before the final color appeared. It still checks every recorded frame, the final pixel and the minimum sample count. The updated grid and chrome fixtures passed 26 focused tests.

Later full runs found a collection-view crash when a tab closed before grid layout. UIKit was reading the replacement data-source counts before the delete transaction began. The controller now changes the counts inside the batch and reloads grids before their initial layout. The motion fixture waits for the grid and web geometry to be ready, samples committed frames and slows the fixture window’s local Core Animation clock so simulator scheduling can deliver frames at the original progress checkpoints. The animation driver uses the presented transform during frames before UIKit exposes the animation begin time.

The final harness waits for both local fixture processes to bind and verifies their responses before starting XCTest. An interrupted rerun exposed a port collision during the previous harness teardown. The full suite used `xcodebuild test` with serial test execution, a 120-second per-test watchdog, local HTTP fixture servers and automatic diagnostic collection disabled. It used the dedicated simulator headlessly. The three existing iOS 27 skips cover opt-in Instruments, opt-in live sites and the managed default-browser entitlement. The previous iOS 26.5 result at `950f094` was 177 passed, four skipped and zero failed.

[Final iOS 27 result](iPhone27Build31Clean.xcresult) · [iOS 27 build 30 control](iPhone27Initial.xcresult) · [Updated focused fixtures](iPhone27FixtureChecks.xcresult) · [iOS 26.5 build 30](iPhone26Tests.xcresult)

## 50,000-visit history benchmark

The product changes release the SQLite connection between batches and reapply concurrent mutations before publishing the seed. An already-migrated store skips schema and retention writes during startup. A bulk seed resolves each URL authority once and avoids retaining a second joined search string per entry. Compact postings retain addresses for selective terms and counts for common terms. A dense array stores suggestion records, with a separate address-to-offset lookup. Clear History invalidates the index in one operation and keeps SQLite secure deletion enabled.

The probe uses the production session, window or root view, database and suggestion actor in an instrumented optimized XCTest host. Five process launches per case ran on an Apple M4 Pro with macOS 27.0.1 and Xcode 27.0 (27A266a). The fixture used 50,000 distinct synthetic HTTPS visits across 1,200 hosts, with timestamps, titles, a 500-entry shared projection and typed weights. The measured database was populated before launch. The launch clock starts at process creation and ends at the first laid-out browser window ready for input. The Mac uses the app's own offscreen window under the background UI policy. The iPhone uses the simulator scene's laid-out key window.

Resident memory is the difference between the two median app-process RSS measurements, sampled one second after confirming the index can return the final synthetic visit. It excludes separate WebKit processes. The probe records the synchronous history setup's main-thread CPU and wall time and polls the production recent-history read during seeding. Clear History is timed through a follow-up query that returns no erased suggestions. The probe then verifies the SQLite visit count is zero. The fixture has no populated favicon cache or enabled CloudKit account.

| Metric | Mac | iPhone 18 Pro Simulator, iOS 27.0 |
| --- | ---: | ---: |
| Cold launch, empty history, median | 605 ms | 1,307 ms |
| Cold launch, 50,000 visits, median | 639 ms | 1,338 ms |
| Suggestion seed, median / max | 581 / 592 ms | 646 / 683 ms |
| History setup on main, max wall / CPU | 2.80 / 1.37 ms | 5.48 / 2.37 ms |
| Recent-history read on main during seed, max wall | 2.51 ms | 1.85 ms |
| App-process RSS, empty / 50,000 visits | 280.5 / 340.8 MiB | 358.6 / 400.1 MiB |
| Added resident memory | 60.3 MiB | 41.5 MiB |
| SQLite file, 50,000 visits | 21.06 MiB | 21.09 MiB |
| Clear History call, median | 136 ms | 202 ms |
| Clear through verified suggestion erasure, median / max | 149 / 187 ms | 221 / 261 ms |

An earlier iPhone run recorded a 48.4 ms recent-history read without lock or CPU timing. Instrumented follow-up captured a 19.7 ms read with 1.6 ms of main-thread CPU and 0.001 ms waiting on the SQLite lock. That traced the follow-up spike to time when the simulator thread was off CPU. All sampled main-thread history work during launch and seeding with 50,000 visits in the final build stayed below 16 ms. An empty-store iPhone launch recorded as much as 20.23 ms of synchronous setup wall time and 15.47 ms of main-thread CPU, including SQLite setup. All final seeds finished within one second. The Mac RSS increase was 60.3 MiB, above the roughly 50 MiB target. The iPhone increase was 41.5 MiB.

In the build 30 Mac control, median seed time was 4,609 ms, added RSS was 251.5 MiB, the longest sampled main-thread recent-history read was 180.6 ms, and median clear through suggestion verification was 2,870 ms.

[Raw samples and summaries](probe/summary.json) · [Diagnostic iPhone log](probe/diagnostic-phone-large.log) · [Probe instrumentation](probe/instrument.py) · [Probe runner](probe/run.sh)

The optimized 50,000-entry keystroke benchmark ran 30 queries per case. The highest query p95 was 0.306 ms and the slowest individual query was 0.338 ms. [Release-mode query log](history-authority.log)

## Release gates

Local `ORIV_BACKGROUND_UI=1 ./scripts/check-browser.sh` passed at `cad5d82`. The Mac suite recorded 227 passed, 11 skipped and 0 failed. The gate also built the iPhone Simulator app for arm64 and x86_64 and passed shared tests, public safety, browser scope, contrast, signature, entitlements and whitespace checks. The Mac background audit recorded zero activation, frontmost and display violations. [Local gate log](gate-build31-clean.log) · [Mac XCTest results](../browser-quality.822W48/BrowserTests.xcresult)

Hosted Browser quality passed at exact code commit `cad5d82`. The outgoing public-safety scan passed for all 14 commits before the temporary CI push. The `ci/0160b-f4c9ea6` branch was deleted and remote `main` was verified at `e4e9923` after deletion. [Hosted CI](https://github.com/santhoshbalaji/Oriv/actions/runs/44502984561) · [Remote ref verification](remote-final-refs.txt)

## Code commits

- `f4c9ea6` Bound history index startup and attach iOS 27 test fixtures
- `0d36221` Wait for iPhone grid chrome to settle before sampling its endpoint
- `7b25eb9` Reuse scratch storage while building suggestion postings
- `f5e6c07` Store suggestion records in a dense array
- `6538bd7` Keep UIKit grid counts consistent during iOS 27 tab deletion
- `6eb04ad` Stabilize iOS 27 frame sampling and reduce history seed allocations
- `cad5d82` Give headless grid sampling a controlled animation clock

## Build 30 address-suggestion baseline

Apple M4 Pro, release optimization, prebuilt index, one open tab and a top-seven limit.
Each case ran 30 times. Timings cover matching and ranking.

| Query | Median (ms) | p95 (ms) | Max (ms) |
| --- | ---: | ---: | ---: |
| `h` | 0.023 | 0.037 | 0.120 |
| `host` | 0.023 | 0.025 | 0.028 |
| `docs` | 0.004 | 0.005 | 0.019 |
| `documentation` | 0.007 | 0.008 | 0.013 |
| `example` | 0.009 | 0.009 | 0.011 |
| `/path/` | 0.006 | 0.009 | 0.014 |
| `guide 49999` | 0.286 | 0.303 | 0.373 |
| `host1199` | 0.084 | 0.101 | 0.137 |
| `guide doc` | 0.004 | 0.006 | 0.010 |
| `zz` | 0.004 | 0.005 | 0.007 |
| `not-found` | 0.004 | 0.005 | 0.006 |

[Benchmark log](benchmark.log)
