# Oriv Workspace

The first Mac productivity release connects a saved page to its context, personal notes, next actions and local reminders. Processing is on-device; no AI service receives page content.

## Everyday flow

1. On a normal web page, press **Command-D** or the bookmark toolbar button. Review the captured text, optionally choose a selected passage or link only, and add why it matters.
2. Oriv opens **Workspace**. Use Overview for notes and actions, Content for saved snapshots, and Activity for the history of your work. Command-Shift-B opens Workspace independently of the browser window.
3. Add an action with an optional due date and an independent reminder. Quick choices include five minutes, an hour, and tomorrow at 9 am. macOS requests notification permission when you first save an alert.
4. Complete/reopen actions, edit notes, or use Reference / Active / Waiting / Finished to describe the item. Note edits retain previous text in Activity → Note history.
5. Search titles, purposes, captured text, current notes and actions. Today includes overdue actions. Archive pauses reminders; Trash keeps records recoverable. Restore the item to resume future alerts.

Saving an already-saved URL opens its item. **Library → Capture Page Again** appends an immutable snapshot instead of overwriting the original. Standalone items need no web link.

## Capture boundary

Capture reads the loaded main document in an isolated WebKit script world. It prefers article/main content, includes visible text and an eligible selection, and excludes input fields, forms, editable regions, hidden text, scripts, frames and navigation chrome. It reads no cookies, storage, password vaults or cross-origin frame contents. Navigation during extraction invalidates the capture. Extraction is bounded to 60,000 characters / 18,000 text nodes, with partial or link-only results clearly labeled.

This is a text snapshot, not a faithful offline website, image archive, PDF extractor or AI summary. Passwords visibly rendered as ordinary page text cannot be reliably distinguished from other text; review the preview before saving sensitive content. Private tabs cannot capture into the persistent library.

## Storage and the iPhone / iCloud boundary

`ProductivityKit` owns the shared records, Core Data repository and notification reconciliation. The Mac UI depends on it; it imports no AppKit. Browser capture is in `BrowserEngine`. All three package products compile for the iOS 26 simulator.

`PersonalBrowser/workspace.sqlite` and its SQLite sidecars live in Oriv's sandbox Application Support directory, alongside the existing session files. Saved items, immutable source snapshots, note revisions, actions and activity entries have independent stable UUIDs and timestamps. Snapshots include a content hash. Archive/deletion markers preserve recovery. The old bookmark list migrates once in a transaction with a migration receipt, retaining original identifiers and dates; the session file remains a recovery source.

The model uses optional Core Data attributes, no uniqueness constraints, UUID references, persistent history and appropriate future CloudKit encryption flags. These choices follow [Apple's CloudKit model constraints](https://developer.apple.com/documentation/CoreData/creating-a-core-data-model-for-cloudkit). They do **not** enable sync or encrypt the local SQLite database. Device security and FileVault remain relevant to local data protection.

This release uses `NSPersistentContainer`, not cloud mirroring. Before enabling iCloud, implement signed capabilities, account partitioning and change handling, versioned model migration, conflict resolution, out-of-order import validation, deletion retention and cross-device reminder ownership. Sign in with Apple, Calendar/EventKit, iPhone UI, server AI and cloud sync are still separate milestones. The intended broader roadmap remains in [the product plan](productivity-product-plan.md).

## Reminders

Oriv schedules native `UNUserNotificationCenter` notifications, independent of its process once accepted by macOS. Due dates and reminder times are separate. Dates represent fixed instants and retain the time-zone identifier used when edited. Stable action identifiers prevent duplicate requests; serialized reconciliation cancels obsolete requests even if completion occurs during an asynchronous scheduling call. Completing, archiving or trashing an item cancels its pending alerts and dismisses its delivered notifications, including after relaunch. The action displays “In Notification Center” when the public system API confirms a retained notification; this does not claim the user viewed it. Reopening/restoring only schedules future alerts.

The earliest 48 alerts are scheduled. A visible notice asks the user to reopen Oriv to schedule later alerts as capacity becomes available. Permission denial and scheduling errors remain visible; the action itself is still saved. OS Focus, notification presentation settings, sleep and system delivery policy affect what the user sees. Notification clicks route to the item, including after cold launch or when the browser window is closed. See [Apple's local notification guidance](https://developer.apple.com/documentation/UserNotifications/scheduling-a-notification-locally-from-your-app).

These are Oriv reminders delivered by macOS, not records in the Apple Reminders application. Apple Reminders and Calendar integration require a separate EventKit implementation and permission flow.

## Apple Passwords

The toolbar key button and Settings → Passwords explain native in-page filling: Control-click a login field, then choose **AutoFill → Passwords…**. The picker is provided by macOS and WebKit. The user confirmed it opens on this Mac; the menu is also present in private tabs. Oriv does not import the vault or inject passwords through JavaScript.

This is the user-invoked field-menu flow, not Safari-style automatic suggestions. **Manage passwords…** remains a separate app handoff. No developer account is needed for the field menu. Browser passkeys and public distribution have separate signing/Apple approval requirements. See [setup, evidence and limitations](passwords.md).

## Design

Native NavigationSplitView, sidebar selection, toolbars, search, date pickers, menus and sheets provide standard Mac behavior. Liquid Glass is used for controls and navigation; saved content has a stable readable surface. System fonts, semantic colors, native focus rings and labeled symbol controls follow [Apple's materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials) and [SwiftUI Liquid Glass guidance](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views). This is implementation against those guidelines, not Apple certification or a completed accessibility audit.
