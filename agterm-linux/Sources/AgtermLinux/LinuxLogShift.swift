import Foundation
import agtermCore

/// Reconcile the upstream bounded log snapshots without moving a paused reader.
enum LinuxLogShift {
    struct Shift: Equatable {
        var dropped = 0
        var cut = false
        var replaced = false
    }
    static func shift(from old: LogTail.Snapshot?, stamp oldStamp: BoundedFile.FileStamp?, to new: LogTail.Snapshot?,
                      stamp newStamp: BoundedFile.FileStamp?) -> Shift {
        guard let old, let new, old != new || oldStamp != newStamp else { return Shift() }
        guard let oldStamp, let newStamp, oldStamp.device == newStamp.device, oldStamp.inode == newStamp.inode,
              newStamp.size >= oldStamp.size, new.startOffset >= old.startOffset else { return Shift(replaced: true) }
        let bytes = Array(old.text.utf8)
        let gone = min(new.startOffset - old.startOffset, bytes.count)
        guard gone < bytes.count else {
            let unterminated = bytes.last.map { $0 != lineFeed && $0 != carriageReturn } ?? false
            return Shift(dropped: lineBreaks(bytes, before: bytes.count) + (unterminated ? 1 : 0))
        }
        return Shift(dropped: lineBreaks(bytes, before: gone), cut: gone > 0 && !breakEnds(bytes, at: gone))
    }

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    // LF, CRLF and a lone CR are each one break, as the page counts lines once it normalizes them
    private static func lineBreaks(_ bytes: [UInt8], before end: Int) -> Int {
        (0..<end).reduce(0) { $0 + (bytes[$1] == lineFeed || isLoneCR(bytes, $1) ? 1 : 0) }
    }

    private static func breakEnds(_ bytes: [UInt8], at index: Int) -> Bool {
        bytes[index - 1] == lineFeed || isLoneCR(bytes, index - 1)
    }

    private static func isLoneCR(_ bytes: [UInt8], _ index: Int) -> Bool {
        bytes[index] == carriageReturn && (index + 1 == bytes.count || bytes[index + 1] != lineFeed)
    }

}
