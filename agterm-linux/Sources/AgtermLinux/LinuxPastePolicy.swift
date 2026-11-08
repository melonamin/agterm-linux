import Foundation
import agtermCore

extension ShellEscape {
    static func dropPayload(_ payload: String) -> String? {
        if let paths = PasteDecoder.posixPaths(fromURIList: payload) {
            return paths
        }
        return payload.isEmpty ? nil : payload
    }
}

enum PasteDecoder {
    static func posixPaths(fromURIList text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("file://") }) else { return nil }
        let paths = lines.compactMap { URL(string: $0)?.path }
        guard paths.count == lines.count else { return nil }
        return paths.joined(separator: " ")
    }
}
