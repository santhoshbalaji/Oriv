import SwiftUI

struct BrowserCommands: Commands {
    let controller: BrowserController
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
            Divider()
            Button("Next Tab") { controller.session.selectRelativeTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { controller.session.selectRelativeTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { controller.session.selectedTab?.zoomIn() }.keyboardShortcut("+")
            Button("Zoom Out") { controller.session.selectedTab?.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { controller.session.selectedTab?.resetZoom() }.keyboardShortcut("0")
        }
        CommandMenu("Library") {
            Button("Save Page with Context…") { openWindow(id: "browser"); controller.saveCurrentPage() }.keyboardShortcut("d")
                .disabled(controller.session.selectedTab?.url == nil || controller.session.selectedTab?.isPrivate == true || controller.isCapturing)
            Button("Capture Page Again…") { openWindow(id: "browser"); controller.saveCurrentPage(forceCapture: true) }
                .disabled(controller.session.selectedTab?.url == nil || controller.session.selectedTab?.isPrivate == true || controller.isCapturing)
            Divider()
            Button("Workspace") { openWindow(id: "workspace") }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button("History") { openWindow(id: "browser"); controller.library = .history }.keyboardShortcut("y")
            Button("Downloads") { openWindow(id: "browser"); controller.library = .downloads }.keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
            Button("Password AutoFill Help…") { openWindow(id: "browser"); controller.passwordsGuideRequest += 1 }
            Button("Open Apple Passwords…") { ApplePasswords.open() }
        }
    }
}
