import CGtk

struct LinuxStructuredLogger {
    struct Record: Equatable, Sendable {
        let message: String
        let priority: String
        let domain: String
        let identifier: String
    }

    private static let messageKey: StaticString = "MESSAGE"
    private static let priorityKey: StaticString = "PRIORITY"
    private static let domainKey: StaticString = "GLIB_DOMAIN"
    private static let identifierKey: StaticString = "SYSLOG_IDENTIFIER"
    private static let noticePriority: StaticString = "5"
    private static let applicationIdentifier: StaticString = "agterm"
    // Swift's GLib importer does not expose the G_LOG_LEVEL_MESSAGE enum case.
    private static let messageLevel = GLogLevelFlags(rawValue: 1 << 5)

    let category: String

    static func noticeRecord(category: String, message: String) -> Record {
        Record(message: message, priority: "5", domain: category, identifier: "agterm")
    }

    func notice(_ message: String) {
        let record = Self.noticeRecord(category: category, message: message)
        record.message.withCString { messagePointer in
            record.domain.withCString { domainPointer in
                let fields = [
                    GLogField(key: Self.pointer(Self.messageKey), value: messagePointer, length: -1),
                    GLogField(key: Self.pointer(Self.priorityKey),
                              value: Self.pointer(Self.noticePriority), length: -1),
                    GLogField(key: Self.pointer(Self.domainKey), value: domainPointer, length: -1),
                    GLogField(key: Self.pointer(Self.identifierKey),
                              value: Self.pointer(Self.applicationIdentifier), length: -1),
                ]
                fields.withUnsafeBufferPointer {
                    g_log_structured_array(Self.messageLevel, $0.baseAddress, gsize($0.count))
                }
            }
        }
    }

    private static func pointer(_ string: StaticString) -> UnsafePointer<CChar> {
        UnsafeRawPointer(string.utf8Start).assumingMemoryBound(to: CChar.self)
    }
}
