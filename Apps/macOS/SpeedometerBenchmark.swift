#if ORIV_BENCH
import AppKit
import BrowserEngine
import SwiftUI
import WebKit

@MainActor final class SpeedometerBenchmark: NSObject, WKScriptMessageHandler {
    private static let environment = ProcessInfo.processInfo.environment
    static let configured = environment["ORIV_BENCH_URL"] != nil
    static let profileDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Oriv-Bench-\(UUID())", isDirectory: true)

    private let url: URL
    private var result: [String: Any]?
    private let receivedResult = AsyncStream<Void>.makeStream()

    private init(url: URL) { self.url = url }

    static func run(profiles: BrowserProfiles) async {
        write("ORIV_BENCH_PID", ["pid": ProcessInfo.processInfo.processIdentifier])
        do {
            guard let value = environment["ORIV_BENCH_URL"], let url = URL(string: value),
                  url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
                throw Failure("Expected a loopback fixture URL")
            }
            let driver = SpeedometerBenchmark(url: url)
            try await driver.measure(profiles: profiles)
        } catch {
            write("ORIV_BENCH_ERROR", ["message": error.localizedDescription])
        }
        NSApp.terminate(nil)
    }

    private func measure(profiles: BrowserProfiles) async throws {
        let controller = profiles.controller
        let window: NSWindow?
        if BackgroundUIMode.isEnabled {
            let frame = NSRect(x: 0, y: 0, width: 1250, height: 820)
            let owned = BackgroundUIMode.Window(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            owned.isReleasedWhenClosed = false
            owned.contentView = NSHostingView(rootView: BrowserWindow(controller: controller, profiles: profiles)
                .browserAppearance(controller.appearance))
            BackgroundUIMode.show(owned)
            window = owned
        } else { window = nil }
        defer { window?.orderOut(nil); window?.close() }

        guard let tab = controller.session.selectedTab else { throw Failure("Browser has no selected tab") }
        let view = tab.webView
        let scripts = view.configuration.userContentController
        scripts.add(self, name: "orivBenchResult")
        defer { scripts.removeScriptMessageHandler(forName: "orivBenchResult") }
        scripts.addUserScript(WKUserScript(source: Self.reader, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        BenchmarkOptions.noteScript("result-reader", source: Self.reader)
        tab.navigate(to: url)

        var viewport: [String: Int]?
        let deadline = ContinuousClock.now + .seconds(75)
        while viewport == nil && ContinuousClock.now < deadline {
            if let error = tab.errorMessage { throw Failure(error) }
            if !view.isLoading, view.url?.path == url.path, view.window != nil {
                viewport = (try? await view.evaluateJavaScript("""
                    globalThis.benchmarkClient && document.querySelector('.start-tests-button')
                        ? { width: innerWidth, height: innerHeight } : null
                    """)) as? [String: Int]
            }
            if viewport == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let viewport else { throw Failure("Benchmark page did not load in a browser window") }
        let smoke = Self.environment["ORIV_BENCH_SMOKE"] == "1"
        if !smoke && ((viewport["width"] ?? 0) < 850 || (viewport["height"] ?? 0) < 650) {
            throw Failure("Speedometer needs a web viewport of at least 850 × 650. Resize the window or use a larger display.")
        }

        let installed = BenchmarkOptions.installedScripts(in: scripts)
        let rules = controller.session.adBlocker.installedRuleComponents(in: scripts)
        let started = ISO8601DateFormatter().string(from: .now)
        _ = try await view.evaluateJavaScript("document.querySelector('.start-tests-button').click()")
        // The page sends one result after completion. No JavaScript polling
        // or native probes run during the timed workload.
        for await _ in receivedResult.stream { break }
        guard var result, let score = result["score"] as? Double, score.isFinite, score > 0 else {
            throw Failure("Benchmark returned an invalid score")
        }
        result["started_at"] = started
        result["finished_at"] = ISO8601DateFormatter().string(from: .now)
        result["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        result["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
        result["disabled"] = BenchmarkOptions.disabled.sorted()
        result["scripts"] = installed
        result["content_rule_components"] = rules
        result["viewport"] = viewport
        if smoke {
            let audit = BackgroundUIMode.audit()
            result["background_ui"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(audit))
        }
        Self.write("ORIV_BENCH_RESULT", result)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard result == nil, message.frameInfo.isMainFrame, let sender = message.frameInfo.request.url,
              sender.scheme == url.scheme, sender.host == url.host, sender.port == url.port, sender.path == url.path,
              let payload = message.body as? [String: Any] else { return }
        result = payload
        receivedResult.continuation.yield(())
        receivedResult.continuation.finish()
    }

    private static func write(_ prefix: String, _ value: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("\(prefix) ".utf8) + json + Data("\n".utf8))
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static let reader = """
        (() => {
            const target = document.getElementById('result-number');
            if (!target) return;
            const observer = new MutationObserver(() => {
                const value = target.textContent.trim();
                if (!value) return;
                observer.disconnect();
                const client = globalThis.benchmarkClient;
                const allMetrics = client?.metrics ?? {};
                const metrics = Object.values(allMetrics).filter(
                    metric => !metric.parent && metric.children?.length && !metric.name.startsWith('Iteration-')
                );
                window.webkit.messageHandlers.orivBenchResult.postMessage({
                    score: Number(value) > 0 ? allMetrics.Score?.mean ?? Number(value) : null,
                    score_text: value,
                    iteration_scores: allMetrics.Score?.values ?? [],
                    suites: Object.fromEntries(metrics.map(metric => [metric.name, metric.mean]))
                });
            });
            observer.observe(target, { childList: true, characterData: true, subtree: true });
        })();
        """
}
#endif
