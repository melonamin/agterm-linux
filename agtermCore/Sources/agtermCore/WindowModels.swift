import Foundation

/// Metadata for one window — a named bundle of workspaces + sessions in its own macOS window.
/// Named `WindowInfo`, not `Window`, to avoid clashing with the SwiftUI/AppKit `Window` types.
public struct WindowInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// Whether `name` is user-set; the title bar shows it only when true, so "window N" stays hidden.
    public var hasCustomName: Bool { !Self.isAutoName(name) }

    /// Whether `name` matches `WindowLibrary.defaultWindowName`: "window" plus a positive integer.
    public static func isAutoName(_ name: String) -> Bool {
        let parts = name.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "window", let number = Int(parts[1]), number >= 1 else { return false }
        return true
    }
}

/// One entry in the persisted window index: id, name, and open-at-quit, which drives reopen-all.
public struct WindowEntry: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var isOpen: Bool

    public init(id: UUID, name: String, isOpen: Bool) {
        self.id = id
        self.name = name
        self.isOpen = isOpen
    }
}

/// The persisted `windows.json` index: ordered window list plus frontmost id. `version` is independent of
/// `Snapshot.version` (the per-window file shape) so the two evolve separately.
public struct WindowsIndex: Codable, Equatable, Sendable {
    /// Bumped when the index shape changes; a mismatch makes the index count as absent.
    public static let currentVersion = 1

    public var version: Int
    public var frontmost: UUID?
    public var windows: [WindowEntry]

    public init(version: Int = WindowsIndex.currentVersion, frontmost: UUID? = nil, windows: [WindowEntry] = []) {
        self.version = version
        self.frontmost = frontmost
        self.windows = windows
    }
}
