import Foundation

enum LinuxSurfaceFailureKind: Sendable, Equatable {
    case glContext
    case creation
}

enum LinuxSurfaceFailureScope: Sendable, Equatable {
    case displayWide
    case surfaceLocal
}

struct LinuxSurfaceFailurePresentation: Sendable, Equatable {
    let scope: LinuxSurfaceFailureScope
    let message: String

    static func resolve(_ failure: LinuxSurfaceFailureKind, role: LinuxSurfaceRole) -> Self {
        switch failure {
        case .glContext:
            Self(
                scope: .displayWide,
                message: "Terminal rendering needs OpenGL.\n\nNo GL context is available — check your GPU " +
                    "drivers, or enable 3D acceleration if you're running in a VM."
            )
        case .creation:
            Self(
                scope: .surfaceLocal,
                message: "\(role.failureDisplayName) failed to start.\n\nThe terminal engine could not create " +
                    "this surface. Check the application log for font, renderer, configuration, or " +
                    "allocation diagnostics."
            )
        }
    }
}

/// Debug/AT-SPI-only failure injection. Requiring the smoke scenario marker keeps these values inert in
/// normal debug launches even if the failure variable leaks into a user's environment.
struct LinuxSurfaceFailureInjection: Sendable, Equatable {
    static let environmentKey = "AGTERM_ATSPI_SURFACE_FAILURE"

    static func failure(
        for role: LinuxSurfaceRole,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LinuxSurfaceFailureKind? {
        #if DEBUG
        guard environment["AGTERM_ATSPI_SCENARIO"] != nil,
              let request = environment[environmentKey] else { return nil }
        switch request {
        case "gl-context:\(role.failureInjectionName)": return .glContext
        case "creation:\(role.failureInjectionName)": return .creation
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

extension LinuxSurfaceRole {
    fileprivate var failureInjectionName: String {
        switch self {
        case .main: "main"
        case .split: "split"
        case .overlay: "overlay"
        case .scratch: "scratch"
        case .quick: "quick"
        }
    }

    fileprivate var failureDisplayName: String {
        switch self {
        case .main: "Main terminal"
        case .split: "Right terminal"
        case .overlay: "Overlay terminal"
        case .scratch: "Scratch terminal"
        case .quick: "Quick terminal"
        }
    }
}
