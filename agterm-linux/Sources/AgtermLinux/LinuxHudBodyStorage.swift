import Foundation
import Glibc

enum LinuxHudBodyStorage {
    private static let directory: URL? = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-hud-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        let result = url.path.withCString { Glibc.mkdir($0, mode_t(S_IRWXU)) }
        return result == 0 ? url : nil
    }()

    static func path(for sessionID: UUID) -> String? {
        directory?.appendingPathComponent("\(sessionID.uuidString).txt").path
    }

    static func write(_ data: Data, to destinationPath: String) -> Bool {
        guard let directory,
              URL(fileURLWithPath: destinationPath).deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL else { return false }
        let temporary = directory.appendingPathComponent(".write-\(UUID().uuidString)")
        var descriptor = temporary.path.withCString {
            Glibc.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else { return false }
        var installed = false
        defer {
            if descriptor >= 0 { _ = Glibc.close(descriptor) }
            if !installed { temporary.path.withCString { _ = Glibc.unlink($0) } }
        }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { return false }
                let written = Glibc.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard wroteAll else { return false }
        let closeResult = Glibc.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else { return false }
        guard temporary.path.withCString({ source in
            destinationPath.withCString { destination in Glibc.rename(source, destination) }
        }) == 0 else { return false }
        installed = true
        return true
    }
}
