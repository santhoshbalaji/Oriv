# Oriv 0.16.0 history

Oriv 0.15.5 stores at most 500 distinct URLs in each profile’s session JSON.
WebKit records on finish and corrects late titles only for the newest history
row. The session supplies the same array to CloudKit and to the address index.

## Storage and migration

Each profile gets a sandboxed SQLite database beside its session. It holds one
row per visit, with URL, title, timestamp, visit weight and typed weight.
Legacy aggregates keep their original IDs, dates and counts. The newest
50,000 rows are retained per profile, including incoming shared rows. A
configurable count limit bounds storage while preserving infrequently used
history and all legacy dates. History searches and lists read bounded pages
ordered by date, and the start page reads a small recent slice.

Import runs once in a SQLite transaction, before the session and its backup
are rewritten or discarded. An interrupted cleanup can retry without
re-importing visits. Both apps use the same migration through BrowserSession.
Clear History deletes matching rows, invalidates suggestion data and clears
regular site icons. SQLite secure deletion removes deleted content from free
pages. Private sessions never open a profile history database.

## Recording and sharing

Main-frame HTTP(S) commits record the final server-redirect destination.
WebKit URL observation handles in-document changes once no provisional
navigation is active. A short trailing-edge debounce coalesces rapid URL
replacements. Title observation updates the active visit by ID. Failed loads,
HTTP error responses, downloads and non-web URLs are excluded. The local QA
fixture requires explicit per-session opt-in and stays out of production
history. Typed weight comes from address submission, attributed to its
committed destination.

Opt-in Continuity keeps the existing recent projection of up to 500 unique
main-frame destinations using the encrypted body on BrowserRecordV1.
Same-document visits, typed weights and older local visits stay on-device.
Incoming clear ranges erase matching local visits. Projection evictions
retain locally authored visits. An optional eviction marker in the encrypted
body distinguishes pruning by 0.16.0 clients from individual removal. Older
clients still read it as a tombstone. No CloudKit fields or record types change.

## Suggestions

The off-main address index seeds once from aggregated visits, then applies
URL-level changes after inserts, title corrections, removals and pruning.
Visits, typed weight and recency affect ranking within the existing match
tiers. Each query keeps a bounded top-k. Private matching receives only
private open tabs and has no history access. A release-mode 50,000-entry
benchmark covers broad prefixes, infix matches, rare terms and misses.
