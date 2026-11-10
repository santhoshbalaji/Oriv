import Foundation

/// A viewport boundary with a dead band and a short dwell. Negative offsets are
/// rubber banding, not a new page position. Call settle at the returned deadline.
public struct ChromeScrollState: Sendable {
    public static let enterOffset = 10.0
    public static let leaveOffset = 1.0
    public static let dwell = 0.08
    public private(set) var isScrolled = false
    public private(set) var deadline: TimeInterval?
    private var candidate = false
    public init() {}

    public mutating func update(offset: Double, at time: TimeInterval) {
        guard offset.isFinite, offset >= 0, time.isFinite else { return }
        let desired = isScrolled ? offset > Self.leaveOffset : offset > Self.enterOffset
        guard desired != isScrolled else { deadline = nil; return }
        if deadline == nil || candidate != desired {
            candidate = desired
            deadline = time + Self.dwell
        }
        settle(at: time)
    }

    public mutating func settle(at time: TimeInterval) {
        guard let deadline, time >= deadline else { return }
        isScrolled = candidate
        self.deadline = nil
    }
}

/// Require the same measured paint twice over a stability interval. The first
/// document sample is immediate; later samples never discard the cached value.
public struct ChromeStableValue<Value: Equatable & Sendable>: Sendable {
    public private(set) var value: Value?
    public private(set) var deadline: TimeInterval?
    private var candidate: Value?
    public let interval: TimeInterval
    public init(interval: TimeInterval = 0.12) { self.interval = interval }

    @discardableResult public mutating func update(_ next: Value, at time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        guard value != nil else { value = next; return true }
        guard next != value else { candidate = nil; deadline = nil; return false }
        if candidate != next {
            candidate = next; deadline = time + interval
        }
        guard let deadline, time >= deadline else { return false }
        value = next; candidate = nil; self.deadline = nil
        return true
    }
}
