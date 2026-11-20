import Foundation
import XCTest

let webFixtureTimeoutScale: Double = {
    #if os(iOS)
    if let value = ProcessInfo.processInfo.environment["ORIV_CI_TIMEOUT_SCALE"],
       let scale = Double(value), (1...4).contains(scale) {
        return scale
    }
    #endif
    return 1
}()

func webFixtureTimeout(_ seconds: TimeInterval) -> TimeInterval {
    // Any callback can be the first one to reach a cold WebContent process.
    webFixtureTimeoutScale > 1 ? max(20, seconds) * webFixtureTimeoutScale : seconds
}

func logSlowWebWait(_ description: String, started: ContinuousClock.Instant,
                            timeout: TimeInterval, file: StaticString, line: UInt) {
    let elapsed = started.duration(to: .now)
    if webFixtureTimeoutScale > 1, elapsed > .seconds(timeout) {
        print("ORIV_SLOW_WEB_WAIT \(URL(fileURLWithPath: String(describing: file)).lastPathComponent):\(line) \(description) took \(elapsed) (local limit \(timeout)s)")
    }
}

@MainActor func eventually(_ description: String, timeout: TimeInterval = 5,
                           poll: Duration = .milliseconds(40), scaleForWebKit: Bool = false,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: @MainActor () async throws -> Bool) async throws {
    let started = ContinuousClock.now
    let limit = scaleForWebKit ? webFixtureTimeout(timeout) : timeout
    let deadline = started + .seconds(limit)
    while true {
        if try await predicate() {
            if scaleForWebKit { logSlowWebWait(description, started: started, timeout: timeout, file: file, line: line) }
            return
        }
        guard ContinuousClock.now < deadline else { break }
        try await Task.sleep(for: poll)
    }
    _ = try XCTUnwrap(nil as Bool?, "Timed out waiting for \(description) after \(limit)s", file: file, line: line)
}

@MainActor func waitForFixtureCondition(_ description: String, timeout: TimeInterval,
                                       file: StaticString = #filePath, line: UInt = #line,
                                       _ predicate: @MainActor () async throws -> Bool) async throws {
    try await eventually(description, timeout: timeout, scaleForWebKit: true, file: file, line: line, predicate)
}
