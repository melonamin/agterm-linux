/// ReorderDirection is a relative one-step reorder used by the control API/CLI (`--to`),
/// mirroring `session.go --to next|prev|first|last`. No wraparound.
public enum ReorderDirection: String, Sendable {
    case up, down, top, bottom
}

extension ReorderDirection {
    /// destinationIndex returns the post-removal insert index for a relative reorder within a list
    /// of `count` elements, or nil when the move is a no-op (already at the end in this direction).
    /// No wraparound.
    public func destinationIndex(from current: Int, count: Int) -> Int? {
        switch self {
        case .up: return current > 0 ? current - 1 : nil
        case .down: return current < count - 1 ? current + 1 : nil
        case .top: return current > 0 ? 0 : nil
        case .bottom: return current < count - 1 ? count - 1 : nil
        }
    }
}
