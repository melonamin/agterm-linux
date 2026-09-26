import Foundation
import agtermCore

extension CommandRestore {
    static func parseProcCmdline(_ data: Data) -> [String]? {
        let parts = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return parts.isEmpty ? nil : parts
    }
}
