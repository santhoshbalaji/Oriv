import Foundation

/// Distances use logical coordinates. Negative moves toward the next profile.
struct ProfileSwipe {
    enum Phase { case began, changed, ended, cancelled, momentum, unphased }
    enum Result: Equatable {
        case pass, swallow, track(CGFloat), settle(step: Int?)
    }
    private enum Axis { case idle, undecided, vertical, horizontal }
    private var axis = Axis.idle
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastTime: TimeInterval = 0
    private var initialOffset: CGFloat = 0
    private var swallowMomentum = false

    mutating func update(_ phase: Phase, dx: CGFloat, dy: CGFloat, at time: TimeInterval,
                         eligible: Bool, width: CGFloat, previous: Bool, next: Bool,
                         presentationOffset: CGFloat = 0) -> Result {
        switch phase {
        case .momentum: return swallowMomentum ? .swallow : .pass
        case .unphased:
            swallowMomentum = false
            return .pass
        case .began:
            axis = eligible ? .undecided : .vertical
            swallowMomentum = false
            x = 0; y = 0; velocity = 0; lastTime = time
            initialOffset = 0
        case .cancelled, .ended:
            guard axis == .horizontal else { axis = .idle; return .pass }
            axis = .idle
            let offset = x + initialOffset
            let step = offset < 0 ? 1 : -1
            let fast = time - lastTime <= 0.10 && abs(velocity) >= 600 && velocity * offset > 0
            let commit = eligible && phase == .ended && (step > 0 ? next : previous) &&
                (abs(offset) >= width * 0.5 || (abs(offset) >= width * 0.1 && fast))
            return .settle(step: commit ? step : nil)
        case .changed: break
        }
        guard width > 0, axis == .horizontal || axis == .undecided else { return .pass }
        if !eligible {
            let wasHorizontal = axis == .horizontal
            axis = .vertical
            return wasHorizontal ? .settle(step: nil) : .pass
        }
        x += dx; y += dy
        if time > lastTime && dx != 0 {
            velocity = dx / (time - lastTime)
            lastTime = time
        }
        if axis == .undecided {
            guard hypot(x, y) >= 6 else { return .pass }
            guard abs(x) > 2 * abs(y) else { axis = .vertical; return .pass }
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
}
