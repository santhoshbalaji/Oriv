# Browser profiles

Profiles separate tabs, website cookies/storage, preferences, bookmarks, history and downloads. Personal retains its existing paths and default WebKit store; additional profiles use stable UUID directories and named WebKit stores. Existing saved data belonging to removed features remains at those paths without being opened as an active service.

On Mac, use Profiles → Manage Profiles to create, rename, color, switch, archive or restore. Switching uses the current window and preserves live page/form state. Page operations and open dialogs block switching until finished. An inactive profile cannot present website dialogs or new popups. Archive is recoverable and refuses unfinished downloads or edited forms; Personal and the active profile cannot be archived.

On iPhone, Settings → Choose profile creates/selects local browser profiles. The older mobile profile-name list is read for compatibility, retaining its UUID and website storage. Controllers for unselected profiles are created only when needed for browsing or enabled continuity; sync leaves their WebViews inactive. Switching works offline without an account. Optional [browser continuity](browser-continuity.md) syncs profile identity, name, color and symbol, plus the profile’s regular browser records and preferences. Active selection and archive state remain device-local; a remote rename never switches the visible profile or joins website stores. Independently created names do not imply the same identity.

Private storage and permission exceptions belong to each profile's private session and disappear after its last private tab closes. macOS/iOS permissions and system Password AutoFill remain OS-level services. Browser profiles do not create separate operating-system accounts.

Tests cover browser records and recovery, separate WebKit cookies/stores, private-store identity, preserved forms, bookmark persistence and archive/restore. Physical-device, VoiceOver and real-provider acceptance remain separate from local regression tests.
