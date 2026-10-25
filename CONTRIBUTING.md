# Contributing to Oriv

Oriv is an early native Mac browser and productivity workspace. Check the [README](README.md) for implemented features and boundaries before proposing changes; the iPhone interface and iCloud sync are future work.

## Development

Use a Mac with macOS 26 or later and Xcode 26 or later. The current release was built with Xcode 27. Open `PersonalBrowser.xcodeproj` and run the `PersonalBrowser` scheme. The generated project is checked in. When changing targets or project configuration, edit `project.yml` and regenerate with XcodeGen.

The project defaults to ad-hoc local signing. It shares the installed application's bundle identifier; use a separate macOS test account or change the development bundle identifier if you need complete isolation from an installed Oriv session.

Run shared tests with:

```sh
swift test --package-path Packages/BrowserKit
```

Native integration tests need the loopback fixture server. Follow the README's verification commands. Video rendering tests require an unlocked desktop with the test window visible; report visibility-related skips separately from passes.

## Changes and reports

- Preserve normal/private browsing boundaries, immutable captured content and recoverable user data.
- Use public Apple APIs and keep AppKit-specific code in the Mac application layer.
- Follow [the design system](docs/design-system.md), including native navigation/controls and readable content surfaces.
- Describe the problem, resulting behavior and relevant validation in pull requests. Add regression coverage when changing privacy, persistence or browser behavior.
- Include OS/app versions and reproducible steps in bug reports. Use synthetic pages and accounts; do not post passwords, tokens, personal browsing history or unredacted system notifications.
- Never commit signing certificates, provisioning profiles, local session databases, build outputs or raw QA captures.

Contributions are provided under this project's MIT license. Keep third-party attribution and applicable license notices with any new dependency or asset.
