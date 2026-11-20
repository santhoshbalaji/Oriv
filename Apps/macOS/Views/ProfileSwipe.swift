import Foundation

/// Distances use logical coordinates. Negative moves toward the next profile.
struct ProfileSwipe {
    enum Phase { case mayBegin, began, changed, stationary, ended, cancelled, momentum, momentumEnded, unphased }
    enum Result: Equatable {
        case pass, swallow, track(CGFloat), settle(step: Int?)
    }
    enum Axis { case idle, undecided, vertical, horizontal }
    private(set) var axis = Axis.idle
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var samples: [(time: TimeInterval, x: CGFloat)] = []
    private var lastDirection: CGFloat = 0
    private var lastMovement: TimeInterval = 0
    private var initialOffset: CGFloat = 0
    private var swallowMomentum = false
    private static let velocityWindow: TimeInterval = 0.08

    mutating func update(_ phase: Phase, dx: CGFloat, dy: CGFloat, at time: TimeInterval,
                         eligible: Bool, width: CGFloat, previous: Bool, next: Bool,
                         presentationOffset: CGFloat = 0) -> Result {
        switch phase {
        case .momentum: return swallowMomentum ? .swallow : .pass
        case .momentumEnded:
            defer { swallowMomentum = false }
            return swallowMomentum ? .swallow : .pass
        case .mayBegin, .unphased: return .pass
        case .began:
            axis = eligible ? .undecided : .vertical
            swallowMomentum = false
            x = 0
            y = 0
            samples = [(time, 0)]
            lastDirection = 0
            lastMovement = time
            initialOffset = 0
        case .cancelled, .ended:
            guard axis == .horizontal else { axis = .idle; return .pass }
            axis = .idle
            let step = x < 0 ? 1 : -1
            let velocity = recentVelocity
            let fast = time - lastMovement <= 0.16 && abs(velocity) >= 550 && velocity * x > 0 && lastDirection * x > 0
            // The previous animation's presentation offset is visual only.
            let commit = eligible && phase == .ended && (step > 0 ? next : previous) &&
                (abs(x) >= width * 0.30 || (abs(x) >= width * 0.10 && fast))
            return .settle(step: commit ? step : nil)
        case .changed, .stationary: break
        }
        guard width > 0, axis == .horizontal || axis == .undecided else { return .pass }
        if !eligible {
            let wasHorizontal = axis == .horizontal
            axis = .vertical
            return wasHorizontal ? .settle(step: nil) : .pass
        }
        if phase == .stationary { return axis == .horizontal ? .swallow : .pass }
        x += dx
        y += dy
        if abs(dx) >= 2 { lastDirection = dx }
        if dx != 0 {
            recordMovement(at: time)
        }
        if axis == .undecided {
            let horizontal = abs(x), vertical = abs(y)
            guard hypot(horizontal, vertical) >= 12 else { return .pass }
            if horizontal < 1.3 * vertical {
                // Give diagonal starts a chance to establish direction while
                // letting clearly vertical scrolls flow through immediately.
                if vertical >= 1.3 * horizontal || hypot(horizontal, vertical) >= 24 { axis = .vertical }
                return .pass
            }
            axis = .horizontal
            initialOffset = presentationOffset
            swallowMomentum = true
        }
        let offset = x + initialOffset
        if offset < 0 ? next : previous { return .track(min(width, max(-width, offset))) }
        let cap = width * 0.30
        let distance = abs(offset) * 0.55
        let resisted = cap * distance / (cap + distance)
        return .track(offset < 0 ? -resisted : resisted)
    }

    private mutating func recordMovement(at time: TimeInterval) {
        let cutoff = time - Self.velocityWindow
        if let last = samples.last, last.time < cutoff {
            // A delta after a pause has no defensible recent rate. Start the
            // next window here instead of projecting that delta over the pause.
            samples = [(time, x)]
        } else if samples.last?.time == time {
            samples[samples.count - 1].x = x
        } else {
            // Keep the sample preceding the cutoff for interpolation.
            while samples.count > 1 && samples[1].time <= cutoff { samples.removeFirst() }
            samples.append((time, x))
        }
        lastMovement = time
    }

    private var recentVelocity: CGFloat {
        guard let first = samples.first, let last = samples.last, first.time < last.time else { return 0 }
        let start = max(first.time, last.time - Self.velocityWindow)
        let second = samples[1]
        let fraction = (start - first.time) / (second.time - first.time)
        let startX = first.x + (second.x - first.x) * fraction
        return (last.x - startX) / (last.time - start)
    }
}
