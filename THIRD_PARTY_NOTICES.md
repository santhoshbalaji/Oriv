# Dependencies and asset provenance

Oriv's original source, documentation and original brand artwork are provided under the repository's [MIT license](LICENSE).

The application uses Apple system frameworks including SwiftUI, AppKit, WebKit, Core Data and UserNotifications. It does not bundle these frameworks or a separate browser engine. Apple SDKs, tools, fonts, system symbols and platform-provided artwork remain subject to Apple's terms; the repository's MIT license does not relicense them. SF Symbols and system fonts are referenced through native APIs rather than distributed as font files.

`Packages/BrowserKit/Package.swift` contains local targets and no external Swift package dependencies. The original Strict analytics supplement is MIT. Maintained filter adaptations are separately licensed EasyList, EasyPrivacy and EasyList Cookie List data, copyright The EasyList authors (https://easylist.to/), distributed under **CC BY-SA 3.0 Unported**, chosen from upstream's dual licensing. The adaptations remain CC BY-SA 3.0; unrelated Oriv source and the original converter remain MIT.

Full attribution, modifications, source commits, SHA-256 digests and conversion counts accompany the resources in `Packages/BrowserKit/Sources/BrowserEngine/Resources/Privacy/NOTICE.txt` and `manifest.json`. The complete licence is `CC-BY-SA-3.0.txt` in that directory, reproduced from Creative Commons' official repository. The same notice and full licence are shipped in Settings → Privacy → Acknowledgements. Each compact list resource carries its own attribution/licence header. Modifications include supported-subset conversion, dropping unsupported syntax with counted reports, grouping cosmetics, conservative site-scoped cosmetic exceptions, separator expansion, compression and rule-limit splitting. Original sources are linked by immutable commit; `scripts/convert-privacy-lists.py` reproduces the adaptations. No additional restrictions are imposed on the list data. See [privacy controls](docs/privacy.md) for capabilities and limitations.

The Oriv mark is original vector geometry inspired by the traditional kolam form. The brand folder retains an AI-generated design concept and the prompt; the shipping mark is the editable vector described in [the identity notes](Assets/Brand/README.md). Icon previews include rendering supplied by Apple's Icon Composer.

The media fixture generates its own local test video. Its optional Apple HLS sample is fetched from Apple's public streaming example URL at test time and is not included in this repository. Third-party webpages and their media remain owned by their respective owners. Raw browsing/notification QA captures and build artifacts are excluded from Git; the published Workspace screenshots use only the project's synthetic fixture content.

Product names, logos and trademarks belonging to third parties are used only to identify their services. This project is independent and is not endorsed or certified by Apple.
