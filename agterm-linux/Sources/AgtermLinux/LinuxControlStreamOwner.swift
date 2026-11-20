import Foundation
import agtermCore

/// Keeps the Linux call sites on the shared bounded socket owner and its single-reader close contract.
final class LinuxControlStreamOwner: Sendable {
    private let owner: ControlStreamOwner

    init(descriptor: Int32, maxPending: Int = 64) {
        owner = ControlStreamOwner(descriptor: descriptor,
            limits: .init(maxLineBytes: PresentationCodec.maxFrameBytes, maxPendingLines: maxPending, writeTimeoutSeconds: 5))
    }

    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        owner.start(onLine: onLine, onClose: onClose)
    }

    func send(_ line: Data) -> Bool { owner.send(line) }
    func sendWaiting(_ line: Data) -> Bool { owner.sendWaiting(line) }
    func sendFinal(_ line: Data) -> Bool { owner.sendFinal(line) }
    func shutdown() { owner.shutdown() }
}
