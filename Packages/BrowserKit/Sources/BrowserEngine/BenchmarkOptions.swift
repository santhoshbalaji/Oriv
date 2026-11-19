#if os(macOS) && ORIV_BENCH
import Foundation
import WebKit

/// Only compiled into the optimized benchmark build.
public enum BenchmarkOptions {
    public static let disabled = Set((ProcessInfo.processInfo.environment["ORIV_BENCH_DISABLE"] ?? "").split(separator: ",").map(String.init))

    @MainActor private static var namesBySource: [String: String] = [:]

    @MainActor public static func noteScript(_ name: String, source: String) {
        namesBySource[source] = name
    }

    @MainActor public static func installedScripts(in controller: WKUserContentController) -> [[String: Any]] {
        controller.userScripts.map { script in
            ["name": namesBySource[script.source] ?? "unknown",
             "mainFrameOnly": script.isForMainFrameOnly,
             "time": script.injectionTime == .atDocumentStart ? "start" : "end"]
        }
    }
}
#endif
