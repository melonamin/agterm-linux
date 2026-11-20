import Foundation
import agtermCore

typealias LinuxPageServeStream = PageServeStream
typealias LinuxPageServeAdmission = PageServeAdmission
let pageLogger = LinuxStructuredLogger(category: "PageServe")

/// Reference ownership lets the reader, transfer worker, and main adapter share cancellation state.
final class LinuxPageLock<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}
