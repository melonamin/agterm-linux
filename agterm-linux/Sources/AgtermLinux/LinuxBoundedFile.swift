import Foundation
import Glibc

/// Judge and read the same open descriptor. Nonblocking open refuses FIFOs/devices without waiting;
/// the regular-file and byte-cap checks precede allocation and reading, as in the upstream host.
enum BoundedFile {
    enum Failure: Error, Sendable, Equatable {
        case unreadable
        case tooLarge
    }

    static func check(path: String, maxBytes: Int) -> Result<Void, Failure> {
        withDescriptor(path: path, maxBytes: maxBytes) { _, _ in .success(()) }
    }

    static func read(path: String, maxBytes: Int) -> Result<Data, Failure> {
        withDescriptor(path: path, maxBytes: maxBytes) { descriptor, size in
            var data = Data(count: size)
            var filled = 0
            while filled < size {
                let count = data.withUnsafeMutableBytes { buffer in
                    Glibc.read(descriptor, buffer.baseAddress! + filled, size - filled)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return .failure(.unreadable) }
                filled += count
            }
            return .success(data)
        }
    }

    private static func withDescriptor<T>(path: String, maxBytes: Int,
                                          _ body: (Int32, Int) -> Result<T, Failure>) -> Result<T, Failure> {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(.unreadable) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            return .failure(.unreadable)
        }
        guard info.st_size <= maxBytes else { return .failure(.tooLarge) }
        return body(descriptor, Int(info.st_size))
    }
}
