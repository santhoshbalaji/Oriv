import AppKit

/// Presents only the private scene's own window, after SwiftUI has attached it.
/// URL delivery can front the receiving regular scene later in the same launch.
@MainActor final class ExternalPrivateWindowPresenter {
    private let present: @MainActor (NSWindow) -> Void
    private let hasBlockingSheet: @MainActor (NSWindow) -> Bool
    private let now: @MainActor () -> TimeInterval
    private let center: NotificationCenter
    private weak var window: NSWindow?
    private var lastRequest: Int?
    private var generation = 0
    private var pending = false
    private var retryUntil: TimeInterval?
    private var retried = false
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         hasBlockingSheet: @escaping @MainActor (NSWindow) -> Bool = { target in
             target.attachedSheet != nil || NSApp.windows.contains {
                 $0.identifier?.rawValue == "browser" && $0.attachedSheet != nil
             }
         },
         present: @escaping @MainActor (NSWindow) -> Void = BackgroundUIMode.showExternalPrivateWindow) {
        self.center = center
        self.now = now
        self.hasBlockingSheet = hasBlockingSheet
        self.present = present
    }

    func request(_ request: Int, in window: NSWindow) {
        guard request > 0, lastRequest != request || self.window !== window else { return }
        cancel()
        self.window = window
        lastRequest = request
        pending = true
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let source = note.object as? NSWindow
                MainActor.assumeIsolated { self?.receive(name, from: source) }
            })
        }
        schedulePresentation()
    }

    func cancel() {
        generation += 1
        pending = false
        retryUntil = nil
        retried = false
        lastRequest = nil
        window = nil
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    private func receive(_ name: Notification.Name, from source: NSWindow?) {
        guard let source, let window else { return }
        if name == NSWindow.willCloseNotification, source === window {
            cancel()
        } else if name == NSWindow.didEndSheetNotification, pending {
            // AppKit posts this before detaching the sheet from its parent.
            schedulePresentation()
        } else if name == NSWindow.didBecomeKeyNotification,
                  source !== window, source.identifier?.rawValue == "browser",
                  let retryUntil, now() <= retryUntil, !retried {
            retried = true
            pending = true
            schedulePresentation()
        }
    }

    private func schedulePresentation() {
        let scheduledGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == scheduledGeneration, pending, let window,
                  !hasBlockingSheet(window) else { return }
            pending = false
            present(window)
            // One correction for the main scene's late presentation; later user
            // window selections must retain focus. Sheets defer the first show.
            if retryUntil == nil { retryUntil = now() + 0.5 }
        }
    }
}
