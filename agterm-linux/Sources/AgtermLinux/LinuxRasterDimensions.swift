import Foundation

/// Budget preflight before GdkPixbuf sees compressed data. Some loaders (notably GIF) ignore requested
/// decode scaling and allocate their original canvas inside loader_write, before it returns to the caller.
enum LinuxRasterDimensions {
    static func read(_ data: Data, mime: String) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        func value(_ offset: Int, _ count: Int, bigEndian: Bool = false) -> Int? {
            guard offset >= 0, count <= bytes.count - offset else { return nil }
            let indices = bigEndian ? Array(offset..<(offset + count)) : Array((offset..<(offset + count)).reversed())
            return indices.reduce(0) { ($0 << 8) | Int(bytes[$1]) }
        }
        func pair(_ offset: Int, _ count: Int, bigEndian: Bool = false) -> (Int, Int)? {
            guard let width = value(offset, count, bigEndian: bigEndian),
                  let height = value(offset + count, count, bigEndian: bigEndian) else { return nil }
            return (width, height)
        }
        switch mime {
        case "image/png": return pair(16, 4, bigEndian: true)
        case "image/gif": return pair(6, 2)
        case "image/jpeg":
            var offset = 2
            while offset + 4 <= bytes.count {
                guard bytes[offset] == 0xFF else { return nil }
                offset += 1
                while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
                guard offset + 3 <= bytes.count else { return nil }
                let marker = bytes[offset]
                offset += 1
                if marker == 0xD9 || marker == 0xDA { return nil }
                if marker == 0x01 || (0xD0...0xD8).contains(marker) { continue }
                guard let length = value(offset, 2, bigEndian: true), length >= 2,
                      length <= bytes.count - offset else { return nil }
                if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                    guard length >= 7, let height = value(offset + 3, 2, bigEndian: true),
                          let width = value(offset + 5, 2, bigEndian: true) else { return nil }
                    return (width, height)
                }
                offset += length
            }
            return nil
        case "image/webp":
            var offset = 12
            while offset + 8 <= bytes.count {
                let kind = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
                guard let count = value(offset + 4, 4), count <= bytes.count - offset - 8 else { return nil }
                let start = offset + 8
                if kind == "VP8X", count >= 10, let size = pair(start + 4, 3) { return (size.0 + 1, size.1 + 1) }
                if kind == "VP8 ", count >= 10, let size = pair(start + 6, 2) { return (size.0 & 0x3FFF, size.1 & 0x3FFF) }
                if kind == "VP8L", count >= 5, bytes[start] == 0x2F, let packed = value(start + 1, 4) {
                    return ((packed & 0x3FFF) + 1, ((packed >> 14) & 0x3FFF) + 1)
                }
                offset += 8 + count + count % 2
            }
            return nil
        default: return nil
        }
    }
}
