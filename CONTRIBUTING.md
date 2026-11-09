# Contributing to Oriv

Oriv currently focuses on a privacy-first, performance-optimized native browser for Mac and iPhone. See the [README](README.md) and [browser priorities](docs/browser-quality.md). Productivity and AI features are outside the current scope.

Oriv is developed and maintained by [Santhosh Balaji S](https://github.com/santhoshbalaji), currently the sole maintainer.

Use macOS 26 or later, Swift 6 and an appropriate Xcode installation. `project.yml` is the source of truth; run `xcodegen generate` after changing configuration or adding files. The generated project is checked in.

Debug Mac builds use `local.personalbrowser.qa`; the installed release uses `local.personalbrowser.mac`. Preserve existing app identities and browser storage. Build without installing when reviewing changes. `scripts/run-mac.sh` explicitly installs/opens Oriv-Dev; `scripts/install-dev.sh` installs without opening and keeps the previous bundle under `build/dev-install-backups`.

Run `./scripts/check-browser.sh`. It covers package tests, native Mac fixtures, scope boundaries, signatures/entitlements and whitespace. Build the `OrivMobile` simulator scheme as well for shared/interface changes. Report skipped tests, local results, remote CI, signing, installation and publication separately. Do not count compilation as live account, physical-device or standards acceptance.

Protect private state: no private tabs, form values, cookies, credentials or page content in logs, screenshots or fixtures. Use synthetic data. Do not introduce remote suggestions, telemetry or provider requests without an explicit product decision. Test persistence/migration changes against old, damaged and future formats; unknown data must be preserved.

See [manual testing](docs/testing.md), [architecture](docs/architecture.md) and [dependency notices](THIRD_PARTY_NOTICES.md). Keep keys, tokens, certificates, provisioning profiles, databases, generated app bundles and personal browser data out of source control.

## Local signing setup

All committed `DEVELOPMENT_TEAM` settings and distribution-template `teamID` values are blank. Use your own Apple development team for signed builds. Keep account names, team IDs, signing certificates, device identifiers and account history out of commits and public QA notes.

Ordinary Debug builds do not require a development team. Build without signing or installing:

```sh
xcodebuild -project PersonalBrowser.xcodeproj -scheme PersonalBrowser \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivMobile \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/mobile CODE_SIGNING_ALLOWED=NO build
```

For a signed build, set `ORIV_DEVELOPMENT_TEAM` locally and pass it as a build override. The shell check fails clearly if it is unset. An alternative is an untracked xcconfig under the ignored `build/` directory, supplied with `xcodebuild -xcconfig`; never commit the local value.

```sh
: "${ORIV_DEVELOPMENT_TEAM:?Set ORIV_DEVELOPMENT_TEAM to your own development team}"
xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivContinuityMac \
  -configuration ContinuityDevelopment -destination 'platform=macOS' \
  -derivedDataPath build/continuity-mac \
  DEVELOPMENT_TEAM="$ORIV_DEVELOPMENT_TEAM" build
xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivContinuityMobile \
  -configuration ContinuityDevelopment -destination 'generic/platform=iOS' \
  -derivedDataPath build/continuity-mobile \
  DEVELOPMENT_TEAM="$ORIV_DEVELOPMENT_TEAM" build
```

Configure the capabilities and container association for your own team as described in [browser continuity](docs/browser-continuity.md#build-configuration). Bundle and CloudKit identifiers are public application configuration, not account credentials. The templates under `Config/Distribution/` contain no team selection; copy a needed template to ignored `build/`, set its `teamID` locally, and use that copy. Do not populate the committed templates. `scripts/package-mac.sh` uses local ad-hoc signing by default and accepts an optional `ORIV_SIGNING_IDENTITY` environment override.
