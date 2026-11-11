# Privacy controls

Oriv uses the same privacy engine on Mac and iPhone. Settings → Privacy applies to the selected profile, including its private tabs. Existing users retain their saved Off/Balanced/Strict blocker choice. New settings default to link cleaning on, HTTPS upgrades on, native Global Privacy Control on where available, and cookie-banner hiding off.

Open **Site Privacy** from the Mac page menu or **Site Privacy & Settings** from the iPhone page menu. Each layer shows its effective setting, the blocker mode, and the bundled list version. Turn off one layer for the current exact hostname, or choose **Site broken? Turn protections off for this site**. Changes offer a reload; choosing Later preserves the current form. Reset Site Protections removes overrides. Off in profile settings takes priority over a site's switch. Scheme/port changes share an exception, while subdomains have separate exceptions. Private exceptions remain memory-only and are erased with the last private tab. The external-private context keeps its existing profile-less ephemeral store and lifetime.

## Clean links

Copy Link, full-URL Copy in the address editor, and Share remove the original, conservative table of tracking keys below. Copy Original Link preserves the complete URL. Selection of ordinary text is unchanged. The same cleaned URL is carried by Handoff, Open on Device and outgoing continuity tab records. Local tab records keep their original URL. Cleaning needs no network request.

- Any `utm_*` key; `fbclid`, `gclid`, `dclid`, `msclkid`, `mc_eid`, `mc_cid`, `igshid`, `yclid`, `_hsenc`, `_hsmi`, `gbraid`, `wbraid`, `twclid`, `ttclid`, `li_fat_id`, `mkt_tok`, `vero_id`, `vero_conv`.
- `si` only on `youtu.be` and the explicitly listed YouTube hosts in `URLCleaner`. Generic `ref`, `source`, `id`, `si` and nested redirect values are retained elsewhere.

Names match case-insensitively after one percent decode; values are never decoded or changed. Remaining query bytes, ordering, duplicates, empty fields and fragments are preserved. URLs with credentials or known authentication/signature/payment keys and paths are left byte-for-byte unchanged, including `sig`, `signature`, `X-Amz-*`, `X-Goog-*`, tokens, OAuth code/state, SAML, expiry, checkout/login/oauth/callback paths and password-reset/magic-link paths. Unknown signing schemes cannot be inferred; Copy Original Link and the navigation-cleaning exception are the recovery paths. No redirect unwrapping or fragment stripping is performed.

Navigation cleaning applies before typed/pasted/external HTTP(S) loads, including external-private loads. For page-initiated navigation it cancels and reloads only a GET main-frame navigation to another hostname, preserving the supplied request's headers and request policy. It excludes bodies/streams, POST, subframes, same-document changes, reloads and back/forward traversal. A replacement guard and idempotent transformation prevent rewrite loops. An exact-host comparison is deliberately conservative about same-site detection; no guessed public-suffix table is used. Server redirects may already have contacted the original endpoint before WebKit reports them; this is not universal request interception.

## Previews

Long-pressing a link on iPhone shows its title, domain and full cleaned URL in a native card. It creates no destination WebView or load. **Load Preview** explicitly creates a media-suspended tab using the source tab's existing data store and protections, with no history or continuity callbacks. This applies to regular, private and external-private tabs. Opening the link remains a separate action.

## HTTPS and GPC

Eligible public HTTP GET navigations use WebKit's `preferredHTTPSNavigationPolicy = .userMediatedFallbackToHTTP`. WebKit provides its first warning when the upgrade fails. If the user requests its HTTP fallback, Oriv cancels that unencrypted request and shows its native **This site doesn't support a secure connection** interstitial with **Continue to HTTP / Go Back**. The extra confirmation is deliberate: the public API has no callback for replacing WebKit's own warning. Continuing records an exact-host HTTPS exception in this profile (memory-only in private). It never grants a server-trust challenge or bypasses a certificate failure.

Localhost, single-label intranet names, `.local`, loopback, link-local, RFC1918/ULA addresses, carrier-grade NAT and known captive-connectivity endpoints are exempt. Other captive portals can use the explicit per-site HTTPS switch. HTTPS upgrades do not promise encrypted subresources or anonymity.

Native GPC is enabled by default on macOS/iOS 27+, using `WKWebpagePreferences.globalPrivacyControlEnabled`. The OS supplies `Sec-GPC: 1` and `navigator.globalPrivacyControl`. On OS 26 the UI reports unavailable and no header/property shim is installed. It is a preference signal, not a guarantee that a website honors it.

## Maintained rules and licences

See [ad-blocking.md](ad-blocking.md) and the bundled `Resources/Privacy/manifest.json` for exact rule counts, bytes, upstream commits and source digests. Updates arrive only with Oriv releases; the app never subscribes or phones home. Settings → Privacy → Acknowledgements includes attribution, modifications and the full CC BY-SA 3.0 licence.

The original MIT converter `scripts/convert-privacy-lists.py` fetches immutable EasyList/EasyPrivacy generated commits and the EasyList Cookie template/source commit. Cookie includes are bounded to repository paths and resolved at that commit. Input SHA-256 digests authenticate offline caches as well as downloads. `--source-dir` permits an offline rebuild. Output order and raw-deflate encoding are deterministic. `scripts/test-privacy-converter.py` validates counts, headers, hashes, splitting and exception ordering.

The supported subset covers network URL patterns, resource types, first/third party, domain restrictions and ordinary CSS hiding. Unsupported options, procedural cosmetics, scriptlets, remote executable replacements and regex filters are dropped with counted categories in the manifest. ABP separator/end-of-URL matching is expanded because WebKit has no regex disjunction. Network exceptions follow blocking rules in every chunk; cross-list EasyList/EasyPrivacy exceptions share the merged network component. Scoped cosmetic exceptions conservatively disable cosmetics on the affected sites because WebKit cannot undo only one selector. They do not disable network filtering. Unsupported mixed domain scopes are dropped, with counts.

Committed `.orivrules` resources contain an attribution/licence header and base64 raw-deflate JSON. This keeps the repository and application much smaller than the expanded JSON, while avoiding a networked build or requiring Python at app runtime. Runtime decoding verifies the byte count and SHA-256 before using the existing SHA-named WebKit compilation cache. Each chunk stays below 140,000 rules including repeated exceptions, under WebKit's approximately 150,000 limit. No profile/private hostname is encoded into the immutable cache.

Balanced uses EasyPrivacy plus EasyList network filtering and light generic class/ID cosmetics. Strict adds broader site/generic cosmetics and the original first-party analytics supplement. Off remains available. Cookie hiding is a separate opt-in network/cosmetic pair. It **hides banners; it doesn't reject cookies**. Original scroll restoration only releases recognized OneTrust/Cookiebot lock classes after their banner is confirmed hidden; it performs no consent clicks or cookie writes and its observer is bounded.

Privacy protections do not provide complete ad removal, extension/scriptlet compatibility, IP masking or a block count. Lists can break sign-in, media and layouts; the site panel provides the recovery path without reloading a form automatically. New privacy preferences/exceptions remain local per profile; they are deliberately not added to the continuity preference schema in this batch.
