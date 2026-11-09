# Browser continuity

Optional browser continuity shares regular-browser metadata between Mac and iPhone, independently of the removed Workspace product. The [implementation plan](browser-implementation-plan.md) records remaining correctness, delivery and recovery work. This document describes reusable configuration and test boundaries; it does not record personal account or device history.

## What moves between devices

| Data | Behavior |
| --- | --- |
| Bookmarks | Additions merge; known deletions propagate; explicit Undo restores a bookmark. Independently saved copies of the same URL appear once. |
| History | The newest 500 distinct regular pages per profile, matching the existing browser limit. Clearing history propagates a time-range marker, including older visits from an offline device. Removed/evicted records retain identifiers as tombstones but discard their URL/title payloads. |
| Profiles | Stable UUID, name, color and symbol. Profiles created independently with the same name retain separate identities and get a name suffix. Website stores are never joined by name. |
| Regular tabs | A device-owned list of URL, title, pin state and order in Library → Other devices. Closing a tab updates that device’s list. Opening a remote page creates a new regular tab in its matching profile. Local live tabs and edited forms are never replaced by a remote session. |
| Preferences | Per-profile appearance, search engine, restore-tabs choice, default zoom, blocking mode, regular-site exceptions and regular-site rules. OS device permissions remain local. |
| Open on another device | An explicit page-menu action sends one regular HTTP(S) page to a selected known device. It creates a new regular tab in the matching profile and leaves all existing tabs intact. |
| Handoff | Publishes the selected regular HTTP(S) page while foregrounded, after account verification and with sync/Handoff enabled. Receives a validated URL and profile identity and opens a new tab. Private pages withdraw the activity. |

Website cookies/login sessions, private tabs, form values, downloads, selected profile, profile archive state, private site exceptions/rules and OS grants remain on the device. Passwords/passkeys use the platform’s Passwords/Keychain facilities; this implementation does not copy credentials. Local browsing works without any iCloud or developer account.

Archiving a profile hides it on the current device and withdraws that device’s tab list. Its synced bookmarks/history remain associated with the profile; another device may continue using it. Restore the profile before opening one of its remote tabs on the device where it is archived.

## Controls and delivery

Mac: Settings → Continuity. iPhone: Settings → Mac & iPhone → Continuity. Both expose opt-in, status, last successful sync, Sync now, a device name and Handoff. Library → Other devices shows last-seen timestamps. Pausing sync keeps existing local and cloud copies; resuming merges locally journaled edits. A cloud request already submitted when paused may finish, but subsequent upload batches are cancelled.

The coordinator debounces changes for two seconds, reconciles every 30 seconds while foregrounded, and resumes when returning to the app. It does not promise immediate delivery while the app is suspended or quit. Other-device lists are snapshots, not live remote control. The device heartbeat changes at most every five minutes. Background push delivery and a device-removal/cloud-reset UI are later work.

The initial rollout has an explicit 100,000-record / 100 MB local safety ceiling. Tombstones are retained to protect offline replicas; exceeding a ceiling pauses sync rather than silently dropping deletion information. A coordinated tombstone-compaction policy is still needed for long-lived high-volume libraries. The 500-history-page limit bounds retained page payloads, not the tombstone count.

## Open on another device

The Mac page menu offers **Open on iPhone** and the iPhone page menu offers **Open on Mac**, using the synced destination name for a single device. With several other devices, a submenu lists each by its synced name. The action is hidden until sync is enabled, the bound account is verified, another device is known, and the current tab is a regular HTTP(S) page. The sender briefly shows “Sent to [device]”; the receiver shows “Opened from [source]”. Existing regular-tab sync is unchanged.

Each send writes an `openRequest` continuity payload under `open.<request UUID>` using the existing `BrowserRecordV1` record type and encrypted `body` field. There are no new CloudKit types or fields. The encrypted payload contains the request UUID, target and source device UUIDs, source device name, validated HTTP(S) URL, title, profile UUID and creation date. Sending requests an immediate foreground sync. Receipt still depends on the receiver's existing foreground sync schedule; no background push or instant-delivery guarantee is added.

Only the target device applies a request, after account verification. A matching synced profile is imported using the same identity rules as Other Devices. An archived profile must be restored before its request can open; a missing identity waits for its profile metadata. Requests never fall back to a different profile. Unhandled requests expire after seven days and are tombstoned. Receipt creates a new regular tab using the destination's website store, never the sender's cookies or form state.

Before acknowledging a request, the receiver atomically saves its request receipt together with the new tab in the profile's session snapshot. Replaying an interrupted incoming journal checks that durable receipt, including after the delivered tab is closed or the app relaunches. It then writes a normal replica tombstone. A failed session write leaves the request available for retry. Tombstones retain deletion identity and discard the page payload.

**Upgrade both devices together for this release.** Oriv 0.6.0 uses a closed synthesized payload decoder and rejects the new record kind, pausing its sync. Updated CloudKit readers inspect the encrypted body and skip unknown future kinds, including unknown tombstones, without treating them as deletions. Malformed known records still fail the batch. This forward tolerance cannot change an older installed decoder.

## Links from other apps

On both platforms, **Open Links from Other Apps Privately** defaults to on in Settings → Browsing (Mac: Settings → General → Browsing). Incoming HTTP(S) links open signed out in a profile-less, memory-only private context. Repeated links add tabs to one external-private Mac window or iPhone private tab group. They never access a profile's bookmarks, history, defaults, website store or saved session, and never enter continuity. Links clicked inside Oriv retain their existing behavior. Turning the setting off restores opening external links as new regular tabs in the last regular profile.

The private banner says “Opened privately”, adding a source app name only when the active Mac URL Apple event reliably identifies its sender. iPhone does not infer a source application. Its profile picker starts at the last regular profile. **Move to [Profile]** opens the selected private tab's current HTTP(S) URL as a new regular tab in that profile, focuses it, then closes the private tab (and an empty external-private Mac window). Only the URL crosses this boundary: the destination uses its own sign-ins, with no private cookies, form data or session state copied. Non-HTTP(S) pages have no Move action. **Keep Private** dismisses the banner and leaves the page private. The iPhone page menu can return to the last regular profile or reopen a retained external-private group.

The banner uses native pickers and buttons, semantic theme tokens and solid surfaces, respects the app's Reduce Motion/Transparency settings, and provides keyboard/VoiceOver labels and 44-point iPhone controls.

## Merge, storage and account boundaries

`BrowserCore/BrowserContinuityRecords.swift` defines an allowlist of metadata payloads and validated record identities. A persisted logical counter and writer UUID give deterministic conflict resolution. Concurrent edits to different records merge independently; the same record resolves by counter, then deletion, then writer identity. A newly joining device’s initial metadata/preferences yield to records already in iCloud, so its defaults do not overwrite established settings.

`continuity/replica.json` is atomically written with owner-only file access and iOS file protection. Incoming application is journaled before changing sessions; recovery applies that journal before interpreting a missing local bookmark as deletion. Future/corrupt stores stop sync without rewriting the original file. Ordinary session application changes bookmarks/history/preferences without replacing tabs or WebKit website stores. Explicit open requests append a new tab through the separate receipt transaction above.

`BrowserEngine/ContinuityCloudTransport.swift` is the sole CloudKit client, instantiated only after explicit opt-in. It uses a private custom zone (`BrowserContinuityV1`), records of type `BrowserRecordV1`, and an encrypted `body` field. Record names contain UUIDs/category names, not URL/title text. Fetches are paginated and validated before accepting the batch. Uploads use change-tag checks and inspect individual results; conflicts are merged and retried. Partial failures preserve the local journal and do not mark sync successful.

The replica binds to its first iCloud user-record identity. Account identity is checked before fetch, before importing its response, and before upload. An account-change notification withdraws Handoff and restarts account verification. An account mismatch pauses uploads; it never automatically moves old account data into a new account. A missing/reset previously used cloud zone also pauses rather than repopulating it automatically. The user must return to the original account; switching accounts or recreating a reset store needs an explicit future recovery flow. CloudKit token cache is process-local, so relaunch performs a complete zone fetch. Cloud-service quota/rate-limit behavior still needs acceptance testing with a real account.

Handoff uses `com.santhoshbalaji.oriv.dev.browsing`, declared in both app Info plists, with no Search/public indexing eligibility. The payload includes only validated page/profile metadata. Handoff availability requires compatible Apple-signed apps and device settings; the simulator tests validate payloads and routing logic, not physical Handoff discovery.

Apple references: [encrypted CloudKit fields](https://github.com/apple/sample-cloudkit-encryption), [record-zone changes](https://developer.apple.com/documentation/cloudkit/ckdatabase/recordzonechanges(inzonewith:since:desiredkeys:resultslimit:)), [Handoff implementation](https://developer.apple.com/documentation/foundation/implementing-handoff-in-your-app).

## Build configuration

`project.yml` is the source of truth. Committed `DEVELOPMENT_TEAM` values are blank; select your own team only through a local override. See [local signing setup](../CONTRIBUTING.md#local-signing-setup) for unsigned Debug builds and signed-build commands.

- `ContinuityDevelopment`, through `OrivContinuityMac` and `OrivContinuityMobile`, declares the Development CloudKit environment and `iCloud.com.santhoshbalaji.oriv.browser.dev`.
- The Mac development bundle is `com.santhoshbalaji.oriv.mac.dev`, product `Oriv-Continuity-Dev`. The iPhone development bundle is `com.santhoshbalaji.oriv.ios.dev`, product `Oriv-Mobile-Dev`.
- Ordinary Debug builds have no iCloud container configured. Their continuity controls explain why enabling sync is unavailable.
- `ContinuityRelease`, through `OrivReleaseMac` and `OrivReleaseMobile`, selects the separate Production CloudKit environment. The Mac bundle remains `local.personalbrowser.mac`; iPhone uses `com.santhoshbalaji.oriv.ios`. The release Handoff type is `com.santhoshbalaji.oriv.browsing`.
- Development and Production CloudKit data are separate even when they use the same container identifier. Its historical `.dev` suffix does not select the environment. Development replica files and test data are not copied automatically into Production. Sync remains opt-in.

Both continuity targets need the iCloud capability, the CloudKit service, an explicit container environment, and the container association for the contributor's team. Development entitlements include both container-identifier lists; Production entitlements omit the development-only list. The scope guard checks this allowlist. These capabilities do not restore Workspace app groups, Calendar, AI or extensions. Managed browser capabilities require their own approval; declaring an entitlement alone does not grant it.

CloudKit schema deployment is separate from local compilation and signing. Contributors must configure and verify their own container's schema and Production environment. See Apple's [container-schema deployment guidance](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema).

## Verification boundaries

Synthetic package and native tests cover request validation/targeting/expiry, durable receipt replay, profile matching, unknown-kind tolerance, external-private routing/isolation/Move, convergence, joining-device defaults, offline deletion/Undo, history erasure and retention, tab order/ownership, profile name collisions, account binding, corrupt/future data and Handoff validation. Coordinator fixtures use an in-memory transport to check opt-in, private-tab exclusion, two-device merge, account-switch rejection, failures, journal recovery and preservation of local tabs/private overrides. These tests do not establish real CloudKit delivery or physical Handoff discovery.

Debug Simulator builds accept repeated `--oriv-external-url` launch arguments to exercise the same external-link router and private banner without changing the Simulator default browser. This checks routing and UI, separately from OS default-browser delivery.

Use synthetic pages and dedicated test accounts when validating signed builds on compatible devices:

1. Verify bookmarks, deletion/Undo, preferences, profiles, regular-tab order/pinning and Handoff in both directions without replacing edited/private tabs.
2. Disconnect a device, edit both, clear history on one, reconnect and relaunch; confirm convergence and absence of deleted URL payloads.
3. Exercise account sign-out/switch, quota exhaustion, rate limiting, interrupted batches, encrypted-key reset and zone removal. Confirm visible failure with local data retained and no cross-account upload.
4. Verify Handoff withdrawal for private pages, disabled sync, backgrounding and account errors; measure foreground cost with a representative library.
5. Verify Development/Production separation, warm/cold Handoff, upgrade/data preservation and rollback before considering a production installation. The production release hold remains in place until the implementation-plan gates pass.

## Seamless continuity requirement and remaining implementation

After an explicit initial opt-in, ordinary browsing should not require Sync now, reopening both apps, or visiting sync settings. Background delivery is subject to Apple's scheduling and cannot be guaranteed instantly while an app is suspended or force-quit.

The current coordinator debounces local changes for two seconds and polls every thirty seconds only while foregrounded. No push subscription, background notification handler, network-reconnection trigger or server-directed retry/backoff is implemented. The local replica and merge journal preserve offline edits; scheduling and recovery still need completion.

Pending work:

1. Resolve the Handoff activity type from the build configuration and defer valid cold-start Handoff until account verification completes. Runtime currently defaults to the development type, which differs from the release declaration.
2. Add push-triggered and OS-managed background synchronization, a bounded opportunity to finish pending writes when backgrounding, and automatic catch-up on launch/reconnection.
3. Persist incremental cloud sync state across relaunches; respect server retry delays, quota/network failures and interrupted batches without busy retry loops.
4. Add clear pending/offline/action-required statuses and safe user-controlled recovery for account changes, cloud resets and unreadable local replicas. Include old-device removal and stale-tab cleanup.
5. Reduce full-store scans/writes, compact deletion records without reviving offline deletions, and measure latency, battery, CPU and large-library cost. History currently retains 500 distinct pages per profile; retention beyond that is a separate scope decision.
6. Complete the synthetic-data acceptance matrix above before a production installation.
