# Browser architecture

`BrowserCore` contains URL/search interpretation, browser/profile records, JSON persistence and one read-only legacy bookmark adapter. It has no UI dependency. `BrowserEngine` depends only on BrowserCore and system frameworks; it owns WebKit configuration, tab/session lifetimes, site settings, content blocking and transient reader extraction. No AI, EventKit or productivity package remains in the build. Optional CloudKit browser continuity uses an explicit metadata allowlist.

The Mac and iPhone apps provide their own native browsing UI, website dialogs, file selection and download handling. Mac supplies keyboard commands, printing and export. iPhone supplies Browse, Bookmarks, Settings and the standard page share sheet. There is no separate Share extension. The optional browser continuity transport is shared by both apps; dedicated signing configurations enable its iCloud capability.

## Browser lifetimes

Each tab creates a WebKit view only when needed. Restored background pages remain unloaded until selected; switching retains an existing live view and its page state. Current live tabs stay resident. WebKit idle-view throttling is enabled; measured memory-pressure reclamation remains future browser work with form/media/call/download exclusions.

Each profile owns a browser session, site rules, blocker preferences and separate persistent website storage. Controllers are created when selected, or as inactive data sources after continuity opt-in. Sync does not activate their WebViews. Inactive profiles suspend media/capture and cannot present website dialogs or popups; existing downloads retain their owner.

Private tabs share a separate ephemeral store within a private session. Closing the last private tab discards that store and private site exceptions/rules. Private records never enter history, bookmarks, restored sessions or reopen history. Explicitly saved downloads can remain on disk; private browsing is not network anonymity.

`BrowserSession` owns URL/title bookmarks independently of any saved-content database. Snapshots are atomic, bounded and protected by a last-valid backup. Unknown future versions pause writes rather than silently rolling back. Bookmarks remain scoped to their profile and can optionally sync. Website login data always remains local to the device and profile.

## Upgrade and data preservation

Session format 3 removes old Workspace/dashboard/conversation destinations during restoration, preserving regular tabs, pinning, history and bookmarks. Formats 1 and 2 remain readable. Older builds cannot safely edit format 3 sessions and should preserve them as unsupported.

`LegacyBookmarkReader` recognizes the two historical Core Data models and opens the old `workspace.sqlite` read-only. It fetches only saved-link metadata. Active HTTP(S) links retain their UUID, title and creation date; archived/trashed links are excluded. The original database, notes, attachments, cloud replica files and credentials are neither rewritten nor deleted. An unknown/corrupt legacy database produces a visible migration notice and leaves ordinary browsing available.

The one-time import runs asynchronously outside browser construction. Its receipt is saved with the browser session. Subsequent bookmark edits/deletions do not alter the legacy database or re-import deleted bookmarks. Existing browser links added while import is running are retained. Synthetic tests verify historical formats, metadata preservation and byte-for-byte preservation of the old database.

A small launch-time compatibility cleanup removes only old `oriv.action.*` / `oriv.profile.<UUID>.action.*` notifications, without requesting permission. There is no notification scheduler, reminder UI or EventKit reconciliation. Credentials from removed integrations remain untouched in Keychain and are never read by this build.

## Privacy boundaries

Navigation permits HTTP(S) or safely encoded searches and rejects embedded credentials/executable URLs. WebKit handles TLS; the app has no trust bypass. Native dialogs identify their source. External application links require confirmation. Search suggestions use local records; the browser’s ordinary path contains no app-owned AI or analytics client. The browser-only CloudKit transport is constructed only after continuity opt-in. Website stores never enter its data model. See [continuity](browser-continuity.md).

WebKit supplies the web engine and its security behavior. The app supplies isolation and permission boundaries, content rules, safe file handling and visible controls. Static inspection is not a network privacy audit or proof of complete tracking/fingerprinting protection. See [browser quality](browser-quality.md) for the next acceptance gates.
