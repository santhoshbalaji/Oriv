# Profile-switch focus regression

## Root cause

A swipe committed through `BrowserProfiles.select` with `focusLocation: false`. An empty destination still triggered an address-focus request because selection also checked for a missing URL. The keyed `BrowserWindow` rebuild independently requested address focus on appearance for empty tabs. On a loaded tab, a fresh `AddressField` coordinator could replay a previous ⌘L or ⌘T request retained by the destination controller and take focus from WebKit.

## Fix and behavior

Profile selection records the destination controller's current address request and suppresses start-page autofocus on the rebuilt window. The window applies focus once its destination view is attached. A fresh address command for that profile takes precedence.

| Action | Loaded destination | Empty destination |
| --- | --- | --- |
| Two-finger sidebar swipe, either direction | Selected tab's WebKit view | No focused control |
| Profile dots, ⌃1…⌃9, and ⌥⌘←/→ | Selected tab's WebKit view | No focused control |
| Profiles menu, sidebar profile picker, and Profile Manager selection | Selected tab's WebKit view | No focused control |

Continuity and external-tab moves use the same selection policy when they change profiles. An empty initial window still focuses the address field. ⌘L and ⌘T still request address focus. Tab and arrow navigation continue to govern keyboard focus rings.

## Verification

- Four new `ProfileSwipeWindowTests` cover routed swipes and synthetic clicks on the profile dots, each with loaded and empty destinations. They check the native first responder and field editor after the keyed rebuild, including a previously handled address-focus request. They also exercise the address and new-tab command handlers after switching.
- The focused window suite passed all six tests. The background audit recorded zero activation, frontmost, or display-overlap violations. Gesture verification used synthetic events in an offscreen window.
- `ORIV_BACKGROUND_UI=1 ./scripts/check-browser.sh` passed. The generic iOS simulator build, shared tests, Mac tests, public-safety, scope, contrast, signature, entitlement, and whitespace checks passed. The Mac suite passed 279 tests and skipped 11 existing background or opt-in cases. The shared suite skipped its opt-in history benchmark. The full Mac audit recorded zero activation, frontmost, or display-overlap violations.
