enum GhosttyActionDecoder {
    static func utf8String(_ bytes: UnsafePointer<CChar>?, length: UInt) -> String? {
        guard length <= UInt(Int.max) else { return nil }
        guard length > 0 else { return "" }
        guard let bytes else { return nil }
        let buffer = UnsafeRawBufferPointer(start: bytes, count: Int(length))
        return String(bytes: buffer, encoding: .utf8)
    }
}
