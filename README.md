# Oriv

A native Mac and iPhone browser built with SwiftUI and Apple's system WebKit. The current milestone is a privacy-first, performance-optimized browser with verified web compatibility.

Open source under the [MIT license](LICENSE). See [contributing](CONTRIBUTING.md) and [dependencies and asset provenance](THIRD_PARTY_NOTICES.md).

## Maintainer

Oriv is developed and maintained by [Santhosh Balaji S](https://github.com/santhoshbalaji), currently the sole maintainer.

## Browser scope

- Regular/private tabs, browsing profiles, pinned tabs, session recovery and local history.
- Local bookmarks and HTML bookmark import/export on Mac.
- Address/search input with selectable search engine; suggestions use local browser records.
- WebKit content blocking, per-site exceptions, site permissions and browsing-data controls.
- Native website dialogs, authentication, file uploads and downloads.
- Find, zoom, Mac reading view, print, PDF/webarchive export and system Password AutoFill support.
- Native iPhone Browse, Bookmarks and Settings, with separate local profiles and page sharing.

Workspace, AI/chat, dashboards, application/diet tracking, source monitoring, reminders, Calendar links, Workspace cloud sync and the Workspace Share extension have been removed from the active application and package targets. Existing saved databases, documents and credentials are retained on disk. A read-only upgrade imports active saved web links into browser bookmarks; the old database is never migrated or edited. See [upgrade behavior](docs/architecture.md#upgrade-and-data-preservation).

## Run locally

Requirements: macOS 26 or later, Xcode 26 or later and Swift 6. Current validation uses Xcode 27. No provider account is required for browsing.

Open `PersonalBrowser.xcodeproj`, choose **PersonalBrowser / My Mac**, and run. Debug is **Oriv-Dev** (`local.personalbrowser.qa`); Release retains `local.personalbrowser.mac`. These identities preserve existing browsing data and keep the development sandbox separate from the installed release.

`./scripts/run-mac.sh` builds, installs and opens `/Applications/Oriv-Dev.app`; it replaces that development installation. To build without installing:

```sh
xcodebuild -project PersonalBrowser.xcodeproj -scheme PersonalBrowser \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/mac build
xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/mobile CODE_SIGNING_ALLOWED=NO build
```

Browser continuity supports optional iCloud bookmarks, history, profile metadata, regular-tab lists, preferences and Handoff. See [continuity scope and validation](docs/browser-continuity.md). Development and Production CloudKit databases are separate; local test results do not establish production acceptance.

`project.yml` is the XcodeGen source of truth. Regenerate using `xcodegen generate` after changing targets or adding files. `OrivBrowserMobile` declares Apple's managed browser entitlement; contributors must obtain any required capability approval for their own team. See [local signing setup](CONTRIBUTING.md#local-signing-setup). No iCloud container or developer-account sign-in is needed for unsigned local builds.

## Verify

```sh
./scripts/check-browser.sh
```

This runs the scope checks, shared tests, native Mac fixtures, signature/entitlement checks and whitespace validation. Media tests need an unobscured foreground window; a skipped test is not a pass. [Browser quality and remaining priorities](docs/browser-quality.md) distinguishes implementation, local test evidence and release gates. See [manual testing](docs/testing.md), [architecture](docs/architecture.md), [profiles](docs/profiles.md), [ad blocking](docs/ad-blocking.md) and [media compatibility](docs/media-compatibility.md).

## Release status

The browser-only changes target 0.6.0 (6). The production release hold remains until the [implementation and acceptance gates](docs/browser-implementation-plan.md) pass. The historical [0.5.0 release record](docs/releases/0.5.0.md) describes that earlier artifact, including features since removed from development.

Appearance: [T3 Code and the built-in themes](docs/appearance.md) are shared by Mac and iPhone.
