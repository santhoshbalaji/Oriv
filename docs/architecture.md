# Browser foundation and the iPhone boundary

## Responsibilities

`BrowserCore` has no UI dependency. It contains Codable/Sendable records, URL/search interpretation, session schema validation and atomic file persistence. Initial storage is an explicit JSON snapshot because recovery and inspection are straightforward at this scale. Productivity records now live separately in the shared Core Data repository; WebKit cookies and live pages are never stored in that database.

`BrowserEngine` owns observable, main-actor WebKit tabs. Each tab holds one web view for its lifetime once activated. Switching tabs reparents that same view, preserving form inputs, navigation and scroll state. On launch, stored tab records remain lazy until selected. All current live tabs remain resident; background tab suspension is a separate later change that must account for unsaved inputs and active media.

`BrowserSession` manages selection, bounded history, bookmarks, private-tab lifetime and debounced persistence. Its snapshots filter out private tabs and select a regular tab for restoration. Closing the last private tab releases that session's ephemeral data store. Recently closed private tabs cannot be reopened.

`BrowserWebConfiguration` applies public media and compatibility settings before each view is constructed, including popup views. It enables webpage fullscreen and AirPlay, with inline/PiP settings for iOS, and retains WebKit's platform identity and codec selection while adding Safari compatibility tokens on Mac. `BrowserRuntime` exposes the loaded framework build separately from the application version. See [media compatibility and version policy](media-compatibility.md).

`AdBlocker` compiles native WebKit content rules before navigation. Each tab has an independent user-content controller, including popups, while the session shares compiled rules and a global mode. Regular hostname exceptions use local preferences; private exceptions stay in memory and clear when the last private tab closes. Static compiled lists contain no visited hostnames. See [ad-blocking design and limits](ad-blocking.md).

The Mac app provides window layout, keyboard commands, an AppKit web-view wrapper, website dialogs, upload file selection and download destination selection. Those adapters are deliberately not in the shared engine. Downloads use an app-temporary file, then move/replace the selected destination after successful completion.

## Safety and recovery behavior

- The address bar only opens HTTP(S) URLs or a safely encoded search. It rejects executable/local schemes and URLs containing embedded credentials.
- WebKit uses its default TLS handling. The app has no certificate-validation bypass.
- User-activated mail and phone links require a native handoff confirmation. Other custom schemes are currently cancelled.
- Website dialogs show their source origin. Provider/native credentials never enter page script context.
- Session writes are atomic, preserve one last valid snapshot and restrict file permissions. Invalid stored navigation is filtered before restoration.
- Unsupported future session formats pause writes. Damaged files without a usable backup also pause writes; no automatic destructive reset exists.
- Session snapshots contain titles/URLs, not website documents or form content. Credentials and page content must never be added to these records implicitly.

## iPhone next

Add an iOS app target that depends on the same package products. Supply `UIViewRepresentable`, mobile tab/Space navigation, upload/download sheets and mobile `WKUIDelegate` behavior. Share model logic, not desktop view composition.

Future Core Data/CloudKit sync should cover explicitly selected saved content, metadata and note revisions. Website sessions and provider authentication remain device-local initially. Do not treat CloudKit as a command transport or promise continuous iPhone background execution.

Long-running Mac jobs and any local Codex/Claude runtime integration belong behind an authenticated host interface. The first agent should expose explicit tools for selected-tab reads and website actions. Runtime auth, permissions, cancellation and event recording are separate from the WebKit view.

## Release boundary

The current app is sandboxed with outgoing network and user-selected file access. Local signing is ad-hoc for development. No provisioning profile, distribution identity, notarization, default-browser entitlement or passkey entitlement is assumed. Adding a claimed entitlement to a file is not evidence of Apple approval.

## Productivity layer (0.4.0)

`ProductivityKit` supplies local Core Data persistence, stable domain identifiers, immutable capture/note revisions, recoverable item state and serialized native reminder reconciliation. `PageCaptureService` is a user-initiated BrowserEngine service; the Mac capture sheet previews its result before saving. The separate native Workspace scene can reopen from reminder notifications. See [the full storage, privacy, reminder and Apple Passwords boundaries](workspace.md). CloudKit mirroring and Apple account services are not active.
