import Foundation

/// A conservative allowlist. Private interaction state is never exported to disk.
/// Keep private pages resident until ephemeral restoration has separate acceptance.
struct TabDiscardPolicy {
    static let idleInterval: TimeInterval = 10 * 60
    static let recentUseInterval: TimeInterval = 60
    var isSelected = false
    var isPinned = false
    var isPrivate = false
    var hasEditedFields = false
    var isLoading = false
    var isCapturing = false
    var hasDownloads = false
    var hasTerminated = false
    var hasRequestBody = false
    var committedMethod: String?
    var pendingMethod: String?

    var allowsDiscard: Bool {
        !isSelected && !isPinned && !isPrivate && !hasEditedFields && !isLoading &&
        !isCapturing && !hasDownloads && !hasTerminated && !hasRequestBody && committedMethod == "GET" &&
        (pendingMethod == nil || pendingMethod == "GET")
    }

    static func isOldEnough(lastUsed: TimeInterval, now: TimeInterval, underMemoryPressure: Bool) -> Bool {
        now - lastUsed >= (underMemoryPressure ? recentUseInterval : idleInterval)
    }
}
