#if os(macOS)
import Foundation

/// One coalesced idle timer and pressure source per session. No system-wide
/// pressure is generated: tests inject events through receive(_:).
@MainActor final class TabReclamationMonitor {
    private final class Sources {
        var pressure: (any DispatchSourceMemoryPressure)?
        var timer: Timer?
        func cancel() { pressure?.cancel(); pressure = nil; timer?.invalidate(); timer = nil }
        deinit { cancel() }
    }
    private let sources = Sources()
    private var action: ((Bool) -> Void)?
    private var underPressure = false

    init(startSources: Bool = true, action: @escaping (Bool) -> Void) {
        self.action = action
        guard startSources else { return }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        sources.pressure = pressure
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.receive(self.sources.pressure?.data ?? [])
            }
        }
        pressure.resume()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        timer.tolerance = 15
        sources.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func receive(_ event: DispatchSource.MemoryPressureEvent) {
        if !event.intersection([.warning, .critical]).isEmpty { underPressure = true; action?(true) }
        // A coalesced recovery event must not leave the shorter deadline latched.
        if event.contains(.normal) { underPressure = false }
    }
    func poll() { action?(underPressure) }
    func stopSources() { sources.cancel() }
    func stop() { action = nil; stopSources() }
}
#endif
