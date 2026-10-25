# Apple Passwords in Oriv

## Current native path

Control-click (or right-click) a username/password field in a webpage, then choose **AutoFill → Passwords…**. Authenticate in the macOS interface and choose the correct website/account. WebKit and macOS own the picker and insertion. Oriv preserves their native field context menu; there is no JavaScript credential bridge, clipboard intermediary, imported vault or password database.

The toolbar key button explains this workflow. Settings → Passwords includes setup guidance and a separate **Manage passwords…** command for opening Apple's app. That management command is not the filling mechanism.

Synthetic `/login` loopback fixtures exercise the native field menu in normal and private WKWebViews. Menu availability does not establish authenticated credential insertion, which remains a manual acceptance check. Earlier 0.4.0 wording saying all in-page AutoFill was unavailable was too broad.

## What the user needs

1. Enable AutoFill in **System Settings → General → AutoFill & Passwords**, with Passwords selected as a provider.
2. Store the login in Apple Passwords. Enable iCloud Passwords & Keychain if credentials should sync across Apple devices.
3. Unlock the system picker using Touch ID or the Mac login password. Confirm the website/account before filling.

No developer subscription, domain association or additional Oriv entitlement is needed for the verified native field-menu flow. Never send Mac passwords, Apple account passwords or private signing keys to the developer/chat.

## Deliberate boundaries

- This is user-invoked in-page filling, not Safari's automatic per-site suggestion dropdown or a custom injected key icon. Oriv does not implement automatic password generation/saving.
- A site can replace/suppress a native context menu; behavior also depends on macOS, field implementation and local AutoFill settings. The menu's presence alone does not prove a credential was inserted.
- Private browsing isolates browsing storage, not the operating system's user-authorized Passwords picker. Choosing a credential still gives the destination webpage the filled value.
- `ASAuthorizationPasswordProvider` is associated-domain credential sharing for app sign-in; it is not arbitrary access to the user's website vault.
- `com.apple.developer.web-browser.public-key-credential` is a separate Apple-managed capability for **passkeys/security keys**, not the permission for this password menu. To add that browser capability for distribution, Apple's documented process requires an organization Apple Developer Program account, an Account Holder request, Apple's approval and a properly provisioned signed build. A paid account by itself does not grant it.
- The current personal DMG is ad-hoc signed. Public distribution independently requires a suitable Developer ID identity and notarization.

## Sources checked

- [Apple Passwords setup](https://support.apple.com/120758)
- [Apple browser credential documentation](https://developer.apple.com/documentation/authenticationservices/password-use-in-web-browsers)
- [Browser public-key credential entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
- [Apple Password AutoFill](https://developer.apple.com/documentation/security/password-autofill)

SDK inspection: Xcode 27 public AuthenticationServices, AppKit and WebKit APIs. No private selector, KVC preference or undocumented entitlement is used. `WKContentWorldConfiguration.autofillScriptingEnabled` exposes scripting capabilities; it does not supply Apple's saved passwords. `ASCredentialDataManager.save(password:...)` is unavailable on macOS in this SDK.
