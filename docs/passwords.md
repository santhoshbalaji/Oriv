# Apple Passwords in Oriv

## Fill on Mac

Focus a username or existing-password field. On macOS 27 with WebKit’s AutoFill scripting support, click the key inside the field. On macOS 26, or when WebKit lacks that glyph, click the highlighted toolbar key. The toolbar tooltip and page-menu command say **AutoFill from Passwords**. You can also choose **Edit → AutoFill Password…** or press **⌥⇧⌘P**.

Oriv checks the focused field, then requests WebKit’s native context menu at the selection. If the password action is available in that menu, Oriv invokes it. If macOS adds AutoFill during display, choose **AutoFill → Passwords…** in the menu. Authenticate with Touch ID or your Mac login password and choose the matching website and account. The picker can show the full list of passwords, so check the website and account before filling.

If Oriv cannot open the focused field’s context menu, it opens the guide with the manual steps. Control-click or right-click the field and choose **AutoFill → Passwords…**. WebKit and macOS handle selection and insertion. **Library → Password AutoFill Help…** also opens the guide, with a short hint while the key is available. **Manage Passwords…** opens Apple’s app for vault management.

In **System Settings → General → AutoFill & Passwords**, enable AutoFill and select Passwords. Turn on iCloud Passwords & Keychain if you want credentials on your other Apple devices.

## Fill on iPhone

Tap the key above the keyboard and choose the account from iOS AutoFill. The shipping app can show the generic picker with the full list. Passkeys for arbitrary websites require the applicable Apple-managed browser capability on each platform.

## Privacy and platform limits

Passwords stay with Apple Passwords. Oriv asks the operating system to fill the field. Oriv never sees, stores or sends your saved passwords. On Mac the isolated classifier inspects field type, autocomplete metadata and form structure. It reports the category of the focused field and its frame origin. It has no clipboard or network access in its implementation.

Private tabs can fill from Passwords. The site receives the credential you choose. Oriv offers neither saving nor generation in private tabs. Public macOS APIs do not let Oriv offer automatic password suggestions on focus, save or update website passwords, or suggest strong passwords. New-password and verification-code fields do not display Oriv’s saved-password affordance.

AppKit owns the menu and can change its placement, title or availability across macOS releases and languages. Oriv looks for an enabled **Passwords…** action in the context menu’s AutoFill submenu. The field context menu remains available where the site and system support it. Dispatching the action does not establish that the picker appeared or that a credential was inserted.

## Observed results

| Check | Result |
| --- | --- |
| Oriv 0.24.0 Mac, owner’s practice-page check | Focusing the username showed no suggestion. The native field context menu opened the full Passwords list after Touch ID. No save prompt appeared after login. |
| Oriv 0.24.0 Mac menu bar, owner’s check | Edit contained AutoFill. The submenu started empty and is populated by AppKit. |
| Oriv 0.24.0 iPhone, owner’s check | The keyboard showed the generic key. The picker offered the full list. |
| Oriv 0.24.0, passkeys on webauthn.io | The owner saw an error on both Mac and iPhone. |
| Phase 0 Mac probe on 27.0.1, off-screen | After WebKit focused the fixture password field and the submenu updated, **Passwords…** was present and disabled. No action was dispatched. |
| Phase 1 Mac classifier on 27.0.1 | The isolated world set WebKit’s credentials glyph in both regular and private tabs. This verifies glyph state. Authenticated insertion and foreground menu eligibility remain manual checks. |
| macOS 27.0.1 focused password field, off-screen context-menu probe | WebKit built Cut, Copy and Paste. AppKit separately built AutoFill with Contact…, Passwords… and Credit Card…. The probe suppressed menu display and dispatched no action. |

Verification-code AutoFill and site-matched suggestions with the iPhone browser entitlement still need device verification.

## Manual check

1. Open the development build in a regular window. In Apple Passwords, use a disposable entry for the practice site with the demo username and password printed on the page. [Practice login](https://the-internet.herokuapp.com/login)
2. Focus the password field. On macOS 27 look for the in-field key. On macOS 26 look for the highlighted toolbar key. Click the key once.
3. If the context menu opens, choose **AutoFill → Passwords…**. In the system picker, authenticate and select the entry for `the-internet.herokuapp.com`. Confirm the password field fills and submit the practice form.
4. Reload the practice page, focus the password field and repeat with **⌥⇧⌘P**. Repeat in a private tab and confirm the fill works there.
5. Record whether each entry point opens the picker, the native menu, or the help guide. If the guide opens, right-click the field and choose **AutoFill → Passwords…** to verify manual fill.
6. Remove the disposable entry after testing.

For local form checks, run `python3 scripts/qa-server.py` and use `http://localhost:8768`. The fixtures are `/login`, `/signup`, `/change-password`, `/otp`, `/login-2step` and `/passkey`. The latter uses a disposable WebAuthn credential and keeps its ID in page memory. Use a throwaway passkey, and remove it from the provider if creation succeeds.

## Sources

- [Apple Passwords setup](https://support.apple.com/120758)
- [Apple Password AutoFill](https://developer.apple.com/documentation/security/password-autofill)
- [Apple browser credential documentation](https://developer.apple.com/documentation/authenticationservices/password-use-in-web-browsers)
- [Browser public-key credential entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
- [WebKit isolated-world AutoFill configuration](https://developer.apple.com/documentation/webkit/wkcontentworld/configuration)
- [WebKit input glyph types](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/html/HTMLInputElement.idl)
