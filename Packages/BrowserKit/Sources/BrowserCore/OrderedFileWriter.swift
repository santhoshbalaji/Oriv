import Foundation

/// Submission order is the write order, including synchronous durability barriers.
/// Work always runs on the worker queue (even when a caller waits on the main actor).
public final class OrderedFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "oriv.file-writer", qos: .utility)
    private var failure: (any Error)? // Accessed only on queue.

    public init() {}
    public func enqueue(_ operation: @escaping @Sendable () throws -> Void) {
        queue.async { [self] in
            do { try operation() } catch { failure = error }
        }
    }
    public func write(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { try checkFailure(); try operation(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func writeAndWait(_ operation: @escaping @Sendable () throws -> Void = {}) throws {
        let result = WriterResult()
        let work = DispatchWorkItem { [self] in
            result.value = Result { try checkFailure(); try operation() }
        }
        queue.async(execute: work)
        // Dispatch donates the waiter's priority to this barrier and its predecessors.
        work.wait()
        try result.value!.get()
    }
    public func flush() throws { try writeAndWait() }
    private func checkFailure() throws {
        if let error = failure { failure = nil; throw error }
    }
}

// Waiting on the work item transfers exclusive access from the queue to the waiter.
private final class WriterResult: @unchecked Sendable {
    var value: Result<Void, any Error>?
}

/// A store is accessed exclusively through this writer after it has been loaded.
public final class OrderedSessionWriter: @unchecked Sendable {
    private let store: any BrowserSessionStore
    private let writer = OrderedFileWriter()
    private let lock = NSLock()
    private var completed: [SessionWriteCompletion] = []
    public init(store: any BrowserSessionStore) { self.store = store }
    public func enqueue(_ snapshot: BrowserSnapshot, discardPrevious: Bool = false, didFinish: @escaping @Sendable () -> Void = {}) {
        writer.enqueue { [self] in
            let result = Result { try store.save(snapshot, discardPrevious: discardPrevious) }
            lock.lock(); completed.append(SessionWriteCompletion(snapshot: snapshot, result: result)); lock.unlock()
            didFinish()
            _ = try result.get()
        }
    }
    public func takeCompletions() -> [SessionWriteCompletion] {
        lock.lock(); defer { lock.unlock() }
        let results = completed; completed = []; return results
    }
    public func saveAndWait(_ snapshot: BrowserSnapshot, discardPrevious: Bool = false) throws {
        try writer.writeAndWait { [self] in _ = try store.save(snapshot, discardPrevious: discardPrevious) }
    }
    public func flush() throws { try writer.flush() }
}

public struct SessionWriteCompletion: Sendable {
    public let snapshot: BrowserSnapshot
    public let result: Result<Bool, any Error>
}
