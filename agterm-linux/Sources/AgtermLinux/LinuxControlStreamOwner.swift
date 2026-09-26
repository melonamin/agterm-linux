import Foundation
import Glibc
import agtermCore

/// A bounded, bidirectional socket owner after a control request becomes a presentation stream.
final class LinuxControlStreamOwner: @unchecked Sendable {
    private let fd: Int32
    private let state = NSCondition()
    private var pending: [Data] = []
    private var closing = false
    private var descriptorClosed = false
    private let maxPending = 64

    init(descriptor: Int32) { fd = descriptor }

    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
        var writeTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
        let writerDone = DispatchSemaphore(value: 0)
        let writer = Thread { [self] in
            writeLoop()
            writerDone.signal()
        }
        writer.name = "agterm.presentation.socket.write"
        writer.start()
        let reader = Thread { [self] in
            readLoop(onLine: onLine)
            shutdown()
            writerDone.wait()
            state.lock()
            descriptorClosed = true
            _ = Glibc.close(fd)
            state.unlock()
            onClose()
        }
        reader.name = "agterm.presentation.socket.read"
        reader.start()
    }

    func send(_ line: Data) -> Bool {
        state.lock()
        defer { state.unlock() }
        guard !closing, pending.count < maxPending else { return false }
        pending.append(line)
        state.signal()
        return true
    }

    func shutdown() {
        state.lock()
        defer { state.unlock() }
        guard !closing else { return }
        closing = true
        state.broadcast()
        if !descriptorClosed { _ = Glibc.shutdown(fd, Int32(SHUT_RDWR)) }
    }

    private func readLoop(onLine: (Data) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Glibc.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                guard newline - buffer.startIndex <= PresentationCodec.maxFrameBytes else { return }
                onLine(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            guard buffer.count <= PresentationCodec.maxFrameBytes else { return }
        }
    }

    private func writeLoop() {
        while let line = nextLine() {
            guard write(line) else { shutdown(); return }
        }
    }

    private func nextLine() -> Data? {
        state.lock()
        defer { state.unlock() }
        while pending.isEmpty, !closing { state.wait() }
        return closing ? nil : pending.removeFirst()
    }

    private func write(_ line: Data) -> Bool {
        line.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            var offset = 0
            while offset < line.count {
                let count = Glibc.send(fd, base + offset, line.count - offset, Int32(MSG_NOSIGNAL))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
