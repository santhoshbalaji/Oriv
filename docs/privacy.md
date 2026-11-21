# Privacy controls

Oriv uses the same privacy engine on Mac and iPhone. Settings → Privacy applies to the selected profile, including its private tabs. Existing users retain their saved Off/Balanced/Strict blocker choice. New settings default to link cleaning on, HTTPS upgrades on, native Global Privacy Control on where available, YouTube filtering on, and cookie-banner handling set to Reject. A saved cookie-banner Off or Hide choice is preserved.

Open **Site Privacy** from the Mac page menu or **Site Privacy & Settings** from the iPhone page menu. Each layer shows its effective setting, the blocker mode, and the bundled list version. Turn off one layer for the current exact hostname, or choose **Site broken? Turn protections off for this site**. Changes offer a reload; choosing Later preserves the current form. Reset Site Protections removes overrides. Off in profile settings takes priority over a site's switch. Scheme/port changes share an exception, while subdomains have separate exceptions. Private exceptions remain memory-only and are erased with the last private tab. The external-private context remains profile-less.

## Private tab isolation

**Isolate each private tab** is on by default on Mac and iPhone and applies to tabs opened after a setting change. The device-local setting applies to every profile and to external private browsing. New private tabs, duplicates and links explicitly opened in another tab by Oriv start with fresh, non-persistent cookies, local storage, IndexedDB, caches and service worker state.

WebKit-created windows, including sign-in popups and site links that request a new window, use their opener’s store to preserve login and opener behavior. The store lasts until the last tab in that group closes. Turn isolation off to let newly opened private tabs share one ephemeral store within their session. Closing the last tab using that store discards it. Private tabs stay out of saved sessions and Reopen Closed Tab.

Content blockers still apply in each tab. Oriv’s favicon requests use their own cookieless transport. Private icons stay in the session’s in-memory favicon cache. Explicitly saved downloads can remain on disk. More isolated tabs can increase WebKit memory use because they keep separate website state.

## Clean links

Copy Link, full-URL Copy in the address editor, and Share remove the original, conservative table of tracking keys below. Copy Original Link preserves the complete URL. Selection of ordinary text is unchanged. The same cleaned URL is carried by Handoff, Open on Device and outgoing continuity tab records. Local tab records keep their original URL. Cleaning needs no network request.

- Any `utm_*` key; `fbclid`, `gclid`, `dclid`, `msclkid`, `mc_eid`, `mc_cid`, `igshid`, `yclid`, `_hsenc`, `_hsmi`, `gbraid`, `wbraid`, `twclid`, `ttclid`, `li_fat_id`, `mkt_tok`, `vero_id`, `vero_conv`, `_gl`, `srsltid`, `igsh`, `oly_enc_id`, `oly_anon_id`, `irclickid`, `ysclid`, `_openstat`, `rb_clickid`, `s_cid`.
- `si` only on `youtu.be` and the explicitly listed YouTube hosts in `URLCleaner`. Generic `ref`, `source`, `id`, `si` and nested redirect values are retained elsewhere.

Names match case-insensitively after one percent decode; values are never decoded or changed. Remaining query bytes, ordering, duplicates, empty fields and fragments are preserved. URLs with credentials or known authentication/signature/payment keys and paths are left byte-for-byte unchanged, including `sig`, `signature`, `X-Amz-*`, `X-Goog-*`, tokens, OAuth code/state, SAML, expiry, checkout/login/oauth/callback paths and password-reset/magic-link paths. Unknown signing schemes cannot be inferred; Copy Original Link and the navigation-cleaning exception are the recovery paths.

Navigation cleaning applies to typed, pasted, external and eligible page-initiated loads. It can go directly to the single explicit HTTP(S) destination of known HTTPS wrappers at Google `/url`, Facebook `/l.php` and Instagram `l.instagram.com/`. The destination then receives the normal signed-link-aware cleanup. The wrapper's credentials, cookies and referrer headers do not accompany a replacement to another origin. Links such as `t.co` that require a network lookup follow their normal redirects. Copy and Share clean the link's own parameters and preserve wrapper destinations.

Page-initiated cleaning applies to main-frame GETs without a request body and excludes downloads, same-document changes, reloads and back/forward. Ordinary parameter cleaning skips exact same-host clicks. Known wrappers can unwrap from same-host pages such as Google search. Site exceptions apply to the source, wrapper and destination as applicable. Server redirects may already have contacted the original endpoint before WebKit reports them.

## Cookie banners

- **Reject** uses the bundled DuckDuckGo Autoconsent opt-out recipes. If no supported recipe succeeds, Oriv applies matching EasyList Cookie cosmetics in that document. Hidden banners leave consent undecided. Site Privacy can show that an opt-out recipe completed or that Oriv only hid a banner.
- **Hide** uses the EasyList Cookie network and cosmetic rules immediately. A bounded scroll fix releases recognized OneTrust and Cookiebot locks when their banners are hidden.
- **Off** leaves cookie banners and consent choices to the website.

Reject runs the bundled runtime in an isolated world in the main document and on recognized consent-service frame hosts. Oriv only asks Autoconsent to opt out and exposes a fixed set of reviewed page-world snippets for detection and rejection. Some consent actions are unsupported, including recipes that require other page-world code. Reject leaves cookie-list network rules inactive so CMP scripts can load and handle the user's opt-out. All three modes also apply in private tabs.

## Previews

Long-pressing a link on iPhone shows its title, domain and full cleaned URL in a native card. It creates no destination WebView or load. **Load Preview** explicitly creates a media-suspended tab using the source tab's existing data store and protections, with no history or continuity callbacks. This applies to regular, private and external-private tabs. Opening the link remains a separate action.

## HTTPS and GPC

Eligible public HTTP GET navigations use WebKit's `preferredHTTPSNavigationPolicy = .userMediatedFallbackToHTTP`. WebKit provides its first warning when the upgrade fails. If the user requests its HTTP fallback, Oriv cancels that unencrypted request and shows its native **This site doesn't support a secure connection** interstitial with **Continue to HTTP / Go Back**. The extra confirmation is deliberate: the public API has no callback for replacing WebKit's own warning. Continuing records an exact-host HTTPS exception in this profile (memory-only in private). It never grants a server-trust challenge or bypasses a certificate failure.

Localhost, single-label intranet names, `.local`, loopback, link-local, RFC1918/ULA addresses, carrier-grade NAT and known captive-connectivity endpoints are exempt. Other captive portals can use the explicit per-site HTTPS switch. HTTPS upgrades do not promise encrypted subresources or anonymity.

Native GPC is enabled by default on macOS/iOS 27+, using `WKWebpagePreferences.globalPrivacyControlEnabled`. The OS supplies `Sec-GPC: 1` and `navigator.globalPrivacyControl`. On OS 26 the UI reports unavailable and no header/property shim is installed. It is a preference signal, not a guarantee that a website honors it.

## Maintained rules and licences

See [ad-blocking.md](ad-blocking.md) and the bundled `Resources/Privacy/manifest.json` for exact rule counts, bytes, upstream commits and source digests. Updates arrive only with Oriv releases; the app never subscribes or phones home. Settings → Privacy → Acknowledgements includes attribution and full licences for EasyList (CC BY-SA 3.0) and Autoconsent (MPL-2.0).

The original MIT converter `scripts/convert-privacy-lists.py` fetches immutable EasyList/EasyPrivacy generated commits and the EasyList Cookie template/source commit. Cookie includes are bounded to repository paths and resolved at that commit. Input SHA-256 digests authenticate offline caches as well as downloads. `--source-dir` permits an offline rebuild. Output order and raw-deflate encoding are deterministic. `scripts/test-privacy-converter.py` validates counts, headers, hashes, splitting and exception ordering.

The supported subset covers network URL patterns, resource types, first/third party, domain restrictions and ordinary CSS hiding. Unsupported options, procedural cosmetics, scriptlets, remote executable replacements and regex filters are dropped with counted categories in the manifest. ABP separator/end-of-URL matching is expanded because WebKit has no regex disjunction. Network exceptions follow blocking rules in every chunk; cross-list EasyList/EasyPrivacy exceptions share the merged network component. Scoped cosmetic exceptions affect their matching selectors. The converter uses domain or top-URL exclusions and omits the affected selector when WebKit cannot express the scope difference. Unsupported mixed domain scopes are dropped, with counts.

Committed `.orivrules` resources contain an attribution/licence header and base64 raw-deflate JSON. This keeps the repository and application much smaller than the expanded JSON, while avoiding a networked build or requiring Python at app runtime. Runtime decoding verifies the byte count and SHA-256 before using the existing SHA-named WebKit compilation cache. Each chunk stays below 140,000 rules including repeated exceptions, under WebKit's approximately 150,000 limit. No profile/private hostname is encoded into the immutable cache.

Balanced uses EasyPrivacy and EasyList plus light generic class/ID cosmetics. Strict adds broader site/generic cosmetics, the original first-party analytics supplement, and the AdGuard list of disguised (CNAME-cloaked) trackers. The CNAME rules match requests to known tracker hosts even when WebKit treats them as first-party, and leave direct navigation available. The per-site ad-blocking exception also disables the CNAME rules. Strict prepares these rules in the background and uses about 139 MiB of extra compiled storage per device. Oriv removes that cache on the next launch when no saved profile uses Strict. Oriv refreshes the MIT-licensed host list with app updates using `CNAME_PIN` and `CNAME_SHA256` in the converter. Cookie-banner controls operate independently of the ad blocker.

## Forget This Site

Use Browser Actions or a Library history row on Mac, or the page menu on iPhone. The confirmation names the registrable domain using the bundled Mozilla Public Suffix List. Oriv removes WebKit website data and cookies, history, history-derived suggestions and frequent tiles, and site icon and tab snapshot caches in the current profile. Open tabs keep their identity and restart with a fresh browsing context. Bookmarks are preserved. The command is unavailable in private page menus.

Continuity shares a site history deletion marker through its existing encrypted records. It removes matching visits through the time of the request on updated devices, including visits that arrive from an offline device later. Website data is cleared on the device where you use the command.

Privacy protections do not provide complete ad removal, extension/scriptlet compatibility, IP masking or a block count. Lists can break sign-in, media and layouts; the site panel provides the recovery path without reloading a form automatically. New privacy preferences/exceptions remain local per profile; they are deliberately not added to the continuity preference schema in this batch.

### Site icons and address suggestions

Address queries stay on this device. The editor uses the current profile's local
bookmarks, visit frequency and visit time, plus open tabs. No remote suggestion
service or opt-in setting has been added. The Search row uses the profile's search
engine only after submission. Private queries see only private open tabs: neither
regular history/bookmarks nor any private visit history is exposed. Private
browsing never records visits or visit counts.

Site icons come from icon/apple-touch-icon links in an already loaded page, with
that site's `/favicon.ico` as a fallback. Looking up a saved-page icon never loads
that page or wakes a sleeping tab. There is no third-party favicon service. Icon
requests use the page’s WebKit User-Agent and an ephemeral URLSession with
cookies, credential storage and HTTP caching disabled. Icon URLs with embedded
credentials are rejected, authentication challenges are cancelled (with default
TLS certificate validation), and requests omit the page referrer. Requests and response
sizes are bounded. ImageIO decoding/downsampling happens off the main actor;
WebKit rasterizes SVG when ImageIO cannot decode it and the document permits it.

Each regular profile has a separate `Favicons` cache: SHA-256 origin filenames,
64 px PNGs, a seven-day lifetime, at most 256 files / 4 MiB. The session's memory
cache holds at most 128 decoded icons, with duplicate requests coalesced and at
most 16 loads in flight. Private icons use a separate memory namespace, never
read or write the disk cache, and are dropped when the last private tab closes or
the session shuts down. The Clear Browsing Data cache/site-data choices also clear the icon cache.
