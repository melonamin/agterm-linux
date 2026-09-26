import Foundation
import Glibc

enum AppImageChildEnvironment {
    static func sanitized(_ environment: [String: String]) -> [String: String] {
        guard let appDirectory = environment["APPDIR"],
              let libraryPath = environment["LD_LIBRARY_PATH"] else { return environment }

        let appDirectoryPath = URL(fileURLWithPath: appDirectory).standardizedFileURL.path
        let appDirectoryPrefix = appDirectoryPath.hasSuffix("/") ? appDirectoryPath : "\(appDirectoryPath)/"
        let remainingPaths = libraryPath
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0 != appDirectoryPath && !$0.hasPrefix(appDirectoryPrefix) }

        var result = environment
        if remainingPaths.isEmpty {
            result.removeValue(forKey: "LD_LIBRARY_PATH")
        } else {
            result["LD_LIBRARY_PATH"] = remainingPaths.joined(separator: ":")
        }
        return result
    }

    static func sanitizeCurrentProcess() {
        let environment = sanitized(ProcessInfo.processInfo.environment)
        if let libraryPath = environment["LD_LIBRARY_PATH"] {
            setenv("LD_LIBRARY_PATH", libraryPath, 1)
        } else {
            unsetenv("LD_LIBRARY_PATH")
        }
    }
}
