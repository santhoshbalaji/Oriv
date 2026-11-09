import SwiftUI

struct BrowserCommands: Commands {
    let controller: BrowserController
    var profiles: BrowserProfiles? = nil
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { openWindow(id: "browser"); controller.newTab() }.keyboardShortcut("t")
            Button("New Private Tab") { openWindow(id: "browser"); controller.newTab(isPrivate: true) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close") { controller.closeTabOrPanel() }.keyboardShortcut("w")
            Button("Reopen Closed Tab") { controller.session.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!controller.session.canReopenTab)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Page…") { openWindow(id: "browser"); controller.findRequest += 1 }.keyboardShortcut("f")
                .disabled(controller.session.selectedTab?.url == nil)
            Button("Find Next") { controller.findBackwards = false; controller.findNextRequest += 1 }.keyboardShortcut("g")
            Button("Find Previous") { controller.findBackwards = true; controller.findNextRequest += 1 }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(after: .undoRedo) {
            Button("Undo Remove Bookmark") { controller.session.undoBookmarkRemoval() }.disabled(!controller.session.canUndoBookmarkRemoval)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { controller.printPage() }.keyboardShortcut("p")
                .disabled(controller.session.selectedTab?.url == nil || controller.session.selectedTab?.isLoading == true)
            Button("Export as PDF…") { controller.exportPage(asPDF: true) }.disabled(controller.session.selectedTab?.url == nil || controller.isExportingPage)
            Button("Save Web Archive…") { controller.exportPage(asPDF: false) }.keyboardShortcut("s")
                .disabled(controller.session.selectedTab?.url == nil || controller.isExportingPage)
        }
        CommandMenu("Navigate") {
            Button("Open Location…") { openWindow(id: "browser"); controller.focusAddress() }.keyboardShortcut("l")
            Divider()
            Button("Back") { controller.session.selectedTab?.goBack() }.keyboardShortcut("[")
                .disabled(controller.session.selectedTab?.canGoBack != true)
            Button("Forward") { controller.session.selectedTab?.goForward() }.keyboardShortcut("]")
                .disabled(controller.session.selectedTab?.canGoForward != true)
            Button("Reload Page") { controller.session.selectedTab?.reload() }.keyboardShortcut("r")
                .disabled(controller.session.selectedTab?.url == nil)
            Button("Stop Loading") { controller.session.selectedTab?.stop() }.keyboardShortcut(".")
            Button("Reload Without Cache") { controller.session.selectedTab?.reloadFromOrigin() }.keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(controller.session.selectedTab?.url == nil)
            Divider()
            Button("Next Tab") { controller.session.selectRelativeTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { controller.session.selectRelativeTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Select Last Tab" : "Select Tab \(number)") { controller.session.selectNumberedTab(number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))))
            }
        }
        CommandMenu("Profiles") {
            if let profiles {
                ForEach(profiles.available) { profile in
                    Button(profile.name + (profile.id == profiles.active.id ? " ✓" : "")) { profiles.perform { try profiles.select(profile.id) } }
                }
                Divider()
                Button("Manage Profiles…") { openWindow(id: "browser"); profiles.showManager = true }
            }
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Read Page Text") { controller.openReader() }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(controller.session.selectedTab?.url == nil || controller.session.selectedTab?.isLoading == true || controller.isPreparingReader)
            Button("Zoom In") { controller.session.selectedTab?.zoomIn() }.keyboardShortcut("+")
            Button("Zoom Out") { controller.session.selectedTab?.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { controller.session.selectedTab?.resetZoom() }.keyboardShortcut("0")
        }
        CommandMenu("Library") {
            Button("Toggle Bookmark") { controller.saveCurrentPage() }.keyboardShortcut("d")
                .disabled(controller.session.selectedTab?.url == nil || controller.session.selectedTab?.isPrivate == true)
            Button("Bookmarks") { openWindow(id: "browser"); controller.library = .bookmarks }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button("History") { openWindow(id: "browser"); controller.library = .history }.keyboardShortcut("y")
            Button("Downloads") { openWindow(id: "browser"); controller.library = .downloads }.keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
            Button("Import Bookmarks…") { controller.importBookmarks() }
            Button("Export Bookmarks…") { controller.exportBookmarks() }.disabled(controller.savedBookmarks.isEmpty)
            Divider()
            Button("Password AutoFill Help…") { openWindow(id: "browser"); controller.passwordsGuideRequest += 1 }
            Button("Open Apple Passwords…") { ApplePasswords.open() }
            Divider()
            Button("Manage Website Data…") { controller.showWebsiteData = true }
            Button("Clear Browsing Data…") { controller.showClearBrowsingData = true }.keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
    }
}
