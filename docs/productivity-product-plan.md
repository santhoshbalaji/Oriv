# Oriv productivity product plan

Status: proposal for discussion; no application features implemented by this document.
Prepared: 25 October 2026.

Confirmed direction: Swift and system WebKit; Mac first with iPhone support designed in. “Follow” means recording the user's actions and next steps. Prefer on-device processing. Automatic page monitoring is a later, separate feature.

## 1. Product definition

Oriv should help a person turn something they discover into something they can remember, act on, and follow through. The central object is a **saved item**: source material, personal intent, and an evolving record of work.

The product loop is:

**Discover → Save context → Choose a next step → Get reminded → Record the outcome → Continue or finish.**

A saved item can remain a simple reference forever. Adding a reminder, action, or collection is optional. A task can also exist without a web page. Content types should provide helpful templates, not rigid schemas that exclude unusual bookmarks.

Start with one Oriv app containing Browser and Workspace experiences. Workspace can open in its own Mac window and remain useful when no website is open. The shared productivity domain should support a future companion app, but a second binary and separate identity are unnecessary for the first release.

## 2. Main use cases

| Situation | What to retain | Useful next step | Follow-up record |
| --- | --- | --- | --- |
| Article or research paper | Readable text, selected passages, author/date when available, source, reason saved | Read, compare, extract notes | Findings, decisions, related sources |
| Product purchase | Product/variant, displayed price and currency, features, source and capture date | Compare or decide on a date | Alternatives considered, purchase note, delivery/return follow-up |
| Job or scholarship application | Description, eligibility, quoted deadline, application URL | Prepare documents, submit, follow up | Draft prepared, submitted by user, reference number, response |
| Government service or complaint | Requirements, instructions, source date, user-entered reference | Apply, check response, follow up | Submission, contacts, response, resolution |
| Course or tutorial | Description, sections, selected explanations, relevant URLs | Study or practice | Sessions completed, exercises, questions |
| Video | URL, title, description, user-selected timestamp, available permitted transcript excerpt | Watch or revisit a segment | Notes by timestamp, conclusions |
| Event or webinar | Title, start/end, timezone, place/meeting link, quoted source text | Add to Calendar or prepare | Registration note, attendance, follow-up |
| Travel or booking research | Options, dates, displayed terms/prices, source timestamps | Compare, book, prepare documents | Decisions, user-added confirmation, next action |
| Subscription or renewal | Renewal terms visible to the user, source, renewal date | Review before renewal | Decision, user-reported cancellation/renewal |
| Support case or issue | Visible issue context, thread URL, user-selected relevant messages | Reply or check again | Actions taken, response received, resolution |
| Recipe, place, or idea | Ingredients/address/idea, selected content, personal note | Try, visit, develop | Adjustments, experience, results |
| PDF, screenshot, or standalone note | File or selected excerpt, page number/OCR provenance, user context | Any manually chosen action | Same timeline as a web-based item |

Prices and deadlines are captured observations, not live verified facts. Oriv must show the capture time and original source. A video save does not promise downloading the video or obtaining a transcript. External actions such as submitting an application or buying something remain separate from recording that the user did them.

## 3. The saved item and its lifecycle

An item contains a title, optional kind, collection/tags, personal “why I saved this,” lifecycle state, sources, notes, and optional next actions. Its detail view presents:

1. **Overview:** purpose, current state, nearest next action, key source facts.
2. **Content:** captured readable text, selected passages, source links, optional attachments, original capture times.
3. **Activity:** notes and chronological events, including actions taken and outcomes.

The library has Inbox, Today, Upcoming, Waiting, All Saved, Collections, and Archive. Today is derived from actions and follow-up dates. A simple reference should not appear overdue merely because it was saved a long time ago.

Separate item state from task state: an item can be Reference, Active, Waiting, or Finished; each action can be Planned, In progress, Done, or Cancelled. Archive controls visibility independently. “Waiting” should offer a next check-in date, while allowing the user to leave it unset.

Example: save a job opening with the eligibility passage → add “Prepare portfolio” → record “Application submitted” → mark the item Waiting → remind in seven days → record the reply → create an interview preparation action and link an interview event. The original source and earlier steps stay available throughout.

When saving an existing URL, show the existing item and offer Add note, Capture updated content, Add action, or Save as a separate item. Do not silently merge different intentions or overwrite older snapshots. Clicking the existing bookmark button must open saved-item details rather than delete an item containing notes and tasks.

## 4. Capture from the page being viewed

Use an explicit Save command or selection context menu. The default save includes the source URL/title, readable main content when extraction succeeds, selected passage, capture time, and an optional personal note. Offer Link only and Selected passage as alternatives. A content preview and “captured fully / partially / link only” indicator explain what will be retained.

The capture pipeline should:

- Read the selected `WKWebView` using bounded, read-only JavaScript in an isolated content world. Capture the visible document's URL/navigation identity before and after extraction; discard and retry if it changed.
- Extract main content, selection, headings, useful metadata, and structured facts where available. Treat DOM and structured metadata as untrusted input. WebKit exposes a public asynchronous script interface; an isolated content world separates JavaScript namespaces, not the underlying DOM. [WebKit API](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:contentworld:))
- Exclude password fields, form values, editable drafts, cookies, browser storage, and hidden application state. Do not automatically traverse other tabs or embedded cross-origin documents. Sensitive visible text still requires a meaningful capture preview; exclusion rules cannot detect every secret.
- Preserve extracted source text independently of any generated summary. Store content hashes, extraction version, capture status, original/canonical URL, and language. Strip only known tracking parameters; preserve functional identifiers and fragments.
- Save safe text and structured blocks for offline reading. Do not replay captured page scripts. Images/PDFs/screenshots are explicit optional attachments with storage controls.
- Keep saving usable when extraction fails, a page is paywalled, content is dynamically unloaded, or a PDF is inaccessible. Fall back to selected text, a user-supplied attachment, or a link with a clear explanation. Never imply a complete archive was captured.

The current private-tab rule excludes bookmarks. Keep that default. A later explicit “Save outside Private Browsing” flow can promote selected content to the ordinary library after clearly showing that it will persist and may sync. Never silently index private browsing or send its content into AI, Spotlight, notifications, or iCloud.

## 5. On-device assistance

The baseline must work without AI: capture, edit, search, notes, dates, tasks, and reminders remain available on every supported device.

Use Apple's Foundation Models on-device model when available for concise summaries, suggested tags, candidate item type, and next-step suggestions. Availability depends on device eligibility, Apple Intelligence settings, model readiness, and supported language. Check these at runtime and provide a manual fallback; test Intel Macs and unsupported/mixed-language material explicitly. [Model availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason/modelnotready), [language support](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)

For long pages, process bounded chunks and retain source passage references. Generated output must be distinguishable from source facts and user notes. Dates and obligations are proposals with supporting text, not facts to schedule automatically. Apple provides structured generation, but model context remains limited. [Foundation Models generation](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models)

Select the on-device model explicitly. No automatic fallback to Private Cloud Compute or another remote provider. Any future remote option requires a separate user choice explaining the content and destination. Downloadable third-party local models can be evaluated later for language coverage, size, licensing, memory, and battery cost.

Page text must never authorize tool calls, external writes, or changes to user preferences. In the first version, enrichment produces drafts only. It cannot create a Calendar event, complete an action, submit a form, or mark an application submitted.

## 6. Reminders and follow-through

A **task** is something to do. A **reminder** is an alert about that task or saved item. A **calendar event** reserves a time interval. These are linked concepts with separate state.

Allow “Remind me about this,” “Add next action,” and “Schedule time.” Suggestions may come from the selected passage or page, but a review sheet confirms title, date/time, timezone, recurrence, and destination. Preserve the distinction between an all-day deadline and a precise time. Ambiguous dates, expired deadlines, and relative wording such as “tomorrow” require resolution using the source/capture context, not an invented date.

V1 includes one-off reminders, snooze, complete, reschedule, overdue handling, and notification deep links. Add recurrence and multi-step dependencies after the basic lifecycle is proven. Completing an action logs an event and cancels its pending alerts; reopening it does not erase completion history.

Use UserNotifications for Oriv-owned alerts. Notifications can be delivered by the system while the app is not running, subject to authorization and system presentation settings; do not run a browser timer as the reminder mechanism. [Local notification scheduling](https://developer.apple.com/documentation/UserNotifications/scheduling-a-notification-locally-from-your-app)

Define one alert owner per action: Oriv, Apple Reminders, or Calendar. If Apple owns the alert, Oriv should not create a second equivalent notification. For Oriv alerts, offer a preferred device with a clear fallback. Offline devices and delayed sync prevent guaranteed exactly-once alerts across all devices; show and test that limitation rather than promising instant cancellation everywhere.

The timeline records user notes, action creation/completion, status changes, attachment additions, source updates, and observed external changes. Identify who or what produced each entry. User-authored content needs revisions/undo and deletion controls; an activity history is not a claim of tamper-proof evidence.

## 7. Apple Calendar and Apple Reminders

Use EventKit on Mac and iPhone. Offer integrations only when the user chooses the relevant action. Calendar write-only access supports creating events, while reading or maintaining links requires full access. Reminders requires full access; these permissions are separate from Sign in with Apple and iCloud. [EventKit access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)

Start with deliberate exports: “Add to Calendar” and “Add to Apple Reminders,” with a source link, Oriv item link, minimal context, and a user-chosen destination. Avoid copying complete captured documents into a calendar, especially a shared or work calendar. Use iPhone's system event editor where appropriate; the Mac requires its own native editor around EventKit. A permission-free iPhone editor handoff does not give Oriv enough visibility to claim a maintained two-way link. [EventKit UI](https://developer.apple.com/documentation/eventkitui), [Calendar access approaches](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui)

Then add maintained links under full permission:

| Property/change | Ownership rule |
| --- | --- |
| Source content and personal notes | Oriv owns these; external apps receive only selected context |
| Task initially exported to Reminders | Establish a linked task; import external completion/due changes and export deliberate Oriv edits |
| Calendar event time | Calendar is authoritative after linking; moving a time block does not change a separate task deadline |
| Event passes its end time | Do not mark the task completed automatically |
| External item deleted | Mark the link missing; offer relink/unlink, do not recreate it silently |
| Saved item deleted | Explain linked objects and let the user choose their disposition; do not delete unrelated calendar data |
| Concurrent edits | Compare last linked revision; preserve conflicting edits for review instead of repeatedly overwriting |

Use stable Oriv UUIDs, per-device EventKit mappings, an Oriv deep link/marker when supported, and reconciliation. Calendar local identifiers can change after sync; external identifiers can have duplicates, recurring-event ambiguity, and provider differences. Do not sync a local EventKit identifier and assume it resolves everywhere. [Local identifiers](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier), [external identifiers](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier)

Only the device processing a user-authorized export should create the external object. Receiving its Oriv record through CloudKit must not create another copy. Two simultaneous offline exports need detection/reconciliation; exact-once external writes cannot be promised without coordination.

## 8. Apple identity and iCloud sync

Implement the requested Sign in with Apple capability for an optional Oriv profile, while keeping local capture usable without an account. Use AuthenticationServices, Apple's standard button, stable user identity rather than email, Keychain storage, credential-revocation handling, and an account deletion flow. Group the related Mac/iPhone App IDs. If we introduce an Oriv server account, verify Apple tokens on the server; a decorative login button is not account infrastructure. [Sign in with Apple](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple), [App ID grouping](https://developer.apple.com/help/account/capabilities/about-sign-in-with-apple), [account UX](https://developer.apple.com/design/human-interface-guidelines/managing-accounts)

**Sign in with Apple and iCloud sync are separate services.** CloudKit private data belongs to the device's iCloud account and uses that person's storage quota. Native Sign in with Apple uses the signed-in iCloud user, but it neither enables CloudKit nor grants Calendar/Reminders access. A server login also cannot redirect a device's private CloudKit database to another account. [Private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)

Provide separate status for Oriv profile and iCloud. A cloud-only product does not technically need a custom server for personal-library sync; decide whether the optional profile has useful account-level features before creating a backend solely for login. Preserve Sign in with Apple in the roadmap without making it a false dependency of sync.

Sync saved items, content snapshots, notes, actions, activity, collections, and external-link metadata. Keep browser cookies, website login sessions, private tabs, raw browsing history, local notification registrations, search indexes, and authentication secrets outside the productivity sync model. Initial sync covers selected saved content, not all browsing activity.

Support offline edits, pending/error states, storage quota failures, attachment download states, deletes, recovery, and account changes. Partition local cloud-backed stores by account; never upload one account's cached library into another account automatically. Offer local-only use and export. Turning sync off, removing local downloads, deleting a cloud item, and deleting an account are separate operations.

Do not promise real-time sync. The system schedules Core Data/CloudKit work. Consequently, a last-second reminder cancellation on an offline second device may arrive too late. [Sync scheduling](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)

## 9. Proposed Swift architecture and data migration

Retain BrowserCore and BrowserEngine for browsing. Add a shared productivity domain and platform adapters:

| Component | Responsibility |
| --- | --- |
| ProductivityCore | Saved items, tasks, timeline, capture metadata, scheduling rules, merge rules |
| ProductivityStore | Core Data persistence, migrations, CloudKit mirroring, attachments, durable export jobs |
| PageCapture | WebKit extraction and capture-quality reporting |
| ContextAssistant | Optional on-device enrichment; structured drafts with evidence |
| AppleIntegrations | EventKit, UserNotifications, AuthenticationServices, Keychain, deep links |
| SearchIndex | Local searchable content, rebuilt from the library; optional Spotlight exposure |
| Mac/iPhone UI | Shared interaction concepts, platform-specific layout and presentation |

Recommend **Core Data with NSPersistentCloudKitContainer**, wrapped by Swift repositories. Its explicit stores, persistent history, and sync event reporting fit migration and integration reconciliation. SwiftData remains a viable alternative, but it uses the same CloudKit machinery; it does not remove the conflict, schema, or duplicate-handling work. Validate this choice in the first persistence/sync spike. [Core Data container](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/), [SwiftData sync constraints](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)

Proposed entities: SavedItem, SourceSnapshot, NoteRevision, Action, ReminderPlan, ActivityEntry, Collection, Attachment, ExternalLink, and local-only integration jobs. Each has a stable UUID; snapshots and activity additions merge independently. Preserve concurrent note revisions rather than applying whole-record last-write-wins. Recurrence occurrences and notification registrations use stable logical occurrence IDs. Apply deterministic duplicate reconciliation in the domain layer; CloudKit does not enforce unique constraints.

Choose encrypted CloudKit attributes for source text, notes, summaries, and other sensitive values before publishing the schema. Keep search local and disclose searchable metadata boundaries. Encryption options must be verified end to end; “private database” alone is not a blanket end-to-end-encryption promise. [Core Data encrypted attributes](https://developer.apple.com/documentation/coredata/nsattributedescription/allowscloudencryption), [CloudKit encrypted fields](https://developer.apple.com/documentation/CloudKit/CKRecord/encryptedValues)

The current bookmark is only UUID, title, URL, and creation date, inside session.json. Migrate bookmarks transactionally and idempotently, preserving those IDs and dates, retaining a recoverable backup, and checking counts. Leave tab/session restoration separate. Old bookmarks remain valid link-only items; do not refetch them in bulk or fabricate historical page content. Replace the destructive bookmark-toggle behavior with open/edit saved-item behavior.

Start with deterministic keyword search across titles, sources, notes, and captured content. Add optional Core Spotlight indexing; it is private and on-device and needs rebuilding on each device. Provide controls for sensitive items. Semantic search is later and must not become a prerequisite for finding saved records. [Core Spotlight](https://developer.apple.com/documentation/CoreSpotlight)

## 10. Mac and iPhone experience

On Mac, preserve the browser toolbar and tab sidebar. Add a compact Save sheet and a context panel for the current saved item. Workspace uses a native sidebar/list/detail layout with keyboard navigation, accessible labels, semantic colors, and progressive disclosure. Keep a simple save fast; expose timeline and scheduling when needed.

On iPhone, use compact Today/Library/Browse navigation, a shared saved-item detail model, and a Share extension. Sharing from Safari may provide only a URL and selected/shared text; it does not automatically expose the authenticated page DOM. Rich capture is available in Oriv's own web view; shared external links need a preview/fallback. A PDF or file shared explicitly can be processed on device.

Use an App Group for extension handoff and one app-owned sync coordinator, avoiding two processes simultaneously mirroring the same store. Consider App Intents/Shortcuts, widgets, and Handoff after capture and scheduling are reliable. No permanent iPhone background agent is assumed: background execution times are system-controlled. [Background task timing](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)

## 11. Delivery plan and acceptance gates

| Phase | Scope | Exit condition |
| --- | --- | --- |
| 0. Model and technical spikes | Saved-item UX, persistence schema, migration, CloudKit/identity capability setup, notification and EventKit prototypes | Demonstrate a saved item with two independent actions; verify the chosen sync and permission approaches with development signing |
| 1. Useful Mac workspace | Context saves, selected text, offline content, notes, timeline, next actions, Inbox/Today/Waiting, search, export/undo | Read a saved article offline; track an application through three steps; migrate existing bookmarks without loss |
| 2. Reminders and Apple actions | Oriv notifications, snooze/completion, reviewed Calendar/Reminders export, optional on-device suggestions | Create from a source passage; alert when app is closed; complete without an equivalent duplicate alert |
| 3. Identity, sync, and maintained links | Optional Apple profile, iCloud library, account boundaries, conflict recovery, external change reconciliation | Two real devices retain simultaneous notes/actions, reconcile calendar moves/completion, and survive offline edits/account changes |
| 4. iPhone companion | Library/Today, saved-item editing, Share extension, notifications, Calendar/Reminders, then mobile browsing | Save on Mac and continue on iPhone; save from Share sheet; permission denial and model unavailability remain usable |
| 5. Product polish | Recurrence, richer PDF/OCR/video capture, Shortcuts/widgets, contextual retrieval, optional semantic search | Measured retrieval/capture quality, accessibility, battery/memory and large-library checks |
| Later. Monitoring | Explicit opt-in public-page change detection and change evidence | Clearly labelled last-check time and delivery guarantees; no implied always-running phone watcher |

Phases 3 and 4 overlap: a minimal physical-iPhone client is required during Phase 3 to prove sync before the full mobile interface is polished. Cloud-compatible IDs, schema, history and ownership are designed in Phase 0, not bolted on at the end.

Before cloud-backed distribution, configure the Apple developer team, registered App IDs, correct signing/profiles, iCloud container, push/remote-notification capabilities, and Sign in with Apple. Promote the verified CloudKit schema to production and test that environment separately. The current ad-hoc-signed 0.3.0 DMG has none of these capabilities configured. This is a release dependency, not a reason to delay the local workspace.

## 12. Test matrix and scope boundaries

Acceptance includes: article/SPA/PDF capture, selection-only and failure fallback, malicious page instructions, navigation during capture, private-tab exclusion, Unicode/mixed-language source retention, model unavailable, ambiguous dates, timezone changes and DST, app-closed reminders, permissions denied/revoked, recurrence, duplicate notification prevention, two-device offline edits, concurrent notes, account changes, quota exhaustion, interrupted migration, external item move/delete, recurring calendar occurrences, shared/read-only calendars, export/recovery, and attachment cleanup. Test actual iPhone hardware and a non-AI-capable path; simulator compilation is insufficient.

Measure save responsiveness separately from optional enrichment, capture completeness, retrieval success, reminder correctness, lost/conflicting edits, and duplicate external writes. Performance targets are to be established with fixtures and measured on supported hardware, not asserted from framework choice.

The first complete product slice is: **save a viewed page with context → add a personal note and next action → get a reminder → record what happened → find the full history later.** It should be useful offline before cloud sync or AI enhancement. Collaboration, autonomous website actions, automatic monitoring, and a complete project-management suite remain later scope.
