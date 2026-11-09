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

For a signed build, create the ignored `Config/Local.xcconfig`: put your team ID here as a `DEVELOPMENT_TEAM` assignment; never commit it. Supply this file explicitly to Xcode or `xcodebuild -xcconfig Config/Local.xcconfig`. It is not included in the generated project, so regeneration never copies local values into tracked settings:

```sh
xcodebuild -project PersonalBrowser.xcodeproj -scheme OrivContinuityMobile \
  -configuration ContinuityDevelopment -destination 'generic/platform=iOS' \
  -derivedDataPath build/continuity-mobile -xcconfig Config/Local.xcconfig build
```

Alternatively, set `ORIV_DEVELOPMENT_TEAM` locally and pass it as a build override. The shell check fails clearly if it is unset:

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

## Public repository rules

Never commit Apple account names or roles, team names or IDs, signing identities, provisioning/device lists, personal emails, device names, absolute personal paths, private browsing/QA notes, or account-specific distribution and submission status. Keep other people's names out of published material. The maintainer attribution, noreply Git identities, synthetic example addresses, reusable technical guidance and licensing belong in public source. Use synthetic fixtures and screenshots.

Keep sensitive build/deploy values in the ignored `Config/Local.xcconfig`, ignored local files under `build/`, or local environment variables. Keep personal and operational release records local. Never stage these files with force-add or copy their values into generated projects, patches, commit messages, CI logs or published artifacts.

Run `python3 scripts/check-public-safety.py` to check tracked working files; `scripts/check-browser.sh` runs the same guard in CI. Before pushing, run `python3 scripts/check-public-safety.py --range origin/main..HEAD`. The range mode checks every outgoing commit's full tree, patch (including deletions), message and author/committer identities; a tip such as `--range HEAD` checks its entire history. Empty team settings and explicit local environment references are allowed. Diagnostics withhold matched values.

Optionally create the ignored `.publication-denylist` at the repository root, with one sensitive literal term per line (case insensitive). Blank lines and lines starting with `#` are ignored. Add private names, account/team names and other local-only terms there; never commit the denylist itself. Automated patterns cannot identify every person's name or private screenshot, so review all published content as well.

Run `./scripts/install-pre-push-hook.sh` if you want the local outgoing-commit check before every push. Installation is opt-in and refuses to overwrite an unrelated hook. It handles existing/new refs and deletions without fetching or publishing extra refs. Hooks and the local denylist are not installed by CI or automatically for contributors.
